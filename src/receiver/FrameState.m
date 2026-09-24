#import "Internal.h"

@implementation SharpDisplayApp (FrameState)
- (void)recordFrameEnd:(uint32_t)frameId
        videoRegionMask:(uint16_t)videoRegionMask
             arrivalSeq:(uint64_t)arrivalSeq
               sendNs:(uint64_t)sendNs {
    uint32_t slot = frameId % SHARP_COMMIT_TRACK_SLOTS;
    BOOL incomingHasVideo = NO;
    BOOL previousHasVideo = _endValid[slot] && _endFrameIds[slot] == frameId &&
                            _endHasVideo[slot];
    _endValid[slot] = 1u;
    _endFrameIds[slot] = frameId;
    memset(&_endVideoRegions[slot], 0, sizeof(_endVideoRegions[slot]));
    if (_observedVideoValid[slot] && _observedVideoFrameIds[slot] == frameId) {
        _endVideoRegions[slot] = _observedVideoRegions[slot];
    }
    if (videoRegionMask != 0) {
        for (uint16_t regionId = 1; regionId < 16u; regionId++) {
            if ((videoRegionMask & (uint16_t)(1u << regionId)) == 0) {
                continue;
            }
            BOOL alreadyPresent = NO;
            for (uint8_t i = 0; i < _endVideoRegions[slot].count; i++) {
                if (_endVideoRegions[slot].ids[i] == regionId) {
                    alreadyPresent = YES;
                    break;
                }
            }
            if (!alreadyPresent &&
                _endVideoRegions[slot].count < SHARP_MAX_VIDEO_REGIONS) {
                _endVideoRegions[slot].ids[_endVideoRegions[slot].count++] =
                    regionId;
            }
        }
    }
    _endHasVideo[slot] = _endVideoRegions[slot].count > 0;
    incomingHasVideo = _endHasVideo[slot];

    BOOL newerFrame = !_frameReady || frameId > _latestFrameEnd;
    BOOL sameFrameAddsVideo = _frameReady && frameId == _latestFrameEnd &&
                              incomingHasVideo && !previousHasVideo;
    if (newerFrame || sameFrameAddsVideo) {
        _latestFrameEnd = frameId;
        _latestFrameEndArrival = arrivalSeq;
        _latestFrameEndSendNs = sendNs;
        _frameReady = YES;
    }
}

- (void)recordMotionMask:(const uint8_t *)mask
                   bytes:(uint32_t)bytes
                 frameId:(uint32_t)frameId {
    if (!self.overlayMaskEnabled || mask == NULL || bytes != _motionMaskBytes ||
        bytes > SHARP_MOTION_MASK_MAX_BYTES) {
        return;
    }
    memcpy(_pendingMotionMask, mask, bytes);
    if (bytes < SHARP_MOTION_MASK_MAX_BYTES) {
        memset(_pendingMotionMask + bytes, 0,
               SHARP_MOTION_MASK_MAX_BYTES - bytes);
    }
    _pendingMotionMaskFrameId = frameId;
    _pendingMotionMaskValid = 1u;
}

