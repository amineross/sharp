#import "Internal.h"

@implementation SharpScreenSender (Capture)
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    (void)stream;
    fprintf(stderr, "m1-screen-send stream stopped: %s\n",
            error.localizedDescription.UTF8String);
}

- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type {
    (void)stream;
    if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sampleBuffer)) {
        return;
    }
    uint64_t callbackNs = shtp_now_ns();
    uint64_t sourceNs = sharp_screen_source_time_ns(sampleBuffer, callbackNs);
    [self enqueueSampleBuffer:sampleBuffer
                   callbackNs:callbackNs
                     sourceNs:sourceNs];
}

- (void)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer
                  callbackNs:(uint64_t)callbackNs
                    sourceNs:(uint64_t)sourceNs {
    if (sampleBuffer == NULL || !CMSampleBufferIsValid(sampleBuffer)) {
        return;
    }
    _captureCallbacks++;
    /* Status-only notifications must not replace an unprocessed image. */
    if (![self shouldEnqueueCaptureSample:sampleBuffer]) {
        return;
    }
    CFRetain(sampleBuffer);
    BOOL shouldSchedule = NO;
    @synchronized (self) {
        if (_pendingSampleBuffer != NULL) {
            CFRelease(_pendingSampleBuffer);
            _replacedFrames++;
        }
        _pendingSampleBuffer = sampleBuffer;
        _pendingCallbackNs = callbackNs;
        _pendingSourceNs = sourceNs;
        if (_encodeTickEnabled) {
            return;
        }
        if (!_processingScheduled) {
            _processingScheduled = 1u;
            shouldSchedule = YES;
        }
    }
    if (shouldSchedule) {
        dispatch_async(_processingQueue, ^{
          [self processPendingSamples];
        });
    }
}

- (BOOL)shouldEnqueueCaptureSample:(CMSampleBufferRef)sampleBuffer {
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (attachments == NULL || CFArrayGetCount(attachments) == 0) {
        return YES;
    }
    NSDictionary *info =
        (__bridge NSDictionary *)CFArrayGetValueAtIndex(attachments, 0);
    NSNumber *statusNumber = info[SCStreamFrameInfoStatus];
    if (statusNumber == nil) {
        return YES;
    }
    NSInteger status = statusNumber.integerValue;
    if (status == SCFrameStatusComplete || status == SCFrameStatusStarted) {
        return YES;
    }
    if (status == SCFrameStatusIdle) {
        uint64_t idleNs = shtp_now_ns();
        dispatch_async(_processingQueue, ^{ [self noteCaptureIdleAtTime:idleNs]; });
    } else {
        dispatch_async(_processingQueue, ^{ _captureIdleSinceNs = 0; });
    }
    unsigned int bucket = sck_status_bucket(status);
    if (bucket < SHARP_SCK_STATUS_BUCKETS) {
        _sckStatusCounts[bucket]++;
    } else {
        _sckStatusOther++;
    }
    _skippedFrames++;
    return NO;
}

- (void)noteCaptureIdleAtTime:(uint64_t)nowNs {
    if (_verifiedSource) { [self verifiedMaintenance]; return; }
    if (!_fullFrameActive || _captureIdleSinceNs != 0 ||
        _lastCompleteSampleBuffer == NULL || _processingQueue == nil) {
        return;
    }
    _captureIdleSinceNs = nowNs;
    __weak SharpScreenSender *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, SHARP_CAPTURE_IDLE_REFINE_NS),
                   _processingQueue, ^{
        [weakSelf finishCaptureIdleSince:nowNs];
    });
}

- (void)finishCaptureIdleSince:(uint64_t)idleSinceNs {
    if (_captureIdleSinceNs != idleSinceNs || !_fullFrameActive ||
        _lastCompleteSampleBuffer == NULL ||
        atomic_load_explicit(&_txStopping, memory_order_acquire)) {
        return;
    }
    uint64_t nowNs = shtp_now_ns();
    uint64_t activeNs = nowNs - _fullFrameEnteredNs;
    _fullFrameActive = NO;
    _fullFrameExitRefinePending = YES;
    _fullFrameForceKeyframe = NO;
    _fullFrameQuietStartNs = 0;
    _fullFrameMotionStartNs = 0;
    _fullFrameEnteredNs = 0;
    _fullFrameLastExitNs = nowNs;
    _fullFrameExits++;
    [self logFullFrameEvent:"exit" reason:"capture-idle" motionTiles:0
      sustainedMotionTiles:0 motionRegions:0 tileCount:sharp_tile_count(_width, _height)
      heldNs:activeNs quietNs:nowNs - idleSinceNs];
    /* Force a scan of the retained surface: the video fast path may have
     * skipped the BGRA snapshot. This is a repair, not a new capture sample. */
    _idleRefineInProgress = YES;
    [self processSampleBuffer:_lastCompleteSampleBuffer callbackNs:nowNs sourceNs:0];
    _idleRefineInProgress = NO;
}

- (void)scheduleMotionPrerollDeadline {
    if (_motionPrerollDeadlineNs != 0 || _processingQueue == nil) {
        return;
    }
    uint64_t intervalNs = 1000000000ULL / MAX(_fps, 1u);
    uint64_t deadline = shtp_now_ns() + intervalNs;
    _motionPrerollDeadlineNs = deadline;
    __weak SharpScreenSender *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, intervalNs), _processingQueue, ^{
        SharpScreenSender *sender = weakSelf;
        if (sender == nil || sender->_motionPrerollDeadlineNs != deadline) {
            return;
        }
        sender->_motionPrerollDeadlineNs = 0;
        if (sender->_motionPrerollJob != NULL && !sender->_fullFrameActive &&
            !atomic_load_explicit(&sender->_txStopping, memory_order_acquire)) {
            screen_tx_frame_job_t *job = sender->_motionPrerollJob;
            sender->_motionPrerollJob = NULL;
            sender->_motionPrerollReleasedFrames++;
            [sender enqueueTxFrameJob:job];
        }
    });
}

- (BOOL)processOnePendingSample {
    CMSampleBufferRef sampleBuffer = NULL;
    uint64_t callbackNs = 0;
    uint64_t sourceNs = 0;
    @synchronized (self) {
        sampleBuffer = _pendingSampleBuffer;
        callbackNs = _pendingCallbackNs;
        sourceNs = _pendingSourceNs;
        _pendingSampleBuffer = NULL;
        _pendingCallbackNs = 0;
        _pendingSourceNs = 0;
        if (sampleBuffer == NULL) {
            return NO;
        }
    }
    [self processSampleBuffer:sampleBuffer
                   callbackNs:callbackNs
                     sourceNs:sourceNs];
    CFRelease(sampleBuffer);
    return YES;
}

