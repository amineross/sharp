#import "Internal.h"

@implementation SharpScreenSender
@synthesize fd = _fd;
@synthesize width = _width;
@synthesize height = _height;
@synthesize sequence = _sequence;
@synthesize frameId = _frameId;
@synthesize payloadSize = _payloadSize;
@synthesize fps = _fps;
@synthesize initialFullFrames = _initialFullFrames;
@synthesize fullRefreshIntervalNs = _fullRefreshIntervalNs;
@synthesize nextFullRefreshNs = _nextFullRefreshNs;
@synthesize pacingMbps = _pacingMbps;
@synthesize dirtyMap = _dirtyMap;
@synthesize stats = _stats;
@synthesize firstFrameNs = _firstFrameNs;
@synthesize captureStartNs = _captureStartNs;
@synthesize firstH264Ns = _firstH264Ns;
@synthesize lastFrameNs = _lastFrameNs;
@synthesize captureCallbacks = _captureCallbacks;
@synthesize sentFrames = _sentFrames;
@synthesize idleFrames = _idleFrames;
@synthesize fullFrames = _fullFrames;
@synthesize dirtyRectFrames = _dirtyRectFrames;
@synthesize dirtyRects = _dirtyRects;
@synthesize dirtyRectScaledFrames = _dirtyRectScaledFrames;
@synthesize dirtyRectClipped = _dirtyRectClipped;
@synthesize candidateTiles = _candidateTiles;
@synthesize falseDirtyTiles = _falseDirtyTiles;
@synthesize metadataFallbackFrames = _metadataFallbackFrames;
@synthesize skippedFrames = _skippedFrames;
@synthesize replacedFrames = _replacedFrames;
@synthesize invalidFrames = _invalidFrames;
@synthesize frameLog = _frameLog;
@synthesize m2Log = _m2Log;
@synthesize episodeLog = _episodeLog;
@synthesize m2Classifier = _m2Classifier;
@synthesize m2MotionFrames = _m2MotionFrames;
@synthesize m2MotionTiles = _m2MotionTiles;
@synthesize m2RefineTiles = _m2RefineTiles;
@synthesize m2BornRegions = _m2BornRegions;
@synthesize m2ResizedRegions = _m2ResizedRegions;
@synthesize m2DiedRegions = _m2DiedRegions;
@synthesize hybridH264 = _hybridH264;
@synthesize h264Session = _h264Session;
@synthesize h264Width = _h264Width;
@synthesize h264Height = _h264Height;
@synthesize h264RegionId = _h264RegionId;
@synthesize h264Generation = _h264Generation;
@synthesize h264Frames = _h264Frames;
@synthesize h264EncodeSubmissions = _h264EncodeSubmissions;
@synthesize h264EncodeInFlight = _h264EncodeInFlight;
@synthesize h264MaxEncodeInFlight = _h264MaxEncodeInFlight;
@synthesize h264PixelBufferPoolCreates = _h264PixelBufferPoolCreates;
@synthesize h264PixelBufferPoolFailures = _h264PixelBufferPoolFailures;
@synthesize h264FrameEndWaits = _h264FrameEndWaits;
@synthesize h264FrameEndWaitTimeouts = _h264FrameEndWaitTimeouts;
@synthesize h264FrameEndVideoDrops = _h264FrameEndVideoDrops;
@synthesize h264Packets = _h264Packets;
@synthesize h264Bytes = _h264Bytes;
@synthesize h264TargetBitrate = _h264TargetBitrate;
@synthesize h264Keyframes = _h264Keyframes;
@synthesize h264EncodeFailures = _h264EncodeFailures;
@synthesize h264FeedbackPackets = _h264FeedbackPackets;
@synthesize h264FullFrameFeedbackIgnored = _h264FullFrameFeedbackIgnored;
@synthesize h264FullFrameKeyframeRequests = _h264FullFrameKeyframeRequests;
@synthesize h264MissingGenerations = _h264MissingGenerations;
@synthesize h264KeyframeRequests = _h264KeyframeRequests;
@synthesize h264VsliceNacks = _h264VsliceNacks;
@synthesize h264RetransmitPackets = _h264RetransmitPackets;
@synthesize h264RetransmitBytes = _h264RetransmitBytes;
@synthesize h264RetransmitMisses = _h264RetransmitMisses;
@synthesize h264IdrRequests = _h264IdrRequests;
@synthesize h264IdrSent = _h264IdrSent;
@synthesize h264MaxActiveRegions = _h264MaxActiveRegions;
@synthesize h264Pframes = _h264Pframes;
@synthesize h264WarmupSkips = _h264WarmupSkips;
@synthesize h264MotionCandidateTiles = _h264MotionCandidateTiles;
@synthesize h264MotionCoveredTiles = _h264MotionCoveredTiles;
@synthesize h264MotionFallbackLosslessTiles = _h264MotionFallbackLosslessTiles;
@synthesize h264LaneAdoptions = _h264LaneAdoptions;
@synthesize h264LaneBirths = _h264LaneBirths;
@synthesize h264LaneRetires = _h264LaneRetires;
@synthesize fullFrameEnabled = _fullFrameEnabled;
@synthesize fullFrameDirectFeed = _fullFrameDirectFeed;
@synthesize motionMaskEnabled = _motionMaskEnabled;
@synthesize motionPrerollEnabled = _motionPrerollEnabled;
@synthesize motionPrerollHeldFrames = _motionPrerollHeldFrames;
@synthesize motionPrerollReleasedFrames = _motionPrerollReleasedFrames;
@synthesize motionPrerollDiscardedFrames = _motionPrerollDiscardedFrames;
@synthesize fullFrameActive = _fullFrameActive;
@synthesize fullFrameForceKeyframe = _fullFrameForceKeyframe;
@synthesize fullFrameExitRefinePending = _fullFrameExitRefinePending;
@synthesize fullFrameMotionStartNs = _fullFrameMotionStartNs;
@synthesize fullFrameQuietStartNs = _fullFrameQuietStartNs;
@synthesize fullFrameEnteredNs = _fullFrameEnteredNs;
@synthesize fullFrameLastExitNs = _fullFrameLastExitNs;
@synthesize fullFrameEntries = _fullFrameEntries;
@synthesize fullFrameExits = _fullFrameExits;
@synthesize fullFrameModeFrames = _fullFrameModeFrames;
@synthesize fullFrameH264Frames = _fullFrameH264Frames;
@synthesize fullFrameH264Bytes = _fullFrameH264Bytes;
@synthesize fullFrameProcessedFrames = _fullFrameProcessedFrames;
@synthesize fullFrameEncodeSubmissions = _fullFrameEncodeSubmissions;
@synthesize fullFrameEncodeInFlight = _fullFrameEncodeInFlight;
@synthesize fullFrameMaxEncodeInFlight = _fullFrameMaxEncodeInFlight;
@synthesize fullFrameSendDrops = _fullFrameSendDrops;
@synthesize fullFrameTraceUntilNs = _fullFrameTraceUntilNs;
@synthesize fullFrameTraceSendDropsBase = _fullFrameTraceSendDropsBase;
@synthesize fullFrameTraceKeyframeAttempted = _fullFrameTraceKeyframeAttempted;
@synthesize fullFrameFrameEndsFromCallback = _fullFrameFrameEndsFromCallback;
@synthesize fullFrameDirectSubmissions = _fullFrameDirectSubmissions;
@synthesize fullFrameCopiedSubmissions = _fullFrameCopiedSubmissions;
@synthesize fullFrameDirectFallbacks = _fullFrameDirectFallbacks;
@synthesize fullFrameAnalyzerSkippedFrames = _fullFrameAnalyzerSkippedFrames;
@synthesize fullFrameExitRefinementTiles = _fullFrameExitRefinementTiles;
@synthesize fullFrameEpisodeMaskTiles = _fullFrameEpisodeMaskTiles;
@synthesize fullFrameEpisodeMaskPeakTiles = _fullFrameEpisodeMaskPeakTiles;
@synthesize fullFrameMotionCandidateTiles = _fullFrameMotionCandidateTiles;
@synthesize fullFrameMotionCoveredTiles = _fullFrameMotionCoveredTiles;
@synthesize fullFrameSuppressedLosslessTiles = _fullFrameSuppressedLosslessTiles;
@synthesize h264AdaptiveBitrateEnabled = _h264AdaptiveBitrateEnabled;
@synthesize h264AdaptiveBitrate = _h264AdaptiveBitrate;
@synthesize h264AdaptiveMinBitrate = _h264AdaptiveMinBitrate;
@synthesize h264AdaptiveMaxBitrate = _h264AdaptiveMaxBitrate;
@synthesize h264AdaptiveLastAdjustNs = _h264AdaptiveLastAdjustNs;
@synthesize h264AdaptiveBackoffs = _h264AdaptiveBackoffs;
@synthesize h264AdaptiveRamps = _h264AdaptiveRamps;
@synthesize txFrames = _txFrames;
@synthesize txTiles = _txTiles;
@synthesize txFailures = _txFailures;
@synthesize txFrameEnds = _txFrameEnds;
@synthesize txDroppedJobs = _txDroppedJobs;
@synthesize txDroppedTiles = _txDroppedTiles;
@synthesize txDroppedMotionFallbackTiles = _txDroppedMotionFallbackTiles;
@synthesize txDroppedRefineTiles = _txDroppedRefineTiles;
@synthesize txDroppedStaleFrames = _txDroppedStaleFrames;
@synthesize txCoalescedJobs = _txCoalescedJobs;
@synthesize txMaxPendingJobs = _txMaxPendingJobs;
@synthesize txMaxJobAgeMs = _txMaxJobAgeMs;
@synthesize txEstimatedBytes = _txEstimatedBytes;
@synthesize cleanupReplacedTiles = _cleanupReplacedTiles;
@synthesize cleanupCoalescedTiles = _cleanupCoalescedTiles;
@synthesize cleanupCancelledTiles = _cleanupCancelledTiles;
@synthesize cleanupSentTiles = _cleanupSentTiles;
@synthesize cleanupProtectedTiles = _cleanupProtectedTiles;
@synthesize cleanupObsoleteTiles = _cleanupObsoleteTiles;
@synthesize cleanupMaxLatencyMs = _cleanupMaxLatencyMs;
@synthesize tileDigestPackets = _tileDigestPackets;
@synthesize tileDigestEntries = _tileDigestEntries;
@synthesize tileDigestMismatches = _tileDigestMismatches;
@synthesize tileDigestRepairsQueued = _tileDigestRepairsQueued;
@synthesize txOldestCleanupAgeMs = _txOldestCleanupAgeMs;
@synthesize txLatestSourceLagMaxFrames = _txLatestSourceLagMaxFrames;
@synthesize h264InducedDrops = _h264InducedDrops;
@synthesize h264OriginalPackets = _h264OriginalPackets;
@synthesize h264FecPackets = _h264FecPackets;
@synthesize h264FecBytes = _h264FecBytes;
@synthesize h264ResendEvictions = _h264ResendEvictions;
@synthesize h264ResendRepairEvictions = _h264ResendRepairEvictions;
@synthesize h264FreshMotionSkippedForRepair = _h264FreshMotionSkippedForRepair;
@synthesize h264RepairPressureFrames = _h264RepairPressureFrames;
@synthesize h264PostFrameRepairDrains = _h264PostFrameRepairDrains;
@synthesize h264ResendTarget = _h264ResendTarget;
@synthesize h264ResendMaxActive = _h264ResendMaxActive;
@synthesize h264RequestedRegion = _h264RequestedRegion;
@synthesize h264HaveKeyframeRequest = _h264HaveKeyframeRequest;
@synthesize h264RequestIsIdr = _h264RequestIsIdr;
@synthesize vsliceDropEvery = _vsliceDropEvery;
@synthesize fecEnabled = _fecEnabled;
@synthesize encodeTickEnabled = _encodeTickEnabled;
@synthesize tileBatchEnabled = _tileBatchEnabled;
@synthesize tileZstdEnabled = _tileZstdEnabled;
@synthesize encodeTickFires = _encodeTickFires;
@synthesize encodeTickIdleSkips = _encodeTickIdleSkips;
@synthesize phaseLockEnabled = _phaseLockEnabled;
@synthesize vtLowLatencyRequested = _vtLowLatencyRequested;
@synthesize vtLowLatencyActive = _vtLowLatencyActive;
@synthesize vtLowLatencyFallbacks = _vtLowLatencyFallbacks;
@synthesize vtSpeedPriorityActive = _vtSpeedPriorityActive;
@synthesize vtFrameDelayBounded = _vtFrameDelayBounded;
@synthesize vtFastProfileRequested = _vtFastProfileRequested;
@synthesize vtFastProfileActive = _vtFastProfileActive;
@synthesize vtReferenceBufferBounded = _vtReferenceBufferBounded;
@synthesize vtHardwareEncoder = _vtHardwareEncoder;
@synthesize vtNv12Requested = _vtNv12Requested;
@synthesize vtNv12Active = _vtNv12Active;
@synthesize vtPixelTransferFailures = _vtPixelTransferFailures;
@synthesize phaseLockFeedbackReports = _phaseLockFeedbackReports;
@synthesize phaseLockTimerAdjustments = _phaseLockTimerAdjustments;
@synthesize phaseLockTimerAdjustmentAbsNs = _phaseLockTimerAdjustmentAbsNs;
@synthesize phaseLockLeadNs = _phaseLockLeadNs;
@synthesize phaseLockLastPeriodNs = _phaseLockLastPeriodNs;
@synthesize phaseLockLastErrorNs = _phaseLockLastErrorNs;
@synthesize phaseLockLastAdjustmentNs = _phaseLockLastAdjustmentNs;
@synthesize pacingNextNs = _pacingNextNs;
@synthesize processingQueue = _processingQueue;
@synthesize txQueue = _txQueue;
@synthesize h264OutputQueue = _h264OutputQueue;
- (instancetype)init {
    self = [super init];
    if (self != nil) {
        pthread_mutex_init(&_sendLock, NULL);
        pthread_mutex_init(&_timingLock, NULL);
    }
    return self;
}

