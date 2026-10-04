#import "Internal.h"

int main(int argc, char **argv) {
    screen_config_t config;
    if (parse_args(argc, argv, &config) != 0) {
        usage(stderr);
        return 2;
    }

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = sharp_screen_send_signal_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    if (@available(macOS 12.3, *)) {
        if (!CGPreflightScreenCaptureAccess()) {
            if (config.request_permission) {
                (void)CGRequestScreenCaptureAccess();
            }
            if (!CGPreflightScreenCaptureAccess()) {
                fprintf(stderr,
                        "Screen Recording permission is required. Grant it in System Settings, "
                        "then rerun m1-screen-send.\n");
                return 3;
            }
        }
        if (config.check_permission) {
            return 0;
        }
    } else {
        fprintf(stderr, "m1-screen-send requires macOS 12.3+ for ScreenCaptureKit.\n");
        return 3;
    }

    int virtualDisplayApi = sharp_virtual_display_api_available();
    int virtualDisplayRequested = env_flag_enabled("SHARP_VDISPLAY");
    int virtualMirrorRequested = env_flag_enabled("SHARP_MIRROR_VDISPLAY");
    int virtualDisplayProbeRequested =
        env_flag_enabled("SHARP_VDISPLAY_PROBE");
    int virtualDisplayCreation = 0;
    CGDirectDisplayID virtualDisplayProbeId = 0;
    if (virtualDisplayProbeRequested && virtualDisplayApi) {
        virtualDisplayCreation =
            sharp_probe_virtual_display_creation(&virtualDisplayProbeId);
    }
    fprintf(stdout,
            "m1-screen-vdisplay api_available=%u creation_probe_requested=%u "
            "creation_probe_passed=%u probe_display_id=%u requested=%u\n",
            virtualDisplayApi ? 1u : 0u,
            virtualDisplayProbeRequested ? 1u : 0u,
            virtualDisplayCreation ? 1u : 0u, virtualDisplayProbeId,
            virtualDisplayRequested ? 1u : 0u);

    int fd = shtp_udp_socket(8 * 1024 * 1024, 32 * 1024 * 1024);
    if (fd < 0) {
        perror("socket");
        return 1;
    }
    if (config.source_ip != NULL && shtp_bind_ipv4(fd, config.source_ip, 0) != 0) {
        perror("bind source");
        close(fd);
        return 1;
    }

    struct sockaddr_in target;
    memset(&target, 0, sizeof(target));
    target.sin_family = AF_INET;
    target.sin_port = htons((unsigned short)config.port);
    if (inet_pton(AF_INET, config.target_ip, &target.sin_addr) != 1 ||
        connect(fd, (struct sockaddr *)&target, sizeof(target)) != 0) {
        perror("connect");
        close(fd);
        return 1;
    }

    @autoreleasepool {
        CGDirectDisplayID physicalDisplayID = CGMainDisplayID();
        CGDirectDisplayID requestedDisplayID = 0u;
        id virtualDisplay = nil;
        if (virtualDisplayRequested && virtualDisplayApi) {
            virtualDisplay = sharp_create_virtual_display(
                config.width, config.height, (double)config.fps,
                &requestedDisplayID);
        }
        if (virtualMirrorRequested && virtualDisplay == nil) {
            fprintf(stderr,
                    "target-shaped mirror requires a working virtual display; refusing distorted fallback\n");
            close(fd);
            return 1;
        }
        if (virtualMirrorRequested && virtualDisplay != nil) {
            int virtualMirrorActive =
                sharp_mirror_physical_display_from_virtual(physicalDisplayID,
                                                           requestedDisplayID);
            fprintf(stdout,
                    "m1-screen-vdisplay-mirror requested=1 active=%u physical=%u master=%u\n",
                    virtualMirrorActive ? 1u : 0u, physicalDisplayID,
                    requestedDisplayID);
            fflush(stdout);
            if (!virtualMirrorActive) {
                fprintf(stderr,
                        "target-shaped mirror could not be configured; refusing distorted fallback\n");
                close(fd);
                return 1;
            }
        }
        fprintf(stdout,
                "m1-screen-vdisplay-active requested=%u active=%u display_id=%u "
                "mode=%ux%u@%u fallback=%s\n",
                virtualDisplayRequested ? 1u : 0u,
                virtualDisplay != nil ? 1u : 0u, requestedDisplayID,
                config.width, config.height, config.fps,
                virtualDisplay != nil ? "none" : "mirror");
        fflush(stdout);

        SCShareableContent *shareable = nil;
        NSError *shareableError = nil;
        SCDisplay *display = nil;
        NSUInteger lastDiscoveredWidth = 0u;
        NSUInteger lastDiscoveredHeight = 0u;
        unsigned int discoveryAttempts = requestedDisplayID != 0u ? 100u : 1u;
        BOOL modeSelected = NO;
        for (unsigned int attempt = 0; attempt < discoveryAttempts; attempt++) {
            shareable = sharp_copy_shareable_content(&shareableError);
            if (shareable != nil) {
                display = find_display_with_id(shareable, requestedDisplayID);
                if (display != nil) {
                    lastDiscoveredWidth = display.width;
                    lastDiscoveredHeight = display.height;
                    if (requestedDisplayID == 0u ||
                        (lastDiscoveredWidth == config.width &&
                         lastDiscoveredHeight == config.height)) {
                        break;
                    }
                    display = nil;
                    if (!modeSelected && attempt >= 3u) {
                        modeSelected = YES;
                        fprintf(stdout,
                                "m1-screen-vdisplay-mode-select display_id=%u "
                                "from=%lux%lu to=%ux%u selected=%d\n",
                                requestedDisplayID, (unsigned long)lastDiscoveredWidth,
                                (unsigned long)lastDiscoveredHeight, config.width,
                                config.height,
                                sharp_select_display_mode(requestedDisplayID,
                                                          config.width, config.height));
                        fflush(stdout);
                    }
                }
            }
            if (attempt + 1u < discoveryAttempts) {
                usleep(100000);
            }
        }
        if (shareable == nil) {
            fprintf(stderr, "shareable content failed: %s\n",
                    shareableError.localizedDescription.UTF8String);
            close(fd);
            return 1;
        }
        if (display == nil) {
            fprintf(stderr,
                    "requested display %u did not become ready at %ux%u after "
                    "%u attempts (last=%lux%lu)\n",
                    requestedDisplayID, config.width, config.height,
                    discoveryAttempts, (unsigned long)lastDiscoveredWidth,
                    (unsigned long)lastDiscoveredHeight);
            close(fd);
            return 1;
        }

        SCContentFilter *filter =
            [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
        BOOL encodeTickEnabled =
            env_flag_enabled("SHARP_ENCODE_TICK") ? YES : NO;
        int captureFps = (int)llround(env_double_or_default(
            "SHARP_SCK_CAPTURE_FPS",
            encodeTickEnabled ? 120.0 : (double)config.fps));
        captureFps = MAX(1, MIN(captureFps, 240));
        BOOL captureUnthrottled =
            env_flag_enabled("SHARP_SCK_UNTHROTTLED") ? YES : NO;
        int queueDepth = (int)llround(env_double_or_default(
            "SHARP_SCK_QUEUE_DEPTH", encodeTickEnabled ? 6.0 : 4.0));
        queueDepth = MAX(3, MIN(queueDepth, 8));
        SCStreamConfiguration *streamConfig = [[SCStreamConfiguration alloc] init];
        streamConfig.width = config.width;
        streamConfig.height = config.height;
        streamConfig.minimumFrameInterval =
            captureUnthrottled ? kCMTimeZero : CMTimeMake(1, captureFps);
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA;
        streamConfig.queueDepth = queueDepth;
        BOOL cursorOverlayEnabled =
            env_flag_enabled("SHARP_CURSOR_OVERLAY") ? YES : NO;
        // Keep the pointer out of generated image-quality specimens.
        streamConfig.showsCursor = !cursorOverlayEnabled && getenv("SHARP_TEST_SCENE_IMAGE") == NULL;
        streamConfig.scalesToFit = YES;
        streamConfig.colorSpaceName = kCGColorSpaceSRGB;
        const char *captureResolutionName = "automatic";
        if (@available(macOS 14.0, *)) {
            const char *requestedResolution =
                getenv("SHARP_SCK_CAPTURE_RESOLUTION");
            if (requestedResolution != NULL &&
                strcmp(requestedResolution, "best") == 0) {
                streamConfig.captureResolution = SCCaptureResolutionBest;
                captureResolutionName = "best";
            } else if (requestedResolution != NULL &&
                       strcmp(requestedResolution, "nominal") == 0) {
                streamConfig.captureResolution = SCCaptureResolutionNominal;
                captureResolutionName = "nominal";
            }
        }
        fprintf(stdout,
                "m1-screen-capture display_id=%u source=%ux%u output=%ux%u "
                "capture_fps=%d unthrottled=%u queue_depth=%d encode_tick=%u "
                "capture_resolution=%s\n",
                display.displayID, (uint32_t)display.width,
                (uint32_t)display.height, config.width, config.height,
                captureFps, captureUnthrottled ? 1u : 0u, queueDepth,
                encodeTickEnabled ? 1u : 0u, captureResolutionName);

        SharpScreenSender *sender = [[SharpScreenSender alloc] init];
        sender.fd = fd;
        sender.width = config.width;
        sender.height = config.height;
        sender.sequence = 1;
        sender.frameId = 0;
        sender.payloadSize = config.payload_size;
        sender.fps = config.fps;
        sender.initialFullFrames = config.initial_full_frames;
        sender.fullRefreshIntervalNs =
            config.full_refresh_interval > 0.0
                ? (uint64_t)(config.full_refresh_interval * 1000000000.0)
                : 0;
        sender.pacingMbps = config.pacing_mbps;
        sender.hybridH264 = config.hybrid_h264 ? YES : NO;
        sender.fullFrameEnabled = env_flag_enabled("SHARP_FULLFRAME") ? YES : NO;
        sender.fullFrameDirectFeed =
            env_flag_enabled("SHARP_FULLFRAME_DIRECT") ? YES : NO;
        sender.motionMaskEnabled = !env_flag_disabled("SHARP_OVERLAY_MASK");
        sender.motionPrerollEnabled =
            env_flag_enabled("SHARP_MOTION_PREROLL") ? YES : NO;
        sender.encodeTickEnabled = encodeTickEnabled;
        sender.phaseLockEnabled =
            sender.encodeTickEnabled && env_flag_enabled("SHARP_PHASE_LOCK") ? YES : NO;
        sender.vtLowLatencyRequested =
            env_flag_enabled("SHARP_VT_LOW_LATENCY") ? YES : NO;
        sender.vtFastProfileRequested =
            env_flag_enabled("SHARP_VT_FAST_PROFILE") ? YES : NO;
        sender.vtNv12Requested =
            env_flag_enabled("SHARP_VT_NV12_INPUT") ? YES : NO;
        sender.tileBatchEnabled = !env_flag_disabled("SHARP_TILE_BATCH");
        sender.tileZstdEnabled = !env_flag_disabled("SHARP_TILE_ZSTD");
        if (sender.tileZstdEnabled) {
            if (![sender ensureTileZstdContext]) {
                sender.tileZstdEnabled = NO;
                fprintf(stderr, "tile_zstd_init_failed=1\n");
            }
        }
        sender.h264AdaptiveBitrateEnabled =
            !env_flag_enabled("SHARP_H264_ADAPTIVE_BITRATE_DISABLE");
        sender.h264AdaptiveMinBitrate =
            (uint64_t)env_double_or_default("SHARP_H264_ADAPTIVE_MIN",
                                            60000000.0);
        sender.h264AdaptiveMaxBitrate =
            (uint64_t)env_double_or_default("SHARP_H264_ADAPTIVE_MAX", 0.0);
        sender.vsliceDropEvery = config.vslice_drop_every;
        sender.fecEnabled = !env_flag_disabled("SHARP_FEC");
        sender.h264ResendTarget = SHARP_H264_RESEND_MIN_GENERATIONS;
        sender.processingQueue =
            dispatch_queue_create("sh.sharp.m1-screen-send.process",
                                  DISPATCH_QUEUE_SERIAL);
        sender.txQueue =
            dispatch_queue_create("sh.sharp.m1-screen-send.tx",
                                  DISPATCH_QUEUE_SERIAL);
        sender.h264OutputQueue =
            dispatch_queue_create("sh.sharp.m1-screen-send.h264-output",
                                  DISPATCH_QUEUE_SERIAL);
        if (env_flag_enabled("SHARP_VERIFIED_HYBRID") && sender.hybridH264) [sender startVerifiedHybrid];
        [sender startEncodeTick];
        if (config.frame_log_path != NULL) {
            sender.frameLog = fopen(config.frame_log_path, "w");
            if (sender.frameLog != NULL) {
                fprintf(sender.frameLog,
                        "frame_id\tcallback_ns\tanalyze_start_ns\tsend_done_ns\t"
                        "analyze_us\tsend_us\tdirty_tiles\tbytes\tpackets\t"
                        "force_full\tsend_failed\n");
                fflush(sender.frameLog);
            }
        }
        if (config.episode_log_path != NULL) {
            sender.episodeLog = fopen(config.episode_log_path, "w");
            if (sender.episodeLog != NULL) {
                fprintf(sender.episodeLog,
                        "timestamp_ns\tevent\treason\tframe_id\tmotion_tiles\t"
                        "sustained_motion_tiles\tmotion_regions\ttile_count\t"
                        "held_ms\tquiet_ms\tactive\tpre_submitted\t"
                        "submitted\tin_flight\tsend_drops_delta\tforce_keyframe\n");
                fflush(sender.episodeLog);
            }
        }
        if ([sender setupDirtyMap] != 0) {
            fprintf(stderr, "dirty map allocation failed\n");
            close(fd);
            return 1;
        }
        if (config.m2_log_path != NULL || config.hybrid_h264) {
            if ([sender setupM2ClassifierWithFps:config.fps] != 0) {
                fprintf(stderr, "m2 classifier allocation failed\n");
                [sender destroyDirtyMap];
                close(fd);
                return 1;
            }
            sender.m2Log = config.m2_log_path != NULL ? fopen(config.m2_log_path, "w")
                                                       : NULL;
            if (sender.m2Log != NULL) {
                fprintf(sender.m2Log,
                        "frame_id\tdirty_tiles\tsend_tiles\tstatic_tiles\t"
                        "motion_tiles\tpending_refine_tiles\trefine_tiles\tregions\t"
                        "born\tresized\tdied\tevents\n");
                fflush(sender.m2Log);
            }
        }

        dispatch_queue_t queue = dispatch_queue_create("sh.sharp.m1-screen-send.capture",
                                                       DISPATCH_QUEUE_SERIAL);
        SCStream *stream = [[SCStream alloc] initWithFilter:filter
                                              configuration:streamConfig
                                                   delegate:sender];
        NSError *outputError = nil;
        if (![stream addStreamOutput:sender
                                type:SCStreamOutputTypeScreen
                  sampleHandlerQueue:queue
                               error:&outputError]) {
            fprintf(stderr, "addStreamOutput failed: %s\n",
                    outputError.localizedDescription.UTF8String);
            [sender destroyH264Encoder];
            [sender destroyH264ResendRing];
            [sender destroyM2Classifier];
            [sender destroyDirtyMap];
            close(fd);
            return 1;
        }

        sender.captureStartNs = shtp_now_ns();
        __block NSError *startError = nil;
        dispatch_semaphore_t startSem = dispatch_semaphore_create(0);
        [stream startCaptureWithCompletionHandler:^(NSError *_Nullable error) {
          startError = error;
          dispatch_semaphore_signal(startSem);
        }];
        dispatch_semaphore_wait(startSem, DISPATCH_TIME_FOREVER);
        if (startError != nil) {
            fprintf(stderr, "startCapture failed: %s\n",
                    startError.localizedDescription.UTF8String);
            [sender destroyH264Encoder];
            [sender destroyH264ResendRing];
            [sender destroyM2Classifier];
            [sender destroyDirtyMap];
            close(fd);
            return 1;
        }

        dispatch_source_t cursorTimer = nil;
        if (cursorOverlayEnabled) {
            size_t cursorShapes = sharp_cursor_shapes_prepare();
            CGDirectDisplayID cursorDisplayID = display.displayID;
            /* Interactive QoS keeps the 240 Hz rhythm steady under encode load. */
            dispatch_queue_t cursorQueue = dispatch_queue_create(
                "sh.sharp.m1-screen-send.cursor",
                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                        QOS_CLASS_USER_INTERACTIVE, 0));
            __block uint32_t cursorSeq = 1u;
            __block int32_t lastCursorX = INT32_MIN;
            __block int32_t lastCursorY = INT32_MIN;
            __block uint32_t lastCursorImage = 0u;
            __block BOOL lastCursorVisible = NO;
            __block uint64_t lastCursorSendNs = 0u;
            __block uint64_t lastShapeNs = 0u;
            __block uint32_t imageId = SHARP_CURSOR_IMAGE_ARROW;
            cursorTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                 cursorQueue);
            dispatch_source_set_timer(cursorTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                                      4166667ull, 100000ull);
            dispatch_source_set_event_handler(cursorTimer, ^{
              uint64_t nowNs = shtp_now_ns();
              /* The shape lookup costs ~0.2 ms; 30 Hz is quick enough for a
               * pointer turning into a text cursor. */
              if (lastShapeNs == 0u || nowNs - lastShapeNs >= 33000000ULL) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                  imageId = sharp_cursor_image_id(NSCursor.currentSystemCursor);
#pragma clang diagnostic pop
                  lastShapeNs = nowNs;
              }
              /* Global CoreGraphics coordinates, read fresh each sample so a
               * rearranged display does not offset the cursor. */
              CGRect bounds = CGDisplayBounds(cursorDisplayID);
              CGEventRef event = CGEventCreate(NULL);
              if (event == NULL || bounds.size.width <= 0.0 || bounds.size.height <= 0.0) {
                  if (event != NULL) CFRelease(event);
                  return;
              }
              CGPoint loc = CGEventGetLocation(event);
              CFRelease(event);
              uint64_t sampleNs = shtp_now_ns();
              CGFloat sx = (loc.x - bounds.origin.x) / bounds.size.width;
              CGFloat sy = (loc.y - bounds.origin.y) / bounds.size.height;
              BOOL visible = sx >= 0.0 && sx < 1.0 && sy >= 0.0 && sy < 1.0;
              int32_t x = (int32_t)llround(MAX(0.0, MIN(1.0, sx)) *
                                           (CGFloat)MAX(1u, config.width - 1u));
              int32_t y = (int32_t)llround(MAX(0.0, MIN(1.0, sy)) *
                                           (CGFloat)MAX(1u, config.height - 1u));
              BOOL changed = x != lastCursorX || y != lastCursorY ||
                             imageId != lastCursorImage ||
                             visible != lastCursorVisible;
              if (!changed && lastCursorSendNs != 0u &&
                  sampleNs - lastCursorSendNs < 100000000ULL) {
                  return;
              }
              [sender sendCursorPositionX:x
                                        y:y
                                      seq:cursorSeq++
                             sampleTimeNs:sampleNs
                                  imageId:imageId
                                  visible:visible];
              lastCursorX = x;
              lastCursorY = y;
              lastCursorImage = imageId;
              lastCursorVisible = visible;
              lastCursorSendNs = sampleNs;
            });
            dispatch_resume(cursorTimer);
            fprintf(stdout,
                    "m1-screen-cursor sample_hz=240 shape_hz=30 shapes=%zu heartbeat_hz=10\n",
                    cursorShapes);
        }

        uint64_t runStartNs = shtp_now_ns();
        uint64_t endNs =
            config.duration > 0
                ? runStartNs + (uint64_t)config.duration * 1000000000ULL
                : 0;
        uint64_t nextStatsNs =
            config.stats_interval > 0
                ? runStartNs + (uint64_t)config.stats_interval * 1000000000ULL
                : 0;
        uint64_t nextPingNs = runStartNs;
        while (!g_sharp_stop_requested &&
               (config.duration == 0 || shtp_now_ns() < endNs)) {
            uint64_t nowNs = shtp_now_ns();
            if (nowNs >= nextPingNs) {
                [sender sendClockPing];
                nextPingNs = nowNs + 100000000ULL;
            }
            [sender drainFeedback];
            if (config.stats_interval > 0 && nowNs >= nextStatsNs) {
                uint64_t firstNs = sender.firstFrameNs != 0 ? sender.firstFrameNs
                                                            : sender.captureStartNs;
                double liveSec =
                    firstNs != 0 && nowNs > firstNs
                        ? (double)(nowNs - firstNs) / 1000000000.0
                        : 0.0;
                uint64_t totalWirePackets =
                    sender.stats.packets + sender.h264Packets +
                    sender.h264RetransmitPackets;
                uint64_t totalWireBytes =
                    sender.stats.bytes + sender.h264Bytes +
                    sender.h264RetransmitBytes;
                uint64_t liveFrames = sender.fullFrameH264Frames > 0
                                          ? sender.fullFrameH264Frames
                                          : sender.h264Frames;
                double liveFps = liveSec > 0.0 ? (double)liveFrames / liveSec : 0.0;
                double liveMbps =
                    liveSec > 0.0
                        ? (double)totalWireBytes * 8.0 / liveSec / 1000000.0
                        : 0.0;
                double livePps =
                    liveSec > 0.0 ? (double)totalWirePackets / liveSec : 0.0;
                double g2gP50Ms =
                    (double)[sender rollingSourceToPresentPercentileNs:0.50
                                                                   nowNs:nowNs] /
                    1000000.0;
                double g2gP95Ms =
                    (double)[sender rollingSourceToPresentPercentileNs:0.95
                                                                   nowNs:nowNs] /
                    1000000.0;
                double g2gP99Ms =
                    (double)[sender rollingSourceToPresentPercentileNs:0.99
                                                                   nowNs:nowNs] /
                    1000000.0;
                double receiverFreshFps =
                    [sender rollingReceiverFreshFpsNowNs:nowNs];
                char fresh[256];
                [sender freshnessHistogramString:fresh size:sizeof(fresh)];
                fprintf(stdout,
                        "m1-screen-live fps=%.2f mbps=%.2f packets_per_sec=%.2f "
                        "resolution=%ux%u latency_ms=%.3f "
                        "g2g_ms_p50=%.3f g2g_ms_p95=%.3f g2g_ms_p99=%.3f "
                        "receiver_fresh_fps=%.2f "
                        "fresh=%s frame=%u\n",
                        liveFps, liveMbps, livePps, config.width, config.height,
                        g2gP95Ms, g2gP50Ms, g2gP95Ms, g2gP99Ms,
                        receiverFreshFps, fresh,
                        sender.frameId == 0 ? 0 : sender.frameId - 1u);
                [sender writeRollingStageTelemetryNowNs:nowNs toFile:stdout];
                fflush(stdout);
                nextStatsNs =
                    nowNs + (uint64_t)config.stats_interval * 1000000000ULL;
            }
            (void)[[NSRunLoop currentRunLoop]
                runMode:NSDefaultRunLoopMode
             beforeDate:[NSDate date]];
            usleep(4000);
        }

        if (cursorTimer != nil) {
            dispatch_source_cancel(cursorTimer);
            cursorTimer = nil;
        }

        dispatch_semaphore_t stopSem = dispatch_semaphore_create(0);
        [stream stopCaptureWithCompletionHandler:^(NSError *_Nullable error) {
          if (error != nil) {
              fprintf(stderr, "stopCapture failed: %s\n", error.localizedDescription.UTF8String);
          }
          dispatch_semaphore_signal(stopSem);
        }];
        dispatch_semaphore_wait(stopSem, DISPATCH_TIME_FOREVER);

        usleep(200000);
        dispatch_sync(sender.processingQueue, ^{
        });
        [sender flushH264Encoders];
        dispatch_sync(sender.h264OutputQueue, ^{
        });
        [sender requestTxStop];
        dispatch_sync(sender.txQueue, ^{
          [sender stopTxAndSendFinal];
        });
        /* Drain txPump blocks that were queued behind the stop boundary. */
        dispatch_sync(sender.txQueue, ^{
        });

        uint64_t summaryNs = shtp_now_ns();
        double sec = sender.firstFrameNs != 0
                         ? (double)(summaryNs - sender.firstFrameNs) / 1000000000.0
                         : 0.0;
        double captureSec =
            sender.captureStartNs != 0 && summaryNs > sender.captureStartNs
                ? (double)(summaryNs - sender.captureStartNs) / 1000000000.0
                : sec;
        double mbps = sec > 0.0 ? (double)sender.stats.bytes * 8.0 / sec / 1000000.0
                                : 0.0;
        uint64_t totalWirePackets =
            sender.stats.packets + sender.h264Packets + sender.h264RetransmitPackets;
        uint64_t totalWireBytes =
            sender.stats.bytes + sender.h264Bytes + sender.h264RetransmitBytes;
        double totalWireMbps =
            sec > 0.0 ? (double)totalWireBytes * 8.0 / sec / 1000000.0 : 0.0;
        double totalWirePacketsPerSec =
            sec > 0.0 ? (double)totalWirePackets / sec : 0.0;
        double h264PacketsPerSec =
            sec > 0.0 ? (double)sender.h264Packets / sec : 0.0;
        double processedFps = sec > 0.0 ? (double)sender.stats.frames / sec : 0.0;
        double captureCallbackFps =
            captureSec > 0.0 ? (double)sender.captureCallbacks / captureSec : 0.0;
        double sckCompleteFps =
            captureSec > 0.0
                ? (double)[sender sckStatusCountAtIndex:0] / captureSec
                : 0.0;
        double sckIdleFps =
            captureSec > 0.0
                ? (double)[sender sckStatusCountAtIndex:1] / captureSec
                : 0.0;
        double replacedFps =
            captureSec > 0.0 ? (double)sender.replacedFrames / captureSec : 0.0;
        double invalidFps =
            captureSec > 0.0 ? (double)sender.invalidFrames / captureSec : 0.0;
        double fullFrameProcessedFps =
            sec > 0.0 ? (double)sender.fullFrameProcessedFrames / sec : 0.0;
        double fullFrameEncodeSubmitFps =
            sec > 0.0 ? (double)sender.fullFrameEncodeSubmissions / sec : 0.0;
        double fullFrameCallbackFps =
            sec > 0.0 ? (double)sender.fullFrameH264Frames / sec : 0.0;
        double firstFrameMs =
            sender.captureStartNs != 0 && sender.firstFrameNs != 0
                ? (double)(sender.firstFrameNs - sender.captureStartNs) / 1000000.0
                : -1.0;
        double firstH264Ms =
            sender.captureStartNs != 0 && sender.firstH264Ns != 0
                ? (double)(sender.firstH264Ns - sender.captureStartNs) / 1000000.0
                : -1.0;
        uint64_t cleanupLatencyP50 =
            [sender cleanupLatencyPercentile:0.50];
        uint64_t cleanupLatencyP95 =
            [sender cleanupLatencyPercentile:0.95];
        uint64_t txLatestLagP50 =
            [sender txLatestSourceLagPercentile:0.50];
        uint64_t txLatestLagP95 =
            [sender txLatestSourceLagPercentile:0.95];
        uint64_t h264FrameBytesP50 =
            [sender h264FrameBytesPercentile:0.50];
        uint64_t h264FrameBytesP95 =
            [sender h264FrameBytesPercentile:0.95];
        uint64_t callbackToProcessP50 =
            [sender callbackToProcessLatencyPercentileNs:0.50];
        uint64_t callbackToProcessP95 =
            [sender callbackToProcessLatencyPercentileNs:0.95];
        uint64_t processDurationP50 =
            [sender processDurationPercentileNs:0.50];
        uint64_t processDurationP95 =
            [sender processDurationPercentileNs:0.95];
        uint64_t fullFrameProcessP50 =
            [sender fullFrameProcessDurationPercentileNs:0.50];
        uint64_t fullFrameProcessP95 =
            [sender fullFrameProcessDurationPercentileNs:0.95];
        uint64_t fullFrameSubmitP50 =
            [sender fullFrameEncodeSubmitDurationPercentileNs:0.50];
        uint64_t fullFrameSubmitP95 =
            [sender fullFrameEncodeSubmitDurationPercentileNs:0.95];
        uint64_t fullFrameCopyP50 =
            [sender fullFrameCopyDurationPercentileNs:0.50];
        uint64_t fullFrameCopyP95 =
            [sender fullFrameCopyDurationPercentileNs:0.95];
        uint64_t h264CallbackP50 =
            [sender h264CallbackLatencyPercentileNs:0.50];
        uint64_t h264CallbackP95 =
            [sender h264CallbackLatencyPercentileNs:0.95];
        uint64_t h264EncoderResets = [sender h264EncoderResetCount];
        double g2gP50Ms =
            (double)[sender g2gPercentileNs:0.50] / 1000000.0;
        double g2gP95Ms =
            (double)[sender g2gPercentileNs:0.95] / 1000000.0;
        double g2gP99Ms =
            (double)[sender g2gPercentileNs:0.99] / 1000000.0;
        char fresh[256];
        [sender freshnessHistogramString:fresh size:sizeof(fresh)];
        double selectedCoverageRatio =
            sender.h264MotionCandidateTiles > 0
                ? (double)sender.h264MotionCoveredTiles /
                      (double)sender.h264MotionCandidateTiles
                : 1.0;
        fprintf(stdout,
                "m1-screen-vt low_latency_requested=%u low_latency_active=%u "
                "low_latency_fallbacks=%" PRIu64
                " speed_priority=%u frame_delay_bounded=%u hardware=%u "
                "fast_profile_requested=%u fast_profile_active=%u "
                "reference_buffer_bounded=%u nv12_requested=%u nv12_active=%u "
                "pixel_transfer_failures=%" PRIu64 " transfer_ms_p95=%.3f\n",
                sender.vtLowLatencyRequested ? 1u : 0u,
                sender.vtLowLatencyActive ? 1u : 0u,
                sender.vtLowLatencyFallbacks,
                sender.vtSpeedPriorityActive ? 1u : 0u,
                sender.vtFrameDelayBounded ? 1u : 0u,
                sender.vtHardwareEncoder ? 1u : 0u,
                sender.vtFastProfileRequested ? 1u : 0u,
                sender.vtFastProfileActive ? 1u : 0u,
                sender.vtReferenceBufferBounded ? 1u : 0u,
                sender.vtNv12Requested ? 1u : 0u,
                sender.vtNv12Active ? 1u : 0u,
                sender.vtPixelTransferFailures,
                (double)[sender fullFrameConvertDurationPercentileNs:0.95] /
                    1000000.0);
        [sender writeRollingStageTelemetryNowNs:summaryNs toFile:stdout];
        fprintf(stdout,
                "m1-screen-anti-entropy digest_packets=%" PRIu64
                " digest_entries=%" PRIu64 " mismatches=%" PRIu64
                " repairs_queued=%" PRIu64 "\n",
                sender.tileDigestPackets, sender.tileDigestEntries,
                sender.tileDigestMismatches,
                sender.tileDigestRepairsQueued);
        fprintf(stdout,
                "m1-screen-send frames=%" PRIu64 " tiles=%" PRIu64
                " capture_frames=%" PRIu64 " sent_frames=%" PRIu64
                " capture_callbacks=%" PRIu64
                " capture_callback_fps=%.2f"
                " idle_frames=%" PRIu64 " replaced_frames=%" PRIu64
                " replaced_fps=%.2f"
                " full_frames=%" PRIu64
                " dirty_rect_frames=%" PRIu64 " dirty_rects=%" PRIu64
                " dirty_rect_scaled_frames=%" PRIu64
                " dirty_rect_clipped=%" PRIu64
                " candidate_tiles=%" PRIu64 " false_dirty_tiles=%" PRIu64
                " metadata_fallback_frames=%" PRIu64
                " sck_status_complete=%" PRIu64
                " sck_status_idle=%" PRIu64
                " sck_status_blank=%" PRIu64
                " sck_status_suspended=%" PRIu64
                " sck_status_started=%" PRIu64
                " sck_status_stopped=%" PRIu64
                " sck_status_other=%" PRIu64
                " complete_fps=%.2f"
                " idle_fps=%.2f"
                " callback_to_process_ms_p50=%.3f"
                " callback_to_process_ms_p95=%.3f"
                " process_duration_ms_p50=%.3f"
                " process_duration_ms_p95=%.3f"
                " changed_tiles=%" PRIu64
                " tile_batch_enabled=%u"
                " tile_batch_packets=%" PRIu64
                " tile_batch_tiles=%" PRIu64
                " tile_zstd_enabled=%u"
                " solid_tiles=%" PRIu64 " twocolor_tiles=%" PRIu64
                " sparse_tiles=%" PRIu64 " rle_tiles=%" PRIu64
                " raw_tiles=%" PRIu64
                " zstd_tiles=%" PRIu64
                " m2_motion_frames=%" PRIu64
                " m2_motion_tiles=%" PRIu64
                " m2_refine_tiles=%" PRIu64
                " m2_born_regions=%" PRIu64
                " m2_resized_regions=%" PRIu64
                " m2_died_regions=%" PRIu64
                " h264_frames=%" PRIu64
                " h264_keyframes=%" PRIu64
                " h264_pframes=%" PRIu64
                " h264_encode_submissions=%" PRIu64
                " h264_encode_in_flight=%" PRIu64
                " h264_max_encode_in_flight=%" PRIu64
                " h264_pixel_buffer_pool_creates=%" PRIu64
                " h264_pixel_buffer_pool_failures=%" PRIu64
                " h264_frame_end_waits=%" PRIu64
                " h264_frame_end_wait_timeouts=%" PRIu64
                " h264_frame_end_video_drops=%" PRIu64
                " h264_frame_bytes_p50=%" PRIu64
                " h264_frame_bytes_p95=%" PRIu64
                " h264_encoder_resets=%" PRIu64
                " h264_target_bitrate=%" PRIu64
                " h264_packets=%" PRIu64
                " h264_bytes=%" PRIu64
                " h264_fec_packets=%" PRIu64
                " h264_fec_bytes=%" PRIu64
                " h264_failures=%" PRIu64
                " h264_feedback=%" PRIu64
                " h264_fullframe_feedback_ignored=%" PRIu64
                " h264_fullframe_keyframe_requests=%" PRIu64
                " h264_missing_generations=%" PRIu64
                " h264_keyframe_requests=%" PRIu64
                " h264_vslice_nacks=%" PRIu64
                " h264_retransmit_packets=%" PRIu64
                " h264_retransmit_bytes=%" PRIu64
                " h264_retransmit_misses=%" PRIu64
                " h264_idr_requests=%" PRIu64
                " h264_idr_sent=%" PRIu64
                " h264_max_active_regions=%" PRIu64
                " h264_warmup_skips=%" PRIu64
                " h264_motion_candidate_tiles=%" PRIu64
                " h264_motion_covered_tiles=%" PRIu64
                " h264_motion_fallback_lossless_tiles=%" PRIu64
                " h264_lane_births=%" PRIu64
                " h264_lane_adoptions=%" PRIu64
                " h264_lane_retires=%" PRIu64
                " full_frame_enabled=%u"
                " full_frame_direct_feed=%u"
                " full_frame_active=%u"
                " full_frame_entries=%" PRIu64
                " full_frame_exits=%" PRIu64
                " full_frame_mode_frames=%" PRIu64
                " full_frame_h264_frames=%" PRIu64
                " full_frame_h264_bytes=%" PRIu64
                " full_frame_processed_frames=%" PRIu64
                " full_frame_processed_fps=%.2f"
                " full_frame_encode_submissions=%" PRIu64
                " full_frame_encode_submit_fps=%.2f"
                " full_frame_encode_in_flight=%" PRIu64
                " full_frame_max_encode_in_flight=%" PRIu64
                " full_frame_send_drops=%" PRIu64
                " full_frame_frame_ends_from_callback=%" PRIu64
                " full_frame_h264_callback_fps=%.2f"
                " full_frame_direct_submissions=%" PRIu64
                " full_frame_copied_submissions=%" PRIu64
                " full_frame_direct_fallbacks=%" PRIu64
                " full_frame_process_ms_p50=%.3f"
                " full_frame_process_ms_p95=%.3f"
                " full_frame_encode_submit_ms_p50=%.3f"
                " full_frame_encode_submit_ms_p95=%.3f"
                " full_frame_copy_ms_p50=%.3f"
                " full_frame_copy_ms_p95=%.3f"
                " encode_tick_enabled=%u"
                " encode_tick_fires=%" PRIu64
                " encode_tick_idle_skips=%" PRIu64
                " phase_lock_enabled=%u"
                " phase_lock_feedback=%" PRIu64
                " phase_lock_adjustments=%" PRIu64
                " phase_lock_adjustment_ms_total=%.3f"
                " phase_lock_lead_ms=%.3f"
                " phase_lock_period_ms=%.3f"
                " phase_lock_last_error_ms=%.3f"
                " phase_lock_last_adjust_ms=%.3f"
                " h264_callback_latency_ms_p50=%.3f"
                " h264_callback_latency_ms_p95=%.3f"
                " g2g_ms_p50=%.3f"
                " g2g_ms_p95=%.3f"
                " g2g_ms_p99=%.3f"
                " fresh=%s"
                " full_frame_analyzer_skipped_frames=%" PRIu64
                " full_frame_exit_refinement_tiles=%" PRIu64
                " full_frame_motion_candidate_tiles=%" PRIu64
                " full_frame_motion_covered_tiles=%" PRIu64
                " full_frame_suppressed_lossless_tiles=%" PRIu64
                " h264_adaptive_bitrate=%" PRIu64
                " h264_adaptive_min_bitrate=%" PRIu64
                " h264_adaptive_max_bitrate=%" PRIu64
                " h264_adaptive_backoffs=%" PRIu64
                " h264_adaptive_ramps=%" PRIu64
                " selected_h264_coverage_ratio=%.4f"
                " tx_frames=%" PRIu64
                " tx_tiles=%" PRIu64
                " tx_failures=%" PRIu64
                " tx_frame_ends=%" PRIu64
                " tx_dropped_jobs=%" PRIu64
                " tx_dropped_tiles=%" PRIu64
                " tx_dropped_motion_fallback_tiles=%" PRIu64
                " tx_dropped_refine_tiles=%" PRIu64
                " tx_dropped_stale_frames=%" PRIu64
                " tx_coalesced_jobs=%" PRIu64
                " tx_max_pending_jobs=%" PRIu64
                " tx_max_job_age_ms=%" PRIu64
                " tx_estimated_bytes=%" PRIu64
                " cleanup_pending_tiles=%u"
                " cleanup_replaced_tiles=%" PRIu64
                " cleanup_coalesced_tiles=%" PRIu64
                " cleanup_cancelled_tiles=%" PRIu64
                " cleanup_sent_tiles=%" PRIu64
                " cleanup_protected_tiles=%" PRIu64
                " cleanup_obsolete_tiles=%" PRIu64
                " cleanup_latency_ms_p50=%" PRIu64
                " cleanup_latency_ms_p95=%" PRIu64
                " cleanup_latency_ms_max=%" PRIu64
                " tx_latest_source_lag_frames_p50=%" PRIu64
                " tx_latest_source_lag_frames_p95=%" PRIu64
                " tx_latest_source_lag_frames_max=%" PRIu64
                " tx_oldest_cleanup_age_ms=%" PRIu64
                " h264_induced_drops=%" PRIu64
                " h264_resend_target=%u"
                " h264_resend_max_active=%u"
                " h264_resend_evictions=%" PRIu64
                " h264_resend_repair_evictions=%" PRIu64
                " h264_post_frame_repair_drains=%" PRIu64
                " first_frame_ms=%.1f"
                " first_h264_ms=%.1f"
                " processed_fps=%.2f"
                " invalid_fps=%.2f"
                " total_wire_packets=%" PRIu64
                " total_wire_bytes=%" PRIu64
                " total_wire_mbps=%.2f"
                " total_wire_packets_per_sec=%.2f"
                " h264_packets_per_sec=%.2f"
                " packets=%" PRIu64 " bytes=%" PRIu64 " seconds=%.3f "
                "bandwidth=%.2fMbps final_frame=%u skipped=%" PRIu64
                " invalid=%" PRIu64 "\n",
                sender.stats.frames, sender.stats.tiles, sender.stats.frames,
                sender.sentFrames, sender.captureCallbacks,
                captureCallbackFps,
                sender.idleFrames, sender.replacedFrames, replacedFps,
                sender.fullFrames,
                sender.dirtyRectFrames, sender.dirtyRects,
                sender.dirtyRectScaledFrames, sender.dirtyRectClipped,
                sender.candidateTiles,
                sender.falseDirtyTiles, sender.metadataFallbackFrames,
                [sender sckStatusCountAtIndex:0],
                [sender sckStatusCountAtIndex:1],
                [sender sckStatusCountAtIndex:2],
                [sender sckStatusCountAtIndex:3],
                [sender sckStatusCountAtIndex:4],
                [sender sckStatusCountAtIndex:5],
                [sender sckStatusOtherCount],
                sckCompleteFps, sckIdleFps,
                (double)callbackToProcessP50 / 1000000.0,
                (double)callbackToProcessP95 / 1000000.0,
                (double)processDurationP50 / 1000000.0,
                (double)processDurationP95 / 1000000.0,
                sender.stats.tiles,
                sender.tileBatchEnabled ? 1u : 0u,
                sender.stats.batch_packets,
                sender.stats.batch_tiles,
                sender.tileZstdEnabled ? 1u : 0u,
                sender.stats.solid_tiles, sender.stats.twocolor_tiles,
                sender.stats.sparse_tiles, sender.stats.rle_tiles, sender.stats.raw_tiles,
                sender.stats.zstd_tiles,
                sender.m2MotionFrames, sender.m2MotionTiles, sender.m2RefineTiles,
                sender.m2BornRegions, sender.m2ResizedRegions, sender.m2DiedRegions,
                sender.h264Frames, sender.h264Keyframes, sender.h264Pframes,
                sender.h264EncodeSubmissions, sender.h264EncodeInFlight,
                sender.h264MaxEncodeInFlight,
                sender.h264PixelBufferPoolCreates,
                sender.h264PixelBufferPoolFailures,
                sender.h264FrameEndWaits,
                sender.h264FrameEndWaitTimeouts,
                sender.h264FrameEndVideoDrops,
                h264FrameBytesP50, h264FrameBytesP95, h264EncoderResets,
                sender.h264TargetBitrate,
                sender.h264Packets,
                sender.h264Bytes,
                sender.h264FecPackets, sender.h264FecBytes,
                sender.h264EncodeFailures,
                sender.h264FeedbackPackets,
                sender.h264FullFrameFeedbackIgnored,
                sender.h264FullFrameKeyframeRequests,
                sender.h264MissingGenerations,
                sender.h264KeyframeRequests,
                sender.h264VsliceNacks, sender.h264RetransmitPackets,
                sender.h264RetransmitBytes, sender.h264RetransmitMisses,
                sender.h264IdrRequests, sender.h264IdrSent,
                sender.h264MaxActiveRegions,
                sender.h264WarmupSkips,
                sender.h264MotionCandidateTiles,
                sender.h264MotionCoveredTiles,
                sender.h264MotionFallbackLosslessTiles,
                sender.h264LaneBirths, sender.h264LaneAdoptions,
                sender.h264LaneRetires,
                sender.fullFrameEnabled ? 1u : 0u,
                sender.fullFrameDirectFeed ? 1u : 0u,
                sender.fullFrameActive ? 1u : 0u,
                sender.fullFrameEntries, sender.fullFrameExits,
                sender.fullFrameModeFrames,
                sender.fullFrameH264Frames, sender.fullFrameH264Bytes,
                sender.fullFrameProcessedFrames, fullFrameProcessedFps,
                sender.fullFrameEncodeSubmissions, fullFrameEncodeSubmitFps,
                sender.fullFrameEncodeInFlight,
                sender.fullFrameMaxEncodeInFlight,
                sender.fullFrameSendDrops,
                sender.fullFrameFrameEndsFromCallback,
                fullFrameCallbackFps,
                sender.fullFrameDirectSubmissions,
                sender.fullFrameCopiedSubmissions,
                sender.fullFrameDirectFallbacks,
                (double)fullFrameProcessP50 / 1000000.0,
                (double)fullFrameProcessP95 / 1000000.0,
                (double)fullFrameSubmitP50 / 1000000.0,
                (double)fullFrameSubmitP95 / 1000000.0,
                (double)fullFrameCopyP50 / 1000000.0,
                (double)fullFrameCopyP95 / 1000000.0,
                sender.encodeTickEnabled ? 1u : 0u,
                sender.encodeTickFires,
                sender.encodeTickIdleSkips,
                sender.phaseLockEnabled ? 1u : 0u,
                sender.phaseLockFeedbackReports,
                sender.phaseLockTimerAdjustments,
                (double)sender.phaseLockTimerAdjustmentAbsNs / 1000000.0,
                (double)sender.phaseLockLeadNs / 1000000.0,
                (double)sender.phaseLockLastPeriodNs / 1000000.0,
                (double)sender.phaseLockLastErrorNs / 1000000.0,
                (double)sender.phaseLockLastAdjustmentNs / 1000000.0,
                (double)h264CallbackP50 / 1000000.0,
                (double)h264CallbackP95 / 1000000.0,
                g2gP50Ms, g2gP95Ms, g2gP99Ms, fresh,
                sender.fullFrameAnalyzerSkippedFrames,
                sender.fullFrameExitRefinementTiles,
                sender.fullFrameMotionCandidateTiles,
                sender.fullFrameMotionCoveredTiles,
                sender.fullFrameSuppressedLosslessTiles,
                sender.h264AdaptiveBitrate,
                sender.h264AdaptiveMinBitrate,
                sender.h264AdaptiveMaxBitrate,
                sender.h264AdaptiveBackoffs,
                sender.h264AdaptiveRamps,
                selectedCoverageRatio,
                sender.txFrames, sender.txTiles, sender.txFailures,
                sender.txFrameEnds,
                sender.txDroppedJobs, sender.txDroppedTiles,
                sender.txDroppedMotionFallbackTiles,
                sender.txDroppedRefineTiles,
                sender.txDroppedStaleFrames, sender.txCoalescedJobs,
                sender.txMaxPendingJobs, sender.txMaxJobAgeMs,
                sender.txEstimatedBytes,
                [sender cleanupPendingTileCount],
                sender.cleanupReplacedTiles, sender.cleanupCoalescedTiles,
                sender.cleanupCancelledTiles, sender.cleanupSentTiles,
                sender.cleanupProtectedTiles, sender.cleanupObsoleteTiles,
                cleanupLatencyP50, cleanupLatencyP95,
                sender.cleanupMaxLatencyMs,
                txLatestLagP50, txLatestLagP95,
                sender.txLatestSourceLagMaxFrames,
                sender.txOldestCleanupAgeMs,
                sender.h264InducedDrops,
                sender.h264ResendTarget, sender.h264ResendMaxActive,
                sender.h264ResendEvictions, sender.h264ResendRepairEvictions,
                sender.h264PostFrameRepairDrains,
                firstFrameMs, firstH264Ms, processedFps, invalidFps,
                totalWirePackets, totalWireBytes, totalWireMbps,
                totalWirePacketsPerSec, h264PacketsPerSec,
                sender.stats.packets, sender.stats.bytes, sec, mbps,
                sender.frameId == 0 ? 0 : sender.frameId - 1u, sender.skippedFrames,
                sender.invalidFrames);
        fprintf(stdout,
                "motion_mask_enabled=%u full_frame_episode_mask_tiles=%" PRIu64
                " full_frame_episode_mask_peak_tiles=%" PRIu64 "\n",
                sender.motionMaskEnabled ? 1u : 0u,
                sender.fullFrameEpisodeMaskTiles,
                sender.fullFrameEpisodeMaskPeakTiles);
        fprintf(stdout,
                "motion_preroll_enabled=%u held_frames=%" PRIu64
                " released_frames=%" PRIu64 " discarded_frames=%" PRIu64 "\n",
                sender.motionPrerollEnabled ? 1u : 0u,
                sender.motionPrerollHeldFrames,
                sender.motionPrerollReleasedFrames,
                sender.motionPrerollDiscardedFrames);
        [sender writeH264RegionSummaryToFile:stdout];

        [sender destroyH264Encoder];
        [sender destroyH264ResendRing];
        [sender destroyM2Classifier];
        [sender destroyDirtyMap];
        [sender destroyFrameScratch];
        [sender destroyCleanupState];
        [sender destroyLatestFrame];
        if (sender.frameLog != NULL) {
            fclose(sender.frameLog);
            sender.frameLog = NULL;
        }
        if (sender.m2Log != NULL) {
            fclose(sender.m2Log);
            sender.m2Log = NULL;
        }
        if (sender.episodeLog != NULL) {
            fclose(sender.episodeLog);
            sender.episodeLog = NULL;
        }
    }

    close(fd);
    return g_sharp_capture_stopped ? SHARP_EXIT_CAPTURE_STOPPED : 0;
}
