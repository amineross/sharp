#import "Internal.h"

@implementation SharpDisplayApp (Feedback)
- (void)sendVideoFeedbackKind:(sharp_video_feedback_kind_t)kind
                     regionId:(uint16_t)regionId
                   generation:(uint32_t)generation
                    firstChunk:(uint16_t)firstChunk
                 missingChunks:(uint16_t)missingChunks {
    if (regionId == SHARP_H264_FULLFRAME_ID) {
        if (kind == SHARP_VIDEO_FEEDBACK_VSLICE_NACK) {
            _h264FullFrameNacksSuppressed++;
            return;
        }
        if (kind == SHARP_VIDEO_FEEDBACK_IDR_REQ) {
            _h264FullFrameIdrSuppressed++;
            return;
        }
    }
    if (!_haveSenderAddr) {
        _h264FeedbackFailed++;
        return;
    }
    uint8_t packet[sizeof(shtp_header_t) + sizeof(sharp_video_feedback_t)];
    shtp_header_t sh;
    memset(&sh, 0, sizeof(sh));
    sh.magic = SHTP_MAGIC;
    sh.version = SHTP_VERSION;
    sh.header_bytes = SHTP_HEADER_BYTES;
    sh.type = SHTP_PACKET_STATS;
    sh.payload_type = SHTP_PAYLOAD_CONTROL;
    sh.sequence = 0;
    sh.frame_id = generation;
    sh.payload_len = sizeof(sharp_video_feedback_t);
    sh.send_time_ns = shtp_now_ns();
    sharp_video_feedback_t feedback;
    memset(&feedback, 0, sizeof(feedback));
    feedback.magic = SHARP_VIDEO_FEEDBACK_MAGIC;
    feedback.kind = (uint16_t)kind;
    feedback.region_id = regionId;
    feedback.generation = generation;
    feedback.missing_chunks = missingChunks;
    feedback.chunk_id = firstChunk;
    shtp_header_host_to_wire(&sh);
    sharp_video_feedback_host_to_wire(&feedback);
    memcpy(packet, &sh, sizeof(sh));
    memcpy(packet + sizeof(sh), &feedback, sizeof(feedback));
    ssize_t sent = sendto(_fd, packet, sizeof(packet), 0,
                          (struct sockaddr *)&_senderAddr, _senderAddrLen);
    if (sent == (ssize_t)sizeof(packet)) {
        _h264FeedbackSent++;
        sharp_h264_region_stats_t *stats =
            [self h264RegionStatsForRegion:regionId create:YES];
        if (kind == SHARP_VIDEO_FEEDBACK_VSLICE_NACK) {
            _h264VsliceNacksSent++;
            if (stats != NULL) {
                stats->nacks_sent++;
            }
        } else if (kind == SHARP_VIDEO_FEEDBACK_IDR_REQ) {
            _h264IdrRequestsSent++;
            if (stats != NULL) {
                stats->idr_requests_sent++;
            }
        } else if (kind == SHARP_VIDEO_FEEDBACK_KEYFRAME_REQUEST) {
            _h264KeyframeRequestsSent++;
        }
    } else {
        _h264FeedbackFailed++;
    }
}