- (void)dealloc {
    [self stopEncodeTick];
    if (_verifiedTimer) dispatch_source_cancel(_verifiedTimer);
    if (_verifiedSource) { sharp_hybrid_source_destroy(_verifiedSource); free(_verifiedSource); }
    if (_pendingSampleBuffer != NULL) {
        CFRelease(_pendingSampleBuffer);
        _pendingSampleBuffer = NULL;
    }
    if (_lastCompleteSampleBuffer != NULL) {
        CFRelease(_lastCompleteSampleBuffer);
        _lastCompleteSampleBuffer = NULL;
    }
    sharp_tile_zstd_cctx_destroy(_tileZstdCCtx);
    free(_h264FecParityScratch);
    free(_fullFrameEpisodeMask);
    free(_fullFrameCurrentMask);
    pthread_mutex_destroy(&_timingLock);
    pthread_mutex_destroy(&_sendLock);
}

- (sharp_tile_sender_codec_t)tileCodec {
    sharp_tile_sender_codec_t codec;
    memset(&codec, 0, sizeof(codec));
    codec.session = _verifiedSession;
    if (_tileZstdEnabled && _tileZstdCCtx != NULL) {
        codec.zstd_enabled = 1;
        codec.zstd_cctx = _tileZstdCCtx;
    }
    return codec;
}

