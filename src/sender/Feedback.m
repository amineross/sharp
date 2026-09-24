#import "Internal.h"

@implementation SharpScreenSender (Feedback)
- (void)sendClockPing {
    shtp_header_t sh;
    memset(&sh, 0, sizeof(sh));
    sh.magic = SHTP_MAGIC;
    sh.version = SHTP_VERSION;
    sh.header_bytes = SHTP_HEADER_BYTES;
    sh.type = SHTP_PACKET_PING;
    sh.payload_type = SHTP_PAYLOAD_CONTROL;
    sh.sequence = _sequence++;
    sh.frame_id = _frameId;
    sh.payload_len = 0;
    sh.send_time_ns = shtp_now_ns();
    shtp_header_host_to_wire(&sh);
    (void)send(_fd, &sh, sizeof(sh), 0);
}

- (void)handleClockPong:(const shtp_header_t *)sh payload:(const uint8_t *)payload {
    if (sh == NULL || payload == NULL || sh->payload_len < sizeof(uint64_t)) {
        return;
    }
    uint64_t t0 = sh->send_time_ns;
    uint64_t tRx = sh->aux_time_ns;
    uint64_t tTx = 0;
    memcpy(&tTx, payload, sizeof(tTx));
    tTx = shtp_ntohll(tTx);
    uint64_t t3 = shtp_now_ns();
    if (t0 == 0 || t3 < t0 || tTx < tRx) {
        return;
    }
    uint64_t senderDelta = t3 - t0;
    uint64_t receiverDelta = tTx - tRx;
    if (senderDelta < receiverDelta) {
        return;
    }
    uint64_t rtt = senderDelta - receiverDelta;
    uint32_t count = _clockRttSampleCount < SHARP_CLOCK_RTT_SAMPLES
                         ? _clockRttSampleCount
                         : SHARP_CLOCK_RTT_SAMPLES;
    if (count >= 3) {
        uint64_t median = percentile_u64(_clockRttSamples, count, 0.50);
        if (median > 0 && rtt > median * 3u) {
            return;
        }
    }
    _clockRttSamples[_clockRttSampleCount % SHARP_CLOCK_RTT_SAMPLES] = rtt;
    _clockRttSampleCount++;
    int64_t offset =
        (((int64_t)tRx - (int64_t)t0) +
         ((int64_t)tTx - (int64_t)t3)) /
        2;
    if (_clockRttNs == 0) {
        _clockOffsetNs = offset;
        _clockRttNs = rtt;
    } else {
        _clockOffsetNs =
            (int64_t)((double)_clockOffsetNs * 0.9 + (double)offset * 0.1);
        _clockRttNs =
            (uint64_t)((double)_clockRttNs * 0.9 + (double)rtt * 0.1);
    }
}

- (void)recordCaptureTimestampForFrameId:(uint32_t)frameId
                              timestampNs:(uint64_t)timestampNs {
    uint32_t slot = frameId % SHARP_CAPTURE_TIME_TRACK_SLOTS;
    _captureFrameIds[slot] = frameId;
    _captureFrameNs[slot] = timestampNs;
}

- (void)recordFrameTimingFrameId:(uint32_t)frameId
                         sourceNs:(uint64_t)sourceNs
                       callbackNs:(uint64_t)callbackNs
                       analyzerNs:(uint64_t)analyzerNs {
    pthread_mutex_lock(&_timingLock);
    sharp_frame_timing_t *timing =
        &_frameTimings[frameId % SHARP_FRAME_TIMING_SLOTS];
    memset(timing, 0, sizeof(*timing));
    timing->valid = 1u;
    timing->frame_id = frameId;
    timing->source_ns = sourceNs;
    timing->callback_ns = callbackNs;
    timing->analyzer_ns = analyzerNs;
    if (sourceNs != 0 && callbackNs >= sourceNs) {
        rolling_metric_add(&_rollingSourceToCallback, analyzerNs,
                           callbackNs - sourceNs);
    }
    if (callbackNs != 0 && analyzerNs >= callbackNs) {
        rolling_metric_add(&_rollingCallbackToAnalyzer, analyzerNs,
                           analyzerNs - callbackNs);
    }
    pthread_mutex_unlock(&_timingLock);
}

