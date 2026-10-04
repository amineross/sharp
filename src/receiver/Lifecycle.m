#import "Internal.h"

/* Startup failures must reach the app as failures so it can save a report;
 * -[NSApp terminate:] would exit with status 0. */
static void sharp_receiver_startup_failed(void) {
    fflush(stdout);
    fflush(stderr);
    exit(1);
}

/* Hide this Mac's own pointer while it is idle; Sharp draws the sender's. */
static void sharp_hide_idle_local_cursor(void) {
    __block NSPoint last = [NSEvent mouseLocation];
    __block NSUInteger idleTicks = 0;
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        NSPoint now = [NSEvent mouseLocation];
        if (!NSEqualPoints(now, last)) { last = now; idleTicks = 0; return; }
        if (++idleTicks >= 2 && NSApp.isActive) [NSCursor setHiddenUntilMouseMoves:YES];
    }];
}

@implementation SharpDisplayApp
@synthesize config = _config;
@synthesize receiver = _receiver;
@synthesize videoReassembler = _videoReassembler;
@synthesize frontFb = _frontFb;
@synthesize fd = _fd;
@synthesize senderAddr = _senderAddr;
@synthesize senderAddrLen = _senderAddrLen;
@synthesize haveSenderAddr = _haveSenderAddr;
@synthesize startNs = _startNs;
@synthesize displayLink = _displayLink;
@synthesize readSource = _readSource;
@synthesize netQueue = _netQueue;
@synthesize renderQueue = _renderQueue;
@synthesize renderScheduled = _renderScheduled;
@synthesize stagingDirty = _stagingDirty;
@synthesize stagingDirtyBounds = _stagingDirtyBounds;
@synthesize frameReady = _frameReady;
@synthesize terminateScheduled = _terminateScheduled;
@synthesize latestFrameEnd = _latestFrameEnd;
@synthesize committedFrame = _committedFrame;
@synthesize presentedFrames = _presentedFrames;
@synthesize committedFrames = _committedFrames;
@synthesize droppedFrameEnds = _droppedFrameEnds;
@synthesize presentSupersededCommits = _presentSupersededCommits;
@synthesize lateLosslessCommits = _lateLosslessCommits;
@synthesize frameEndSupersededDirty = _frameEndSupersededDirty;
@synthesize frameEndSupersededNewerPatch = _frameEndSupersededNewerPatch;
@synthesize renderWaitMissingLossless = _renderWaitMissingLossless;
@synthesize renderWaitMissingVideo = _renderWaitMissingVideo;
@synthesize renderWaitNewerStaged = _renderWaitNewerStaged;
@synthesize renderWaitNoPatchRecord = _renderWaitNoPatchRecord;
@synthesize renderWaitNoExpectedRecord = _renderWaitNoExpectedRecord;
@synthesize renderWaitNoStagingDirty = _renderWaitNoStagingDirty;
@synthesize videoDecodeFailedFrames = _videoDecodeFailedFrames;
@synthesize videoDecodeNoSessionFrames = _videoDecodeNoSessionFrames;
@synthesize videoDecodeStatusFailures = _videoDecodeStatusFailures;
@synthesize h264StaleVideoDrops = _h264StaleVideoDrops;
@synthesize h264NoDecoderDrops = _h264NoDecoderDrops;
@synthesize netDrainCalls = _netDrainCalls;
@synthesize netDrainBudgetYields = _netDrainBudgetYields;
@synthesize netDrainMaxPackets = _netDrainMaxPackets;
@synthesize textureFullUploads = _textureFullUploads;
@synthesize textureRegionUploads = _textureRegionUploads;
@synthesize textureRegionPixels = _textureRegionPixels;
@synthesize presenterSnapshotCount = _presenterSnapshotCount;
@synthesize videoMaxActiveRegions = _videoMaxActiveRegions;
@synthesize videoTextureUploads = _videoTextureUploads;
@synthesize videoTextureFrames = _videoTextureFrames;
@synthesize videoDecoderTextureBinds = _videoDecoderTextureBinds;
@synthesize videoNv12TextureBinds = _videoNv12TextureBinds;
@synthesize videoBgraTextureUploads = _videoBgraTextureUploads;
@synthesize videoDecoderTextureFallbacks = _videoDecoderTextureFallbacks;
@synthesize videoCpuFramebufferPatches = _videoCpuFramebufferPatches;
@synthesize videoLayerActivations = _videoLayerActivations;
@synthesize videoLayerDeactivations = _videoLayerDeactivations;
@synthesize videoLayerMoves = _videoLayerMoves;
@synthesize videoLayerResizes = _videoLayerResizes;
@synthesize videoOldFootprintCleanups = _videoOldFootprintCleanups;
@synthesize videoOldFootprintCleanupSkipped = _videoOldFootprintCleanupSkipped;
@synthesize videoOldFootprintLastMoveFrame = _videoOldFootprintLastMoveFrame;
@synthesize videoOldFootprintLastRedrawFrame = _videoOldFootprintLastRedrawFrame;
@synthesize videoHandoffBakes = _videoHandoffBakes;
@synthesize videoHandoffBakePixels = _videoHandoffBakePixels;
@synthesize videoHandoffBakeFailures = _videoHandoffBakeFailures;
@synthesize staleRevealPixels = _staleRevealPixels;
@synthesize commitDeactivateNoVideoRegion = _commitDeactivateNoVideoRegion;
@synthesize h264Packets = _h264Packets;
@synthesize h264Chunks = _h264Chunks;
@synthesize h264Frames = _h264Frames;
@synthesize h264DecodeCallbacks = _h264DecodeCallbacks;
@synthesize h264HardwareDecoderSessions = _h264HardwareDecoderSessions;
@synthesize h264SoftwareDecoderSessions = _h264SoftwareDecoderSessions;
@synthesize h264HardwareDecoderUnknownSessions = _h264HardwareDecoderUnknownSessions;
@synthesize h264Bytes = _h264Bytes;
@synthesize h264Invalid = _h264Invalid;
@synthesize h264MissingGenerations = _h264MissingGenerations;
@synthesize h264FeedbackSent = _h264FeedbackSent;
@synthesize h264FeedbackFailed = _h264FeedbackFailed;
@synthesize h264VsliceNacksSent = _h264VsliceNacksSent;
@synthesize h264IdrRequestsSent = _h264IdrRequestsSent;
@synthesize h264KeyframeRequestsSent = _h264KeyframeRequestsSent;
@synthesize h264FullFrameNacksSuppressed = _h264FullFrameNacksSuppressed;
@synthesize h264FullFrameIdrSuppressed = _h264FullFrameIdrSuppressed;
@synthesize h264FullFrameKeyframeRequestsSuppressed = _h264FullFrameKeyframeRequestsSuppressed;
@synthesize h264FullFrameLastKeyframeRequestNs = _h264FullFrameLastKeyframeRequestNs;
@synthesize cursorPackets = _cursorPackets;
@synthesize cursorPresents = _cursorPresents;
@synthesize cursorLastRxNs = _cursorLastRxNs;
@synthesize cursorLastPresentedSeq = _cursorLastPresentedSeq;
@synthesize cursorSeq = _cursorSeq;
@synthesize cursorX = _cursorX;
@synthesize cursorY = _cursorY;
@synthesize cursorPrevX = _cursorPrevX;
@synthesize cursorPrevY = _cursorPrevY;
@synthesize cursorSampleNs = _cursorSampleNs;
@synthesize cursorPrevSampleNs = _cursorPrevSampleNs;
@synthesize cursorHotspotX = _cursorHotspotX;
@synthesize cursorHotspotY = _cursorHotspotY;
@synthesize cursorImageId = _cursorImageId;
@synthesize cursorVisible = _cursorVisible;
@synthesize h264RecoveredGenerations = _h264RecoveredGenerations;
@synthesize h264UnrecoveredGenerations = _h264UnrecoveredGenerations;
@synthesize drawableWidth = _drawableWidth;
@synthesize drawableHeight = _drawableHeight;
@synthesize displayScale = _displayScale;
@synthesize windowContentSize = _windowContentSize;
@synthesize frameLog = _frameLog;
@synthesize window = _window;
@synthesize frameView = _frameView;
@synthesize overlayMaskEnabled = _overlayMaskEnabled;
- (instancetype)init {
    self = [super init];
    if (self != nil) {
        pthread_mutex_init(&_stateLock, NULL);
        pthread_mutex_init(&_videoRingLock, NULL);
        pthread_cond_init(&_videoRingCond, NULL);
        pthread_mutex_init(&_tileRingLock, NULL);
        pthread_cond_init(&_tileRingCond, NULL);
        atomic_init(&_netThreadsRunning, 0u);
        atomic_init(&_ringDropsVideo, 0u);
        atomic_init(&_ringDropsTile, 0u);
        atomic_init(&_ringPacketsVideo, 0u);
        atomic_init(&_ringPacketsTile, 0u);
        atomic_init(&_arrivalCounter, 0u);
        atomic_init(&_videoProcessedThrough, 0u);
        atomic_init(&_stageVDrainedThrough, 0u);
        atomic_init(&_stageTDrainedThrough, 0u);
        atomic_init(&_recvmsgXBatches, 0u);
        atomic_init(&_recvmsgXPackets, 0u);
        atomic_init(&_recvmsgXFallbacks, 0u);
    }
    return self;
}