- (BOOL)ensureTileZstdContext {
    if (_tileZstdCCtx != NULL) {
        return YES;
    }
    _tileZstdCCtx = sharp_tile_zstd_cctx_create();
    return _tileZstdCCtx != NULL ? YES : NO;
}

- (int)ensureFrameScratchCapacity:(uint32_t)tileCount {
    if (tileCount == 0) {
        return -1;
    }
    if (_scratchTileCap >= tileCount && _dirtyScratch != NULL &&
        _sendScratch != NULL && _refineScratch != NULL &&
        _m2ProbeScratch != NULL && _sendSeenScratch != NULL &&
        _sendKindScratch != NULL &&
        _rectScratch != NULL) {
        return 0;
    }
    uint16_t *dirty = realloc(_dirtyScratch, (size_t)tileCount * sizeof(dirty[0]));
    uint16_t *send = realloc(_sendScratch, (size_t)tileCount * sizeof(send[0]));
    uint16_t *refine = realloc(_refineScratch, (size_t)tileCount * sizeof(refine[0]));
    sharp_m2_tile_probe_t *probes =
        realloc(_m2ProbeScratch, (size_t)tileCount * sizeof(probes[0]));
    uint8_t *seen = realloc(_sendSeenScratch, (size_t)tileCount * sizeof(seen[0]));
    uint8_t *kind = realloc(_sendKindScratch, (size_t)tileCount * sizeof(kind[0]));
    sharp_dirty_rect_t *rects =
        realloc(_rectScratch, (size_t)tileCount * sizeof(rects[0]));
    if (dirty == NULL || send == NULL || refine == NULL || probes == NULL ||
        seen == NULL || kind == NULL || rects == NULL) {
        free(dirty);
        free(send);
        free(refine);
        free(probes);
        free(seen);
        free(kind);
        free(rects);
        _dirtyScratch = NULL;
        _sendScratch = NULL;
        _refineScratch = NULL;
        _m2ProbeScratch = NULL;
        _sendSeenScratch = NULL;
        _sendKindScratch = NULL;
        _rectScratch = NULL;
        _scratchTileCap = 0;
        return -1;
    }
    _dirtyScratch = dirty;
    _sendScratch = send;
    _refineScratch = refine;
    _m2ProbeScratch = probes;
    _sendSeenScratch = seen;
    _sendKindScratch = kind;
    _rectScratch = rects;
    _scratchTileCap = tileCount;
    return 0;
}

