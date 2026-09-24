#import "Internal.h"

@implementation SharpDisplayApp (Presentation)
- (void)scheduleRenderTick {
    if (_renderQueue == nil) {
        return;
    }

    BOOL shouldSchedule = NO;
    pthread_mutex_lock(&_stateLock);
    if (!_renderScheduled) {
        _renderScheduled = YES;
        shouldSchedule = YES;
    }
    pthread_mutex_unlock(&_stateLock);

    if (shouldSchedule) {
        dispatch_async(_renderQueue, ^{
          [self renderTick];
        });
    }
}

- (void)renderTick {
    BOOL shouldPresent = NO;
    BOOL shouldTerminate = NO;
    uint32_t drawableWidth = 1;
    uint32_t drawableHeight = 1;
    uint32_t committedFrame = 0;
    uint64_t frameEndSendNs = 0;
    uint64_t committedFrames = 0;
    uint64_t presentedFrames = 0;
    uint64_t droppedFrameEnds = 0;
    uint64_t contentSerial = 0;
    uint32_t contentFrameId = 0;
    uint64_t contentFinalPacketRxNs = 0;
    uint64_t contentDecodeCallbackNs = 0;
    sharp_dirty_bounds_t commitDirty;
    dirty_bounds_reset(&commitDirty);
    sharp_video_layer_snapshot_t videoSnapshots[SHARP_MAX_VIDEO_REGIONS];
    memset(videoSnapshots, 0, sizeof(videoSnapshots));
    size_t videoSnapshotCount = 0;
    sharp_cursor_snapshot_t cursorSnapshot;
    memset(&cursorSnapshot, 0, sizeof(cursorSnapshot));
    uint16_t deactivateRegions[SHARP_MAX_VIDEO_REGIONS];
    memset(deactivateRegions, 0, sizeof(deactivateRegions));
    size_t deactivateRegionCount = 0;
    uint8_t motionMask[SHARP_MOTION_MASK_MAX_BYTES];
    memset(motionMask, 0, sizeof(motionMask));
    uint32_t motionMaskBytes = 0;
    uint64_t motionMaskActiveTiles = 0;
    uint32_t verifiedStaticFrame = 0;
    uint64_t verifiedRenderSession = 0;

    pthread_mutex_lock(&_stateLock);
    if (_frameReady) {
        (void)[self commitFrameBoundaryLocked:_latestFrameEnd
                               frameEndSendNs:_latestFrameEndSendNs];
    }

    if (_presentReady) {
        commitDirty = _presentDirtyBounds;
        deactivateRegionCount = _presentDeactivateRegionCount;
        for (size_t i = 0; i < deactivateRegionCount; i++) {
            deactivateRegions[i] = _presentDeactivateRegions[i];
        }
        committedFrame = _presentFrame;
        frameEndSendNs = _presentFrameEndSendNs;
        committedFrames = _presentCommittedFrames;
        droppedFrameEnds = _presentDroppedFrameEnds;
        _presentDeactivateRegionCount = 0;
        _presentReady = 0;
        _presentFrame = 0;
        _presentFrameEndSendNs = 0;
        _presentCommittedFrames = 0;
        _presentDroppedFrameEnds = 0;
        dirty_bounds_reset(&_presentDirtyBounds);
    }

    if (_verifiedReceiver) {
        verifiedRenderSession=_verifiedReceiver->session;
        const sharp_hybrid_map_t *latest=sharp_hybrid_find_map(_verifiedReceiver,_verifiedReceiver->latest_frame);
        BOOL complete=sharp_hybrid_static_ready(_verifiedReceiver,latest,_receiver.tile_generations);
        BOOL haveVideo=NO;
        for(size_t i=0;i<SHARP_MAX_VIDEO_REGIONS;i++) if(_videoLayers[i].active) haveVideo=YES;
        if (complete) {
            verifiedStaticFrame=latest->frame;
            if (_verifiedReceiver->committed_frame!=latest->frame || haveVideo) {
                dirty_bounds_add(&commitDirty,0,0,_config.width,_config.height,_config.width,_config.height);
                _contentSerial++;_contentFrameId=latest->frame;
                _contentFinalPacketRxNs=0;_contentDecodeCallbackNs=0;
                _committedFrame=latest->frame;_committedFrames++;
            }
            for(size_t i=0;i<SHARP_MAX_VIDEO_REGIONS;i++) if(_videoLayers[i].active) {
                deactivateRegions[deactivateRegionCount++]=_videoLayers[i].region_id;
                [self clearVideoLayerAtIndex:i];_videoLayerDeactivations++;
            }
            dirty_bounds_reset(&_stagingDirtyBounds);
            _motionMaskActiveTiles=0;_verifiedSharpTiles=_receiver.tile_count;
        } else if (haveVideo) {
            commitDirty=_stagingDirtyBounds;
            dirty_bounds_reset(&_stagingDirtyBounds);
        } else {
            /* Keep the last published desktop until the next snapshot is
             * complete. A cache update alone cannot alter visible pixels. */
            dirty_bounds_reset(&commitDirty);
        }
    }

    for (size_t i = 0; i < SHARP_MAX_VIDEO_REGIONS; i++) {
        if (!_videoLayers[i].active || _videoLayers[i].pixel_buffer == NULL ||
            videoSnapshotCount >= SHARP_MAX_VIDEO_REGIONS) {
            continue;
        }
        videoSnapshots[videoSnapshotCount] = _videoLayers[i];
        CVPixelBufferRetain(videoSnapshots[videoSnapshotCount].pixel_buffer);
        _videoLayers[i].updated = 0u;
        videoSnapshotCount++;
    }
    for (size_t i = 0; i < videoSnapshotCount; i++) {
        for (size_t j = i + 1; j < videoSnapshotCount; j++) {
            if (videoSnapshots[j].region_id < videoSnapshots[i].region_id) {
                sharp_video_layer_snapshot_t tmp = videoSnapshots[i];
                videoSnapshots[i] = videoSnapshots[j];
                videoSnapshots[j] = tmp;
            }
        }
    }
    if (videoSnapshotCount > _videoMaxActiveRegions) {
        _videoMaxActiveRegions = videoSnapshotCount;
    }
    cursorSnapshot.visible = _cursorVisible ? 1u : 0u;
    cursorSnapshot.x = _cursorX;
    cursorSnapshot.y = _cursorY;
    cursorSnapshot.seq = _cursorSeq;
    cursorSnapshot.hotspot_x = _cursorHotspotX;
    cursorSnapshot.hotspot_y = _cursorHotspotY;
    cursorSnapshot.image_id = _cursorImageId;
    uint64_t cursorNowNs = shtp_now_ns();
    if (_cursorVisible && _cursorPrevSampleNs != 0u &&
        _cursorSampleNs > _cursorPrevSampleNs && _cursorLastRxNs != 0u &&
        cursorNowNs >= _cursorLastRxNs &&
        cursorNowNs - _cursorLastRxNs <= 20000000ULL) {
        uint64_t sampleDeltaNs = _cursorSampleNs - _cursorPrevSampleNs;
        if (sampleDeltaNs >= 1000000ULL && sampleDeltaNs <= 100000000ULL) {
            uint64_t predictNs = MIN(cursorNowNs - _cursorLastRxNs, 8000000ULL);
            double fraction = (double)predictNs / (double)sampleDeltaNs;
            double predictedX = (double)_cursorX +
                                (double)(_cursorX - _cursorPrevX) * fraction;
            double predictedY = (double)_cursorY +
                                (double)(_cursorY - _cursorPrevY) * fraction;
            cursorSnapshot.x = (int32_t)llround(
                MAX(0.0, MIN((double)_config.width - 1.0, predictedX)));
            cursorSnapshot.y = (int32_t)llround(
                MAX(0.0, MIN((double)_config.height - 1.0, predictedY)));
        }
    }
    if (_verifiedReceiver && videoSnapshotCount) {
        const sharp_video_layer_snapshot_t *video=&videoSnapshots[0];
        const sharp_hybrid_map_t *map=sharp_hybrid_find_map(_verifiedReceiver,video->header.generation);
        motionMaskBytes=_motionMaskBytes;
        _verifiedSharpTiles=sharp_hybrid_video_mask(_verifiedReceiver,map,_receiver.tile_generations,motionMask);
        if (!map) _verifiedMissingMaps++;
        motionMaskActiveTiles=_receiver.tile_count-_verifiedSharpTiles;
        if (!_activeMotionMaskValid || memcmp(_activeMotionMask,motionMask,motionMaskBytes)!=0) _contentSerial++;
        memcpy(_activeMotionMask,motionMask,motionMaskBytes);
        _activeMotionMaskValid=YES;_motionMaskActiveTiles=motionMaskActiveTiles;
        _activeMotionMaskFrameId=video->header.generation;
        if (_committedFrame!=video->header.generation) {
            _committedFrame=video->header.generation;_committedFrames++;
        }
    } else if (!_verifiedReceiver && self.overlayMaskEnabled && _activeMotionMaskValid) {
        motionMaskBytes = _motionMaskBytes;
        motionMaskActiveTiles = _motionMaskActiveTiles;
        [self copyActiveMotionMaskLocked:motionMask bytes:motionMaskBytes];
    }

    drawableWidth = _drawableWidth;
    drawableHeight = _drawableHeight;
    if (committedFrame == 0) {
        committedFrame = _committedFrame;
        committedFrames = _committedFrames;
        droppedFrameEnds = _droppedFrameEnds;
    }
    presentedFrames = _presentedFrames + 1u;
    contentSerial = _contentSerial;
    contentFrameId = _contentFrameId;
    contentFinalPacketRxNs = _contentFinalPacketRxNs;
    contentDecodeCallbackNs = _contentDecodeCallbackNs;
    uint64_t renderNowNs = shtp_now_ns();
    if (_testCorruptTileId >= 0 && _testCorruptNs == 0 && _startNs != 0 &&
        renderNowNs - _startNs >= 3000000000ULL && _committedFrames >= 2) {
        sharp_tile_rect_t testRect;
        if (sharp_tile_rect_for_id(_receiver.fb.width, _receiver.fb.height,
                                   (uint16_t)_testCorruptTileId,
                                   &testRect) == 0) {
            uint8_t *pixel = _receiver.fb.pixels +
                (size_t)testRect.y * _receiver.fb.stride +
                (size_t)testRect.x * 4u;
            pixel[0] ^= 0xffu;
            _receiver.tile_hashes[_testCorruptTileId] = 0;
            dirty_bounds_add(&commitDirty, testRect.x, testRect.y,
                             testRect.w, testRect.h, _receiver.fb.width,
                             _receiver.fb.height);
            _contentSerial++;
            _testCorruptNs = renderNowNs;
            fprintf(stdout,
                    "m1-display-test-corrupt tile=%d at_ns=%" PRIu64 "\n",
                    _testCorruptTileId, _testCorruptNs);
            fflush(stdout);
        }
    }
    /*
     * Publish staged pixels into the GL-owned buffer while commits are
     * excluded. Network threads never write _frontFb, and the serial render
     * queue does not touch it again until the synchronous client upload has
     * returned. This makes the upload snapshot immutable without holding the
     * state lock across OpenGL.
     */
    if (commitDirty.valid) {
        framebuf_copy_rect(&_frontFb, &_receiver.fb, &commitDirty);
    }
    shouldPresent = _frameView != nil && _frontFb.pixels != NULL;
    if (_receiver.stats.have_bye && !_config.keep_open && !_terminateScheduled) {
        _terminateScheduled = YES;
        shouldTerminate = YES;
    }
    _renderScheduled = NO;
    pthread_mutex_unlock(&_stateLock);

    if (shouldPresent) {
        int uploadKind = [_frameView renderFramebuf:&_frontFb
                                      viewportWidth:drawableWidth
                                     viewportHeight:drawableHeight
                                         dirtyBounds:&commitDirty
                                  videoLayers:videoSnapshots
                              videoLayerCount:videoSnapshotCount
                            deactivateRegions:deactivateRegions
                        deactivateRegionCount:deactivateRegionCount
                                  motionMask:motionMaskBytes > 0 ? motionMask : NULL
                             motionMaskBytes:motionMaskBytes
                                      cursor:&cursorSnapshot];
        if (uploadKind == 1) {
            _textureRegionUploads++;
            _textureRegionPixels += (uint64_t)commitDirty.w * commitDirty.h;
        } else if (uploadKind == 2) {
            _textureFullUploads++;
        }
        for (size_t i = 0; i < videoSnapshotCount; i++) {
            _videoTextureFrames++;
            if (videoSnapshots[i].updated) {
                int videoUpdateKind = _frameView.lastVideoUpdateKind;
                if (videoUpdateKind == 2) {
                    _videoDecoderTextureBinds++;
                } else if (videoUpdateKind == 3) {
                    _videoNv12TextureBinds++;
                } else if (videoUpdateKind == 1) {
                    _videoBgraTextureUploads++;
                    _videoDecoderTextureFallbacks++;
                } else {
                    _videoDecoderTextureFallbacks++;
                }
                _videoTextureUploads++;
            }
        }
        for (size_t i = 0; i < videoSnapshotCount; i++) {
            if (videoSnapshots[i].pixel_buffer != NULL) {
                CVPixelBufferRelease(videoSnapshots[i].pixel_buffer);
            }
        }
        _presentedFrames++;
        uint64_t presentNs = shtp_now_ns();
        BOOL contentChanged =
            [self recordPresentNowNs:presentNs contentSerial:contentSerial];
        if (contentChanged) {
            _freshContentPresents++;
            [self sendPresentReportFrameId:contentFrameId
                             contentSerial:contentSerial
                             frameEndSendNs:frameEndSendNs
                          finalPacketRxNs:contentFinalPacketRxNs
                         decodeCallbackNs:contentDecodeCallbackNs
                                  presentNs:presentNs];
        }
        pthread_mutex_lock(&_stateLock);
        if (_verifiedReceiver && _verifiedReceiver->session==verifiedRenderSession) {
            if (verifiedStaticFrame) _verifiedReceiver->committed_frame=verifiedStaticFrame;
            [self sendVerifiedAckLocked];
        }
        pthread_mutex_unlock(&_stateLock);
        [self sendNextTileDigest];
        uint64_t cursorPackets = 0;
        pthread_mutex_lock(&_stateLock);
        if (cursorSnapshot.visible && cursorSnapshot.seq != 0 &&
            cursorSnapshot.seq != _cursorLastPresentedSeq) {
            _cursorLastPresentedSeq = cursorSnapshot.seq;
            _cursorPresents++;
        }
        cursorPackets = _cursorPackets;
        uint64_t cursorPresents = _cursorPresents;
        pthread_mutex_unlock(&_stateLock);
        if (_liveStatsLastNs == 0) {
            _liveStatsLastNs = presentNs;
            _liveStatsLastFreshPresents = _freshContentPresents;
            _liveStatsLastCursorPackets = cursorPackets;
            _liveStatsLastCursorPresents = cursorPresents;
        } else if (presentNs > _liveStatsLastNs + 1000000000ULL) {
            double liveSeconds =
                (double)(presentNs - _liveStatsLastNs) / 1000000000.0;
            double freshFps =
                (double)(_freshContentPresents - _liveStatsLastFreshPresents) /
                liveSeconds;
            double cursorRxFps =
                (double)(cursorPackets - _liveStatsLastCursorPackets) /
                liveSeconds;
            double cursorPresentFps =
                (double)(cursorPresents - _liveStatsLastCursorPresents) /
                liveSeconds;
            fprintf(stdout,
                    "m1-display-live receiver_fresh_fps=%.2f "
                    "cursor_rx_fps=%.2f cursor_present_fps=%.2f "
                    "cursor_seq=%u motion_mask_active_tiles=%" PRIu64 " verified_sharp_tiles=%" PRIu64
                    " verified_missing_maps=%" PRIu64 "\n",
                    freshFps, cursorRxFps, cursorPresentFps,
                    cursorSnapshot.seq, motionMaskActiveTiles, _verifiedSharpTiles, _verifiedMissingMaps);
            fflush(stdout);
            _liveStatsLastNs = presentNs;
            _liveStatsLastFreshPresents = _freshContentPresents;
            _liveStatsLastCursorPackets = cursorPackets;
            _liveStatsLastCursorPresents = cursorPresents;
        }
        if (_frameLog != NULL) {
            fprintf(_frameLog, "%u\t%" PRIu64 "\t%" PRIu64 "\t%" PRIu64
                               "\t%" PRIu64 "\t%" PRIu64 "\t%" PRIu64 "\n",
                    committedFrame, frameEndSendNs, presentNs, committedFrames,
                    presentedFrames, droppedFrameEnds, contentSerial);
            fflush(_frameLog);
        }
        if (_config.presenter_snapshot_dir != NULL &&
            (!getenv("SHARP_TEST_HYBRID_SNAPSHOTS") ||
             strcmp(getenv("SHARP_TEST_HYBRID_SNAPSHOTS"),"0")==0 ||
             (verifiedRenderSession && committedFrame && committedFrame!=_verifiedLastSnapshotFrame &&
              (committedFrame%30==0 || verifiedStaticFrame) &&
              (!videoSnapshotCount || _verifiedSharpTiles>0))) &&
            _config.presenter_snapshot_every > 0 &&
            (_config.presenter_snapshot_max == 0 ||
             _presenterSnapshotCount < _config.presenter_snapshot_max) &&
            (_presentedFrames % _config.presenter_snapshot_every) == 0) {
            char path[4096];
            uint64_t wallNs =
                (uint64_t)([NSDate timeIntervalSinceReferenceDate] *
                           1000000000.0);
            snprintf(path, sizeof(path), "%s/presenter-%06u-%llu.ppm",
                     _config.presenter_snapshot_dir, committedFrame,
                     (unsigned long long)wallNs);
            if ([_frameView writePresenterSnapshotPath:path] == 0) {
                if (verifiedRenderSession) {
                    char maskPath[4102];snprintf(maskPath,sizeof(maskPath),"%s.mask",path);
                    FILE *maskFile=fopen(maskPath,"wb");
                    if(maskFile) {
                        uint8_t zero[SHARP_MOTION_MASK_MAX_BYTES]={0};
                        fwrite(motionMaskBytes?motionMask:zero,1,(_receiver.tile_count+7u)/8u,maskFile);fclose(maskFile);
                    }
                    _verifiedLastSnapshotFrame=committedFrame;
                }
                _presenterSnapshotCount++;
            }
        }
    } else {
        for (size_t i = 0; i < videoSnapshotCount; i++) {
            if (videoSnapshots[i].pixel_buffer != NULL) {
                CVPixelBufferRelease(videoSnapshots[i].pixel_buffer);
            }
        }
    }

    if (shouldTerminate) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [NSApp terminate:self];
        });
    }
}
@end
