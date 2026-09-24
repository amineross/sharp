#import "Internal.h"

@implementation SharpDisplayApp (Transport)
- (int)startNetworkThreads {
    if (sharp_net_ring_init(&_videoRing, SHARP_NET_RING_CAPACITY) != 0) {
        return -1;
    }
    if (sharp_net_ring_init(&_tileRing, SHARP_NET_RING_CAPACITY) != 0) {
        sharp_net_ring_destroy(&_videoRing);
        return -1;
    }
    struct timeval tv;
    memset(&tv, 0, sizeof(tv));
    tv.tv_usec = 100000;
    (void)setsockopt(_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    int flags = fcntl(_fd, F_GETFL, 0);
    if (flags >= 0) {
        (void)fcntl(_fd, F_SETFL, flags & ~O_NONBLOCK);
    }
    atomic_store_explicit(&_netThreadsRunning, 1u, memory_order_release);
    if (pthread_create(&_socketThread, NULL, sharp_socket_thread_main,
                       (__bridge void *)self) != 0) {
        atomic_store_explicit(&_netThreadsRunning, 0u, memory_order_release);
        sharp_net_ring_destroy(&_videoRing);
        sharp_net_ring_destroy(&_tileRing);
        return -1;
    }
    if (pthread_create(&_videoThread, NULL, sharp_video_thread_main,
                       (__bridge void *)self) != 0) {
        atomic_store_explicit(&_netThreadsRunning, 0u, memory_order_release);
        pthread_join(_socketThread, NULL);
        sharp_net_ring_destroy(&_videoRing);
        sharp_net_ring_destroy(&_tileRing);
        return -1;
    }
    if (pthread_create(&_tileThread, NULL, sharp_tile_thread_main,
                       (__bridge void *)self) != 0) {
        atomic_store_explicit(&_netThreadsRunning, 0u, memory_order_release);
        pthread_mutex_lock(&_videoRingLock);
        pthread_cond_broadcast(&_videoRingCond);
        pthread_mutex_unlock(&_videoRingLock);
        pthread_join(_socketThread, NULL);
        pthread_join(_videoThread, NULL);
        sharp_net_ring_destroy(&_videoRing);
        sharp_net_ring_destroy(&_tileRing);
        return -1;
    }
    _netThreadsStarted = 1u;
    return 0;
}

- (void)stopNetworkThreads {
    if (!_netThreadsStarted) {
        return;
    }
    atomic_store_explicit(&_netThreadsRunning, 0u, memory_order_release);
    pthread_mutex_lock(&_videoRingLock);
    pthread_cond_broadcast(&_videoRingCond);
    pthread_mutex_unlock(&_videoRingLock);
    pthread_mutex_lock(&_tileRingLock);
    pthread_cond_broadcast(&_tileRingCond);
    pthread_mutex_unlock(&_tileRingLock);
    pthread_join(_socketThread, NULL);
    pthread_join(_videoThread, NULL);
    pthread_join(_tileThread, NULL);
    sharp_net_ring_destroy(&_videoRing);
    sharp_net_ring_destroy(&_tileRing);
    _netThreadsStarted = 0u;
}

- (void)socketThreadMain {
    uint8_t buffer[SHTP_MAX_DATAGRAM];
    uint8_t batchBuffers[SHARP_RECVMSG_X_BATCH][SHTP_MAX_DATAGRAM];
    struct sockaddr_in batchPeers[SHARP_RECVMSG_X_BATCH];
    struct iovec batchIov[SHARP_RECVMSG_X_BATCH];
    sharp_msghdr_x_t batchMsgs[SHARP_RECVMSG_X_BATCH];
    int useRecvmsgX = _config.recvmsg_x;
    while (atomic_load_explicit(&_netThreadsRunning, memory_order_acquire)) {
        if (useRecvmsgX) {
            memset(batchMsgs, 0, sizeof(batchMsgs));
            memset(batchPeers, 0, sizeof(batchPeers));
            for (unsigned int i = 0; i < SHARP_RECVMSG_X_BATCH; i++) {
                batchIov[i].iov_base = batchBuffers[i];
                batchIov[i].iov_len = sizeof(batchBuffers[i]);
                batchMsgs[i].msg_name = &batchPeers[i];
                batchMsgs[i].msg_namelen = sizeof(batchPeers[i]);
                batchMsgs[i].msg_iov = &batchIov[i];
                batchMsgs[i].msg_iovlen = 1;
            }
            long received = syscall(SYS_recvmsg_x, _fd, batchMsgs,
                                    (unsigned int)SHARP_RECVMSG_X_BATCH, 0);
            if (received > 0) {
                atomic_fetch_add_explicit(&_recvmsgXBatches, 1u,
                                          memory_order_relaxed);
                atomic_fetch_add_explicit(&_recvmsgXPackets, (uint64_t)received,
                                          memory_order_relaxed);
                for (long i = 0; i < received; i++) {
                    if (batchMsgs[i].msg_datalen > 0 &&
                        batchMsgs[i].msg_datalen <= SHTP_MAX_DATAGRAM) {
                        [self handleNetworkDatagram:batchBuffers[i]
                                             length:batchMsgs[i].msg_datalen
                                               peer:&batchPeers[i]
                                            peerLen:batchMsgs[i].msg_namelen];
                    }
                }
                continue;
            }
            if (received < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                    continue;
                }
                if (errno == ENOSYS || errno == EINVAL || errno == ENOTSUP) {
                    atomic_fetch_add_explicit(&_recvmsgXFallbacks, 1u,
                                              memory_order_relaxed);
                    useRecvmsgX = 0;
                    continue;
                }
            }
        }

        struct sockaddr_in peer;
        socklen_t peerLen = sizeof(peer);
        ssize_t n = recvfrom(_fd, buffer, sizeof(buffer), 0,
                             (struct sockaddr *)&peer, &peerLen);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                continue;
            }
            if (!atomic_load_explicit(&_netThreadsRunning, memory_order_acquire)) {
                break;
            }
            continue;
        }
        [self handleNetworkDatagram:buffer length:(size_t)n peer:&peer peerLen:peerLen];
    }
}