- (int)ensureFullFrameEpisodeMaskCapacity:(uint32_t)tileCount {
    uint32_t bytes = (tileCount + 7u) / 8u;
    if (bytes == 0) {
        return -1;
    }
    if (_fullFrameEpisodeMaskCap >= bytes && _fullFrameEpisodeMask != NULL) {
        return 0;
    }
    uint8_t *mask = realloc(_fullFrameEpisodeMask, bytes);
    if (mask == NULL) {
        return -1;
    }
    uint8_t *currentMask = realloc(_fullFrameCurrentMask, bytes);
    if (currentMask == NULL) {
        _fullFrameEpisodeMask = mask;
        return -1;
    }
    memset(mask + _fullFrameEpisodeMaskCap, 0, bytes - _fullFrameEpisodeMaskCap);
    memset(currentMask + _fullFrameEpisodeMaskCap, 0,
           bytes - _fullFrameEpisodeMaskCap);
    _fullFrameEpisodeMask = mask;
    _fullFrameCurrentMask = currentMask;
    _fullFrameEpisodeMaskCap = bytes;
    return 0;
}

- (void)beginFullFrameEpisodeForTileCount:(uint32_t)tileCount {
    if (!_motionMaskEnabled ||
        [self ensureFullFrameEpisodeMaskCapacity:tileCount] != 0) {
        return;
    }
    memset(_fullFrameEpisodeMask, 0, _fullFrameEpisodeMaskCap);
    memset(_fullFrameCurrentMask, 0, _fullFrameEpisodeMaskCap);
    _fullFrameEpisodeMaskTiles = 0;
}