- (void)applyMotionMaskAtCommitLocked:(uint32_t)frameId {
    if (!self.overlayMaskEnabled || _motionMaskBytes == 0) {
        return;
    }
    if (_pendingMotionMaskValid && _pendingMotionMaskFrameId == frameId) {
        int32_t generationDelta =
            (int32_t)(_pendingMotionMaskFrameId -
                      _desiredMotionMaskFrameId);
        BOOL closesOnly = YES;
        if (_desiredMotionMaskValid && generationDelta == 0) {
            for (uint32_t i = 0; i < _motionMaskBytes; i++) {
                if ((_pendingMotionMask[i] &
                     (uint8_t)~_desiredMotionMask[i]) != 0) {
                    closesOnly = NO;
                    break;
                }
            }
        }
        BOOL acceptDesired = !_desiredMotionMaskValid || generationDelta > 0 ||
                             (generationDelta == 0 && closesOnly);
        if (acceptDesired) {
            uint32_t tileCount = _receiver.tile_count;
            BOOL anyWanted = NO;
            for (uint32_t tileId = 0; tileId < tileCount; tileId++) {
                uint8_t bit = (uint8_t)(1u << (tileId & 7u));
                uint32_t byteIndex = tileId >> 3;
                BOOL wasWanted = _desiredMotionMaskValid &&
                                 (_desiredMotionMask[byteIndex] & bit) != 0;
                BOOL nowWanted = (_pendingMotionMask[byteIndex] & bit) != 0;
                if (nowWanted) {
                    anyWanted = YES;
                    /* A new motion episode cancels any unfinished release. */
                    _motionMaskReleaseGeneration[tileId] = 0u;
                } else if (wasWanted) {
                    /* Latch the first 1 -> 0 boundary; do not advance it. */
                    _motionMaskReleaseGeneration[tileId] = frameId;
                }
            }
            if (!anyWanted && _activeMotionMaskValid &&
                _motionMaskActiveTiles > 0) {
                /*
                 * Full-frame video ownership must end as one visual event.
                 * Releasing ready tiles individually produces the exact
                 * sharpening checkerboard that the hybrid compositor exists
                 * to avoid.
                 */
                if (!_motionMaskAtomicReleasePending) {
                    _motionMaskAtomicReleaseGeneration = frameId;
                }
                _motionMaskAtomicReleasePending = 1u;
            } else if (anyWanted) {
                _motionMaskAtomicReleasePending = 0u;
                _motionMaskAtomicReleaseGeneration = 0u;
            }
            memcpy(_desiredMotionMask, _pendingMotionMask, _motionMaskBytes);
            _desiredMotionMaskFrameId = frameId;
            _desiredMotionMaskValid = 1u;
        }
        _pendingMotionMaskValid = 0u;
    }
    if (!_desiredMotionMaskValid) {
        return;
    }
    if (_motionMaskAtomicReleasePending) {
        BOOL releaseReady = YES;
        for (uint32_t tileId = 0; tileId < _receiver.tile_count; tileId++) {
            uint8_t bit = (uint8_t)(1u << (tileId & 7u));
            if ((_activeMotionMask[tileId >> 3] & bit) == 0) {
                continue;
            }
            uint32_t generation = sharp_tile_receiver_tile_generation(
                &_receiver, (uint16_t)tileId);
            if ((int32_t)(generation -
                          _motionMaskAtomicReleaseGeneration) < 0) {
                releaseReady = NO;
                break;
            }
        }
        if (!releaseReady) {
            _activeMotionMaskFrameId = _desiredMotionMaskFrameId;
            _motionMaskUpdates++;
            return;
        }
        memset(_activeMotionMask, 0, _motionMaskBytes);
        memset(_motionMaskReleaseGeneration, 0,
               sizeof(_motionMaskReleaseGeneration));
        _motionMaskAtomicReleasePending = 0u;
        _motionMaskAtomicReleaseGeneration = 0u;
        _activeMotionMaskFrameId = _desiredMotionMaskFrameId;
        _motionMaskActiveTiles = 0u;
        _motionMaskUpdates++;
        return;
    }
    uint64_t activeTiles = 0;
    for (uint32_t tileId = 0; tileId < _receiver.tile_count; tileId++) {
        uint8_t bit = (uint8_t)(1u << (tileId & 7u));
        uint32_t byteIndex = tileId >> 3;
        BOOL wanted = (_desiredMotionMask[byteIndex] & bit) != 0;
        BOOL active = (_activeMotionMask[byteIndex] & bit) != 0;
        uint32_t generation =
            sharp_tile_receiver_tile_generation(&_receiver, (uint16_t)tileId);
        if (!wanted && active) {
            uint32_t releaseGeneration =
                _motionMaskReleaseGeneration[tileId];
            if (releaseGeneration == 0u) {
                /* Defensive fallback for streams that begin mid-episode. */
                releaseGeneration = _desiredMotionMaskFrameId;
                _motionMaskReleaseGeneration[tileId] = releaseGeneration;
            }
            if ((int32_t)(generation - releaseGeneration) < 0) {
                wanted = YES;
            } else {
                _motionMaskReleaseGeneration[tileId] = 0u;
            }
        }
        if (wanted) {
            _activeMotionMask[byteIndex] |= bit;
            activeTiles++;
        } else {
            _activeMotionMask[byteIndex] &= (uint8_t)~bit;
        }
    }
    if (_motionMaskBytes < SHARP_MOTION_MASK_MAX_BYTES) {
        memset(_activeMotionMask + _motionMaskBytes, 0,
               SHARP_MOTION_MASK_MAX_BYTES - _motionMaskBytes);
    }
    _activeMotionMaskFrameId = _desiredMotionMaskFrameId;
    _activeMotionMaskValid = 1u;
    _motionMaskActiveTiles = activeTiles;
    _motionMaskUpdates++;
}

