#import "Internal.h"

@implementation SharpScreenSender (Hybrid)
- (void)sendVerifiedMessage:(sharp_hybrid_message_t *)message {
    if (message->kind==SHARP_HYBRID_MAP && (message->flags&SHARP_HYBRID_STATIC) &&
        _verifiedExitPending && _verifiedDropStaticMaps) {
        _verifiedDropStaticMaps--;fprintf(stdout,"verified-test drop_static_map=1 remaining=%u\n",_verifiedDropStaticMaps);return;
    }
    uint8_t packet[1200];
    size_t len = sharp_hybrid_encode(packet + SHTP_HEADER_BYTES,
                                     sizeof(packet) - SHTP_HEADER_BYTES, message);
    if (!len) return;
    shtp_header_t sh = {0};
    sh.magic=SHTP_MAGIC; sh.version=SHTP_VERSION; sh.header_bytes=SHTP_HEADER_BYTES;
    sh.type=SHTP_PACKET_DATA; sh.payload_type=SHTP_PAYLOAD_HYBRID_STATE;
    sh.payload_len=(uint32_t)len; sh.frame_id=message->frame; sh.send_time_ns=shtp_now_ns();
    pthread_mutex_lock(&_sendLock);
    sh.sequence=_sequence++; shtp_header_host_to_wire(&sh); memcpy(packet,&sh,sizeof(sh));
    (void)send(_fd,packet,sizeof(sh)+len,0);
    pthread_mutex_unlock(&_sendLock);
}

- (void)startVerifiedHybrid {
    _verifiedSource=calloc(1,sizeof(*_verifiedSource));
    if (!_verifiedSource || sharp_hybrid_source_init(_verifiedSource,_width,_height)!=0) {
        fprintf(stderr,"verified-hybrid allocation failed\n"); exit(1);
    }
    arc4random_buf(&_verifiedSession,sizeof(_verifiedSession));
    if (!_verifiedSession) _verifiedSession=1;
    if ([self ensureCleanupCapacity:_verifiedSource->total]!=0) exit(1);
    _verifiedDropStaticMaps=(uint32_t)env_double_or_default("SHARP_TEST_HYBRID_DROP_STATIC_MAPS",0);
    _frameId=1; _fullFrameEnabled=YES;
    atomic_store(&_verifiedPacingBps,(uint64_t)(_pacingMbps*1000000.0));
    _verifiedHandshakeStartNs=shtp_now_ns();
    _verifiedTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,_processingQueue);
    dispatch_source_set_timer(_verifiedTimer,dispatch_time(DISPATCH_TIME_NOW,0),10000000ULL,1000000ULL);
    __weak SharpScreenSender *weakSelf=self;
    dispatch_source_set_event_handler(_verifiedTimer,^{ [weakSelf verifiedMaintenance]; });
    dispatch_resume(_verifiedTimer);
    fprintf(stdout,"verified-hybrid enabled=1 session=%llu\n",_verifiedSession);
}