- (void)clearCurrentMotionMask {
    if (_fullFrameCurrentMask != NULL && _fullFrameEpisodeMaskCap > 0) {
        memset(_fullFrameCurrentMask, 0, _fullFrameEpisodeMaskCap);
    }
}

- (void)addMotionMaskTile:(uint16_t)tileId {
    if (!_motionMaskEnabled || _fullFrameEpisodeMask == NULL ||
        _fullFrameCurrentMask == NULL ||
        ((uint32_t)tileId >> 3) >= _fullFrameEpisodeMaskCap) {
        return;
    }
    uint8_t bit = (uint8_t)(1u << (tileId & 7u));
    _fullFrameCurrentMask[tileId >> 3] |= bit;
    uint8_t *slot = &_fullFrameEpisodeMask[tileId >> 3];
    if ((*slot & bit) == 0) {
        *slot |= bit;
        _fullFrameEpisodeMaskTiles++;
        if (_fullFrameEpisodeMaskTiles > _fullFrameEpisodeMaskPeakTiles) {
            _fullFrameEpisodeMaskPeakTiles = _fullFrameEpisodeMaskTiles;
        }
    }
}

- (void)addMotionMaskRects:(const sharp_dirty_rect_t *)rects
                     count:(size_t)rectCount
                 tileCount:(uint32_t)tileCount {
    if (!_motionMaskEnabled || rects == NULL || rectCount == 0 ||
        _fullFrameEpisodeMask == NULL || tileCount == 0) {
        return;
    }
    uint32_t cols = sharp_tile_cols(_width);
    uint32_t rows = sharp_tile_rows(_height);
    for (size_t i = 0; i < rectCount; i++) {
        const sharp_dirty_rect_t *rect = &rects[i];
        if (rect->w == 0 || rect->h == 0) {
            continue;
        }
        uint32_t tx0 = rect->x / SHARP_TILE_SIZE;
        uint32_t ty0 = rect->y / SHARP_TILE_SIZE;
        uint32_t tx1 = (rect->x + rect->w - 1u) / SHARP_TILE_SIZE;
        uint32_t ty1 = (rect->y + rect->h - 1u) / SHARP_TILE_SIZE;
        if (tx0 >= cols || ty0 >= rows) {
            continue;
        }
        tx1 = MIN(tx1, cols - 1u);
        ty1 = MIN(ty1, rows - 1u);
        for (uint32_t ty = ty0; ty <= ty1; ty++) {
            for (uint32_t tx = tx0; tx <= tx1; tx++) {
                uint32_t tileId = ty * cols + tx;
                if (tileId < tileCount) {
                    [self addMotionMaskTile:(uint16_t)tileId];
                }
            }
        }
    }
}