- (void)copyActiveMotionMaskLocked:(uint8_t *)out bytes:(uint32_t)bytes {
    if (out == NULL || bytes == 0 || bytes > SHARP_MOTION_MASK_MAX_BYTES ||
        !self.overlayMaskEnabled || !_activeMotionMaskValid ||
        bytes != _motionMaskBytes) {
        return;
    }
    memcpy(out, _activeMotionMask, bytes);
}

- (uint16_t)videoRegionForFrame:(uint32_t)frameId valid:(BOOL *)valid {
    uint32_t slot = frameId % SHARP_COMMIT_TRACK_SLOTS;
    BOOL found = _endValid[slot] && _endFrameIds[slot] == frameId &&
                 _endHasVideo[slot];
    if (valid != NULL) {
        *valid = found;
    }
    return found && _endVideoRegions[slot].count > 0
               ? _endVideoRegions[slot].ids[0]
               : 0;
}

- (sharp_video_frame_regions_t)videoRegionsForFrame:(uint32_t)frameId
                                              valid:(BOOL *)valid {
    uint32_t slot = frameId % SHARP_COMMIT_TRACK_SLOTS;
    BOOL found = _endValid[slot] && _endFrameIds[slot] == frameId &&
                 _endHasVideo[slot];
    if (valid != NULL) {
        *valid = found;
    }
    sharp_video_frame_regions_t regions;
    memset(&regions, 0, sizeof(regions));
    if (found) {
        regions = _endVideoRegions[slot];
    }
    return regions;
}

- (BOOL)motionMaskCoversLayerLocked:(const sharp_video_layer_snapshot_t *)layer {
    if (layer == NULL || !layer->active || !self.overlayMaskEnabled ||
        !_activeMotionMaskValid || _motionMaskActiveTiles == 0 ||
        _receiver.tile_count == 0) {
        return NO;
    }
    uint32_t cols = sharp_tile_cols(_receiver.fb.width);
    uint32_t rows = sharp_tile_rows(_receiver.fb.height);
    uint32_t tx0 = layer->header.x / SHARP_TILE_SIZE;
    uint32_t ty0 = layer->header.y / SHARP_TILE_SIZE;
    uint32_t tx1 = (layer->header.x + layer->header.w - 1u) /
                   SHARP_TILE_SIZE;
    uint32_t ty1 = (layer->header.y + layer->header.h - 1u) /
                   SHARP_TILE_SIZE;
    if (tx0 >= cols || ty0 >= rows) {
        return NO;
    }
    tx1 = MIN(tx1, cols - 1u);
    ty1 = MIN(ty1, rows - 1u);
    for (uint32_t ty = ty0; ty <= ty1; ty++) {
        for (uint32_t tx = tx0; tx <= tx1; tx++) {
            uint32_t tileId = ty * cols + tx;
            if (tileId >= _receiver.tile_count) {
                continue;
            }
            if ((_activeMotionMask[tileId >> 3] &
                 (uint8_t)(1u << (tileId & 7u))) != 0) {
                return YES;
            }
        }
    }
    return NO;
}

- (void)clearPendingPresentationLocked {
    for (size_t i = 0; i < _presentVideoLayerCount; i++) {
        if (_presentVideoLayers[i].pixel_buffer != NULL) {
            CVPixelBufferRelease(_presentVideoLayers[i].pixel_buffer);
        }
    }
    memset(_presentVideoLayers, 0, sizeof(_presentVideoLayers));
    memset(_presentDeactivateRegions, 0, sizeof(_presentDeactivateRegions));
    _presentVideoLayerCount = 0;
    _presentDeactivateRegionCount = 0;
    _presentReady = 0;
    _presentFrame = 0;
    _presentFrameEndSendNs = 0;
    _presentCommittedFrames = 0;
    _presentDroppedFrameEnds = 0;
    dirty_bounds_reset(&_presentDirtyBounds);
}