- (void)recordAnalyzerDoneForFrameId:(uint32_t)frameId
                           timestamp:(uint64_t)timestampNs {
    pthread_mutex_lock(&_timingLock);
    sharp_frame_timing_t *timing =
        &_frameTimings[frameId % SHARP_FRAME_TIMING_SLOTS];
    if (timing->valid && timing->frame_id == frameId) {
        timing->analyzer_done_ns = timestampNs;
    }
    pthread_mutex_unlock(&_timingLock);
}

- (void)recordVtSubmitForFrameId:(uint32_t)frameId timestamp:(uint64_t)timestampNs {
    pthread_mutex_lock(&_timingLock);
    sharp_frame_timing_t *timing =
        &_frameTimings[frameId % SHARP_FRAME_TIMING_SLOTS];
    if (timing->valid && timing->frame_id == frameId) {
        timing->vt_submit_ns = timestampNs;
        uint64_t startNs = timing->analyzer_ns;
        if (startNs != 0 && timestampNs >= startNs) {
            rolling_metric_add(&_rollingAnalyzerToSubmit, timestampNs,
                               timestampNs - startNs);
        }
    }
    pthread_mutex_unlock(&_timingLock);
}

- (void)recordVtCallbackForFrameId:(uint32_t)frameId timestamp:(uint64_t)timestampNs {
    pthread_mutex_lock(&_timingLock);
    sharp_frame_timing_t *timing =
        &_frameTimings[frameId % SHARP_FRAME_TIMING_SLOTS];
    if (timing->valid && timing->frame_id == frameId) {
        timing->vt_callback_ns = timestampNs;
        if (timing->vt_submit_ns != 0 && timestampNs >= timing->vt_submit_ns) {
            rolling_metric_add(&_rollingVtCallback, timestampNs,
                               timestampNs - timing->vt_submit_ns);
        }
    }
    pthread_mutex_unlock(&_timingLock);
}

- (void)recordFinalPacketSendForFrameId:(uint32_t)frameId
                              timestamp:(uint64_t)timestampNs {
    pthread_mutex_lock(&_timingLock);
    sharp_frame_timing_t *timing =
        &_frameTimings[frameId % SHARP_FRAME_TIMING_SLOTS];
    if (timing->valid && timing->frame_id == frameId &&
        timestampNs >= timing->final_packet_send_ns) {
        timing->final_packet_send_ns = timestampNs;
    }
    pthread_mutex_unlock(&_timingLock);
}

- (uint64_t)rollingPercentileForMetric:(const sharp_rolling_metric_t *)metric
                                  nowNs:(uint64_t)nowNs
                             percentile:(double)percentile
                                  count:(uint32_t *)countOut {
    sharp_rolling_metric_t snapshot;
    pthread_mutex_lock(&_timingLock);
    snapshot = *metric;
    pthread_mutex_unlock(&_timingLock);
    return rolling_metric_percentile(&snapshot, nowNs,
                                     SHARP_ROLLING_WINDOW_NS, percentile,
                                     countOut);
}

- (double)rollingRateForMetric:(const sharp_rolling_metric_t *)metric
                          nowNs:(uint64_t)nowNs {
    sharp_rolling_metric_t snapshot;
    pthread_mutex_lock(&_timingLock);
    snapshot = *metric;
    pthread_mutex_unlock(&_timingLock);
    return rolling_metric_rate(&snapshot, nowNs, SHARP_ROLLING_WINDOW_NS);
}

- (uint64_t)rollingSourceToPresentPercentileNs:(double)percentile
                                           nowNs:(uint64_t)nowNs {
    return [self rollingPercentileForMetric:&_rollingSourceToPresent
                                      nowNs:nowNs
                                 percentile:percentile
                                      count:NULL];
}

- (double)rollingReceiverFreshFpsNowNs:(uint64_t)nowNs {
    return [self rollingRateForMetric:&_rollingFreshReports nowNs:nowNs];
}