- (void)handleNetworkDatagram:(const uint8_t *)buffer
                       length:(size_t)n
                         peer:(const struct sockaddr_in *)peer
                      peerLen:(socklen_t)peerLen {
        pthread_mutex_lock(&_stateLock);
        _senderAddr = *peer;
        _senderAddrLen = peerLen;
        _haveSenderAddr = YES;
        _netDrainCalls++;
        pthread_mutex_unlock(&_stateLock);

        shtp_header_t sh;
        memset(&sh, 0, sizeof(sh));
        int valid = 0;
        if ((size_t)n >= sizeof(sh)) {
            memcpy(&sh, buffer, sizeof(sh));
            shtp_header_wire_to_host(&sh);
            valid = shtp_header_is_valid(&sh, (size_t)n);
        }
        if (valid && sh.type == SHTP_PACKET_DATA &&
            sh.payload_type == SHTP_PAYLOAD_H264_REGION) {
            uint64_t arrivalSeq =
                atomic_fetch_add_explicit(&_arrivalCounter, 1u,
                                           memory_order_relaxed) + 1u;
            sharp_net_slot_t *slot = sharp_net_ring_acquire(&_videoRing);
            if (slot == NULL) {
                atomic_fetch_add_explicit(&_ringDropsVideo, 1u,
                                          memory_order_relaxed);
                return;
            }
            slot->len = (uint16_t)n;
            slot->arrival_seq = arrivalSeq;
            memcpy(slot->data, buffer, (size_t)n);
            sharp_net_ring_commit(&_videoRing);
            atomic_fetch_add_explicit(&_ringPacketsVideo, 1u,
                                      memory_order_relaxed);
            pthread_mutex_lock(&_videoRingLock);
            pthread_cond_signal(&_videoRingCond);
            pthread_mutex_unlock(&_videoRingLock);
            pthread_mutex_lock(&_tileRingLock);
            pthread_cond_signal(&_tileRingCond);
            pthread_mutex_unlock(&_tileRingLock);
        } else if (valid && sh.type == SHTP_PACKET_DATA &&
                   sh.payload_type == SHTP_PAYLOAD_SYNTH_CURSOR) {
            [self handleCursorDatagram:&sh payload:buffer + sizeof(sh)];
        } else if (valid && sh.type == SHTP_PACKET_PING &&
                   sh.payload_type == SHTP_PAYLOAD_CONTROL) {
            [self handlePingDatagram:&sh];
        } else {
            uint64_t arrivalSeq =
                atomic_fetch_add_explicit(&_arrivalCounter, 1u,
                                           memory_order_relaxed) + 1u;
            sharp_net_slot_t *slot = sharp_net_ring_acquire(&_tileRing);
            if (slot == NULL) {
                atomic_fetch_add_explicit(&_ringDropsTile, 1u,
                                          memory_order_relaxed);
                return;
            }
            slot->len = (uint16_t)n;
            slot->arrival_seq = arrivalSeq;
            memcpy(slot->data, buffer, (size_t)n);
            sharp_net_ring_commit(&_tileRing);
            atomic_fetch_add_explicit(&_ringPacketsTile, 1u,
                                      memory_order_relaxed);
            pthread_mutex_lock(&_tileRingLock);
            pthread_cond_signal(&_tileRingCond);
            pthread_mutex_unlock(&_tileRingLock);
            pthread_mutex_lock(&_videoRingLock);
            pthread_cond_signal(&_videoRingCond);
            pthread_mutex_unlock(&_videoRingLock);
        }
}