- (BOOL)commitFrameBoundaryLocked:(uint32_t)frameId
                    frameEndSendNs:(uint64_t)frameEndSendNs {
    if (_verifiedReceiver) return NO;
    BOOL maskBoundary = self.overlayMaskEnabled && _pendingMotionMaskValid &&
                        _pendingMotionMaskFrameId == frameId;
    if (!_frameReady || (!_stagingDirty && !maskBoundary)) {
        return NO;
    }
    if (_latestFrameEndArrival != 0) {
        uint64_t videoWatermark =
            atomic_load_explicit(&_stageVDrainedThrough, memory_order_acquire);
        uint64_t tileWatermark =
            atomic_load_explicit(&_stageTDrainedThrough, memory_order_acquire);
        if (videoWatermark < _latestFrameEndArrival ||
            tileWatermark < _latestFrameEndArrival) {
            return NO;
        }
    }
    if (_committedFrames > 0 && frameId <= _committedFrame) {
        /*
         * Async video frame ends can commit a frame before its lossless TX job
         * reaches this thread. Per-tile generation checks have already made the
         * staged pixels latest-wins safe, so publish them without moving the
         * logical frame frontier backwards. Dropping this dirty state leaves a
         * tile frozen until an unrelated newer frame end happens to arrive.
         */
        /* Late accepted repairs can close desired-mask holes too. */
        [self applyMotionMaskAtCommitLocked:frameId];
        sharp_dirty_bounds_t lateDirty = _stagingDirtyBounds;
        if (lateDirty.valid) {
            if (_presentReady && _presentDirtyBounds.valid) {
                dirty_bounds_add(&_presentDirtyBounds, lateDirty.x, lateDirty.y,
                                 lateDirty.w, lateDirty.h, _receiver.fb.width,
                                 _receiver.fb.height);
            } else {
                _presentDirtyBounds = lateDirty;
                _presentFrame = _committedFrame;
                _presentFrameEndSendNs = 0;
                _presentCommittedFrames = _committedFrames;
                _presentDroppedFrameEnds = _droppedFrameEnds;
                _presentReady = 1u;
            }
            _contentSerial++;
            _contentFrameId = _committedFrame;
            _contentFinalPacketRxNs = 0;
            _contentDecodeCallbackNs = 0;
            _lateLosslessCommits++;
        }
        _frameReady = NO;
        _stagingDirty = NO;
        _lastWaitReason = SHARP_RENDER_WAIT_NONE;
        dirty_bounds_reset(&_stagingDirtyBounds);
        return lateDirty.valid ? YES : NO;
    }

    BOOL videoValid = NO;
    sharp_video_frame_regions_t videoRegions =
        [self videoRegionsForFrame:frameId valid:&videoValid];
    sharp_dirty_bounds_t commitDirty = _stagingDirtyBounds;
    if (!commitDirty.valid && !videoValid) {
        dirty_bounds_add(&commitDirty, 0, 0, _receiver.fb.width,
                         _receiver.fb.height, _receiver.fb.width,
                         _receiver.fb.height);
    }

    // Apply the generation-gated mask before deciding whether an old video
    // layer can retire. The layer must cover every still-masked tile.
    [self applyMotionMaskAtCommitLocked:frameId];

    for (size_t i = 0; i < SHARP_MAX_VIDEO_REGIONS; i++) {
        if (!_videoLayers[i].active) {
            continue;
        }
        BOOL layerInFrame = NO;
        for (uint8_t r = 0; videoValid && r < videoRegions.count; r++) {
            if (videoRegions.ids[r] == _videoLayers[i].region_id) {
                layerInFrame = YES;
                break;
            }
        }
        if (videoValid && layerInFrame) {
            _videoLayers[i].missed_commits = 0u;
            continue;
        }

        if ([self motionMaskCoversLayerLocked:&(_videoLayers[i])]) {
            _videoLayers[i].missed_commits = 0u;
            continue;
        }

        BOOL maskLifecycleComplete =
            self.overlayMaskEnabled &&
            _videoLayers[i].region_id == SHARP_H264_FULLFRAME_ID &&
            _activeMotionMaskValid && _motionMaskActiveTiles == 0;
        if (maskLifecycleComplete) {
            _videoLayers[i].missed_commits = UINT8_MAX;
        } else if (_videoLayers[i].missed_commits < UINT8_MAX) {
            _videoLayers[i].missed_commits++;
        }
        if (_videoLayers[i].pixel_buffer != NULL &&
            _videoLayers[i].missed_commits < SHARP_VIDEO_LAYER_RETIRE_MISSES) {
            continue;
        }

        if (!videoValid) {
            _commitDeactivateNoVideoRegion++;
        }
        [self bakeVideoLayerIntoBase:&_videoLayers[i]
                                   x:_videoLayers[i].header.x
                                   y:_videoLayers[i].header.y
                                   w:_videoLayers[i].header.w
                                   h:_videoLayers[i].header.h];
        dirty_bounds_add(&commitDirty, _videoLayers[i].header.x,
                         _videoLayers[i].header.y, _videoLayers[i].header.w,
                         _videoLayers[i].header.h, _receiver.fb.width,
                         _receiver.fb.height);
        _videoOldFootprintCleanups++;
        _videoOldFootprintLastRedrawFrame = frameId;
        if (_presentDeactivateRegionCount < SHARP_MAX_VIDEO_REGIONS) {
            _presentDeactivateRegions[_presentDeactivateRegionCount++] =
                _videoLayers[i].region_id;
        }
        [self clearVideoLayerAtIndex:i];
        _videoLayerDeactivations++;
    }

    if (_presentReady && _presentDirtyBounds.valid) {
        _presentSupersededCommits++;
        dirty_bounds_add(&commitDirty, _presentDirtyBounds.x,
                         _presentDirtyBounds.y, _presentDirtyBounds.w,
                         _presentDirtyBounds.h, _receiver.fb.width,
                         _receiver.fb.height);
    }

    _committedFrame = frameId;
    _committedFrames++;
    _presentFrame = frameId;
    _presentFrameEndSendNs = frameEndSendNs;
    _presentCommittedFrames = _committedFrames;
    _presentDroppedFrameEnds = _droppedFrameEnds;
    _presentDirtyBounds = commitDirty;
    _presentReady = 1u;
    BOOL preserveVideoTiming = _contentFrameId == frameId &&
                               _contentFinalPacketRxNs != 0 &&
                               _contentDecodeCallbackNs != 0;
    _contentSerial++;
    _contentFrameId = frameId;
    if (!preserveVideoTiming) {
        _contentFinalPacketRxNs = 0;
        _contentDecodeCallbackNs = 0;
    }

    _frameReady = NO;
    _stagingDirty = NO;
    _lastWaitReason = SHARP_RENDER_WAIT_NONE;
    dirty_bounds_reset(&_stagingDirtyBounds);
    return YES;
}