- (void)writeRollingStageTelemetryNowNs:(uint64_t)nowNs toFile:(FILE *)file {
    if (file == NULL) {
        return;
    }
#define SHARP_STAGE_P95_MS(metric)                                          \
    ((double)[self rollingPercentileForMetric:&(metric)                     \
                                           nowNs:nowNs                      \
                                      percentile:0.95                       \
                                           count:NULL] /                    \
     1000000.0)
    uint32_t sourceSamples = 0;
    (void)[self rollingPercentileForMetric:&_rollingSourceToPresent
                                      nowNs:nowNs
                                 percentile:0.95
                                      count:&sourceSamples];
    fprintf(file,
            "m1-screen-stages window_s=10 samples=%u "
            "source_to_callback_ms_p95=%.3f "
            "callback_to_analyzer_ms_p95=%.3f "
            "analyzer_to_submit_ms_p95=%.3f "
            "vt_callback_ms_p95=%.3f "
            "callback_to_final_send_ms_p95=%.3f "
            "final_send_to_present_ms_p95=%.3f "
            "final_rx_to_decode_ms_p95=%.3f "
            "decode_to_present_ms_p95=%.3f "
            "source_to_present_ms_p95=%.3f "
            "receiver_fresh_fps=%.2f source_timestamp_missing=%" PRIu64
            "\n",
            sourceSamples, SHARP_STAGE_P95_MS(_rollingSourceToCallback),
            SHARP_STAGE_P95_MS(_rollingCallbackToAnalyzer),
            SHARP_STAGE_P95_MS(_rollingAnalyzerToSubmit),
            SHARP_STAGE_P95_MS(_rollingVtCallback),
            SHARP_STAGE_P95_MS(_rollingCallbackToFinalSend),
            SHARP_STAGE_P95_MS(_rollingFinalSendToPresent),
            SHARP_STAGE_P95_MS(_rollingFinalRxToDecode),
            SHARP_STAGE_P95_MS(_rollingDecodeToPresent),
            SHARP_STAGE_P95_MS(_rollingSourceToPresent),
            [self rollingReceiverFreshFpsNowNs:nowNs],
            _sourceTimestampMissing);
#undef SHARP_STAGE_P95_MS
}

- (uint64_t)captureTimestampForFrameId:(uint32_t)frameId {
    uint32_t slot = frameId % SHARP_CAPTURE_TIME_TRACK_SLOTS;
    if (_captureFrameIds[slot] != frameId) {
        return 0;
    }
    return _captureFrameNs[slot];
}