- (void)sendNextTileDigest {
    enum { kMaxEntries = 96 };
    if (!_haveSenderAddr || _receiver.tile_count == 0 || _committedFrames < 2) {
        return;
    }
    uint8_t packet[sizeof(shtp_header_t) + sizeof(sharp_tile_digest_header_t) +
                   kMaxEntries * sizeof(sharp_tile_digest_entry_t)];
    sharp_tile_digest_entry_t entries[kMaxEntries];
    uint16_t count = 0;
    pthread_mutex_lock(&_stateLock);
    if (_verifiedReceiver) { pthread_mutex_unlock(&_stateLock); return; }
    uint32_t tileCount = _receiver.tile_count;
    while (count < kMaxEntries && count < tileCount) {
        uint16_t tileId = (uint16_t)_tileDigestNextTile;
        entries[count].tile_id = tileId;
        entries[count].reserved = 0;
        entries[count].hash =
            sharp_tile_receiver_tile_hash(&_receiver, tileId);
        uint8_t bit = (uint8_t)(1u << (tileId & 7u));
        BOOL releasing = _desiredMotionMaskValid && _activeMotionMaskValid &&
                         (_activeMotionMask[tileId >> 3] & bit) != 0 &&
                         (_desiredMotionMask[tileId >> 3] & bit) == 0;
        if (releasing) {
            uint32_t requiredGeneration = _motionMaskAtomicReleasePending
                ? _motionMaskAtomicReleaseGeneration
                : _motionMaskReleaseGeneration[tileId];
            uint32_t generation =
                sharp_tile_receiver_tile_generation(&_receiver, tileId);
            if ((int32_t)(generation - requiredGeneration) < 0) {
                /* Equal pixels still need a fresh generation to release video. */
                entries[count].reserved |= SHARP_TILE_DIGEST_REFRESH_REQUIRED;
            }
        }
        count++;
        _tileDigestNextTile = (_tileDigestNextTile + 1u) % tileCount;
    }
    pthread_mutex_unlock(&_stateLock);
    if (count == 0) {
        return;
    }
    shtp_header_t sh;
    memset(&sh, 0, sizeof(sh));
    sh.magic = SHTP_MAGIC;
    sh.version = SHTP_VERSION;
    sh.header_bytes = SHTP_HEADER_BYTES;
    sh.type = SHTP_PACKET_STATS;
    sh.payload_type = SHTP_PAYLOAD_TILE_DIGEST;
    sh.frame_id = _committedFrame;
    sh.payload_len = (uint32_t)(sizeof(sharp_tile_digest_header_t) +
                                count * sizeof(sharp_tile_digest_entry_t));
    sh.send_time_ns = shtp_now_ns();
    sharp_tile_digest_header_t digest;
    digest.magic = SHARP_TILE_DIGEST_MAGIC;
    digest.version = SHARP_TILE_DIGEST_VERSION;
    digest.entry_count = count;
    sharp_tile_digest_header_host_to_wire(&digest);
    shtp_header_host_to_wire(&sh);
    memcpy(packet, &sh, sizeof(sh));
    memcpy(packet + sizeof(sh), &digest, sizeof(digest));
    uint8_t *cursor = packet + sizeof(sh) + sizeof(digest);
    for (uint16_t i = 0; i < count; i++) {
        sharp_tile_digest_entry_host_to_wire(&entries[i]);
        memcpy(cursor, &entries[i], sizeof(entries[i]));
        cursor += sizeof(entries[i]);
    }
    size_t packetLen = (size_t)(cursor - packet);
    ssize_t sent = sendto(_fd, packet, packetLen, 0,
                          (struct sockaddr *)&_senderAddr, _senderAddrLen);
    if (sent == (ssize_t)packetLen) {
        _tileDigestPackets++;
        _tileDigestEntries += count;
    }
}

- (void)requestKeyframeForUndecodableVideoRegion:(uint16_t)regionId
                                      generation:(uint32_t)generation {
    sharp_video_feedback_kind_t kind =
        regionId == SHARP_H264_FULLFRAME_ID
            ? SHARP_VIDEO_FEEDBACK_KEYFRAME_REQUEST
            : SHARP_VIDEO_FEEDBACK_IDR_REQ;
    if (regionId == SHARP_H264_FULLFRAME_ID) {
        uint64_t now = shtp_now_ns();
        if (_h264FullFrameLastKeyframeRequestNs != 0 &&
            now - _h264FullFrameLastKeyframeRequestNs < 250000000ULL) {
            _h264FullFrameKeyframeRequestsSuppressed++;
            return;
        }
        _h264FullFrameLastKeyframeRequestNs = now;
    }
    [self sendVideoFeedbackKind:kind
                       regionId:regionId
                     generation:generation
                     firstChunk:0
                   missingChunks:0];
}