- (void)tryCommitArrivalWatermark {
    pthread_mutex_lock(&_stateLock);
    if (_frameReady) {
        (void)[self commitFrameBoundaryLocked:_latestFrameEnd
                               frameEndSendNs:_latestFrameEndSendNs];
    }
    pthread_mutex_unlock(&_stateLock);
}

- (void)publishVideoArrivalWatermark {
    uint64_t processed =
        atomic_load_explicit(&_videoProcessedThrough, memory_order_acquire);
    if (sharp_net_ring_peek(&_videoRing) == NULL) {
        uint64_t frontier =
            atomic_load_explicit(&_arrivalCounter, memory_order_acquire);
        if (frontier > processed) {
            processed = frontier;
            atomic_store_explicit(&_videoProcessedThrough, processed,
                                  memory_order_release);
        }
    }
    uint64_t oldestPending = UINT64_MAX;
    pthread_mutex_lock(&_stateLock);
    for (size_t i = 0; i < _pendingVideoDecodeCount; i++) {
        if (_pendingVideoDecodeArrivals[i] < oldestPending) {
            oldestPending = _pendingVideoDecodeArrivals[i];
        }
    }
    pthread_mutex_unlock(&_stateLock);
    uint64_t watermark = processed;
    if (oldestPending != UINT64_MAX && watermark >= oldestPending) {
        watermark = oldestPending - 1u;
    }
    atomic_store_explicit(&_stageVDrainedThrough, watermark,
                          memory_order_release);
    [self tryCommitArrivalWatermark];
}