- (void)handlePresentReport:(const sharp_video_feedback_t *)feedback
                    frameId:(uint32_t)frameId {
    if (feedback == NULL) {
        return;
    }
    uint64_t observedNs = shtp_now_ns();
    if (feedback->version >= 5 && feedback->fresh_content_presents != 0) {
        pthread_mutex_lock(&_timingLock);
        if (_haveReceiverFreshCount &&
            feedback->fresh_content_presents > _lastReceiverFreshCount) {
            rolling_metric_add(
                &_rollingFreshReports, observedNs,
                feedback->fresh_content_presents - _lastReceiverFreshCount);
        }
        _lastReceiverFreshCount = feedback->fresh_content_presents;
        _haveReceiverFreshCount = 1;
        pthread_mutex_unlock(&_timingLock);
    }
    if (feedback->present_ns == 0 || _clockRttNs == 0) {
        return;
    }
    sharp_frame_timing_t timing;
    memset(&timing, 0, sizeof(timing));
    pthread_mutex_lock(&_timingLock);
    sharp_frame_timing_t *stored =
        &_frameTimings[frameId % SHARP_FRAME_TIMING_SLOTS];
    if (stored->valid && stored->frame_id == frameId) {
        timing = *stored;
    }
    pthread_mutex_unlock(&_timingLock);
    uint64_t captureNs = timing.source_ns;
    if (captureNs == 0) {
        return;
    }
    int64_t senderPresentNs = (int64_t)feedback->present_ns - _clockOffsetNs;
    if (senderPresentNs <= 0 || (uint64_t)senderPresentNs < captureNs) {
        return;
    }
    uint64_t g2gNs = (uint64_t)senderPresentNs - captureNs;
    if (_g2gSampleCount < SHARP_TX_LATENCY_SAMPLES) {
        _g2gSamples[_g2gSampleCount++] = g2gNs;
    }
    uint64_t freshNs = g2gNs;
    uint64_t bucket = freshNs / 2000000ULL;
    if (bucket >= SHARP_FRESHNESS_BUCKETS) {
        bucket = SHARP_FRESHNESS_BUCKETS - 1u;
    }
    _freshnessBuckets[bucket]++;
    _presentReports++;
    pthread_mutex_lock(&_timingLock);
    rolling_metric_add(&_rollingSourceToPresent, observedNs, g2gNs);
    if (timing.callback_ns != 0 &&
        timing.final_packet_send_ns >= timing.callback_ns) {
        rolling_metric_add(&_rollingCallbackToFinalSend, observedNs,
                           timing.final_packet_send_ns - timing.callback_ns);
    }
    if (timing.final_packet_send_ns != 0 &&
        (uint64_t)senderPresentNs >= timing.final_packet_send_ns) {
        rolling_metric_add(&_rollingFinalSendToPresent, observedNs,
                           (uint64_t)senderPresentNs -
                               timing.final_packet_send_ns);
    }
    if (feedback->final_packet_rx_ns != 0 &&
        feedback->decode_callback_ns >= feedback->final_packet_rx_ns) {
        rolling_metric_add(&_rollingFinalRxToDecode, observedNs,
                           feedback->decode_callback_ns -
                               feedback->final_packet_rx_ns);
    }
    if (feedback->decode_callback_ns != 0 &&
        feedback->present_ns >= feedback->decode_callback_ns) {
        rolling_metric_add(&_rollingDecodeToPresent, observedNs,
                           feedback->present_ns -
                               feedback->decode_callback_ns);
    }
    pthread_mutex_unlock(&_timingLock);
    [self updatePhaseLockFromFeedback:feedback];
}

- (void)updatePhaseLockFromFeedback:(const sharp_video_feedback_t *)feedback {
    if (!_phaseLockEnabled || !_encodeTickEnabled || feedback == NULL ||
        feedback->vsync_ns == 0 || feedback->vsync_period_ns == 0 ||
        _clockRttNs == 0 || _encodeTickTimer == nil) {
        return;
    }
    uint64_t periodNs = feedback->vsync_period_ns;
    if (periodNs < 1000000ULL || periodNs > 100000000ULL) {
        return;
    }
    int64_t senderVsyncNs = (int64_t)feedback->vsync_ns - _clockOffsetNs;
    if (senderVsyncNs <= 0) {
        return;
    }
    if (_g2gSampleCount >= 16) {
        uint64_t tunedLeadNs = [self g2gPercentileNs:0.90] + 1000000ULL;
        if (tunedLeadNs < SHARP_PHASE_LOCK_LEAD_MIN_NS) {
            tunedLeadNs = SHARP_PHASE_LOCK_LEAD_MIN_NS;
        } else if (tunedLeadNs > SHARP_PHASE_LOCK_LEAD_MAX_NS) {
            tunedLeadNs = SHARP_PHASE_LOCK_LEAD_MAX_NS;
        }
        _phaseLockLeadNs = tunedLeadNs;
    } else if (_phaseLockLeadNs == 0) {
        _phaseLockLeadNs = SHARP_PHASE_LOCK_LEAD_INITIAL_NS;
    }
    uint64_t nowNs = shtp_now_ns();
    int64_t targetNs = senderVsyncNs - (int64_t)_phaseLockLeadNs;
    while (targetNs <= (int64_t)nowNs) {
        targetNs += (int64_t)periodNs;
    }
    if (_encodeTickNextFireNs == 0) {
        _encodeTickNextFireNs = (uint64_t)targetNs;
    }
    int64_t errorNs = targetNs - (int64_t)_encodeTickNextFireNs;
    int64_t halfPeriodNs = (int64_t)(periodNs / 2u);
    if (errorNs > halfPeriodNs) {
        errorNs -= (int64_t)periodNs;
    } else if (errorNs < -halfPeriodNs) {
        errorNs += (int64_t)periodNs;
    }
    uint64_t elapsedNs =
        _phaseLockLastAdjustNs != 0 && nowNs > _phaseLockLastAdjustNs
            ? nowNs - _phaseLockLastAdjustNs
            : 1000000000ULL;
    uint64_t maxAdjustNs =
        (uint64_t)((__uint128_t)elapsedNs *
                   SHARP_PHASE_LOCK_MAX_ADJUST_NS_PER_SEC /
                   1000000000ULL);
    if (maxAdjustNs == 0) {
        maxAdjustNs = 1;
    }
    int64_t adjustmentNs = errorNs;
    if (adjustmentNs > (int64_t)maxAdjustNs) {
        adjustmentNs = (int64_t)maxAdjustNs;
    } else if (adjustmentNs < -(int64_t)maxAdjustNs) {
        adjustmentNs = -(int64_t)maxAdjustNs;
    }
    if (adjustmentNs != 0) {
        int64_t nextFireNs = (int64_t)_encodeTickNextFireNs + adjustmentNs;
        if (nextFireNs <= (int64_t)nowNs) {
            nextFireNs = (int64_t)nowNs + 1000000;
        }
        _encodeTickNextFireNs = (uint64_t)nextFireNs;
        dispatch_source_set_timer(_encodeTickTimer,
                                  dispatch_time(DISPATCH_TIME_NOW,
                                                (int64_t)(_encodeTickNextFireNs - nowNs)),
                                  _encodeTickIntervalNs, 500000ULL);
        _phaseLockTimerAdjustments++;
        _phaseLockTimerAdjustmentAbsNs +=
            adjustmentNs < 0 ? (uint64_t)(-adjustmentNs) : (uint64_t)adjustmentNs;
    }
    _phaseLockLastAdjustNs = nowNs;
    _phaseLockFeedbackReports++;
    _phaseLockLastPeriodNs = periodNs;
    _phaseLockLastErrorNs = errorNs;
    _phaseLockLastAdjustmentNs = adjustmentNs;
}