- (void)videoThreadMain {
    while (atomic_load_explicit(&_netThreadsRunning, memory_order_acquire) ||
           sharp_net_ring_peek(&_videoRing) != NULL) {
        sharp_net_slot_t *slot = sharp_net_ring_peek(&_videoRing);
        if (slot == NULL) {
            [self publishVideoArrivalWatermark];
            pthread_mutex_lock(&_videoRingLock);
            if (atomic_load_explicit(&_netThreadsRunning, memory_order_acquire) &&
                sharp_net_ring_peek(&_videoRing) == NULL) {
                pthread_cond_wait(&_videoRingCond, &_videoRingLock);
            }
            pthread_mutex_unlock(&_videoRingLock);
            continue;
        }
        uint64_t arrivalSeq = slot->arrival_seq;
        shtp_header_t sh;
        memcpy(&sh, slot->data, sizeof(sh));
        shtp_header_wire_to_host(&sh);
        if (shtp_header_is_valid(&sh, slot->len)) {
            [self handleVideoDatagram:&sh
                              payload:slot->data + sizeof(sh)
                          arrivalSeq:arrivalSeq];
        }
        sharp_net_ring_release(&_videoRing);
        atomic_store_explicit(&_videoProcessedThrough, arrivalSeq,
                              memory_order_release);
        [self publishVideoArrivalWatermark];
    }
}

- (void)tileThreadMain {
    while (atomic_load_explicit(&_netThreadsRunning, memory_order_acquire) ||
           sharp_net_ring_peek(&_tileRing) != NULL) {
        sharp_net_slot_t *slot = sharp_net_ring_peek(&_tileRing);
        if (slot == NULL) {
            [self publishTileArrivalWatermark];
            pthread_mutex_lock(&_tileRingLock);
            if (atomic_load_explicit(&_netThreadsRunning, memory_order_acquire) &&
                sharp_net_ring_peek(&_tileRing) == NULL) {
                pthread_cond_wait(&_tileRingCond, &_tileRingLock);
            }
            pthread_mutex_unlock(&_tileRingLock);
            continue;
        }
        uint64_t arrivalSeq = slot->arrival_seq;
        [self handleTileDatagram:slot->data
                          length:slot->len
                      arrivalSeq:arrivalSeq];
        sharp_net_ring_release(&_tileRing);
        atomic_store_explicit(&_stageTDrainedThrough, arrivalSeq,
                              memory_order_release);
        [self publishTileArrivalWatermark];
    }
}