- (void)updateDrawableSize {
    if (_frameView == nil) {
        return;
    }
    NSRect backing = [_frameView convertRectToBacking:_frameView.bounds];
    pthread_mutex_lock(&_stateLock);
    _drawableWidth = (uint32_t)MAX(1.0, floor(backing.size.width));
    _drawableHeight = (uint32_t)MAX(1.0, floor(backing.size.height));
    _displayScale = _window != nil ? _window.backingScaleFactor : 1.0;
    _windowContentSize = _frameView.bounds.size;
    pthread_mutex_unlock(&_stateLock);
}

- (void)windowDidResize:(NSNotification *)notification {
    (void)notification;
    [self updateDrawableSize];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;

    if (sharp_tile_receiver_init(&_receiver, _config.width, _config.height) != 0) {
        fprintf(stderr, "receiver allocation failed\n");
        sharp_receiver_startup_failed();
        return;
    }
    _motionMaskBytes = (_receiver.tile_count + 7u) / 8u;
    if (_motionMaskBytes > SHARP_MOTION_MASK_MAX_BYTES) {
        fprintf(stderr, "motion mask exceeds receiver limit\n");
        sharp_tile_receiver_destroy(&_receiver);
        sharp_receiver_startup_failed();
        return;
    }
    _testCorruptTileId = -1;
    const char *testCorruptTile = getenv("SHARP_TEST_CORRUPT_TILE_ID");
    if (testCorruptTile != NULL && testCorruptTile[0] != '\0') {
        char *end = NULL;
        long parsed = strtol(testCorruptTile, &end, 10);
        if (end != testCorruptTile && parsed >= 0 &&
            (uint32_t)parsed < _receiver.tile_count) {
            _testCorruptTileId = (int32_t)parsed;
        }
    }
    const char *overlayMaskEnv = getenv("SHARP_OVERLAY_MASK");
    self.overlayMaskEnabled =
        !(overlayMaskEnv != NULL && strcmp(overlayMaskEnv, "0") == 0);
    if (sharp_framebuf_init(&_frontFb, _config.width, _config.height) != 0) {
        fprintf(stderr, "front framebuffer allocation failed\n");
        sharp_tile_receiver_destroy(&_receiver);
        sharp_receiver_startup_failed();
        return;
    }
    _videoReassembler =
        sharp_video_region_reassembler_create(_config.width, _config.height);
    if (_videoReassembler == NULL) {
        fprintf(stderr, "video reassembler allocation failed\n");
        sharp_framebuf_destroy(&_frontFb);
        sharp_tile_receiver_destroy(&_receiver);
        sharp_receiver_startup_failed();
        return;
    }

    _fd = shtp_udp_socket((int)_config.rcvbuf, 1024 * 1024);
    if (_fd < 0 || shtp_bind_ipv4(_fd, _config.bind_ip, (unsigned short)_config.port) != 0 ||
        shtp_make_nonblocking(_fd) != 0) {
        perror("socket/bind");
        sharp_receiver_startup_failed();
        return;
    }

    NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                       NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    if (_config.frame_log_path != NULL) {
        _frameLog = fopen(_config.frame_log_path, "w");
        if (_frameLog != NULL) {
            fprintf(_frameLog,
                    "frame_id\tframe_end_send_ns\tpresent_ns\t"
                    "committed_frames\tpresented_frames\tdropped_frame_ends\t"
                    "content_serial\n");
            fflush(_frameLog);
        }
    }
    NSScreen *screen = [NSScreen mainScreen];
    NSRect usableFrame = screen.visibleFrame;
    NSSize streamSize = NSMakeSize(_config.width, _config.height);
    NSSize contentSize;
    const char *sizingMode = "fit";
    if (_config.window_width > 0 && _config.window_height > 0) {
        contentSize = NSMakeSize(_config.window_width, _config.window_height);
        sizingMode = "window";
    } else if (_config.scale > 0) {
        contentSize = NSMakeSize(_config.width * _config.scale,
                                 _config.height * _config.scale);
        sizingMode = "scale";
    } else if (_config.fullscreen) {
        contentSize = usableFrame.size;
        sizingMode = "fullscreen";
    } else {
        NSSize maxContentSize =
            [NSWindow contentRectForFrameRect:usableFrame styleMask:style].size;
        contentSize = fit_size_preserving_aspect(streamSize, maxContentSize);
    }

    NSRect frame = NSMakeRect(0, 0, contentSize.width, contentSize.height);
    _window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:style
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    [_window setTitle:@"sharp M1 framebuffer"];
    [_window setContentAspectRatio:streamSize];
    [_window setLevel:NSNormalWindowLevel];
    [_window setCollectionBehavior:NSWindowCollectionBehaviorManaged |
                                   NSWindowCollectionBehaviorFullScreenPrimary];
    [_window center];
    [_window setDelegate:(id<NSWindowDelegate>)self];

    _frameView = [[SharpFramebufferView alloc] initWithFrame:frame];
    _frameView.videoTextureMode = _config.video_texture_mode;
    if (_config.cursor_path != NULL) {
        _frameView.cursorPath = [NSString stringWithUTF8String:_config.cursor_path];
    }
    if (_config.cursor_dir != NULL) {
        _frameView.cursorDir = [NSString stringWithUTF8String:_config.cursor_dir];
    }
    [_window setContentView:_frameView];
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    if (_config.fullscreen) {
        [_window toggleFullScreen:nil];
    }
    [_frameView prepareOpenGL];
    if (getenv("SHARP_CURSOR_CONTROL")) {
        __weak SharpDisplayApp *weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            char line[128];
            while (fgets(line, sizeof(line), stdin)) {
                if (!strchr(line, '\n')) { int c; while ((c=getchar())!=EOF && c!='\n') {} continue; }
                double scale, hue; char extra;
                if (sscanf(line, "%lf %lf %c", &scale, &hue, &extra) != 2 || !isfinite(scale) || !isfinite(hue)) continue;
                dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf.frameView updateCursorScale:scale hue:hue]; });
            }
        });
    }

    [self updateDrawableSize];
    sharp_hide_idle_local_cursor();

    _renderQueue = dispatch_queue_create("sh.sharp.m1-display-recv.render",
                                         DISPATCH_QUEUE_SERIAL);
    if (_config.net_threads) {
        if ([self startNetworkThreads] != 0) {
            fprintf(stderr, "network thread startup failed\n");
            sharp_receiver_startup_failed();
            return;
        }
    } else {
        _netQueue = dispatch_queue_create("sh.sharp.m1-display-recv.net",
                                          DISPATCH_QUEUE_SERIAL);
        _readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)_fd,
                                             0, _netQueue);
        dispatch_source_set_event_handler(_readSource, ^{
          [self drainSocket];
        });
        dispatch_resume(_readSource);
    }

    if (CVDisplayLinkCreateWithActiveCGDisplays(&_displayLink) == kCVReturnSuccess) {
        CVDisplayLinkSetOutputCallback(_displayLink, sharp_display_link_callback,
                                       (__bridge void *)self);
        CVDisplayLinkStart(_displayLink);
    } else {
        fprintf(stderr, "CVDisplayLink unavailable\n");
        sharp_receiver_startup_failed();
        return;
    }

    _startNs = shtp_now_ns();

    fprintf(stdout,
            "m1-display-recv bind=%s port=%u stream=%ux%u window=%.0fx%.0f "
            "drawable=%ux%u display_scale=%.2f sizing=%s video_texture_mode=%s "
            "bake_video_handoff=%d overlay_mask=%d net_threads=%d recvmsg_x=%d\n",
            _config.bind_ip, _config.port, _config.width, _config.height,
            _windowContentSize.width, _windowContentSize.height, _drawableWidth,
            _drawableHeight, _displayScale, sizingMode,
            video_texture_mode_name(_config.video_texture_mode),
            _config.bake_video_handoff, self.overlayMaskEnabled ? 1 : 0,
            _config.net_threads, _config.recvmsg_x);
    fflush(stdout);
}