- (uint64_t)g2gPercentileNs:(double)percentile {
    return percentile_u64(_g2gSamples, _g2gSampleCount, percentile);
}

- (void)freshnessHistogramString:(char *)buffer size:(size_t)size {
    if (buffer == NULL || size == 0) {
        return;
    }
    size_t used = 0;
    buffer[0] = '\0';
    for (size_t i = 0; i < SHARP_FRESHNESS_BUCKETS; i++) {
        unsigned int upperMs = (unsigned int)((i + 1u) * 2u);
        if (i + 1u == SHARP_FRESHNESS_BUCKETS) {
            upperMs = 40u;
        }
        int written = snprintf(buffer + used, size - used, "%s%u:%" PRIu64,
                               i == 0 ? "" : ",", upperMs,
                               _freshnessBuckets[i]);
        if (written < 0 || (size_t)written >= size - used) {
            buffer[size - 1u] = '\0';
            return;
        }
        used += (size_t)written;
    }
}

- (void)handleTileDigestPayload:(const uint8_t *)payload length:(size_t)length {
    if (payload == NULL || length < sizeof(sharp_tile_digest_header_t)) {
        return;
    }
    sharp_tile_digest_header_t header;
    memcpy(&header, payload, sizeof(header));
    sharp_tile_digest_header_wire_to_host(&header);
    size_t entriesBytes =
        (size_t)header.entry_count * sizeof(sharp_tile_digest_entry_t);
    if (header.magic != SHARP_TILE_DIGEST_MAGIC ||
        header.version != SHARP_TILE_DIGEST_VERSION ||
        header.entry_count == 0 ||
        entriesBytes > length - sizeof(header)) {
        return;
    }
    sharp_tile_digest_entry_t entries[96];
    if (header.entry_count > (uint16_t)(sizeof(entries) / sizeof(entries[0]))) {
        return;
    }
    const uint8_t *cursor = payload + sizeof(header);
    for (uint16_t i = 0; i < header.entry_count; i++) {
        memcpy(&entries[i], cursor, sizeof(entries[i]));
        sharp_tile_digest_entry_wire_to_host(&entries[i]);
        cursor += sizeof(entries[i]);
    }
    _tileDigestPackets++;
    _tileDigestEntries += header.entry_count;

    uint16_t mismatchIds[96];
    uint16_t mismatchCount = 0;
    uint32_t snapshotFrameId = 0;
    screen_tile_repair_batch_t *batch = NULL;
    @synchronized (self) {
        if (!_latestFrameBgraValid || _latestFrameBgra == NULL ||
            _latestFrameStride == 0) {
            return;
        }
        snapshotFrameId = _latestFrameBgraFrameId;
        for (uint16_t i = 0; i < header.entry_count; i++) {
            uint16_t tileId = entries[i].tile_id;
            sharp_tile_rect_t rect;
            if (tileId >= _dirtyMap.tile_count ||
                sharp_tile_rect_for_id(_width, _height, tileId, &rect) != 0) {
                continue;
            }
            if (_fullFrameActive && _fullFrameCurrentMask != NULL &&
                (_fullFrameCurrentMask[tileId >> 3] &
                 (uint8_t)(1u << (tileId & 7u))) != 0) {
                continue;
            }
            uint64_t senderHash = sharp_tile_hash_bgra(
                _latestFrameBgra, _latestFrameStride, &rect);
            if (senderHash != entries[i].hash ||
                (entries[i].reserved & SHARP_TILE_DIGEST_REFRESH_REQUIRED)) {
                mismatchIds[mismatchCount++] = tileId;
            }
        }
        if (mismatchCount == 0) {
            return;
        }
        batch = calloc(1, sizeof(*batch) +
                              (size_t)mismatchCount * sizeof(batch->tiles[0]));
        if (batch == NULL) {
            return;
        }
        batch->frame_id = snapshotFrameId;
        batch->count = mismatchCount;
        for (uint16_t i = 0; i < mismatchCount; i++) {
            screen_tx_tile_t *tile = &batch->tiles[i];
            tile->tile_id = mismatchIds[i];
            tile->kind = SCREEN_TX_TILE_REFINEMENT;
            if (sharp_tile_rect_for_id(_width, _height, tile->tile_id,
                                       &tile->rect) != 0) {
                batch->count = i;
                break;
            }
            size_t rowBytes = (size_t)tile->rect.w * 4u;
            const uint8_t *src =
                _latestFrameBgra +
                (size_t)tile->rect.y * _latestFrameStride +
                (size_t)tile->rect.x * 4u;
            for (uint32_t row = 0; row < tile->rect.h; row++) {
                memcpy(tile->bgra + (size_t)row * rowBytes,
                       src + (size_t)row * _latestFrameStride, rowBytes);
            }
        }
    }
    _tileDigestMismatches += batch->count;
    dispatch_async(_txQueue, ^{
      uint64_t nowNs = shtp_now_ns();
      for (uint16_t i = 0; i < batch->count; i++) {
          [self storeCleanupTile:&batch->tiles[i]
                         frameId:batch->frame_id
                       enqueueNs:nowNs];
      }
      _tileDigestRepairsQueued += batch->count;
      free(batch);
      if (_cleanupPendingTiles > 0 && !_txPumpScheduled) {
          _txPumpScheduled = 1u;
          dispatch_async(_txQueue, ^{
            [self txPump];
          });
      }
    });
}