- (void)handleTileDatagram:(const uint8_t *)buffer
                    length:(size_t)n
                arrivalSeq:(uint64_t)arrivalSeq {
    int patchedThisPacket = 0;
    shtp_header_t sh;
    memset(&sh, 0, sizeof(sh));
    if (n >= sizeof(sh)) {
        memcpy(&sh, buffer, sizeof(sh));
        shtp_header_wire_to_host(&sh);
    }
    pthread_mutex_lock(&_stateLock);
    if (shtp_header_is_valid(&sh,n) && sh.payload_type==SHTP_PAYLOAD_HYBRID_STATE) {
        [self handleVerifiedStateLocked:buffer+sizeof(sh) length:sh.payload_len];
        pthread_mutex_unlock(&_stateLock);return;
    }
    /* A delayed data packet cannot activate the legacy renderer before this
     * process has completed the verified session handshake. */
    if (!_verifiedReceiver && (sh.flags&SHTP_FLAG_VERIFIED_HYBRID)) {
        pthread_mutex_unlock(&_stateLock);return;
    }
    if (_verifiedReceiver && sh.type==SHTP_PACKET_BYE &&
        (!(sh.flags&SHTP_FLAG_VERIFIED_HYBRID) || sh.aux_time_ns!=_verifiedReceiver->session)) {
        pthread_mutex_unlock(&_stateLock);return;
    }
    if (_verifiedReceiver && sh.type!=SHTP_PACKET_BYE) {
        if (!(sh.flags&SHTP_FLAG_VERIFIED_HYBRID) || sh.aux_time_ns!=_verifiedReceiver->session ||
            sh.type!=SHTP_PACKET_DATA) {pthread_mutex_unlock(&_stateLock);return;}
        _verifiedTilePackets++;
        if(_verifiedDropTileEvery && _verifiedTilePackets%_verifiedDropTileEvery==0) {
            pthread_mutex_unlock(&_stateLock);return;
        }
        sharp_tile_dirty_bounds_t dirty;
        (void)sharp_tile_receiver_handle_datagram(&_receiver,buffer,n,&patchedThisPacket,&dirty);
        if(patchedThisPacket && dirty.valid)
            dirty_bounds_add(&_stagingDirtyBounds,dirty.x,dirty.y,dirty.w,dirty.h,_config.width,_config.height);
        pthread_mutex_unlock(&_stateLock);return;
    }
    uint64_t frameEndPacketsBefore = _receiver.stats.frame_end_packets;
    sharp_tile_dirty_bounds_t dirtyBounds;
    (void)sharp_tile_receiver_handle_datagram(&_receiver, buffer, n,
                                              &patchedThisPacket, &dirtyBounds);
    if (sh.type == SHTP_PACKET_FRAME_END &&
        (sh.flags & SHTP_FRAME_END_FLAG_MOTION_MASK) != 0 &&
        sh.payload_len == _motionMaskBytes &&
        n >= sizeof(sh) + sh.payload_len) {
        [self recordMotionMask:buffer + sizeof(sh)
                           bytes:sh.payload_len
                         frameId:sh.frame_id];
    }
    if (patchedThisPacket) {
        if (dirtyBounds.valid) {
            [self markDirtyRectX:dirtyBounds.x y:dirtyBounds.y
                              w:dirtyBounds.w h:dirtyBounds.h];
            if (_testCorruptNs != 0 && _testRepairNs == 0 &&
                _testCorruptTileId >= 0) {
                sharp_tile_rect_t testRect;
                if (sharp_tile_rect_for_id(
                        _receiver.fb.width, _receiver.fb.height,
                        (uint16_t)_testCorruptTileId, &testRect) == 0 &&
                    dirtyBounds.x < testRect.x + testRect.w &&
                    dirtyBounds.x + dirtyBounds.w > testRect.x &&
                    dirtyBounds.y < testRect.y + testRect.h &&
                    dirtyBounds.y + dirtyBounds.h > testRect.y &&
                    _receiver.tile_hashes[_testCorruptTileId] != 0) {
                    _testRepairNs = shtp_now_ns();
                    fprintf(stdout,
                            "m1-display-test-repair tile=%d latency_ms=%.3f\n",
                            _testCorruptTileId,
                            (double)(_testRepairNs - _testCorruptNs) /
                                1000000.0);
                    fflush(stdout);
                }
            }
        } else {
            [self markDirtyRectX:0 y:0 w:_receiver.fb.width
                              h:_receiver.fb.height];
        }
    }
    if (_receiver.stats.frame_end_packets != frameEndPacketsBefore) {
        uint32_t endedFrame = _receiver.stats.frame_end;
        uint16_t videoRegionMask =
            (sh.flags & SHTP_FRAME_END_FLAG_VIDEO_REGIONS)
                ? (uint16_t)sh.aux_time_ns
                : 0u;
        [self recordFrameEnd:endedFrame
              videoRegionMask:videoRegionMask
                   arrivalSeq:arrivalSeq
                     sendNs:_receiver.stats.frame_end_send_time_ns];
        BOOL videoRegionsValid = NO;
        sharp_video_frame_regions_t frameRegions =
            [self videoRegionsForFrame:endedFrame valid:&videoRegionsValid];
        if (videoRegionsValid) {
            for (uint8_t i = 0; i < frameRegions.count; i++) {
                if (frameRegions.ids[i] == SHARP_H264_FULLFRAME_ID) {
                    continue;
                }
                (void)[self sendMissingVsliceNacksForRegion:frameRegions.ids[i]
                                                  generation:endedFrame
                                                 includeTail:YES];
            }
        }
        (void)[self commitFrameBoundaryLocked:_latestFrameEnd
                               frameEndSendNs:_latestFrameEndSendNs];
    }
    if (_receiver.stats.have_bye && !_config.keep_open) {
        [self recordFrameEnd:_receiver.stats.final_frame
              videoRegionMask:0
                   arrivalSeq:arrivalSeq
                     sendNs:0];
    }
    pthread_mutex_unlock(&_stateLock);
}