- (void)sendPresentReportFrameId:(uint32_t)frameId
                    contentSerial:(uint64_t)contentSerial
                    frameEndSendNs:(uint64_t)frameEndSendNs
                 finalPacketRxNs:(uint64_t)finalPacketRxNs
                decodeCallbackNs:(uint64_t)decodeCallbackNs
                         presentNs:(uint64_t)presentNs {
    if (!_haveSenderAddr) {
        _h264FeedbackFailed++;
        return;
    }
    uint8_t packet[sizeof(shtp_header_t) + sizeof(sharp_video_feedback_t)];
    shtp_header_t sh;
    memset(&sh, 0, sizeof(sh));
    sh.magic = SHTP_MAGIC;
    sh.version = SHTP_VERSION;
    sh.header_bytes = SHTP_HEADER_BYTES;
    sh.type = SHTP_PACKET_STATS;
    sh.payload_type = SHTP_PAYLOAD_CONTROL;
    sh.frame_id = frameId;
    sh.payload_len = sizeof(sharp_video_feedback_t);
    sh.send_time_ns = presentNs;
    sharp_video_feedback_t feedback;
    memset(&feedback, 0, sizeof(feedback));
    feedback.magic = SHARP_VIDEO_FEEDBACK_MAGIC;
    feedback.kind = SHARP_VIDEO_FEEDBACK_PRESENT_REPORT;
    feedback.version = SHARP_VIDEO_FEEDBACK_VERSION;
    feedback.generation = (uint32_t)(contentSerial & 0xffffffffu);
    feedback.frame_end_send_ns = frameEndSendNs;
    feedback.present_ns = presentNs;
    feedback.final_packet_rx_ns = finalPacketRxNs;
    feedback.decode_callback_ns = decodeCallbackNs;
    feedback.fresh_content_presents = _freshContentPresents;
    if (_latestVsyncNs != 0 && _latestVsyncPeriodNs != 0 &&
        (presentNs >= _lastVsyncFeedbackNs + SHARP_VSYNC_FEEDBACK_INTERVAL_NS ||
         _lastVsyncFeedbackNs == 0)) {
        feedback.vsync_ns = _latestVsyncNs;
        feedback.vsync_period_ns = _latestVsyncPeriodNs;
        _lastVsyncFeedbackNs = presentNs;
        _vsyncFeedbackReports++;
    }
    shtp_header_host_to_wire(&sh);
    sharp_video_feedback_host_to_wire(&feedback);
    memcpy(packet, &sh, sizeof(sh));
    memcpy(packet + sizeof(sh), &feedback, sizeof(feedback));
    ssize_t sent = sendto(_fd, packet, sizeof(packet), 0,
                          (struct sockaddr *)&_senderAddr, _senderAddrLen);
    if (sent == (ssize_t)sizeof(packet)) {
        _h264FeedbackSent++;
    } else {
        _h264FeedbackFailed++;
    }
}

- (void)handlePingDatagram:(const shtp_header_t *)sh {
    if (sh == NULL || !_haveSenderAddr) {
        return;
    }
    uint8_t packet[sizeof(shtp_header_t) + sizeof(uint64_t)];
    shtp_header_t pong;
    memset(&pong, 0, sizeof(pong));
    uint64_t rxNs = shtp_now_ns();
    uint64_t txNs = shtp_now_ns();
    pong.magic = SHTP_MAGIC;
    pong.version = SHTP_VERSION;
    pong.header_bytes = SHTP_HEADER_BYTES;
    pong.type = SHTP_PACKET_PONG;
    pong.payload_type = SHTP_PAYLOAD_CONTROL;
    pong.sequence = sh->sequence;
    pong.frame_id = sh->frame_id;
    pong.payload_len = sizeof(uint64_t);
    pong.send_time_ns = sh->send_time_ns;
    pong.aux_time_ns = rxNs;
    uint64_t payload = shtp_htonll(txNs);
    shtp_header_host_to_wire(&pong);
    memcpy(packet, &pong, sizeof(pong));
    memcpy(packet + sizeof(pong), &payload, sizeof(payload));
    (void)sendto(_fd, packet, sizeof(packet), 0,
                 (struct sockaddr *)&_senderAddr, _senderAddrLen);
}