- (void)drainFeedback {
    for (;;) {
        uint8_t packet[SHTP_MAX_DATAGRAM];
        ssize_t n = recv(_fd, packet, sizeof(packet), MSG_DONTWAIT);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                return;
            }
            return;
        }
        if ((size_t)n < sizeof(shtp_header_t)) {
            continue;
        }
        shtp_header_t sh;
        memcpy(&sh, packet, sizeof(sh));
        shtp_header_wire_to_host(&sh);
        if (!shtp_header_is_valid(&sh, (size_t)n)) {
            continue;
        }
        if (sh.payload_type == SHTP_PAYLOAD_HYBRID_STATE && _verifiedSource) {
            NSData *data = [NSData dataWithBytes:packet + sizeof(sh) length:sh.payload_len];
            dispatch_async(_processingQueue, ^{ [self handleVerifiedMessage:data]; });
            continue;
        }
        if (_verifiedSource && sh.payload_type == SHTP_PAYLOAD_TILE_DIGEST) continue;
        if (sh.type == SHTP_PACKET_STATS &&
            sh.payload_type == SHTP_PAYLOAD_TILE_DIGEST) {
            [self handleTileDigestPayload:packet + sizeof(sh)
                                  length:sh.payload_len];
            continue;
        }
        if (sh.payload_type != SHTP_PAYLOAD_CONTROL) {
            continue;
        }
        if (sh.type == SHTP_PACKET_PONG && sh.payload_len >= sizeof(uint64_t)) {
            [self handleClockPong:&sh payload:packet + sizeof(sh)];
            continue;
        }
        if (sh.type != SHTP_PACKET_STATS ||
            sh.payload_len < SHARP_VIDEO_FEEDBACK_V1_BYTES) {
            continue;
        }
        sharp_video_feedback_t feedback;
        memset(&feedback, 0, sizeof(feedback));
        size_t feedbackLen = sh.payload_len < sizeof(feedback)
                                 ? sh.payload_len
                                 : sizeof(feedback);
        memcpy(&feedback, packet + sizeof(sh), feedbackLen);
        sharp_video_feedback_wire_to_host(&feedback);
        if (!sharp_video_feedback_is_valid(&feedback)) {
            continue;
        }
        _h264FeedbackPackets++;
        if (feedback.kind == SHARP_VIDEO_FEEDBACK_PRESENT_REPORT) {
            if (feedbackLen >= SHARP_VIDEO_FEEDBACK_V2_BYTES) {
                [self handlePresentReport:&feedback frameId:sh.frame_id];
            }
            continue;
        }
        if (feedback.region_id == SHARP_H264_FULLFRAME_ID) {
            if (feedback.kind == SHARP_VIDEO_FEEDBACK_VSLICE_NACK ||
                feedback.kind == SHARP_VIDEO_FEEDBACK_IDR_REQ) {
                _h264FullFrameFeedbackIgnored++;
                continue;
            }
            if (feedback.kind == SHARP_VIDEO_FEEDBACK_KEYFRAME_REQUEST ||
                feedback.kind == SHARP_VIDEO_FEEDBACK_MISSING_GENERATION) {
                _h264FullFrameKeyframeRequests++;
                _h264KeyframeRequests++;
                _fullFrameForceKeyframe = YES;
                if (feedback.kind == SHARP_VIDEO_FEEDBACK_MISSING_GENERATION ||
                    feedback.missing_chunks >= 2u) {
                    [self noteFullFrameVideoLossFeedback];
                }
                continue;
            }
        }
        h264_region_stream_t *stream =
            [self h264StreamForRegion:feedback.region_id
                                create:NO
                               frameId:feedback.generation];
        if (feedback.kind == SHARP_VIDEO_FEEDBACK_VSLICE_NACK) {
            _h264VsliceNacks++;
            if (stream != NULL) {
                stream->nacks++;
            }
            [self retransmitH264Region:feedback.region_id
                            generation:feedback.generation
                            firstChunk:feedback.chunk_id
                            chunkCount:feedback.missing_chunks];
            continue;
        }
        if (feedback.kind == SHARP_VIDEO_FEEDBACK_MISSING_GENERATION) {
            _h264MissingGenerations++;
        }
        if (feedback.kind == SHARP_VIDEO_FEEDBACK_IDR_REQ) {
            _h264IdrRequests++;
            if (stream != NULL) {
                stream->idr_requests++;
                stream->need_keyframe = 1u;
                stream->force_idr = 1u;
            }
        }
        if (feedback.kind == SHARP_VIDEO_FEEDBACK_KEYFRAME_REQUEST ||
            feedback.kind == SHARP_VIDEO_FEEDBACK_MISSING_GENERATION ||
            feedback.kind == SHARP_VIDEO_FEEDBACK_IDR_REQ) {
            _h264KeyframeRequests++;
            _h264RequestedRegion = feedback.region_id;
            _h264HaveKeyframeRequest = YES;
            _h264RequestIsIdr =
                feedback.kind == SHARP_VIDEO_FEEDBACK_IDR_REQ ? YES : NO;
            if (stream != NULL) {
                stream->need_keyframe = 1u;
            }
        }
    }
}