- (void)drainSocket {
    uint8_t buffer[SHTP_MAX_DATAGRAM];
    uint32_t packetsThisDrain = 0;
    uint64_t drainStartNs = shtp_now_ns();
    int budgetYielded = 0;

    pthread_mutex_lock(&_stateLock);
    _netDrainCalls++;
    pthread_mutex_unlock(&_stateLock);
    for (;;) {
        if (packetsThisDrain >= _config.net_drain_packet_budget ||
            shtp_now_ns() - drainStartNs >= _config.net_drain_time_budget_ns) {
            pthread_mutex_lock(&_stateLock);
            _netDrainBudgetYields++;
            pthread_mutex_unlock(&_stateLock);
            budgetYielded = 1;
            break;
        }
        struct sockaddr_in peer;
        socklen_t peerLen = sizeof(peer);
        ssize_t n = recvfrom(_fd, buffer, sizeof(buffer), 0,
                             (struct sockaddr *)&peer, &peerLen);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                break;
            }
            perror("recv");
            break;
        }
        packetsThisDrain++;
        pthread_mutex_lock(&_stateLock);
        _senderAddr = peer;
        _senderAddrLen = peerLen;
        _haveSenderAddr = YES;
        pthread_mutex_unlock(&_stateLock);
        int patchedThisPacket = 0;
        shtp_header_t sh;
        memset(&sh, 0, sizeof(sh));
        int handledVideo = 0;
        if ((size_t)n >= sizeof(sh)) {
            memcpy(&sh, buffer, sizeof(sh));
            shtp_header_wire_to_host(&sh);
            if (shtp_header_is_valid(&sh, (size_t)n) &&
                sh.type == SHTP_PACKET_DATA &&
                sh.payload_type == SHTP_PAYLOAD_H264_REGION) {
                [self handleVideoDatagram:&sh
                                  payload:buffer + sizeof(sh)
                              arrivalSeq:0];
                handledVideo = 1;
            } else if (shtp_header_is_valid(&sh, (size_t)n) &&
                       sh.type == SHTP_PACKET_DATA &&
                       sh.payload_type == SHTP_PAYLOAD_SYNTH_CURSOR) {
                [self handleCursorDatagram:&sh payload:buffer + sizeof(sh)];
                handledVideo = 1;
            } else if (shtp_header_is_valid(&sh, (size_t)n) &&
                       sh.type == SHTP_PACKET_PING &&
                       sh.payload_type == SHTP_PAYLOAD_CONTROL) {
                [self handlePingDatagram:&sh];
                handledVideo = 1;
            }
        }
        if (!handledVideo && shtp_header_is_valid(&sh,(size_t)n) &&
            (sh.payload_type==SHTP_PAYLOAD_HYBRID_STATE || _verifiedReceiver ||
             (sh.flags&SHTP_FLAG_VERIFIED_HYBRID))) {
            [self handleTileDatagram:buffer length:(size_t)n arrivalSeq:0];
            handledVideo=1;
        }
        if (!handledVideo) {
            pthread_mutex_lock(&_stateLock);
            uint64_t frameEndPacketsBefore = _receiver.stats.frame_end_packets;
            sharp_tile_dirty_bounds_t dirtyBounds;
            (void)sharp_tile_receiver_handle_datagram(&_receiver, buffer, (size_t)n,
                                                      &patchedThisPacket, &dirtyBounds);
            if (sh.type == SHTP_PACKET_FRAME_END &&
                (sh.flags & SHTP_FRAME_END_FLAG_MOTION_MASK) != 0 &&
                sh.payload_len == _motionMaskBytes &&
                (size_t)n >= sizeof(sh) + sh.payload_len) {
                [self recordMotionMask:buffer + sizeof(sh)
                                   bytes:sh.payload_len
                                 frameId:sh.frame_id];
            }
            if (patchedThisPacket) {
                if (dirtyBounds.valid) {
                    [self markDirtyRectX:dirtyBounds.x y:dirtyBounds.y
                                      w:dirtyBounds.w h:dirtyBounds.h];
                } else {
                    [self markDirtyRectX:0 y:0 w:_receiver.fb.width
                                      h:_receiver.fb.height];
                }
            }
            if (_receiver.stats.frame_end_packets != frameEndPacketsBefore) {
                uint32_t endedFrame = _receiver.stats.frame_end;
                uint16_t videoRegionMask =
                    (sh.flags & SHTP_FRAME_END_FLAG_VIDEO_REGIONS)
                        ? (uint16_t)sh.aux_time_ns
                        : 0u;
                [self recordFrameEnd:endedFrame
                      videoRegionMask:videoRegionMask
                           arrivalSeq:0
                             sendNs:_receiver.stats.frame_end_send_time_ns];
                BOOL videoRegionsValid = NO;
                sharp_video_frame_regions_t frameRegions =
                    [self videoRegionsForFrame:endedFrame valid:&videoRegionsValid];
                if (videoRegionsValid) {
                    for (uint8_t i = 0; i < frameRegions.count; i++) {
                        if (frameRegions.ids[i] == SHARP_H264_FULLFRAME_ID) {
                            continue;
                        }
                        (void)[self sendMissingVsliceNacksForRegion:frameRegions.ids[i]
                                                          generation:endedFrame
                                                         includeTail:YES];
                    }
                }
                (void)[self commitFrameBoundaryLocked:_latestFrameEnd
                                       frameEndSendNs:_latestFrameEndSendNs];
            }
            pthread_mutex_unlock(&_stateLock);
        }
    }

    pthread_mutex_lock(&_stateLock);
    if (packetsThisDrain > _netDrainMaxPackets) {
        _netDrainMaxPackets = packetsThisDrain;
    }
    if (_receiver.stats.have_bye && !_config.keep_open) {
        [self recordFrameEnd:_receiver.stats.final_frame
              videoRegionMask:0
                   arrivalSeq:0
                     sendNs:0];
    }
    pthread_mutex_unlock(&_stateLock);
    if (budgetYielded && _netQueue != nil) {
        dispatch_async(_netQueue, ^{
          [self drainSocket];
        });
    }
}
@end