- (void)publishTileArrivalWatermark {
    if (sharp_net_ring_peek(&_tileRing) == NULL) {
        uint64_t frontier =
            atomic_load_explicit(&_arrivalCounter, memory_order_acquire);
        atomic_store_explicit(&_stageTDrainedThrough, frontier,
                              memory_order_release);
    }
    [self tryCommitArrivalWatermark];
}

- (void)markDirtyRectX:(uint32_t)x y:(uint32_t)y w:(uint32_t)w h:(uint32_t)h {
    dirty_bounds_add(&_stagingDirtyBounds, x, y, w, h, _receiver.fb.width,
                     _receiver.fb.height);
    _stagingDirty = YES;
}

- (void)bakeVideoLayerIntoBase:(const sharp_video_layer_snapshot_t *)layer
                              x:(uint32_t)x
                              y:(uint32_t)y
                              w:(uint32_t)w
                              h:(uint32_t)h {
    if (!_config.bake_video_handoff || layer == NULL || layer->pixel_buffer == NULL ||
        _receiver.fb.pixels == NULL || layer->header.w == 0 ||
        layer->header.h == 0 || w == 0 || h == 0) {
        return;
    }
    uint32_t layerX0 = layer->header.x;
    uint32_t layerY0 = layer->header.y;
    uint32_t layerX1 = layer->header.x + layer->header.w;
    uint32_t layerY1 = layer->header.y + layer->header.h;
    uint32_t rectX0 = x;
    uint32_t rectY0 = y;
    uint32_t rectX1 = x + w;
    uint32_t rectY1 = y + h;
    if (rectX1 > _receiver.fb.width) {
        rectX1 = _receiver.fb.width;
    }
    if (rectY1 > _receiver.fb.height) {
        rectY1 = _receiver.fb.height;
    }
    if (rectX0 < layerX0) {
        rectX0 = layerX0;
    }
    if (rectY0 < layerY0) {
        rectY0 = layerY0;
    }
    if (rectX1 > layerX1) {
        rectX1 = layerX1;
    }
    if (rectY1 > layerY1) {
        rectY1 = layerY1;
    }
    if (rectX0 >= rectX1 || rectY0 >= rectY1) {
        return;
    }
    CVPixelBufferRef pixelBuffer = layer->pixel_buffer;
    if (CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) !=
        kCVReturnSuccess) {
        _videoHandoffBakeFailures++;
        return;
    }

    OSType format = CVPixelBufferGetPixelFormatType(pixelBuffer);
    uint64_t changedPixels = 0;
    uint64_t bakedPixels = 0;
    if (format == kCVPixelFormatType_32BGRA) {
        const uint8_t *base = CVPixelBufferGetBaseAddress(pixelBuffer);
        size_t srcStride = CVPixelBufferGetBytesPerRow(pixelBuffer);
        if (base == NULL) {
            _videoHandoffBakeFailures++;
        } else {
            for (uint32_t py = rectY0; py < rectY1; py++) {
                uint32_t sy = py - layerY0;
                uint32_t sx = rectX0 - layerX0;
                const uint8_t *src = base + (size_t)sy * srcStride +
                                     (size_t)sx * 4u;
                uint8_t *dst = _receiver.fb.pixels + (size_t)py * _receiver.fb.stride +
                               (size_t)rectX0 * 4u;
                for (uint32_t px = rectX0; px < rectX1; px++) {
                    if (abs((int)dst[0] - (int)src[0]) > 8 ||
                        abs((int)dst[1] - (int)src[1]) > 8 ||
                        abs((int)dst[2] - (int)src[2]) > 8) {
                        changedPixels++;
                    }
                    dst[0] = src[0];
                    dst[1] = src[1];
                    dst[2] = src[2];
                    dst[3] = 255;
                    src += 4;
                    dst += 4;
                    bakedPixels++;
                }
            }
        }
    } else if (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
               CVPixelBufferGetPlaneCount(pixelBuffer) >= 2) {
        const uint8_t *yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
        const uint8_t *uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
        size_t yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
        size_t uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
        if (yBase == NULL || uvBase == NULL) {
            _videoHandoffBakeFailures++;
        } else {
            for (uint32_t py = rectY0; py < rectY1; py++) {
                uint32_t sy = py - layerY0;
                uint8_t *dst = _receiver.fb.pixels + (size_t)py * _receiver.fb.stride +
                               (size_t)rectX0 * 4u;
                for (uint32_t px = rectX0; px < rectX1; px++) {
                    uint32_t sx = px - layerX0;
                    const uint8_t *uv = uvBase + (size_t)(sy / 2u) * uvStride +
                                        (size_t)(sx / 2u) * 2u;
                    uint8_t bgra[4];
                    nv12_video_range_to_bgra(
                        yBase[(size_t)sy * yStride + sx], uv[0], uv[1],
                        nv12_matrix_for_pixel_buffer(pixelBuffer), bgra);
                    if (abs((int)dst[0] - (int)bgra[0]) > 8 ||
                        abs((int)dst[1] - (int)bgra[1]) > 8 ||
                        abs((int)dst[2] - (int)bgra[2]) > 8) {
                        changedPixels++;
                    }
                    dst[0] = bgra[0];
                    dst[1] = bgra[1];
                    dst[2] = bgra[2];
                    dst[3] = 255;
                    dst += 4;
                    bakedPixels++;
                }
            }
        }
    } else {
        _videoHandoffBakeFailures++;
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    if (bakedPixels > 0) {
        _videoHandoffBakes++;
        _videoHandoffBakePixels += bakedPixels;
        _staleRevealPixels += changedPixels;
        _videoCpuFramebufferPatches++;
    }
}