- (void)handleVerifiedMessage:(NSData *)data {
    sharp_hybrid_message_t m;
    if (sharp_hybrid_decode(&m,data.bytes,data.length)!=0 || m.session!=_verifiedSession ||
        m.width!=_width || m.height!=_height) return;
    if (m.kind==SHARP_HYBRID_OFFER) {
        if (_verifiedNonce!=m.nonce) {
            _verifiedReady=NO;
            _verifiedHandshakeStartNs=shtp_now_ns();
            _verifiedCommittedFrame=0;
            memset(_verifiedAcknowledged,0,sizeof(_verifiedAcknowledged));
            memset(_verifiedAttemptNs,0,sizeof(_verifiedAttemptNs));
            memset(_verifiedAttemptVersion,0,sizeof(_verifiedAttemptVersion));
            memset(_verifiedFirstAttemptNs,0,sizeof(_verifiedFirstAttemptNs));
        }
        _verifiedNonce=m.nonce; m.kind=SHARP_HYBRID_CONFIRM;
        [self sendVerifiedMessage:&m];
    } else if (m.kind==SHARP_HYBRID_READY && m.nonce==_verifiedNonce && m.nonce) {
        if (!_verifiedReady) {
            fprintf(stdout,"verified-hybrid ready=1\n"); fflush(stdout);
            _fullFrameForceKeyframe=YES;
        }
        _verifiedReady=YES;
    } else if (m.kind==SHARP_HYBRID_ACK && _verifiedReady && m.nonce==_verifiedNonce) {
        if (m.flags&SHARP_HYBRID_COMMITTED) _verifiedCommittedFrame=m.frame;
        if ((m.flags&SHARP_HYBRID_COMMITTED) && m.frame!=_verifiedLastCommitLogged && env_flag_enabled("SHARP_HYBRID_TRACE")) {
            _verifiedLastCommitLogged=m.frame;
            fprintf(stdout,"hybrid-commit frame=%u now_ns=%llu\n",m.frame,shtp_now_ns());
        }
        for (uint16_t i=0;i<m.count;i++) {
            uint32_t t=m.first+i, v=m.versions[i];
            if (v && (int32_t)(v-_verifiedAcknowledged[t])>0 &&
                (int32_t)(_verifiedSource->frame-v)>=0) _verifiedAcknowledged[t]=v;
        }
        if ((m.flags&SHARP_HYBRID_COMMITTED) && !_verifiedWantVideo &&
            m.frame==_verifiedTargetFrame && _verifiedExitPending) {
            _verifiedExitPending=NO;
            _fullFrameActive=NO;
            _fullFrameExits++;
            fprintf(stdout,"verified-hybrid exit_ack=1 frame=%u repair_ack_ms=%.3f\n",
                    m.frame,(shtp_now_ns()-_verifiedExitStartNs)/1e6); fflush(stdout);
        }
    }
}

- (void)submitVerifiedVideo:(CVPixelBufferRef)pixels {
    BOOL force=_fullFrameForceKeyframe || _h264HaveKeyframeRequest;
    BOOL submitted=[self encodeH264FullFrame:pixels frameId:_frameId forceKeyframe:force
                                     direct:_fullFrameDirectFeed sourceLocked:NO emitFrameEnd:YES];
    if (submitted && force) { _fullFrameForceKeyframe=NO; _h264HaveKeyframeRequest=NO; }
}