- (void)handleCursorDatagram:(const shtp_header_t *)sh
                     payload:(const uint8_t *)payload {
    /* Arrival time before taking the lock, which rendering may hold. */
    uint64_t rxNs = shtp_now_ns();
    pthread_mutex_lock(&_stateLock);
    if (sh == NULL || payload == NULL ||
        sh->payload_len < sizeof(sharp_cursor_position_t)) {
        _receiver.stats.invalid_packets++;
        pthread_mutex_unlock(&_stateLock);
        return;
    }
    sharp_cursor_position_t cursor;
    memcpy(&cursor, payload, sizeof(cursor));
    uint32_t seq = ntohl(cursor.seq);
    if (_cursorVisible && seq <= _cursorSeq) {
        pthread_mutex_unlock(&_stateLock);
        return;
    }
    uint64_t sampleNs = shtp_ntohll(cursor.sample_time_ns);
    if (_cursorSampleNs != 0u && sampleNs > _cursorSampleNs) {
        _cursorPrevX = _cursorX;
        _cursorPrevY = _cursorY;
        _cursorPrevSampleNs = _cursorSampleNs;
    }
    _cursorSeq = seq;
    _cursorX = (int32_t)ntohl((uint32_t)cursor.x);
    _cursorY = (int32_t)ntohl((uint32_t)cursor.y);
    _cursorSampleNs = sampleNs;
    _cursorHotspotX = ntohs(cursor.hotspot_x);
    _cursorHotspotY = ntohs(cursor.hotspot_y);
    _cursorImageId = ntohl(cursor.image_id);
    if (_cursorImageId == 0u || _cursorImageId >= SHARP_CURSOR_IMAGE_MAX) {
        _cursorImageId = SHARP_CURSOR_IMAGE_ARROW;
    }
    _cursorVisible = (ntohl(cursor.flags) & 1u) != 0;
    _cursorPackets++;
    _cursorLastRxNs = rxNs;
    [self recordCursorSample:sampleNs receivedNs:rxNs];
    pthread_mutex_unlock(&_stateLock);
}

/* Caller holds _stateLock. */
- (void)recordCursorSample:(uint64_t)sampleNs receivedNs:(uint64_t)rxNs {
    if (_cursorHistoryCount > 0 &&
        sampleNs <= _cursorHistory[_cursorHistoryNewest].sample_ns) {
        return;
    }
    /* The smallest arrival-minus-sample offset approximates the clock
     * difference plus the fastest path. Let it rise by 1 ms per second so a
     * slower route or clock drift is followed instead of held forever. */
    int64_t offset = (int64_t)rxNs - (int64_t)sampleNs;
    if (_cursorHistoryCount == 0 || _cursorClockUpdatedNs == 0u) {
        _cursorClockOffsetNs = offset;
    } else {
        int64_t relaxed = _cursorClockOffsetNs +
                          (int64_t)((rxNs - _cursorClockUpdatedNs) / 1000u);
        _cursorClockOffsetNs = MIN(offset, relaxed);
    }
    _cursorClockUpdatedNs = rxNs;
    _cursorHistoryNewest = _cursorHistoryCount == 0
                               ? 0u
                               : (_cursorHistoryNewest + 1u) % SHARP_CURSOR_HISTORY;
    if (_cursorHistoryCount < SHARP_CURSOR_HISTORY) _cursorHistoryCount++;
    sharp_cursor_sample_t *sample = &_cursorHistory[_cursorHistoryNewest];
    sample->sample_ns = sampleNs;
    sample->x = _cursorX;
    sample->y = _cursorY;
    sample->image_id = _cursorImageId;
    sample->visible = _cursorVisible ? 1u : 0u;
}

/* Caller holds _stateLock. Fills position, shape and visibility for a frame
 * drawn at nowNs, a short playout delay behind the newest sample. */