- (void)processPendingSamples {
    for (;;) {
        if (![self processOnePendingSample]) {
            @synchronized (self) {
                _processingScheduled = 0u;
            }
            return;
        }
    }
}

- (void)startEncodeTick {
    if (!_encodeTickEnabled || _encodeTickTimer != nil || _processingQueue == nil) {
        return;
    }
    uint64_t intervalNs = 1000000000ULL / (_fps > 0 ? _fps : 60u);
    _encodeTickIntervalNs = intervalNs;
    _encodeTickNextFireNs = shtp_now_ns() + intervalNs;
    if (_phaseLockLeadNs == 0) {
        _phaseLockLeadNs = SHARP_PHASE_LOCK_LEAD_INITIAL_NS;
    }
    _encodeTickTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                              _processingQueue);
    dispatch_source_set_timer(_encodeTickTimer,
                              dispatch_time(DISPATCH_TIME_NOW, intervalNs),
                              intervalNs, 500000ULL);
    __weak SharpScreenSender *weakSelf = self;
    dispatch_source_set_event_handler(_encodeTickTimer, ^{
      SharpScreenSender *strongSelf = weakSelf;
      if (strongSelf == nil) {
          return;
      }
      strongSelf.encodeTickFires++;
      uint64_t nowNs = shtp_now_ns();
      uint64_t intervalNs = strongSelf->_encodeTickIntervalNs != 0
                                ? strongSelf->_encodeTickIntervalNs
                                : 16666667ULL;
      if (strongSelf->_encodeTickNextFireNs == 0 ||
          nowNs > strongSelf->_encodeTickNextFireNs + intervalNs * 2u) {
          strongSelf->_encodeTickNextFireNs = nowNs + intervalNs;
      } else {
          strongSelf->_encodeTickNextFireNs += intervalNs;
      }
      if (![strongSelf processOnePendingSample]) {
          strongSelf.encodeTickIdleSkips++;
      }
    });
    dispatch_resume(_encodeTickTimer);
}

- (void)stopEncodeTick {
    if (_encodeTickTimer != nil) {
        dispatch_source_cancel(_encodeTickTimer);
        _encodeTickTimer = nil;
    }
}

- (BOOL)processFullFrameHotPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                  info:(NSDictionary *)info
                            callbackNs:(uint64_t)callbackNs
                             forceFull:(BOOL)forceFull
                              tileCount:(uint32_t)tileCount
                preSubmittedFullFrame:(BOOL)preSubmittedFullFrame {
    uint64_t hotStartNs = shtp_now_ns();
    if (!_hybridH264 || !_fullFrameActive || forceFull || pixelBuffer == NULL ||
        tileCount == 0) {
        return NO;
    }
    if ([self ensureFrameScratchCapacity:tileCount] != 0) {
        return NO;
    }

    uint64_t analyzeStartNs = shtp_now_ns();
    int dirtyMetadataPresent = 0;
    int dirtyRectsScaled = 0;
    uint64_t dirtyRectsClipped = 0;
    size_t rectCount = collect_dirty_rects(info, _width, _height, _rectScratch,
                                           tileCount, &dirtyMetadataPresent,
                                           &dirtyRectsScaled, &dirtyRectsClipped);
    if (dirtyMetadataPresent) {
        _dirtyRectFrames++;
        _dirtyRects += rectCount;
        if (dirtyRectsScaled) {
            _dirtyRectScaledFrames++;
        }
        _dirtyRectClipped += dirtyRectsClipped;
    } else {
        _metadataFallbackFrames++;
    }
    if (!dirtyMetadataPresent ||
        ![self hotPathRectsContainOnlyMotion:_rectScratch
                                        count:rectCount
                                    tileCount:tileCount]) {
        return NO;
    }

    uint64_t dirtyArea = 0;
    for (size_t i = 0; i < rectCount; i++) {
        dirtyArea += (uint64_t)_rectScratch[i].w * (uint64_t)_rectScratch[i].h;
    }
    uint32_t estimatedMotionTiles = 0;
    if (dirtyMetadataPresent) {
        uint64_t tilePixels = (uint64_t)SHARP_TILE_SIZE * SHARP_TILE_SIZE;
        estimatedMotionTiles =
            (uint32_t)MIN((uint64_t)tileCount,
                          (dirtyArea + tilePixels - 1u) / tilePixels);
    } else {
        estimatedMotionTiles = tileCount;
    }
    _candidateTiles += estimatedMotionTiles;
    _h264MotionCandidateTiles += estimatedMotionTiles;
    _h264MotionCoveredTiles += estimatedMotionTiles;
    _fullFrameMotionCandidateTiles += estimatedMotionTiles;
    _fullFrameMotionCoveredTiles += estimatedMotionTiles;
    _fullFrameSuppressedLosslessTiles += estimatedMotionTiles;

    [self updateFullFrameModeWithMotionTiles:estimatedMotionTiles
                              activityTiles:estimatedMotionTiles
                         sustainedMotionTiles:estimatedMotionTiles
                              uncoveredTiles:0
                               motionRegions:1
                                    tileCount:tileCount
                                    forceFull:NO];
    if (!_fullFrameActive) {
        return NO;
    }

    [self clearCurrentMotionMask];
    for (uint32_t tileId = 0; tileId < tileCount; tileId++) {
        [self addMotionMaskTile:(uint16_t)tileId];
    }

    _fullFrameProcessedFrames++;
    _fullFrameAnalyzerSkippedFrames++;
    _m2MotionFrames++;
    _m2MotionTiles += estimatedMotionTiles;

    uint64_t analyzeDoneNs = shtp_now_ns();
    [self recordAnalyzerDoneForFrameId:_frameId timestamp:analyzeDoneNs];
    BOOL submittedFullFrame = preSubmittedFullFrame;
    if (!submittedFullFrame) {
        [self drainFeedback];
        BOOL forceFullFrameKeyframe =
            _fullFrameForceKeyframe ||
            (_h264HaveKeyframeRequest &&
             _h264RequestedRegion == SHARP_H264_FULLFRAME_ID);
        submittedFullFrame =
            [self encodeH264FullFrame:pixelBuffer
                              frameId:_frameId
                        forceKeyframe:forceFullFrameKeyframe
                                 direct:_fullFrameDirectFeed
                           sourceLocked:NO
                           emitFrameEnd:YES];
        if (submittedFullFrame && forceFullFrameKeyframe) {
            _fullFrameForceKeyframe = NO;
            if (_h264HaveKeyframeRequest &&
                _h264RequestedRegion == SHARP_H264_FULLFRAME_ID) {
                if (_h264RequestIsIdr) {
                    _h264IdrSent++;
                }
                _h264HaveKeyframeRequest = NO;
                _h264RequestIsIdr = NO;
            }
        }
    }

    uint64_t sendDoneNs = shtp_now_ns();
    if (submittedFullFrame) {
        _sentFrames++;
        _stats.frames++;
        if (_firstFrameNs == 0) {
            _firstFrameNs = shtp_now_ns();
        }
        _lastFrameNs = shtp_now_ns();
    } else {
        _idleFrames++;
    }

    if (_frameLog != NULL) {
        double analyzeUs = (double)(analyzeDoneNs - analyzeStartNs) / 1000.0;
        double sendUs = (double)(sendDoneNs - analyzeDoneNs) / 1000.0;
        fprintf(_frameLog,
                "%u\t%" PRIu64 "\t%" PRIu64 "\t%" PRIu64
                "\t%.1f\t%.1f\t%u\t0\t0\t0\t0\n",
                _frameId, callbackNs, analyzeStartNs, sendDoneNs,
                analyzeUs, sendUs, estimatedMotionTiles);
        fflush(_frameLog);
    }
    [self traceFullFrameFrameId:_frameId
                  preSubmitted:preSubmittedFullFrame
                     submitted:submittedFullFrame
                   forceKeyframe:_fullFrameTraceKeyframeAttempted];
    if (submittedFullFrame) {
        _frameId++;
    }
    uint64_t hotDoneNs = shtp_now_ns();
    if (hotDoneNs >= hotStartNs &&
        _fullFrameProcessDurationCount < SHARP_TX_LATENCY_SAMPLES) {
        _fullFrameProcessDurationSamples[_fullFrameProcessDurationCount++] =
            hotDoneNs - hotStartNs;
    }
    return YES;
}

- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer
                  callbackNs:(uint64_t)callbackNs
                    sourceNs:(uint64_t)sourceNs {
    uint64_t processStartNs = shtp_now_ns();
    _fullFrameTraceKeyframeAttempted = NO;
    if (sourceNs == 0 && !_idleRefineInProgress) {
        _sourceTimestampMissing++;
    }
    [self recordCaptureTimestampForFrameId:_frameId timestampNs:sourceNs];
    [self recordFrameTimingFrameId:_frameId
                          sourceNs:sourceNs
                        callbackNs:callbackNs
                        analyzerNs:processStartNs];
    if (callbackNs != 0 && processStartNs >= callbackNs &&
        _callbackToProcessCount < SHARP_TX_LATENCY_SAMPLES) {
        _callbackToProcessSamples[_callbackToProcessCount++] =
            processStartNs - callbackNs;
    }
#define SHARP_RECORD_PROCESS_DURATION()                                      \
    do {                                                                     \
        uint64_t processDoneNs__ = shtp_now_ns();                            \
        if (processDoneNs__ >= processStartNs &&                             \
            _processDurationCount < SHARP_TX_LATENCY_SAMPLES) {              \
            _processDurationSamples[_processDurationCount++] =               \
                processDoneNs__ - processStartNs;                            \
        }                                                                    \
    } while (0)
    if (sampleBuffer == NULL || !CMSampleBufferIsValid(sampleBuffer)) {
        SHARP_RECORD_PROCESS_DURATION();
        return;
    }

    NSDictionary *info = nil;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (attachments != NULL && CFArrayGetCount(attachments) > 0) {
        info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(attachments, 0);
        NSNumber *statusNumber = info[SCStreamFrameInfoStatus];
        if (statusNumber != nil) {
            NSInteger status = statusNumber.integerValue;
            unsigned int bucket = sck_status_bucket(status);
            if (!_idleRefineInProgress && bucket < SHARP_SCK_STATUS_BUCKETS) {
                _sckStatusCounts[bucket]++;
            } else if (!_idleRefineInProgress) {
                _sckStatusOther++;
            }
            if (status != SCFrameStatusComplete && status != SCFrameStatusStarted) {
                if (status == SCFrameStatusIdle) {
                    [self noteCaptureIdleAtTime:processStartNs];
                } else {
                    _captureIdleSinceNs = 0;
                }
                _skippedFrames++;
                SHARP_RECORD_PROCESS_DURATION();
                return;
            }
        }
    }

    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (pixelBuffer == NULL ||
        CVPixelBufferGetPixelFormatType(pixelBuffer) != kCVPixelFormatType_32BGRA ||
        CVPixelBufferGetWidth(pixelBuffer) != _width ||
        CVPixelBufferGetHeight(pixelBuffer) != _height) {
        _invalidFrames++;
        SHARP_RECORD_PROCESS_DURATION();
        return;
    }

    uint32_t tileCount = sharp_tile_count(_width, _height);
    if (!_idleRefineInProgress) {
        _captureIdleSinceNs = 0;
        if (_hybridH264 && sampleBuffer != _lastCompleteSampleBuffer) {
            CFRetain(sampleBuffer);
            if (_lastCompleteSampleBuffer != NULL) {
                CFRelease(_lastCompleteSampleBuffer);
            }
            _lastCompleteSampleBuffer = sampleBuffer;
        }
    }
    uint64_t nowNs = shtp_now_ns();
    if (_verifiedSource) {
        [self processVerifiedPixels:pixelBuffer now:nowNs];
        SHARP_RECORD_PROCESS_DURATION();
        return;
    }
    uint64_t analyzeStartNs = nowNs;
    int forceAll = _frameId < _initialFullFrames || _idleRefineInProgress;
    if (!forceAll && _fullRefreshIntervalNs > 0 &&
        (_nextFullRefreshNs == 0 || nowNs >= _nextFullRefreshNs)) {
        forceAll = 1;
    }
    if (forceAll && _fullRefreshIntervalNs > 0) {
        _nextFullRefreshNs = nowNs + _fullRefreshIntervalNs;
    }

    BOOL preSubmittedFullFrame = NO;
    /*
     * An active full-frame episode has stable, screen-wide video ownership.
     * Its mask no longer follows individual dirty tiles, so pre-submission is
     * both coherent and valuable: it keeps classifier work off the video
     * latency path without pairing the pixels with a previous moving mask.
     */
    if (_hybridH264 && _fullFrameActive && !forceAll) {
        [self drainFeedback];
        BOOL forceFullFrameKeyframe =
            _fullFrameForceKeyframe ||
            (_h264HaveKeyframeRequest &&
             _h264RequestedRegion == SHARP_H264_FULLFRAME_ID);
        preSubmittedFullFrame =
            [self encodeH264FullFrame:pixelBuffer
                              frameId:_frameId
                        forceKeyframe:forceFullFrameKeyframe
                                 direct:_fullFrameDirectFeed
                           sourceLocked:NO
                           emitFrameEnd:YES];
        if (preSubmittedFullFrame && forceFullFrameKeyframe) {
            _fullFrameForceKeyframe = NO;
            if (_h264HaveKeyframeRequest &&
                _h264RequestedRegion == SHARP_H264_FULLFRAME_ID) {
                if (_h264RequestIsIdr) {
                    _h264IdrSent++;
                }
                _h264HaveKeyframeRequest = NO;
                _h264RequestIsIdr = NO;
            }
        }
    }

    if ([self processFullFrameHotPixelBuffer:pixelBuffer
                                        info:info
                                  callbackNs:callbackNs
                                   forceFull:forceAll ? YES : NO
                                    tileCount:tileCount
                      preSubmittedFullFrame:preSubmittedFullFrame]) {
        SHARP_RECORD_PROCESS_DURATION();
        return;
    }

    if (CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) !=
        kCVReturnSuccess) {
        _invalidFrames++;
        SHARP_RECORD_PROCESS_DURATION();
        return;
    }

    const uint8_t *base = CVPixelBufferGetBaseAddress(pixelBuffer);
    uint32_t stride = (uint32_t)CVPixelBufferGetBytesPerRow(pixelBuffer);
    if ([self ensureFrameScratchCapacity:tileCount] != 0 ||
        [self ensureCleanupCapacity:tileCount] != 0 ||
        [self ensureLatestFrameCapacityWithStride:stride] != 0) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        _invalidFrames++;
        SHARP_RECORD_PROCESS_DURATION();
        return;
    }
    @synchronized (self) {
        memcpy(_latestFrameBgra, base, (size_t)stride * (size_t)_height);
        _latestFrameStride = stride;
        _latestFrameBgraFrameId = _frameId;
        _latestFrameBgraValid = 1u;
    }
    uint16_t *dirty = _dirtyScratch;
    uint16_t *sendTiles = _sendScratch;
    uint16_t *refineTiles = _refineScratch;
    sharp_m2_tile_probe_t *m2Probes = _m2ProbeScratch;
    uint8_t *sendSeen = _sendSeenScratch;
    uint8_t *sendKinds = _sendKindScratch;
    sharp_dirty_rect_t *rects = _rectScratch;
    memset(sendSeen, 0, (size_t)tileCount * sizeof(sendSeen[0]));
    memset(sendKinds, 0, (size_t)tileCount * sizeof(sendKinds[0]));

    int dirtyMetadataPresent = 0;
    int dirtyRectsScaled = 0;
    uint64_t dirtyRectsClipped = 0;
    size_t rectCount = collect_dirty_rects(info, _width, _height, rects, tileCount,
                                           &dirtyMetadataPresent, &dirtyRectsScaled,
                                           &dirtyRectsClipped);
    if (dirtyMetadataPresent) {
        _dirtyRectFrames++;
        _dirtyRects += rectCount;
        if (dirtyRectsScaled) {
            _dirtyRectScaledFrames++;
        }
        _dirtyRectClipped += dirtyRectsClipped;
    } else {
        _metadataFallbackFrames++;
    }

    size_t candidateTiles = 0;
    size_t falseDirtyTiles = 0;
    size_t dirtyCount = 0;
    if (dirtyMetadataPresent || forceAll) {
        dirtyCount = sharp_tile_dirty_map_collect_rects(
            &_dirtyMap, base, stride, rects, rectCount, forceAll, dirty, tileCount,
            &candidateTiles, &falseDirtyTiles);
    } else {
        dirtyCount = sharp_tile_dirty_map_collect(&_dirtyMap, base, stride, 1,
                                                  dirty, tileCount);
        candidateTiles = tileCount;
    }
    _candidateTiles += candidateTiles;
    _falseDirtyTiles += falseDirtyTiles;
    uint32_t broadActivityThreshold =
        (uint32_t)MAX(1.0, ceil((double)tileCount *
                                SHARP_H264_FULLFRAME_BURST_RATIO));
    BOOL broadActivityThisFrame =
        !forceAll && dirtyCount >= broadActivityThreshold;

    sharp_m2_frame_result_t m2Result;
    memset(&m2Result, 0, sizeof(m2Result));
    size_t refineCount = 0;
    sharp_m2_region_t selectedRegions[SHARP_H264_MAX_ACTIVE_REGIONS];
    memset(selectedRegions, 0, sizeof(selectedRegions));
    uint64_t selectedRegionScores[SHARP_H264_MAX_ACTIVE_REGIONS];
    memset(selectedRegionScores, 0, sizeof(selectedRegionScores));
    size_t selectedRegionCount = 0;
    BOOL forceRegionKeyframe[SHARP_H264_MAX_ACTIVE_REGIONS];
    memset(forceRegionKeyframe, 0, sizeof(forceRegionKeyframe));
    uint32_t stableMotionRegionCount = 0;
    uint32_t frameMotionCandidateTiles = 0;
    uint32_t sustainedMotionTiles = 0;
    uint32_t frameUncoveredMotionTiles = 0;
    if (_m2Classifier != NULL) {
        for (size_t i = 0; i < dirtyCount; i++) {
            sharp_m2_probe_bgra_tile(_width, _height, dirty[i], base, stride,
                                     &m2Probes[i]);
        }
        if (sharp_m2_classifier_update(_m2Classifier, _frameId, dirty, m2Probes,
                                       dirtyCount, refineTiles, tileCount,
                                       &m2Result) == 0) {
            refineCount = m2Result.refine_tiles;
            if (m2Result.motion_tiles > 0) {
                _m2MotionFrames++;
            }
            _m2MotionTiles += m2Result.motion_tiles;
            _m2RefineTiles += refineCount;
            _m2BornRegions += m2Result.born_regions;
            _m2ResizedRegions += m2Result.resized_regions;
            _m2DiedRegions += m2Result.died_regions;
        }
        if (_hybridH264) {
            sharp_m2_region_t regions[256];
            size_t regionCount =
                sharp_m2_classifier_regions(_m2Classifier, regions,
                                            sizeof(regions) / sizeof(regions[0]));
            for (size_t i = 0; i < regionCount &&
                               i < sizeof(regions) / sizeof(regions[0]); i++) {
                if (regions[i].event != SHARP_M2_REGION_DIED &&
                    regions[i].w >= 96 && regions[i].h >= 96) {
                    stableMotionRegionCount++;
                }
            }
            size_t activeEncoderCount = 0;
            for (size_t e = 0; e < SHARP_H264_ENCODER_SLOTS; e++) {
                if (_h264Encoders[e].active &&
                    _h264Encoders[e].region_id >= SHARP_H264_FIRST_LANE_ID &&
                    _h264Encoders[e].region_id <
                        SHARP_H264_FIRST_LANE_ID + SHARP_H264_MAX_ACTIVE_REGIONS) {
                    activeEncoderCount++;
                }
            }
            for (size_t i = 0; !_fullFrameActive && !_motionMaskEnabled &&
                               i < regionCount &&
                               i < sizeof(regions) / sizeof(regions[0]); i++) {
                if (regions[i].event == SHARP_M2_REGION_DIED ||
                    regions[i].w < 96 || regions[i].h < 96) {
                    continue;
                }
                uint16_t laneId = [self laneIdForRegion:&regions[i]
                                                 frameId:_frameId
                                                  create:YES];
                if (laneId == 0) {
                    continue;
                }
                [self observeH264LaneRegion:&regions[i]
                                      laneId:laneId
                                     frameId:_frameId];
                h264_region_stream_t *stream =
                    [self h264StreamForRegion:laneId
                                        create:NO
                                       frameId:_frameId];
                if (stream == NULL ||
                    stream->consecutive_frames < SHARP_H264_REGION_WARMUP_FRAMES) {
                    if (stream != NULL) {
                        stream->warmup_skips++;
                    }
                    _h264WarmupSkips++;
                    continue;
                }
                int hasEncoder = 0;
                for (size_t e = 0; e < SHARP_H264_ENCODER_SLOTS; e++) {
                    if (_h264Encoders[e].active &&
                        _h264Encoders[e].region_id == laneId) {
                        hasEncoder = 1;
                        break;
                    }
                }
                if (!hasEncoder && activeEncoderCount >= SHARP_H264_MAX_ACTIVE_REGIONS) {
                    stream->warmup_skips++;
                    _h264WarmupSkips++;
                    continue;
                }
                int alreadySelectedLane = 0;
                for (size_t s = 0; s < selectedRegionCount; s++) {
                    if (selectedRegions[s].id == laneId) {
                        alreadySelectedLane = 1;
                        break;
                    }
                }
                if (alreadySelectedLane) {
                    continue;
                }
                sharp_m2_region_t encodeRegion = regions[i];
                encodeRegion.id = laneId;
                encodeRegion.event = SHARP_M2_REGION_STABLE;
                encodeRegion.x = stream->x;
                encodeRegion.y = stream->y;
                encodeRegion.w = stream->width;
                encodeRegion.h = stream->height;
                uint64_t area = (uint64_t)encodeRegion.w * encodeRegion.h;
                uint64_t score = area +
                                 (uint64_t)stream->consecutive_frames * 1000000ULL;
                if (stream->has_keyframe && !stream->need_keyframe) {
                    score += 1000000000000ULL;
                }
                insert_selected_region(selectedRegions, selectedRegionScores,
                                       &selectedRegionCount, &encodeRegion, score);
            }
            for (size_t e = 0; !_fullFrameActive && !_motionMaskEnabled &&
                               e < SHARP_H264_ENCODER_SLOTS; e++) {
                if (!_h264Encoders[e].active) {
                    continue;
                }
                if (_h264Encoders[e].region_id < SHARP_H264_FIRST_LANE_ID ||
                    _h264Encoders[e].region_id >=
                        SHARP_H264_FIRST_LANE_ID + SHARP_H264_MAX_ACTIVE_REGIONS) {
                    continue;
                }
                h264_region_stream_t *stream =
                    [self h264StreamForRegion:_h264Encoders[e].region_id
                                        create:NO
                                       frameId:_frameId];
                if (stream == NULL || stream->width == 0 || stream->height == 0 ||
                    _frameId < stream->last_seen_frame ||
                    _frameId - stream->last_seen_frame >
                        SHARP_H264_REGION_IDLE_GRACE_FRAMES) {
                    continue;
                }
                int alreadySelected = 0;
                for (size_t s = 0; s < selectedRegionCount; s++) {
                    if (selectedRegions[s].id == stream->region_id) {
                        alreadySelected = 1;
                        break;
                    }
                }
                if (alreadySelected) {
                    continue;
                }
                sharp_m2_region_t keepaliveRegion;
                memset(&keepaliveRegion, 0, sizeof(keepaliveRegion));
                keepaliveRegion.id = stream->region_id;
                keepaliveRegion.x = stream->x;
                keepaliveRegion.y = stream->y;
                keepaliveRegion.w = stream->width;
                keepaliveRegion.h = stream->height;
                keepaliveRegion.event = SHARP_M2_REGION_STABLE;
                uint64_t score = 1000000000000ULL +
                                 (uint64_t)stream->consecutive_frames * 1000000ULL +
                                 (uint64_t)keepaliveRegion.w * keepaliveRegion.h;
                insert_selected_region(selectedRegions, selectedRegionScores,
                                       &selectedRegionCount, &keepaliveRegion, score);
            }
            for (size_t i = 0; i < selectedRegionCount; i++) {
                h264_region_stream_t *stream =
                    [self h264StreamForRegion:(uint16_t)selectedRegions[i].id
                                        create:NO
                                       frameId:_frameId];
                forceRegionKeyframe[i] =
                    stream == NULL || !stream->has_keyframe ||
                    stream->need_keyframe ||
                    selectedRegions[i].event == SHARP_M2_REGION_BORN;
                if (stream != NULL) {
                    stream->selected_frames++;
                }
                if (stream != NULL && stream->force_idr && forceRegionKeyframe[i]) {
                    stream->idr_sent++;
                    _h264IdrSent++;
                    if (_h264HaveKeyframeRequest &&
                        _h264RequestedRegion == (uint16_t)selectedRegions[i].id) {
                        _h264HaveKeyframeRequest = NO;
                        _h264RequestIsIdr = NO;
                    }
                } else if (_h264HaveKeyframeRequest &&
                           _h264RequestedRegion == (uint16_t)selectedRegions[i].id) {
                    if (_h264RequestIsIdr && forceRegionKeyframe[i]) {
                        if (stream != NULL) {
                            stream->idr_sent++;
                        }
                        _h264IdrSent++;
                    }
                    _h264HaveKeyframeRequest = NO;
                    _h264RequestIsIdr = NO;
                }
            }
            if (selectedRegionCount > _h264MaxActiveRegions) {
                _h264MaxActiveRegions = selectedRegionCount;
            }
            for (size_t i = 0; i < dirtyCount; i++) {
                uint16_t tileId = dirty[i];
                if (sharp_m2_classifier_tile_class(_m2Classifier, tileId) !=
                    SHARP_M2_TILE_MOTION) {
                    continue;
                }
                frameMotionCandidateTiles++;
                if (sharp_m2_classifier_tile_consecutive_frames(_m2Classifier,
                                                                tileId) >= 5u) {
                    sustainedMotionTiles++;
                }
                int covered = 0;
                for (size_t r = 0; r < selectedRegionCount; r++) {
                    if (region_contains_tile(&selectedRegions[r], _width, _height,
                                             tileId)) {
                        covered = 1;
                        break;
                    }
                }
                if (!covered) {
                    frameUncoveredMotionTiles++;
                }
            }
            BOOL wasFullFrameActive = _fullFrameActive;
            uint32_t frameActivityTiles =
                (uint32_t)MIN(dirtyCount, (size_t)UINT32_MAX);
            [self updateFullFrameModeWithMotionTiles:frameMotionCandidateTiles
                                        activityTiles:frameActivityTiles
                                 sustainedMotionTiles:sustainedMotionTiles
                                      uncoveredTiles:frameUncoveredMotionTiles
                                       motionRegions:stableMotionRegionCount
                                            tileCount:tileCount
                                            forceFull:forceAll ? YES : NO];
            if (_fullFrameActive) {
                selectedRegionCount = 0;
                memset(forceRegionKeyframe, 0, sizeof(forceRegionKeyframe));
            }
            if (_motionMaskEnabled) {
                if (!wasFullFrameActive && _fullFrameActive) {
                    [self beginFullFrameEpisodeForTileCount:tileCount];
                }
                if (_fullFrameActive) {
                    /*
                     * Never expose a checkerboard of lossless tile times over
                     * a moving video frame.  A full-frame episode is one
                     * temporal owner for the whole scanout; byte-exact tiles
                     * are restored together when the episode settles.
                     */
                    [self clearCurrentMotionMask];
                    for (uint32_t tileId = 0; tileId < tileCount; tileId++) {
                        [self addMotionMaskTile:(uint16_t)tileId];
                    }
                }
            }
        }
    }

    size_t sendCount = 0;
    BOOL refineAllThisFrame = _fullFrameExitRefinePending && !_motionMaskEnabled;
    BOOL refineEpisodeThisFrame = _fullFrameExitRefinePending;
    if (refineAllThisFrame) {
        _fullFrameExitRefinePending = NO;
        _fullFrameExitRefinementTiles += tileCount;
    }
    for (size_t i = 0; i < dirtyCount; i++) {
        uint16_t tileId = dirty[i];
        uint8_t tileKind = forceAll ? SCREEN_TX_TILE_INITIAL_SYNC
                                    : SCREEN_TX_TILE_STATIC_DETAIL;
        if (_hybridH264 && _fullFrameActive && !forceAll) {
            BOOL motionTile =
                _m2Classifier != NULL &&
                sharp_m2_classifier_tile_class(_m2Classifier, tileId) ==
                    SHARP_M2_TILE_MOTION;
            if (motionTile) {
                _h264MotionCandidateTiles++;
                _h264MotionCoveredTiles++;
                _fullFrameMotionCandidateTiles++;
                _fullFrameMotionCoveredTiles++;
            }
            /* Video owns every visible pixel until the atomic exit refine. */
            _fullFrameSuppressedLosslessTiles++;
            continue;
        }
        if (_m2Classifier != NULL &&
            sharp_m2_classifier_tile_class(_m2Classifier, tileId) ==
                SHARP_M2_TILE_MOTION) {
            _h264MotionCandidateTiles++;
            h264_region_stream_t *coveredStream = NULL;
            for (size_t r = 0; r < selectedRegionCount; r++) {
                if (region_contains_tile(&selectedRegions[r], _width, _height,
                                         tileId)) {
                    coveredStream =
                        [self h264StreamForRegion:(uint16_t)selectedRegions[r].id
                                            create:NO
                                           frameId:_frameId];
                    break;
                }
            }
            if (coveredStream != NULL) {
                _h264MotionCoveredTiles++;
                coveredStream->candidate_motion_tiles++;
                coveredStream->covered_motion_tiles++;
                continue;
            }
            _h264MotionFallbackLosslessTiles++;
            tileKind = SCREEN_TX_TILE_MOTION_FALLBACK;
        }
        if (tileId < tileCount && !sendSeen[tileId]) {
            sendSeen[tileId] = 1u;
            sendKinds[tileId] = tileKind;
            sendTiles[sendCount++] = tileId;
        }
    }
    size_t refinementLoopCount = refineAllThisFrame ? tileCount : refineCount;
    for (size_t i = 0; i < refinementLoopCount; i++) {
        uint16_t tileId = refineAllThisFrame ? (uint16_t)i : refineTiles[i];
        if (_hybridH264 && _fullFrameActive && !forceAll) {
            BOOL motionTile =
                _m2Classifier != NULL &&
                sharp_m2_classifier_tile_class(_m2Classifier, tileId) ==
                    SHARP_M2_TILE_MOTION;
            if (!_motionMaskEnabled || motionTile) {
                _fullFrameSuppressedLosslessTiles++;
                continue;
            }
        }
        if (tileId < tileCount && !sendSeen[tileId]) {
            sendSeen[tileId] = 1u;
            sendKinds[tileId] = forceAll ? SCREEN_TX_TILE_INITIAL_SYNC
                                         : SCREEN_TX_TILE_REFINEMENT;
            sendTiles[sendCount++] = tileId;
        }
    }
    if (_motionMaskEnabled && refineEpisodeThisFrame &&
        _fullFrameEpisodeMask != NULL) {
        uint32_t episodeTileCount = sharp_tile_count(_width, _height);
        for (uint32_t tileId = 0; tileId < episodeTileCount; tileId++) {
            if ((_fullFrameEpisodeMask[tileId >> 3] &
                 (uint8_t)(1u << (tileId & 7u))) == 0 || sendSeen[tileId]) {
                continue;
            }
            sendSeen[tileId] = 1u;
            sendKinds[tileId] = SCREEN_TX_TILE_REFINEMENT;
            sendTiles[sendCount++] = (uint16_t)tileId;
        }
        _fullFrameExitRefinementTiles += [self countMotionMaskTiles:episodeTileCount];
    }

    uint64_t analyzeDoneNs = shtp_now_ns();
    [self recordAnalyzerDoneForFrameId:_frameId timestamp:analyzeDoneNs];
    uint64_t packetsBefore = _stats.packets;
    uint64_t bytesBefore = _stats.bytes;
    uint64_t h264PacketsBefore = _h264Packets;
    uint64_t h264BytesBefore = _h264Bytes;
    int sendFailed = 0;
    [self drainFeedback];
    BOOL encodeFullFrameThisFrame =
        _hybridH264 && _fullFrameActive && !preSubmittedFullFrame;
    BOOL submittedFullFrame = preSubmittedFullFrame;
    if (encodeFullFrameThisFrame) {
        BOOL forceFullFrameKeyframe =
            _fullFrameForceKeyframe ||
            (_h264HaveKeyframeRequest &&
             _h264RequestedRegion == SHARP_H264_FULLFRAME_ID);
        submittedFullFrame =
            [self encodeH264FullFrame:pixelBuffer
                              frameId:_frameId
                        forceKeyframe:forceFullFrameKeyframe
                               direct:_fullFrameDirectFeed
                         sourceLocked:_fullFrameDirectFeed ? NO : YES
                         emitFrameEnd:sendCount == 0 ? YES : NO];
        if (submittedFullFrame && forceFullFrameKeyframe) {
            _fullFrameForceKeyframe = NO;
            if (_h264HaveKeyframeRequest &&
                _h264RequestedRegion == SHARP_H264_FULLFRAME_ID) {
                if (_h264RequestIsIdr) {
                    _h264IdrSent++;
                }
                _h264HaveKeyframeRequest = NO;
                _h264RequestIsIdr = NO;
            }
        }
    } else {
        for (size_t i = 0; i < selectedRegionCount; i++) {
            [self drainFeedback];
            [self encodeH264Region:&selectedRegions[i]
                              bgra:base
                            stride:stride
                           frameId:_frameId
                      forceKeyframe:forceRegionKeyframe[i]];
        }
    }
    [self traceFullFrameFrameId:_frameId
                  preSubmitted:preSubmittedFullFrame
                     submitted:submittedFullFrame
                   forceKeyframe:_fullFrameTraceKeyframeAttempted];
    screen_tx_frame_job_t *txJob = NULL;
    BOOL fullFrameUsesCallbackFrameEnd =
        preSubmittedFullFrame || (submittedFullFrame && sendCount == 0);
    uint16_t videoRegionCount =
        (uint16_t)(selectedRegionCount +
                   (submittedFullFrame && !fullFrameUsesCallbackFrameEnd ? 1u
                                                                         : 0u));
    if ((sendCount > 0 || videoRegionCount > 0 ||
         (_motionMaskEnabled && refineEpisodeThisFrame)) && !sendFailed) {
        size_t jobSize = sizeof(*txJob) + sendCount * sizeof(txJob->tiles[0]);
        txJob = calloc(1, jobSize);
        if (txJob == NULL) {
            _invalidFrames++;
            sendFailed = 1;
        } else {
            txJob->frame_id = _frameId;
            txJob->enqueue_ns = shtp_now_ns();
            txJob->tile_count = (uint16_t)sendCount;
            txJob->expected_patches = (uint16_t)(sendCount + videoRegionCount);
            txJob->video_region_count = videoRegionCount;
            for (size_t r = 0; r < selectedRegionCount; r++) {
                if (selectedRegions[r].id > 0 && selectedRegions[r].id < 16u) {
                    txJob->video_region_mask |=
                        (uint16_t)(1u << selectedRegions[r].id);
                }
            }
            if (submittedFullFrame && !fullFrameUsesCallbackFrameEnd) {
                txJob->video_region_mask |=
                    (uint16_t)(1u << SHARP_H264_FULLFRAME_ID);
            }
            if (_motionMaskEnabled &&
                (_fullFrameActive || refineEpisodeThisFrame) &&
                _fullFrameCurrentMask != NULL) {
                size_t maskBytes = (tileCount + 7u) / 8u;
                if (maskBytes == 0 || maskBytes > UINT16_MAX) {
                    sendFailed = 1;
                } else {
                    txJob->motion_mask = malloc(maskBytes);
                    if (txJob->motion_mask == NULL) {
                        sendFailed = 1;
                    } else {
                        /*
                         * An exit refinement describes the desired post-episode
                         * mask, not the set of tiles that need refinement. Ask
                         * the receiver to close every hole; its generation gate
                         * keeps a hole open until that tile's lossless update for
                         * this frame has arrived.
                         */
                        if (refineEpisodeThisFrame && !_fullFrameActive) {
                            memset(txJob->motion_mask, 0, maskBytes);
                        } else {
                            memcpy(txJob->motion_mask, _fullFrameCurrentMask,
                                   maskBytes);
                        }
                        txJob->motion_mask_bytes = (uint16_t)maskBytes;
                        txJob->has_motion_mask = 1u;
                    }
                }
            }
            txJob->initial_sync = forceAll ? 1u : 0u;
            for (size_t i = 0; i < sendCount; i++) {
                sharp_tile_rect_t rect;
                if (sharp_tile_rect_for_id(_width, _height, sendTiles[i], &rect) != 0) {
                    _invalidFrames++;
                    sendFailed = 1;
                    break;
                }
                txJob->tiles[i].tile_id = sendTiles[i];
                txJob->tiles[i].kind = sendKinds[sendTiles[i]];
                txJob->tiles[i].rect = rect;
                txJob->estimated_bytes += (uint64_t)rect.w * (uint64_t)rect.h * 4u;
                if (txJob->tiles[i].kind == SCREEN_TX_TILE_INITIAL_SYNC ||
                    txJob->tiles[i].kind == SCREEN_TX_TILE_STATIC_DETAIL) {
                    txJob->static_tiles++;
                } else if (txJob->tiles[i].kind == SCREEN_TX_TILE_REFINEMENT) {
                    txJob->refine_tiles++;
                } else if (txJob->tiles[i].kind == SCREEN_TX_TILE_MOTION_FALLBACK) {
                    txJob->motion_fallback_tiles++;
                }
                const uint8_t *src =
                    base + (size_t)rect.y * stride + (size_t)rect.x * 4u;
                uint8_t *dst = txJob->tiles[i].bgra;
                size_t rowBytes = (size_t)rect.w * 4u;
                for (uint32_t row = 0; row < rect.h; row++) {
                    memcpy(dst + (size_t)row * rowBytes,
                           src + (size_t)row * stride, rowBytes);
                }
            }
            _txEstimatedBytes += txJob->estimated_bytes;
            if (sendFailed) {
                free(txJob->motion_mask);
                free(txJob);
                txJob = NULL;
            }
        }
    }
    if (_motionPrerollEnabled && _motionMaskEnabled && !forceAll) {
        if (_fullFrameActive) {
            if (_motionPrerollJob != NULL) {
                free(_motionPrerollJob->motion_mask);
                free(_motionPrerollJob);
                _motionPrerollJob = NULL;
                _motionPrerollDeadlineNs = 0;
                _motionPrerollDiscardedFrames++;
            }
        } else if (broadActivityThisFrame && txJob != NULL &&
                   txJob->video_region_count == 0 &&
                   !txJob->has_motion_mask) {
            _motionPrerollJob =
                [self mergeMotionPrerollJob:_motionPrerollJob
                                    withJob:txJob
                                       bgra:base
                                     stride:stride
                                  tileCount:tileCount];
            txJob = NULL;
            _motionPrerollHeldFrames++;
            [self scheduleMotionPrerollDeadline];
        } else if (!broadActivityThisFrame && _motionPrerollJob != NULL) {
            if (txJob != NULL && txJob->video_region_count == 0 &&
                !txJob->has_motion_mask) {
                txJob = [self mergeMotionPrerollJob:_motionPrerollJob
                                            withJob:txJob
                                               bgra:base
                                             stride:stride
                                          tileCount:tileCount];
            } else if (txJob == NULL) {
                txJob = _motionPrerollJob;
            } else {
                free(_motionPrerollJob->motion_mask);
                free(_motionPrerollJob);
            }
            _motionPrerollJob = NULL;
            _motionPrerollDeadlineNs = 0;
            _motionPrerollReleasedFrames++;
        }
    }
    uint64_t sendDoneNs = shtp_now_ns();

    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    if (txJob != NULL) {
        if (refineEpisodeThisFrame && txJob->has_motion_mask) {
            _fullFrameExitRefinePending = NO;
            memset(_fullFrameEpisodeMask, 0, _fullFrameEpisodeMaskCap);
            memset(_fullFrameCurrentMask, 0, _fullFrameEpisodeMaskCap);
            _fullFrameEpisodeMaskTiles = 0;
        }
        /* Ownership transfers to the queue, which may free the job at once. */
        [self enqueueTxFrameJob:txJob];
        if (selectedRegionCount > 0 && _vsliceDropEvery > 0) {
            dispatch_async(_txQueue, ^{
              int repairDrains = 8 + (int)selectedRegionCount * 8;
              for (int i = 0; i < repairDrains; i++) {
                  usleep(1000);
                  [self drainFeedback];
                  _h264PostFrameRepairDrains++;
              }
            });
        }
    }

    BOOL outputProduced =
        sendCount > 0 || videoRegionCount > 0 || fullFrameUsesCallbackFrameEnd ||
        txJob != NULL;
    if (outputProduced && !sendFailed) {
        _sentFrames++;
        if (forceAll) {
            _fullFrames++;
        }
    } else if (!outputProduced) {
        _idleFrames++;
    }
    _stats.frames++;
    _frameId++;
    if (_firstFrameNs == 0) {
        _firstFrameNs = shtp_now_ns();
    }
    _lastFrameNs = shtp_now_ns();

    if (_frameLog != NULL) {
        uint64_t framePackets = _stats.packets - packetsBefore;
        uint64_t frameBytes = _stats.bytes - bytesBefore;
        double analyzeUs = (double)(analyzeDoneNs - analyzeStartNs) / 1000.0;
        double sendUs = (double)(sendDoneNs - analyzeDoneNs) / 1000.0;
        fprintf(_frameLog,
                "%u\t%" PRIu64 "\t%" PRIu64 "\t%" PRIu64 "\t%.1f\t%.1f\t%zu\t%"
                PRIu64 "\t%" PRIu64 "\t%d\t%d\n",
                _frameId - 1u, callbackNs, analyzeStartNs, sendDoneNs, analyzeUs,
                sendUs, dirtyCount, frameBytes, framePackets, forceAll, sendFailed);
        fflush(_frameLog);
    }

    if (_m2Log != NULL && _m2Classifier != NULL) {
        sharp_m2_region_t regions[256];
        size_t regionCount =
            sharp_m2_classifier_regions(_m2Classifier, regions,
                                        sizeof(regions) / sizeof(regions[0]));
        fprintf(_m2Log,
                "%u\t%zu\t%zu\t%zu\t%zu\t%zu\t%zu\t%zu\t%zu\t%zu\t%zu\t",
                _frameId - 1u, dirtyCount, sendCount, m2Result.static_tiles,
                m2Result.motion_tiles, m2Result.pending_refine_tiles,
                m2Result.refine_tiles, m2Result.regions, m2Result.born_regions,
                m2Result.resized_regions, m2Result.died_regions);
        for (size_t i = 0; i < regionCount && i < sizeof(regions) / sizeof(regions[0]);
             i++) {
            if (regions[i].event == SHARP_M2_REGION_STABLE) {
                continue;
            }
            fprintf(_m2Log, "%s:%u:%ux%u+%u+%u;",
                    sharp_m2_region_event_name(regions[i].event), regions[i].id,
                    regions[i].w, regions[i].h, regions[i].x, regions[i].y);
        }
        fprintf(_m2Log, "\n");
        fflush(_m2Log);
    }
    (void)h264PacketsBefore;
    (void)h264BytesBefore;
    SHARP_RECORD_PROCESS_DURATION();
#undef SHARP_RECORD_PROCESS_DURATION
}
@end