- (void)paceAfterBytes:(size_t)bytes {
    if (_pacingMbps <= 0.0 || bytes == 0) {
        return;
    }
    if (_verifiedSource) {
        uint64_t now=shtp_now_ns(),rate=atomic_load(&_verifiedPacingBps);
        if (!rate) return;
        if (!_verifiedRateWindowNs) _verifiedRateWindowNs=now;
        _verifiedRateWindowBytes+=bytes;
        if (now-_verifiedRateWindowNs>=20000000ULL) {
            if (env_flag_enabled("SHARP_HYBRID_TRACE"))
                fprintf(stdout,"hybrid-lossless-rate actual_mbps=%.1f target_mbps=%.1f\n",
                    _verifiedRateWindowBytes*8000.0/(now-_verifiedRateWindowNs),rate/1e6);
            _verifiedRateWindowNs=now;_verifiedRateWindowBytes=0;
        }
        const uint64_t burstNs=400000ULL;
        if (_pacingNextNs+burstNs<now) _pacingNextNs=now-burstNs;
        _pacingNextNs+=(uint64_t)((double)bytes*8e9/(double)rate);
        if (_pacingNextNs>now+200000ULL)
            usleep((useconds_t)((_pacingNextNs-now)/1000ULL));
        return;
    }
    uint64_t now = shtp_now_ns();
    uint64_t delayNs =
        (uint64_t)(((double)bytes * 8.0 * 1000.0) / _pacingMbps);
    if (_pacingNextNs < now) {
        _pacingNextNs = now;
    }
    _pacingNextNs += delayNs;
    now = shtp_now_ns();
    if (_pacingNextNs > now) {
        uint64_t sleepNs = _pacingNextNs - now;
        if (sleepNs > 0) {
            usleep((useconds_t)(sleepNs / 1000u));
        }
    }
}