- (void)interpolateCursorAt:(uint64_t)nowNs into:(sharp_cursor_snapshot_t *)cursor {
    if (_cursorHistoryCount == 0) return;
    if (_cursorPlayoutNs == 0u) {
        const char *env = getenv("SHARP_CURSOR_PLAYOUT_MS");
        double ms = env != NULL ? strtod(env, NULL) : 6.0;
        _cursorPlayoutNs = (uint64_t)(MAX(0.5, MIN(50.0, ms)) * 1000000.0);
    }
    int64_t target = (int64_t)nowNs - _cursorClockOffsetNs - (int64_t)_cursorPlayoutNs;
    const sharp_cursor_sample_t *newer = NULL;
    const sharp_cursor_sample_t *older = NULL;
    for (uint32_t i = 0; i < _cursorHistoryCount; i++) {
        uint32_t index = (_cursorHistoryNewest + SHARP_CURSOR_HISTORY - i) % SHARP_CURSOR_HISTORY;
        const sharp_cursor_sample_t *sample = &_cursorHistory[index];
        if ((int64_t)sample->sample_ns <= target) { older = sample; break; }
        newer = sample;
    }
    /* Before the oldest sample: show it. After the newest: hold it. */
    const sharp_cursor_sample_t *shown = older != NULL ? older : newer;
    double x = shown->x, y = shown->y;
    if (older != NULL && newer != NULL) {
        /* After a pause the previous sample can be far older than the move;
         * glide only across the last sampling interval, not the whole pause. */
        int64_t start = (int64_t)older->sample_ns;
        int64_t end = (int64_t)newer->sample_ns;
        if (end - start > 25000000) start = end - 8000000;
        if (target > start && end > start) {
            double t = (double)(target - start) / (double)(end - start);
            x = older->x + (newer->x - older->x) * t;
            y = older->y + (newer->y - older->y) * t;
        }
    }
    cursor->x = (int32_t)llround(MAX(0.0, MIN((double)_config.width - 1.0, x)));
    cursor->y = (int32_t)llround(MAX(0.0, MIN((double)_config.height - 1.0, y)));
    cursor->image_id = shown->image_id;
    cursor->visible = shown->visible;
}

- (uint16_t)sendMissingVsliceNacksForRegion:(uint16_t)regionId
                                  generation:(uint32_t)generation
                                 includeTail:(BOOL)includeTail {
    if (regionId == SHARP_H264_FULLFRAME_ID) {
        sharp_video_region_chunk_header_t missingHeader;
        uint16_t firstChunk = 0;
        uint16_t missingChunks = 0;
        if (!sharp_video_region_reassembler_next_missing(
                _videoReassembler, regionId, generation, includeTail ? 1 : 0,
                &missingHeader, &firstChunk, &missingChunks)) {
            return 0;
        }
        uint64_t now = shtp_now_ns();
        if (_h264FullFrameLastKeyframeRequestNs == 0 ||
            now - _h264FullFrameLastKeyframeRequestNs >= 250000000ULL) {
            _h264FullFrameLastKeyframeRequestNs = now;
            [self sendVideoFeedbackKind:SHARP_VIDEO_FEEDBACK_KEYFRAME_REQUEST
                               regionId:regionId
                             generation:generation
                             firstChunk:0
                           missingChunks:0];
        } else {
            _h264FullFrameKeyframeRequestsSuppressed++;
        }
        return 0;
    }
    uint16_t sent = 0;
    for (;;) {
        sharp_video_region_chunk_header_t missingHeader;
        uint16_t firstChunk = 0;
        uint16_t missingChunks = 0;
        if (!sharp_video_region_reassembler_next_missing(
                _videoReassembler, regionId, generation, includeTail ? 1 : 0,
                &missingHeader, &firstChunk, &missingChunks)) {
            break;
        }
        [self sendVideoFeedbackKind:SHARP_VIDEO_FEEDBACK_VSLICE_NACK
                           regionId:missingHeader.region_id
                         generation:missingHeader.generation
                         firstChunk:firstChunk
                       missingChunks:missingChunks];
        sent++;
    }
    return sent;
}

- (void)noteFullFrameUnrecoveredGeneration:(uint32_t)generation {
    if (_h264FullFrameUnrecoveredStreak < UINT32_MAX) {
        _h264FullFrameUnrecoveredStreak++;
    }
    _h264UnrecoveredGenerations++;
    if (_h264FullFrameUnrecoveredStreak < 2u) {
        return;
    }
    uint64_t now = shtp_now_ns();
    if (_h264FullFrameLastKeyframeRequestNs == 0 ||
        now - _h264FullFrameLastKeyframeRequestNs >= 250000000ULL) {
        _h264FullFrameLastKeyframeRequestNs = now;
        [self sendVideoFeedbackKind:SHARP_VIDEO_FEEDBACK_KEYFRAME_REQUEST
                           regionId:SHARP_H264_FULLFRAME_ID
                         generation:generation
                         firstChunk:0
                       missingChunks:2];
    } else {
        _h264FullFrameKeyframeRequestsSuppressed++;
    }
}
@end