- (void)clearVideoLayer {
    for (size_t i = 0; i < SHARP_MAX_VIDEO_REGIONS; i++) {
        [self clearVideoLayerAtIndex:i];
    }
}

- (void)clearVideoLayerAtIndex:(size_t)index {
    if (index >= SHARP_MAX_VIDEO_REGIONS) {
        return;
    }
    if (_videoLayers[index].pixel_buffer != NULL) {
        CVPixelBufferRelease(_videoLayers[index].pixel_buffer);
    }
    memset(&_videoLayers[index], 0, sizeof(_videoLayers[index]));
}

- (void)clearH264DecoderAtIndex:(size_t)index {
    if (index >= SHARP_MAX_H264_DECODERS) {
        return;
    }
    if (_h264Decoders[index].session != NULL) {
        VTDecompressionSessionWaitForAsynchronousFrames(_h264Decoders[index].session);
        VTDecompressionSessionInvalidate(_h264Decoders[index].session);
        CFRelease(_h264Decoders[index].session);
    }
    if (_h264Decoders[index].format != NULL) {
        CFRelease(_h264Decoders[index].format);
    }
    memset(&_h264Decoders[index], 0, sizeof(_h264Decoders[index]));
}

- (void)clearH264DecoderForRegion:(uint16_t)regionId {
    for (size_t i = 0; i < SHARP_MAX_H264_DECODERS; i++) {
        if (_h264Decoders[i].active && _h264Decoders[i].region_id == regionId) {
            [self clearH264DecoderAtIndex:i];
            return;
        }
    }
}

- (sharp_h264_region_stats_t *)h264RegionStatsForRegion:(uint16_t)regionId
                                                  create:(BOOL)create {
    sharp_h264_region_stats_t *freeStats = NULL;
    size_t evictIndex = 0;
    uint32_t evictGeneration = UINT32_MAX;
    for (size_t i = 0; i < SHARP_MAX_VIDEO_REGIONS; i++) {
        if (_h264RegionStats[i].active &&
            _h264RegionStats[i].region_id == regionId) {
            return &_h264RegionStats[i];
        }
        if (!_h264RegionStats[i].active && freeStats == NULL) {
            freeStats = &_h264RegionStats[i];
        } else if (_h264RegionStats[i].active) {
            uint32_t generation = 0;
            for (size_t j = 0; j < SHARP_MAX_VIDEO_REGIONS; j++) {
                if (_videoLayers[j].active &&
                    _videoLayers[j].region_id == _h264RegionStats[i].region_id) {
                    generation = _videoLayers[j].header.generation;
                    break;
                }
            }
            if (generation < evictGeneration) {
                evictGeneration = generation;
                evictIndex = i;
            }
        }
    }
    if (!create) {
        return NULL;
    }
    if (freeStats == NULL) {
        freeStats = &_h264RegionStats[evictIndex];
    }
    memset(freeStats, 0, sizeof(*freeStats));
    freeStats->active = 1u;
    freeStats->region_id = regionId;
    return freeStats;
}