- (int)sendFrameEndFrameId:(uint32_t)frameId
             expectedPatches:(uint16_t)expectedPatches
              videoRegionMask:(uint16_t)videoRegionMask
                    motionMask:(const uint8_t *)motionMask
               motionMaskBytes:(uint16_t)motionMaskBytes {
    shtp_header_t h;
    memset(&h, 0, sizeof(h));
    h.magic = SHTP_MAGIC;
    h.version = SHTP_VERSION;
    h.header_bytes = SHTP_HEADER_BYTES;
    h.type = SHTP_PACKET_FRAME_END;
    h.payload_type = SHTP_PAYLOAD_CONTROL;
    h.frame_id = frameId;
    h.chunk_count = expectedPatches;
    h.send_time_ns = shtp_now_ns();
    if (_verifiedSession) { h.flags |= SHTP_FLAG_VERIFIED_HYBRID; h.aux_time_ns = _verifiedSession; }
    if (videoRegionMask != 0) {
        h.flags |= SHTP_FRAME_END_FLAG_VIDEO_REGIONS;
        h.aux_time_ns = videoRegionMask;
    }
    if (motionMask != NULL && motionMaskBytes > 0) {
        if ((size_t)SHTP_HEADER_BYTES + motionMaskBytes >
            SHTP_MAX_DATAGRAM) {
            return -1;
        }
        h.flags |= SHTP_FRAME_END_FLAG_MOTION_MASK;
        h.payload_len = motionMaskBytes;
    }
    uint8_t packet[SHTP_MAX_DATAGRAM];
    pthread_mutex_lock(&_sendLock);
    h.sequence = _sequence++;
    shtp_header_host_to_wire(&h);
    memcpy(packet, &h, sizeof(h));
    if (motionMask != NULL && motionMaskBytes > 0) {
        memcpy(packet + sizeof(h), motionMask, motionMaskBytes);
    }
    size_t packetLen = sizeof(h) + motionMaskBytes;
    ssize_t sent = send(_fd, packet, packetLen, 0);
    pthread_mutex_unlock(&_sendLock);
    if (sent == (ssize_t)packetLen) {
        [self recordFinalPacketSendForFrameId:frameId timestamp:shtp_now_ns()];
        return 0;
    }
    return -1;
}
@end