- (void)processVerifiedPixels:(CVPixelBufferRef)pixels now:(uint64_t)now {
    /* Existing motion can encode while exact tile comparisons run. A missing
     * or late map simply keeps the complete video visible for this frame. */
    BOOL submittedEarly=_verifiedWantVideo && _verifiedReady;
    if (submittedEarly) [self submitVerifiedVideo:pixels];
    if (CVPixelBufferLockBaseAddress(pixels,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess) {
        /* Never reuse a capture ID that may already belong to encoded video. */
        if (submittedEarly) _frameId++;
        return;
    }
    uint32_t repeated=0;
    uint32_t changed=sharp_hybrid_source_update(_verifiedSource,
        CVPixelBufferGetBaseAddress(pixels),(uint32_t)CVPixelBufferGetBytesPerRow(pixels),
        _frameId,now,&repeated);
    CVPixelBufferUnlockBaseAddress(pixels,kCVPixelBufferLock_ReadOnly);
    if (env_flag_enabled("SHARP_HYBRID_TRACE") && changed>=_verifiedSource->total/8)
        fprintf(stdout,"hybrid-change frame=%u tiles=%u now_ns=%llu\n",_frameId,changed,now);
    BOOL broadChange=changed>=MAX(8u,_verifiedSource->total/8u);
    if (repeated>=2 || broadChange) {
        _verifiedLastMotionNs=now;
        if (!_verifiedWantVideo) {
            _verifiedWantVideo=YES; _verifiedExitPending=NO;
            _fullFrameActive=YES; _fullFrameForceKeyframe=YES;
            _fullFrameEntries++;
            fprintf(stdout,"verified-hybrid video_enter=1 frame=%u\n",_frameId); fflush(stdout);
        }
    }
    _verifiedTargetFrame=_frameId;
    if (!submittedEarly && _verifiedWantVideo && _verifiedReady) [self submitVerifiedVideo:pixels];
    if (broadChange && !submittedEarly && _verifiedReady && _h264Session)
        VTCompressionSessionCompleteFrames(_h264Session,CMTimeMake(_frameId,MAX(_fps,1u)));
    _verifiedLastCaptureNs=shtp_now_ns();
    _stats.frames++; _sentFrames++;
    if (!_firstFrameNs) _firstFrameNs=now;
    _lastFrameNs=now;
    if (repeated>=2 || broadChange) _verifiedLastMotionNs=shtp_now_ns();
    [self verifiedMaintenance];
    _frameId++;
}

- (void)verifiedMaintenance {
    if (!_verifiedSource || atomic_load_explicit(&_txStopping,memory_order_acquire)) return;
    uint64_t now=shtp_now_ns();
    sharp_hybrid_message_t m={0};
    m.session=_verifiedSession; m.nonce=_verifiedNonce;
    m.width=_width; m.height=_height; m.total=_verifiedSource->total;
    if (!_verifiedReady) {
        if (now-_verifiedHandshakeStartNs>10000000000ULL) {
            fprintf(stderr,"verified-hybrid error=receiver-handshake-timeout; update both Sharp apps and check the Ethernet connection\n");
            exit(1);
        }
        if (now-_verifiedLastControlNs<100000000ULL) return;
        _verifiedLastControlNs=now; m.kind=SHARP_HYBRID_HELLO;
        [self sendVerifiedMessage:&m]; return;
    }
    /* Reconfirm the active receiver periodically. A delayed offer from an
     * earlier receiver process must not strand us on its obsolete nonce. */
    if (now-_verifiedLastControlNs>=1000000000ULL) {
        _verifiedLastControlNs=now; m.kind=SHARP_HYBRID_HELLO;
        [self sendVerifiedMessage:&m];
    }
    if (!_verifiedSource->frame) return;
    if (_verifiedWantVideo && _h264Session && _verifiedLastCaptureNs &&
        now-_verifiedLastCaptureNs>=40000000ULL && _verifiedLastFlushedFrame!=_verifiedSource->frame) {
        VTCompressionSessionCompleteFrames(_h264Session,CMTimeMake(_verifiedSource->frame,MAX(_fps,1u)));
        _verifiedLastFlushedFrame=_verifiedSource->frame;
    }
    if (_verifiedWantVideo && now-_verifiedLastMotionNs>=150000000ULL) {
        _verifiedWantVideo=NO; _verifiedExitPending=YES;
        _verifiedExitStartNs=now;
        /* A new capture ID makes the immutable STATIC decision distinct from
         * the last VIDEO manifest, even when SCK supplies only idle events. */
        _verifiedTargetFrame=_frameId++;
        _verifiedSource->frame=_verifiedTargetFrame;
        fprintf(stdout,"verified-hybrid exit_pending=1 frame=%u\n",_verifiedTargetFrame); fflush(stdout);
    }
    m.kind=SHARP_HYBRID_MAP; m.frame=_verifiedTargetFrame;
    m.flags=_verifiedWantVideo?0:SHARP_HYBRID_STATIC;
    /* Full maps are cheap and self-contained. Repeat during idle until and
     * after acknowledgement so an isolated lost transition cannot stick. */
    uint64_t mapInterval=(_verifiedCommittedFrame==_verifiedTargetFrame && !_verifiedWantVideo)
        ? 1000000000ULL : 50000000ULL;
    if (_verifiedLastMapFrame!=m.frame || now-_verifiedLastMapNs>=mapInterval) {
        for (uint32_t first=0;first<m.total;first+=SHARP_HYBRID_CHUNK_TILES) {
            m.first=(uint16_t)first; m.count=(uint16_t)MIN(SHARP_HYBRID_CHUNK_TILES,m.total-first);
            memcpy(m.versions,_verifiedSource->versions+first,4u*m.count);
            [self sendVerifiedMessage:&m];
        }
        _verifiedLastMapFrame=m.frame; _verifiedLastMapNs=now;
    }
    const char *dumpDir=getenv("SHARP_TEST_HYBRID_SOURCE_DIR");
    if (dumpDir && _verifiedLastDumpFrame!=_verifiedTargetFrame &&
        (_verifiedTargetFrame%30==0 || !_verifiedWantVideo)) {
        char path[4096];snprintf(path,sizeof(path),"%s/source-%06u.ppm",dumpDir,_verifiedTargetFrame);
        sharp_framebuf_t fb={.width=_width,.height=_height,.stride=_width*4u,.pixels=_verifiedSource->pixels};
        if(sharp_framebuf_write_ppm(&fb,path)==0) _verifiedLastDumpFrame=_verifiedTargetFrame;
    }
    uint16_t selected[SHARP_HYBRID_MAX_TILES],count=0;
    uint32_t limit=_verifiedWantVideo?128u:m.total;
    uint32_t outstanding=0,overdue=0;
    for (uint32_t t=0;t<m.total;t++) {
        if (_verifiedAcknowledged[t] && (int32_t)(_verifiedAcknowledged[t]-_verifiedSource->versions[t])>=0) continue;
        if (_verifiedAttemptVersion[t]!=_verifiedSource->versions[t]) continue;
        outstanding++;
        if (_verifiedFirstAttemptNs[t] && now-_verifiedFirstAttemptNs[t]>250000000ULL) overdue++;
    }
    /* Receiver acknowledgements govern the rate. Back off when a substantial
     * fraction of current tile versions remain unacknowledged, then ramp back
     * gradually. Keep headroom for video and cap bursts in the TX pacer. */
    if (_pacingMbps>120 && now-_verifiedPacingAdjustNs>=500000000ULL) {
        uint64_t rate=atomic_load(&_verifiedPacingBps),ceiling=(uint64_t)(_pacingMbps*1000000.0);
        if (overdue>=MAX(16u,outstanding/4u)) rate=MAX(120000000ULL,rate*3/4);
        else if (!overdue) rate=MIN(ceiling,rate+30000000ULL);
        atomic_store(&_verifiedPacingBps,rate);_verifiedPacingAdjustNs=now;
    }
    for (uint32_t scanned=0;scanned<m.total && count<limit;scanned++) {
        uint32_t t=_verifiedNextTile++%m.total;
        if (_verifiedAcknowledged[t] && (int32_t)(_verifiedAcknowledged[t]-_verifiedSource->versions[t])>=0) continue;
        if (_verifiedWantVideo && now-_verifiedSource->changed_ns[t]<60000000ULL) continue;
        if (_verifiedAttemptVersion[t]==_verifiedSource->versions[t] &&
            _verifiedAttemptNs[t] && now-_verifiedAttemptNs[t]<120000000ULL) continue;
        selected[count++]=(uint16_t)t;
    }
    if (!count) return;
    screen_tx_frame_job_t *job=calloc(1,sizeof(*job)+(size_t)count*sizeof(job->tiles[0]));
    if (!job) return;
    job->frame_id=_verifiedSource->frame; job->enqueue_ns=now;
    job->tile_count=count; job->expected_patches=count; job->refine_tiles=count;
    for (uint16_t i=0;i<count;i++) {
        uint16_t t=selected[i]; screen_tx_tile_t *tile=&job->tiles[i];
        tile->tile_id=t; tile->kind=SCREEN_TX_TILE_REFINEMENT;
        sharp_tile_rect_for_id(_width,_height,t,&tile->rect);
        for(uint32_t y=0;y<tile->rect.h;y++)
            memcpy(tile->bgra+(size_t)y*tile->rect.w*4u,
                   _verifiedSource->pixels+((size_t)(tile->rect.y+y)*_width+tile->rect.x)*4u,
                   tile->rect.w*4u);
        if (_verifiedAttemptVersion[t]!=_verifiedSource->versions[t]) _verifiedFirstAttemptNs[t]=now;
        _verifiedAttemptNs[t]=now;
        _verifiedAttemptVersion[t]=_verifiedSource->versions[t];
    }
    [self enqueueTxFrameJob:job];
}
@end