- (uint64_t)countMotionMaskTiles:(uint32_t)tileCount {
    if (_fullFrameEpisodeMask == NULL) {
        return 0;
    }
    uint64_t count = 0;
    for (uint32_t tileId = 0; tileId < tileCount; tileId++) {
        if ((_fullFrameEpisodeMask[tileId >> 3] &
             (uint8_t)(1u << (tileId & 7u))) != 0) {
            count++;
        }
    }
    return count;
}

- (BOOL)hotPathRectsContainOnlyMotion:(const sharp_dirty_rect_t *)rects
                                count:(size_t)rectCount
                            tileCount:(uint32_t)tileCount {
    if (!_motionMaskEnabled || _m2Classifier == NULL || rects == NULL ||
        rectCount == 0 || tileCount == 0) {
        return NO;
    }
    uint32_t cols = sharp_tile_cols(_width);
    uint32_t rows = sharp_tile_rows(_height);
    for (size_t i = 0; i < rectCount; i++) {
        const sharp_dirty_rect_t *rect = &rects[i];
        if (rect->w == 0 || rect->h == 0) {
            return NO;
        }
        uint32_t tx0 = rect->x / SHARP_TILE_SIZE;
        uint32_t ty0 = rect->y / SHARP_TILE_SIZE;
        uint32_t tx1 = (rect->x + rect->w - 1u) / SHARP_TILE_SIZE;
        uint32_t ty1 = (rect->y + rect->h - 1u) / SHARP_TILE_SIZE;
        if (tx0 >= cols || ty0 >= rows) {
            return NO;
        }
        tx1 = MIN(tx1, cols - 1u);
        ty1 = MIN(ty1, rows - 1u);
        for (uint32_t ty = ty0; ty <= ty1; ty++) {
            for (uint32_t tx = tx0; tx <= tx1; tx++) {
                uint32_t tileId = ty * cols + tx;
                if (tileId >= tileCount ||
                    sharp_m2_classifier_tile_class(_m2Classifier,
                                                   (uint16_t)tileId) !=
                        SHARP_M2_TILE_MOTION) {
                    return NO;
                }
            }
        }
    }
    return YES;
}

- (void)destroyFrameScratch {
    if (_motionPrerollJob != NULL) {
        free(_motionPrerollJob->motion_mask);
        free(_motionPrerollJob);
        _motionPrerollJob = NULL;
    }
    free(_dirtyScratch);
    free(_sendScratch);
    free(_refineScratch);
    free(_m2ProbeScratch);
    free(_sendSeenScratch);
    free(_sendKindScratch);
    free(_rectScratch);
    _dirtyScratch = NULL;
    _sendScratch = NULL;
    _refineScratch = NULL;
    _m2ProbeScratch = NULL;
    _sendSeenScratch = NULL;
    _sendKindScratch = NULL;
    _rectScratch = NULL;
    _scratchTileCap = 0;
}