- (void)writeH264RegionSummaryToFile:(FILE *)file {
    if (file == NULL) {
        return;
    }
    fprintf(file, "m1-display-recv-h264-regions");
    for (size_t i = 0; i < SHARP_MAX_VIDEO_REGIONS; i++) {
        fprintf(file,
                " r%zu_id=%u r%zu_frames=%" PRIu64
                " r%zu_nacks_sent=%" PRIu64
                " r%zu_idr_req_sent=%" PRIu64
                " r%zu_recovered=%" PRIu64
                " r%zu_unrecovered=%" PRIu64
                " r%zu_invalid=%" PRIu64,
                i, _h264RegionStats[i].active ? _h264RegionStats[i].region_id : 0u,
                i, _h264RegionStats[i].frames,
                i, _h264RegionStats[i].nacks_sent,
                i, _h264RegionStats[i].idr_requests_sent,
                i, _h264RegionStats[i].recovered_generations,
                i, _h264RegionStats[i].unrecovered_generations,
                i, _h264RegionStats[i].invalid);
    }
    fprintf(file, "\n");
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    if (_displayLink != NULL) {
        CVDisplayLinkStop(_displayLink);
        CVDisplayLinkRelease(_displayLink);
        _displayLink = NULL;
    }
    [self stopNetworkThreads];
    if (_readSource != nil) {
        dispatch_source_cancel(_readSource);
        _readSource = nil;
    }
    if (_netQueue != nil) {
        dispatch_sync(_netQueue, ^{
        });
    }
    if (_renderQueue != nil) {
        dispatch_sync(_renderQueue, ^{
        });
    }
    if (_fd >= 0) {
        close(_fd);
        _fd = -1;
    }
    if (_config.snapshot_path != NULL && _frontFb.pixels != NULL) {
        if (sharp_framebuf_write_ppm(&_frontFb, _config.snapshot_path) != 0) {
            fprintf(stderr, "snapshot write failed: %s\n", _config.snapshot_path);
        }
    }
    if (_config.presenter_snapshot_path != NULL && _frameView != nil) {
        if ([_frameView writePresenterSnapshotPath:_config.presenter_snapshot_path] !=
            0) {
            fprintf(stderr, "presenter snapshot write failed: %s\n",
                    _config.presenter_snapshot_path);
        }
    }
    for (size_t i = 0; i < SHARP_MAX_H264_DECODERS; i++) {
        [self clearH264DecoderAtIndex:i];
    }
    if (_frameLog != NULL) {
        fclose(_frameLog);
        _frameLog = NULL;
    }
    pthread_mutex_lock(&_stateLock);
    [self clearPendingPresentationLocked];
    pthread_mutex_unlock(&_stateLock);
    [self clearVideoLayer];

    uint64_t doneNs = shtp_now_ns();
    double sec = _startNs != 0 ? (double)(doneNs - _startNs) / 1000000000.0 : 0.0;
    double presentFps = sec > 0.0 ? (double)_presentedFrames / sec : 0.0;
    uint64_t contentFreshPresents = _freshContentPresents;
    double contentFreshFps =
        sec > 0.0 ? (double)contentFreshPresents / sec : 0.0;
    double h264DecodeCallbackFps =
        sec > 0.0 ? (double)_h264DecodeCallbacks / sec : 0.0;
    double h264DecodeLatencyP50Ms =
        (double)[self h264DecodeLatencyPercentileNs:0.50] / 1000000.0;
    double h264DecodeLatencyP95Ms =
        (double)[self h264DecodeLatencyPercentileNs:0.95] / 1000000.0;
    double presentRepeatFraction =
        _presentedFrames > 0
            ? (double)_presentRepeatFrames / (double)_presentedFrames
            : 0.0;
    double presentIntervalMeanMs = [self presentIntervalMeanMs];
    double presentIntervalP95Ms =
        (double)[self presentIntervalPercentileNs:0.95] / 1000000.0;
    double presentIntervalP99Ms =
        (double)[self presentIntervalPercentileNs:0.99] / 1000000.0;
    double presentIntervalCov = [self presentIntervalCov];
    uint64_t ringPacketsVideo =
        atomic_load_explicit(&_ringPacketsVideo, memory_order_relaxed);
    uint64_t ringPacketsTile =
        atomic_load_explicit(&_ringPacketsTile, memory_order_relaxed);
    uint64_t ringDropsVideo =
        atomic_load_explicit(&_ringDropsVideo, memory_order_relaxed);
    uint64_t ringDropsTile =
        atomic_load_explicit(&_ringDropsTile, memory_order_relaxed);
    uint64_t arrivalCounter =
        atomic_load_explicit(&_arrivalCounter, memory_order_relaxed);
    uint64_t videoProcessedThrough =
        atomic_load_explicit(&_videoProcessedThrough, memory_order_relaxed);
    uint64_t stageVDrainedThrough =
        atomic_load_explicit(&_stageVDrainedThrough, memory_order_relaxed);
    uint64_t stageTDrainedThrough =
        atomic_load_explicit(&_stageTDrainedThrough, memory_order_relaxed);
    uint64_t recvmsgXBatches =
        atomic_load_explicit(&_recvmsgXBatches, memory_order_relaxed);
    uint64_t recvmsgXPackets =
        atomic_load_explicit(&_recvmsgXPackets, memory_order_relaxed);
    uint64_t recvmsgXFallbacks =
        atomic_load_explicit(&_recvmsgXFallbacks, memory_order_relaxed);
    uint64_t fecRecoveredChunks =
        sharp_video_region_reassembler_fec_recovered_chunks(_videoReassembler);
    uint64_t fecUnrecoveredGenerations =
        sharp_video_region_reassembler_fec_unrecovered_generations(
            _videoReassembler);
    double idlePresentRepeatFraction =
        _presentedFrames > 0
            ? (double)_idlePresentRepeatFrames / (double)_presentedFrames
            : 0.0;
    double idlePresentIntervalMeanMs =
        _idlePresentIntervalTotalCount > 0
            ? (_idlePresentIntervalSumNs /
               (double)_idlePresentIntervalTotalCount) /
                  1000000.0
            : 0.0;
    double idlePresentIntervalCov = 0.0;
    if (_idlePresentIntervalTotalCount > 0 &&
        _idlePresentIntervalSumNs > 0.0) {
        double idleCount = (double)_idlePresentIntervalTotalCount;
        double idleMean = _idlePresentIntervalSumNs / idleCount;
        double idleVariance =
            (_idlePresentIntervalSumSqNs / idleCount) - idleMean * idleMean;
        if (idleVariance < 0.0) {
            idleVariance = 0.0;
        }
        idlePresentIntervalCov = sqrt(idleVariance) / idleMean;
    }
    fprintf(stdout,
            "m1-display-anti-entropy digest_packets=%" PRIu64
            " digest_entries=%" PRIu64 "\n",
            _tileDigestPackets, _tileDigestEntries);
    if (_config.expect_synthetic) {
        size_t mismatches = _committedFrames > 0
                                ? sharp_framebuf_count_synthetic_mismatches(
                                      &_frontFb, _receiver.stats.final_frame)
                                : (size_t)-1;
        fprintf(stdout,
                "m1-display-recv packets=%" PRIu64 " chunks=%" PRIu64
                " complete_tiles=%" PRIu64 " patched_tiles=%" PRIu64
                " stale_tiles=%" PRIu64
                " frame_end_packets=%" PRIu64
                " committed_frames=%" PRIu64 " presented_frames=%" PRIu64
                " present_fps=%.2f"
                " content_fresh_presents=%" PRIu64
                " content_fresh_fps=%.2f"
                " present_repeat_fraction=%.4f"
                " present_interval_ms_mean=%.3f"
                " present_interval_ms_p95=%.3f"
                " present_interval_ms_p99=%.3f"
                " present_interval_cov=%.4f"
                " present_repeat_frames=%" PRIu64
                " present_longest_stall=%" PRIu64
                " idle_present_repeat_fraction=%.4f"
                " idle_present_interval_ms_mean=%.3f"
                " idle_present_interval_cov=%.4f"
                " idle_present_repeat_frames=%" PRIu64
                " idle_present_longest_stall=%" PRIu64
                " dropped_frame_ends=%" PRIu64 " committed_frame=%u"
                " present_superseded_commits=%" PRIu64
                " late_lossless_commits=%" PRIu64
                " frame_end_superseded_dirty=%" PRIu64
                " frame_end_superseded_newer_patch=%" PRIu64
                " render_wait_missing_lossless=%" PRIu64
                " render_wait_missing_video=%" PRIu64
                " render_wait_newer_staged=%" PRIu64
                " render_wait_no_patch_record=%" PRIu64
                " render_wait_no_expected_record=%" PRIu64
                " render_wait_no_staging_dirty=%" PRIu64
                " video_decode_failed_frames=%" PRIu64
                " video_decode_no_session_frames=%" PRIu64
                " video_decode_status_failures=%" PRIu64
                " h264_stale_video_drops=%" PRIu64
                " h264_no_decoder_drops=%" PRIu64
                " fec_recovered_chunks=%" PRIu64
                " fec_unrecovered_generations=%" PRIu64
                " net_drain_calls=%" PRIu64
                " net_drain_budget_yields=%" PRIu64
                " net_drain_max_packets=%" PRIu64
                " ring_packets_video=%" PRIu64
                " ring_packets_tile=%" PRIu64
                " ring_drops_video=%" PRIu64
                " ring_drops_tile=%" PRIu64
                " arrival_counter=%" PRIu64
                " video_processed_through=%" PRIu64
                " stage_v_drained_through=%" PRIu64
                " stage_t_drained_through=%" PRIu64
                " recvmsg_x_batches=%" PRIu64
                " recvmsg_x_packets=%" PRIu64
                " recvmsg_x_fallbacks=%" PRIu64
                " texture_full_uploads=%" PRIu64
                " texture_region_uploads=%" PRIu64
                " texture_region_pixels=%" PRIu64
                " presenter_snapshot_count=%" PRIu64
                " video_texture_uploads=%" PRIu64
                " video_texture_frames=%" PRIu64
                " video_max_active_regions=%" PRIu64
                " video_decoder_texture_binds=%" PRIu64
                " video_nv12_texture_binds=%" PRIu64
                " video_bgra_texture_uploads=%" PRIu64
                " video_decoder_texture_fallbacks=%" PRIu64
                " video_layer_activations=%" PRIu64
                " video_layer_deactivations=%" PRIu64
                " video_layer_moves=%" PRIu64
                " video_layer_resizes=%" PRIu64
                " video_old_footprint_cleanups=%" PRIu64
                " video_old_footprint_cleanup_skipped=%" PRIu64
                " video_old_footprint_last_move_frame=%u"
                " video_old_footprint_last_redraw_frame=%u"
                " video_cpu_framebuffer_patches=%" PRIu64
                " video_handoff_bakes=%" PRIu64
                " video_handoff_bake_pixels=%" PRIu64
                " video_handoff_bake_failures=%" PRIu64
                " stale_reveal_pixels=%" PRIu64
                " commit_deactivate_no_video_region=%" PRIu64
                " h264_packets=%" PRIu64 " h264_chunks=%" PRIu64
                " h264_frames=%" PRIu64 " h264_bytes=%" PRIu64
                " h264_decode_callbacks=%" PRIu64
                " h264_decode_callback_fps=%.2f"
                " h264_decode_latency_ms_p50=%.3f"
                " h264_decode_latency_ms_p95=%.3f"
                " h264_hw_decoder_sessions=%" PRIu64
                " h264_sw_decoder_sessions=%" PRIu64
                " h264_hw_decoder_unknown_sessions=%" PRIu64
                " h264_invalid=%" PRIu64
                " h264_missing_generations=%" PRIu64
                " h264_feedback_sent=%" PRIu64
                " h264_feedback_failed=%" PRIu64
                " vsync_feedback_reports=%" PRIu64
                " h264_vslice_nacks_sent=%" PRIu64
                " h264_idr_requests_sent=%" PRIu64
                " h264_keyframe_requests_sent=%" PRIu64
                " h264_fullframe_nacks_suppressed=%" PRIu64
                " h264_fullframe_idr_suppressed=%" PRIu64
                " h264_fullframe_keyframe_requests_suppressed=%" PRIu64
                " h264_recovered_generations=%" PRIu64
                " h264_unrecovered_generations=%" PRIu64
                " invalid=%" PRIu64 " bytes=%" PRIu64 " seconds=%.3f final_frame=%u "
                "validation=%s mismatches=%zu\n",
                _receiver.stats.packets, _receiver.stats.tile_chunks,
                _receiver.stats.complete_tiles, _receiver.stats.patched_tiles,
                _receiver.stats.stale_tiles,
                _receiver.stats.frame_end_packets,
                _committedFrames, _presentedFrames, presentFps,
                contentFreshPresents, contentFreshFps, presentRepeatFraction,
                presentIntervalMeanMs, presentIntervalP95Ms,
                presentIntervalP99Ms, presentIntervalCov,
                _presentRepeatFrames, _presentLongestStall,
                idlePresentRepeatFraction, idlePresentIntervalMeanMs,
                idlePresentIntervalCov, _idlePresentRepeatFrames,
                _idlePresentLongestStall,
                _droppedFrameEnds, _committedFrame,
                _presentSupersededCommits,
                _lateLosslessCommits,
                _frameEndSupersededDirty, _frameEndSupersededNewerPatch,
                _renderWaitMissingLossless, _renderWaitMissingVideo,
                _renderWaitNewerStaged, _renderWaitNoPatchRecord,
                _renderWaitNoExpectedRecord, _renderWaitNoStagingDirty,
                _videoDecodeFailedFrames, _videoDecodeNoSessionFrames,
                _videoDecodeStatusFailures, _h264StaleVideoDrops,
                _h264NoDecoderDrops, fecRecoveredChunks,
                fecUnrecoveredGenerations, _netDrainCalls,
                _netDrainBudgetYields, _netDrainMaxPackets,
                ringPacketsVideo, ringPacketsTile, ringDropsVideo, ringDropsTile,
                arrivalCounter, videoProcessedThrough, stageVDrainedThrough,
                stageTDrainedThrough,
                recvmsgXBatches, recvmsgXPackets, recvmsgXFallbacks,
                _textureFullUploads, _textureRegionUploads, _textureRegionPixels,
                _presenterSnapshotCount,
                _videoTextureUploads, _videoTextureFrames,
                _videoMaxActiveRegions,
                _videoDecoderTextureBinds, _videoNv12TextureBinds,
                _videoBgraTextureUploads, _videoDecoderTextureFallbacks,
                _videoLayerActivations, _videoLayerDeactivations,
                _videoLayerMoves, _videoLayerResizes,
                _videoOldFootprintCleanups, _videoOldFootprintCleanupSkipped,
                _videoOldFootprintLastMoveFrame,
                _videoOldFootprintLastRedrawFrame,
                _videoCpuFramebufferPatches,
                _videoHandoffBakes, _videoHandoffBakePixels,
                _videoHandoffBakeFailures, _staleRevealPixels,
                _commitDeactivateNoVideoRegion,
                _h264Packets, _h264Chunks, _h264Frames, _h264Bytes,
                _h264DecodeCallbacks, h264DecodeCallbackFps,
                h264DecodeLatencyP50Ms, h264DecodeLatencyP95Ms,
                _h264HardwareDecoderSessions, _h264SoftwareDecoderSessions,
                _h264HardwareDecoderUnknownSessions, _h264Invalid,
                _h264MissingGenerations, _h264FeedbackSent, _h264FeedbackFailed,
                _vsyncFeedbackReports,
                _h264VsliceNacksSent, _h264IdrRequestsSent,
                _h264KeyframeRequestsSent, _h264FullFrameNacksSuppressed,
                _h264FullFrameIdrSuppressed,
                _h264FullFrameKeyframeRequestsSuppressed,
                _h264RecoveredGenerations, _h264UnrecoveredGenerations,
                _receiver.stats.invalid_packets, _receiver.stats.bytes, sec,
                _receiver.stats.final_frame,
                _receiver.stats.have_bye && mismatches == 0 ? "PASS" : "FAIL",
                mismatches);
    } else {
        fprintf(stdout,
                "m1-display-recv packets=%" PRIu64 " chunks=%" PRIu64
                " complete_tiles=%" PRIu64 " patched_tiles=%" PRIu64
                " stale_tiles=%" PRIu64
                " frame_end_packets=%" PRIu64
                " committed_frames=%" PRIu64 " presented_frames=%" PRIu64
                " present_fps=%.2f"
                " content_fresh_presents=%" PRIu64
                " content_fresh_fps=%.2f"
                " present_repeat_fraction=%.4f"
                " present_interval_ms_mean=%.3f"
                " present_interval_ms_p95=%.3f"
                " present_interval_ms_p99=%.3f"
                " present_interval_cov=%.4f"
                " present_repeat_frames=%" PRIu64
                " present_longest_stall=%" PRIu64
                " idle_present_repeat_fraction=%.4f"
                " idle_present_interval_ms_mean=%.3f"
                " idle_present_interval_cov=%.4f"
                " idle_present_repeat_frames=%" PRIu64
                " idle_present_longest_stall=%" PRIu64
                " dropped_frame_ends=%" PRIu64 " committed_frame=%u"
                " present_superseded_commits=%" PRIu64
                " late_lossless_commits=%" PRIu64
                " frame_end_superseded_dirty=%" PRIu64
                " frame_end_superseded_newer_patch=%" PRIu64
                " render_wait_missing_lossless=%" PRIu64
                " render_wait_missing_video=%" PRIu64
                " render_wait_newer_staged=%" PRIu64
                " render_wait_no_patch_record=%" PRIu64
                " render_wait_no_expected_record=%" PRIu64
                " render_wait_no_staging_dirty=%" PRIu64
                " video_decode_failed_frames=%" PRIu64
                " video_decode_no_session_frames=%" PRIu64
                " video_decode_status_failures=%" PRIu64
                " h264_stale_video_drops=%" PRIu64
                " h264_no_decoder_drops=%" PRIu64
                " fec_recovered_chunks=%" PRIu64
                " fec_unrecovered_generations=%" PRIu64
                " net_drain_calls=%" PRIu64
                " net_drain_budget_yields=%" PRIu64
                " net_drain_max_packets=%" PRIu64
                " ring_packets_video=%" PRIu64
                " ring_packets_tile=%" PRIu64
                " ring_drops_video=%" PRIu64
                " ring_drops_tile=%" PRIu64
                " arrival_counter=%" PRIu64
                " video_processed_through=%" PRIu64
                " stage_v_drained_through=%" PRIu64
                " stage_t_drained_through=%" PRIu64
                " recvmsg_x_batches=%" PRIu64
                " recvmsg_x_packets=%" PRIu64
                " recvmsg_x_fallbacks=%" PRIu64
                " texture_full_uploads=%" PRIu64
                " texture_region_uploads=%" PRIu64
                " texture_region_pixels=%" PRIu64
                " presenter_snapshot_count=%" PRIu64
                " video_texture_uploads=%" PRIu64
                " video_texture_frames=%" PRIu64
                " video_max_active_regions=%" PRIu64
                " video_decoder_texture_binds=%" PRIu64
                " video_nv12_texture_binds=%" PRIu64
                " video_bgra_texture_uploads=%" PRIu64
                " video_decoder_texture_fallbacks=%" PRIu64
                " video_layer_activations=%" PRIu64
                " video_layer_deactivations=%" PRIu64
                " video_layer_moves=%" PRIu64
                " video_layer_resizes=%" PRIu64
                " video_old_footprint_cleanups=%" PRIu64
                " video_old_footprint_cleanup_skipped=%" PRIu64
                " video_old_footprint_last_move_frame=%u"
                " video_old_footprint_last_redraw_frame=%u"
                " video_cpu_framebuffer_patches=%" PRIu64
                " video_handoff_bakes=%" PRIu64
                " video_handoff_bake_pixels=%" PRIu64
                " video_handoff_bake_failures=%" PRIu64
                " stale_reveal_pixels=%" PRIu64
                " commit_deactivate_no_video_region=%" PRIu64
                " h264_packets=%" PRIu64 " h264_chunks=%" PRIu64
                " h264_frames=%" PRIu64 " h264_bytes=%" PRIu64
                " h264_decode_callbacks=%" PRIu64
                " h264_decode_callback_fps=%.2f"
                " h264_decode_latency_ms_p50=%.3f"
                " h264_decode_latency_ms_p95=%.3f"
                " h264_hw_decoder_sessions=%" PRIu64
                " h264_sw_decoder_sessions=%" PRIu64
                " h264_hw_decoder_unknown_sessions=%" PRIu64
                " h264_invalid=%" PRIu64
                " h264_missing_generations=%" PRIu64
                " h264_feedback_sent=%" PRIu64
                " h264_feedback_failed=%" PRIu64
                " vsync_feedback_reports=%" PRIu64
                " h264_vslice_nacks_sent=%" PRIu64
                " h264_idr_requests_sent=%" PRIu64
                " h264_keyframe_requests_sent=%" PRIu64
                " h264_fullframe_nacks_suppressed=%" PRIu64
                " h264_fullframe_idr_suppressed=%" PRIu64
                " h264_fullframe_keyframe_requests_suppressed=%" PRIu64
                " h264_recovered_generations=%" PRIu64
                " h264_unrecovered_generations=%" PRIu64
                " invalid=%" PRIu64 " bytes=%" PRIu64 " seconds=%.3f final_frame=%u "
                "validation=N/A source=screen\n",
                _receiver.stats.packets, _receiver.stats.tile_chunks,
                _receiver.stats.complete_tiles, _receiver.stats.patched_tiles,
                _receiver.stats.stale_tiles,
                _receiver.stats.frame_end_packets,
                _committedFrames, _presentedFrames, presentFps,
                contentFreshPresents, contentFreshFps, presentRepeatFraction,
                presentIntervalMeanMs, presentIntervalP95Ms,
                presentIntervalP99Ms, presentIntervalCov,
                _presentRepeatFrames, _presentLongestStall,
                idlePresentRepeatFraction, idlePresentIntervalMeanMs,
                idlePresentIntervalCov, _idlePresentRepeatFrames,
                _idlePresentLongestStall,
                _droppedFrameEnds, _committedFrame,
                _presentSupersededCommits,
                _lateLosslessCommits,
                _frameEndSupersededDirty, _frameEndSupersededNewerPatch,
                _renderWaitMissingLossless, _renderWaitMissingVideo,
                _renderWaitNewerStaged, _renderWaitNoPatchRecord,
                _renderWaitNoExpectedRecord, _renderWaitNoStagingDirty,
                _videoDecodeFailedFrames, _videoDecodeNoSessionFrames,
                _videoDecodeStatusFailures, _h264StaleVideoDrops,
                _h264NoDecoderDrops, fecRecoveredChunks,
                fecUnrecoveredGenerations, _netDrainCalls,
                _netDrainBudgetYields, _netDrainMaxPackets,
                ringPacketsVideo, ringPacketsTile, ringDropsVideo, ringDropsTile,
                arrivalCounter, videoProcessedThrough, stageVDrainedThrough,
                stageTDrainedThrough,
                recvmsgXBatches, recvmsgXPackets, recvmsgXFallbacks,
                _textureFullUploads, _textureRegionUploads, _textureRegionPixels,
                _presenterSnapshotCount,
                _videoTextureUploads, _videoTextureFrames,
                _videoMaxActiveRegions,
                _videoDecoderTextureBinds, _videoNv12TextureBinds,
                _videoBgraTextureUploads, _videoDecoderTextureFallbacks,
                _videoLayerActivations, _videoLayerDeactivations,
                _videoLayerMoves, _videoLayerResizes,
                _videoOldFootprintCleanups, _videoOldFootprintCleanupSkipped,
                _videoOldFootprintLastMoveFrame,
                _videoOldFootprintLastRedrawFrame,
                _videoCpuFramebufferPatches,
                _videoHandoffBakes, _videoHandoffBakePixels,
                _videoHandoffBakeFailures, _staleRevealPixels,
                _commitDeactivateNoVideoRegion,
                _h264Packets, _h264Chunks, _h264Frames, _h264Bytes,
                _h264DecodeCallbacks, h264DecodeCallbackFps,
                h264DecodeLatencyP50Ms, h264DecodeLatencyP95Ms,
                _h264HardwareDecoderSessions, _h264SoftwareDecoderSessions,
                _h264HardwareDecoderUnknownSessions, _h264Invalid,
                _h264MissingGenerations, _h264FeedbackSent, _h264FeedbackFailed,
                _vsyncFeedbackReports,
                _h264VsliceNacksSent, _h264IdrRequestsSent,
                _h264KeyframeRequestsSent, _h264FullFrameNacksSuppressed,
                _h264FullFrameIdrSuppressed,
                _h264FullFrameKeyframeRequestsSuppressed,
                _h264RecoveredGenerations, _h264UnrecoveredGenerations,
                _receiver.stats.invalid_packets, _receiver.stats.bytes, sec,
                _receiver.stats.final_frame);
    }
    fprintf(stdout,
            "motion_mask_enabled=%d motion_mask_updates=%" PRIu64
            " motion_mask_active_tiles=%" PRIu64
            " motion_mask_active_frame=%u\n",
            self.overlayMaskEnabled ? 1 : 0, _motionMaskUpdates,
            _motionMaskActiveTiles, _activeMotionMaskFrameId);
    [self writeH264RegionSummaryToFile:stdout];
    fflush(stdout);
    free(_verifiedReceiver);_verifiedReceiver=NULL;
    sharp_framebuf_destroy(&_frontFb);
    sharp_video_region_reassembler_destroy(_videoReassembler);
    _videoReassembler = NULL;
    sharp_tile_receiver_destroy(&_receiver);
    pthread_mutex_destroy(&_stateLock);
}
@end