- (void)noteH264InvalidForRegion:(uint16_t)regionId {
    sharp_h264_region_stats_t *stats =
        [self h264RegionStatsForRegion:regionId create:YES];
    if (stats != NULL) {
        stats->invalid++;
    }
}

- (sharp_h264_decoder_slot_t *)h264DecoderForRegion:(uint16_t)regionId
                                             create:(BOOL)create {
    sharp_h264_decoder_slot_t *freeDecoder = NULL;
    size_t evictIndex = 0;
    uint32_t evictGeneration = UINT32_MAX;
    for (size_t i = 0; i < SHARP_MAX_H264_DECODERS; i++) {
        if (_h264Decoders[i].active && _h264Decoders[i].region_id == regionId) {
            return &_h264Decoders[i];
        }
        if (!_h264Decoders[i].active && freeDecoder == NULL) {
            freeDecoder = &_h264Decoders[i];
        } else if (_h264Decoders[i].active) {
            uint32_t generation = 0;
            for (size_t j = 0; j < SHARP_MAX_VIDEO_REGIONS; j++) {
                if (_videoLayers[j].active &&
                    _videoLayers[j].region_id == _h264Decoders[i].region_id) {
                    generation = _videoLayers[j].header.generation;
                    break;
                }
            }
            if (generation < evictGeneration) {
                evictGeneration = generation;
                evictIndex = i;
            }
        }
    }
    if (!create) {
        return NULL;
    }
    if (freeDecoder == NULL) {
        [self clearH264DecoderAtIndex:evictIndex];
        freeDecoder = &_h264Decoders[evictIndex];
    }
    memset(freeDecoder, 0, sizeof(*freeDecoder));
    freeDecoder->active = 1u;
    freeDecoder->region_id = regionId;
    return freeDecoder;
}

- (sharp_video_layer_snapshot_t *)videoLayerForRegion:(uint16_t)regionId
                                               create:(BOOL)create {
    sharp_video_layer_snapshot_t *freeLayer = NULL;
    size_t evictIndex = 0;
    uint32_t evictGeneration = UINT32_MAX;
    for (size_t i = 0; i < SHARP_MAX_VIDEO_REGIONS; i++) {
        if (_videoLayers[i].active && _videoLayers[i].region_id == regionId) {
            return &_videoLayers[i];
        }
        if (!_videoLayers[i].active && freeLayer == NULL) {
            freeLayer = &_videoLayers[i];
        } else if (_videoLayers[i].active &&
                   _videoLayers[i].header.generation < evictGeneration) {
            evictGeneration = _videoLayers[i].header.generation;
            evictIndex = i;
        }
    }
    if (!create) {
        return NULL;
    }
    if (freeLayer == NULL) {
        [self clearVideoLayerAtIndex:evictIndex];
        _videoLayerDeactivations++;
        freeLayer = &_videoLayers[evictIndex];
    }
    memset(freeLayer, 0, sizeof(*freeLayer));
    freeLayer->active = 1u;
    freeLayer->region_id = regionId;
    return freeLayer;
}

- (void)recordObservedVideoRegion:(uint16_t)regionId frameId:(uint32_t)frameId {
    if (regionId == 0) {
        return;
    }
    uint32_t slot = frameId % SHARP_COMMIT_TRACK_SLOTS;
    if (!_observedVideoValid[slot] || _observedVideoFrameIds[slot] != frameId) {
        _observedVideoValid[slot] = 1u;
        _observedVideoFrameIds[slot] = frameId;
        memset(&_observedVideoRegions[slot], 0, sizeof(_observedVideoRegions[slot]));
    }
    sharp_video_frame_regions_t *regions = &_observedVideoRegions[slot];
    for (uint8_t i = 0; i < regions->count; i++) {
        if (regions->ids[i] == regionId) {
            return;
        }
    }
    if (regions->count < SHARP_MAX_VIDEO_REGIONS) {
        regions->ids[regions->count++] = regionId;
    }
}
@end