- (int)ensureCleanupCapacity:(uint32_t)tileCount {
    if (tileCount == 0) {
        return -1;
    }
    if (_cleanupTileCap >= tileCount && _cleanupRecords != NULL) {
        return 0;
    }
    screen_tx_cleanup_record_t *records =
        calloc(tileCount, sizeof(records[0]));
    if (records == NULL) {
        return -1;
    }
    if (_cleanupRecords != NULL) {
        uint32_t copyCount = _cleanupTileCap < tileCount ? _cleanupTileCap : tileCount;
        memcpy(records, _cleanupRecords, (size_t)copyCount * sizeof(records[0]));
        free(_cleanupRecords);
    }
    _cleanupRecords = records;
    _cleanupTileCap = tileCount;
    return 0;
}

- (void)destroyCleanupState {
    free(_cleanupRecords);
    _cleanupRecords = NULL;
    _cleanupTileCap = 0;
    _cleanupPendingTiles = 0;
}

- (int)ensureLatestFrameCapacityWithStride:(uint32_t)stride {
    size_t bytes = (size_t)stride * (size_t)_height;
    if (bytes == 0) {
        return -1;
    }
    if (_latestFrameBgra != NULL && _latestFrameBytes >= bytes) {
        _latestFrameStride = stride;
        return 0;
    }
    uint8_t *buffer = realloc(_latestFrameBgra, bytes);
    if (buffer == NULL) {
        free(_latestFrameBgra);
        _latestFrameBgra = NULL;
        _latestFrameBytes = 0;
        _latestFrameStride = 0;
        return -1;
    }
    _latestFrameBgra = buffer;
    _latestFrameBytes = bytes;
    _latestFrameStride = stride;
    return 0;
}

- (void)destroyLatestFrame {
    free(_latestFrameBgra);
    _latestFrameBgra = NULL;
    _latestFrameBytes = 0;
    _latestFrameStride = 0;
    _latestFrameBgraFrameId = 0;
    _latestFrameBgraValid = 0;
}

- (int)copyLatestFrameTileForRecord:(screen_tx_cleanup_record_t *)record {
    if (record == NULL || _latestFrameBgra == NULL || _latestFrameStride == 0) {
        return -1;
    }
    size_t rowBytes = (size_t)record->rect.w * 4u;
    if (rowBytes > SHARP_TILE_BYTES) {
        return -1;
    }
    @synchronized (self) {
        if (_latestFrameBgra == NULL || _latestFrameStride == 0 ||
            !_latestFrameBgraValid || _latestFrameBgraFrameId < record->frame_id ||
            (size_t)(record->rect.y + record->rect.h) * _latestFrameStride >
                _latestFrameBytes) {
            return -1;
        }
        const uint8_t *src = _latestFrameBgra +
            (size_t)record->rect.y * _latestFrameStride +
            (size_t)record->rect.x * 4u;
        for (uint32_t row = 0; row < record->rect.h; row++) {
            memcpy(record->bgra + (size_t)row * rowBytes,
                   src + (size_t)row * _latestFrameStride, rowBytes);
        }
    }
    return 0;
}

- (int)setupDirtyMap {
    return sharp_tile_dirty_map_init(&_dirtyMap, _width, _height);
}

- (void)destroyDirtyMap {
    sharp_tile_dirty_map_destroy(&_dirtyMap);
}

- (int)setupM2ClassifierWithFps:(uint32_t)fps {
    sharp_m2_classifier_config_t config;
    sharp_m2_classifier_default_config(_width, _height, fps, &config);
    _m2Classifier = sharp_m2_classifier_create(&config);
    return _m2Classifier != NULL ? 0 : -1;
}

- (void)destroyM2Classifier {
    sharp_m2_classifier_destroy(_m2Classifier);
    _m2Classifier = NULL;
}

- (void)destroyH264ResendRing {
    h264_resend_ring_clear(_h264Resend, SHARP_H264_RESEND_MAX_GENERATIONS);
}
@end
