#import "Internal.h"

@implementation SharpScreenSender (Motion)
- (h264_region_stream_t *)h264StreamForRegion:(uint16_t)regionId
                                        create:(BOOL)create
                                       frameId:(uint32_t)frameId {
    h264_region_stream_t *freeSlot = NULL;
    size_t evictIndex = 0;
    uint32_t oldestFrame = UINT32_MAX;
    for (size_t i = 0; i < SHARP_H264_STREAM_TRACK_SLOTS; i++) {
        if (_h264Streams[i].active && _h264Streams[i].region_id == regionId) {
            return &_h264Streams[i];
        }
        if (!_h264Streams[i].active && freeSlot == NULL) {
            freeSlot = &_h264Streams[i];
        } else if (_h264Streams[i].active &&
                   _h264Streams[i].last_seen_frame < oldestFrame) {
            oldestFrame = _h264Streams[i].last_seen_frame;
            evictIndex = i;
        }
    }
    if (!create) {
        return NULL;
    }
    h264_region_stream_t *slot = freeSlot;
    if (slot == NULL) {
        [self retireH264StreamForRegion:_h264Streams[evictIndex].region_id];
        slot = &_h264Streams[evictIndex];
    }
    memset(slot, 0, sizeof(*slot));
    slot->active = 1u;
    slot->region_id = regionId;
    slot->first_seen_frame = frameId;
    slot->last_seen_frame = frameId;
    return slot;
}

- (void)retireH264StreamForRegion:(uint16_t)regionId {
    if (regionId >= SHARP_H264_FIRST_LANE_ID &&
        regionId < SHARP_H264_FIRST_LANE_ID + SHARP_H264_MAX_ACTIVE_REGIONS) {
        _h264LaneRetires++;
    }
    for (size_t i = 0; i < SHARP_H264_ENCODER_SLOTS; i++) {
        if (_h264Encoders[i].active && _h264Encoders[i].region_id == regionId) {
            [self destroyH264EncoderAtIndex:i];
        }
    }
    for (size_t i = 0; i < SHARP_H264_STREAM_TRACK_SLOTS; i++) {
        if (_h264Streams[i].active && _h264Streams[i].region_id == regionId) {
            memset(&_h264Streams[i], 0, sizeof(_h264Streams[i]));
        }
    }
}

- (void)observeH264Region:(const sharp_m2_region_t *)region
                  frameId:(uint32_t)frameId {
    if (region == NULL || region->id == 0) {
        return;
    }
    uint16_t regionId = (uint16_t)region->id;
    if (region->event == SHARP_M2_REGION_DIED) {
        h264_region_stream_t *stream =
            [self h264StreamForRegion:regionId create:NO frameId:frameId];
        if (stream != NULL) {
            stream->last_seen_frame = frameId;
        }
        return;
    }
    if (region->w < 96 || region->h < 96) {
        return;
    }
    h264_region_stream_t *stream =
        [self h264StreamForRegion:regionId create:YES frameId:frameId];
    if (stream == NULL) {
        return;
    }
    sharp_m2_region_t envelope;
    h264_region_envelope(region, _width, _height, &envelope);
    h264_snap_large_envelope(&envelope, _width, _height);
    if (stream->width == 0 ||
        !stream->has_keyframe ||
        stream->need_keyframe ||
        stream->consecutive_frames < SHARP_H264_REGION_WARMUP_FRAMES) {
        uint32_t x0 = stream->width == 0 ? envelope.x : MIN((uint32_t)stream->x, envelope.x);
        uint32_t y0 = stream->height == 0 ? envelope.y : MIN((uint32_t)stream->y, envelope.y);
        uint32_t x1 = stream->width == 0 ? envelope.x + envelope.w
                                         : MAX((uint32_t)stream->x + stream->width,
                                               envelope.x + envelope.w);
        uint32_t y1 = stream->height == 0 ? envelope.y + envelope.h
                                         : MAX((uint32_t)stream->y + stream->height,
                                               envelope.y + envelope.h);
        stream->x = (uint16_t)x0;
        stream->y = (uint16_t)y0;
        stream->width = x1 - x0;
        stream->height = y1 - y0;
    } else if (region->x < stream->x || region->y < stream->y ||
               region->x + region->w > (uint32_t)stream->x + stream->width ||
               region->y + region->h > (uint32_t)stream->y + stream->height) {
        uint32_t oldArea = stream->width * stream->height;
        uint32_t x0 = MIN((uint32_t)stream->x, envelope.x);
        uint32_t y0 = MIN((uint32_t)stream->y, envelope.y);
        uint32_t x1 = MAX((uint32_t)stream->x + stream->width,
                          envelope.x + envelope.w);
        uint32_t y1 = MAX((uint32_t)stream->y + stream->height,
                          envelope.y + envelope.h);
        uint32_t newArea = (x1 - x0) * (y1 - y0);
        sharp_m2_region_t grownEnvelope = *region;
        grownEnvelope.x = x0;
        grownEnvelope.y = y0;
        grownEnvelope.w = x1 - x0;
        grownEnvelope.h = y1 - y0;
        h264_snap_large_envelope(&grownEnvelope, _width, _height);
        x0 = grownEnvelope.x;
        y0 = grownEnvelope.y;
        x1 = grownEnvelope.x + grownEnvelope.w;
        y1 = grownEnvelope.y + grownEnvelope.h;
        newArea = (x1 - x0) * (y1 - y0);
        int largeEscape = oldArea == 0 || newArea > oldArea + oldArea / 2u;
        if (largeEscape) {
            stream->need_keyframe = 1u;
            stream->x = (uint16_t)x0;
            stream->y = (uint16_t)y0;
            stream->width = x1 - x0;
            stream->height = y1 - y0;
            stream->envelope_expands++;
        }
    }
    if (stream->last_seen_frame + 1u == frameId ||
        stream->last_seen_frame == frameId) {
        if (stream->consecutive_frames < UINT32_MAX) {
            stream->consecutive_frames++;
        }
    } else {
        stream->consecutive_frames = 1u;
    }
    stream->last_seen_frame = frameId;
}

- (uint16_t)laneIdForRegion:(const sharp_m2_region_t *)region
                    frameId:(uint32_t)frameId
                     create:(BOOL)create {
    if (region == NULL || region->w == 0 || region->h == 0 ||
        region->event == SHARP_M2_REGION_DIED) {
        return 0;
    }
    sharp_m2_region_t envelope;
    h264_region_envelope(region, _width, _height, &envelope);
    uint16_t freeLane = 0;
    uint16_t bestLane = 0;
    uint64_t bestOverlap = 0;
    uint64_t bestDistance = UINT64_MAX;
    for (uint16_t lane = 0; lane < SHARP_H264_MAX_ACTIVE_REGIONS; lane++) {
        uint16_t laneId = (uint16_t)(SHARP_H264_FIRST_LANE_ID + lane);
        h264_region_stream_t *stream =
            [self h264StreamForRegion:laneId create:NO frameId:frameId];
        if (stream == NULL || !stream->active || stream->width == 0 ||
            stream->height == 0 ||
            frameId > stream->last_seen_frame + SHARP_H264_REGION_IDLE_GRACE_FRAMES) {
            if (freeLane == 0) {
                freeLane = laneId;
            }
            continue;
        }
        uint64_t overlap = rect_intersection_area_u64(
            stream->x, stream->y, stream->width, stream->height,
            envelope.x, envelope.y, envelope.w, envelope.h);
        uint64_t distance = rect_center_distance2_u64(
            stream->x, stream->y, stream->width, stream->height,
            envelope.x, envelope.y, envelope.w, envelope.h);
        if (overlap > bestOverlap ||
            (overlap == bestOverlap && distance < bestDistance)) {
            bestOverlap = overlap;
            bestDistance = distance;
            bestLane = laneId;
        }
    }
    uint64_t regionArea = (uint64_t)region->w * (uint64_t)region->h;
    if (bestLane != 0 &&
        (bestOverlap > 0 || bestDistance <= regionArea * 64ULL)) {
        _h264LaneAdoptions++;
        return bestLane;
    }
    if (!create) {
        return 0;
    }
    if (freeLane != 0) {
        h264_region_stream_t *staleStream =
            [self h264StreamForRegion:freeLane create:NO frameId:frameId];
        if (staleStream != NULL && staleStream->active) {
            [self retireH264StreamForRegion:freeLane];
        }
        _h264LaneBirths++;
        return freeLane;
    }
    uint16_t nearestLane = 0;
    bestDistance = UINT64_MAX;
    for (uint16_t lane = 0; lane < SHARP_H264_MAX_ACTIVE_REGIONS; lane++) {
        uint16_t laneId = (uint16_t)(SHARP_H264_FIRST_LANE_ID + lane);
        h264_region_stream_t *stream =
            [self h264StreamForRegion:laneId create:NO frameId:frameId];
        if (stream == NULL || stream->width == 0 || stream->height == 0) {
            continue;
        }
        uint64_t distance = rect_center_distance2_u64(
            stream->x, stream->y, stream->width, stream->height,
            envelope.x, envelope.y, envelope.w, envelope.h);
        if (distance < bestDistance) {
            bestDistance = distance;
            nearestLane = laneId;
        }
    }
    if (nearestLane != 0) {
        _h264LaneAdoptions++;
        return nearestLane;
    }
    return 0;
}

- (void)observeH264LaneRegion:(const sharp_m2_region_t *)region
                        laneId:(uint16_t)laneId
                       frameId:(uint32_t)frameId {
    if (region == NULL || laneId == 0 || region->w < 96 || region->h < 96) {
        return;
    }
    sharp_m2_region_t laneRegion = *region;
    laneRegion.id = laneId;
    [self observeH264Region:&laneRegion frameId:frameId];
}

- (void)updateFullFrameModeWithMotionTiles:(uint32_t)motionTiles
                            activityTiles:(uint32_t)activityTiles
                     sustainedMotionTiles:(uint32_t)sustainedMotionTiles
                            uncoveredTiles:(uint32_t)uncoveredTiles
                             motionRegions:(uint32_t)motionRegions
                                  tileCount:(uint32_t)tileCount
                                  forceFull:(BOOL)forceFull {
    if (!_fullFrameEnabled || tileCount == 0 || forceFull) {
        return;
    }
    (void)uncoveredTiles;
    uint64_t nowNs = shtp_now_ns();
    BOOL meaningfulMotion = sustainedMotionTiles >=
                            SHARP_H264_FULLFRAME_MIN_MOTION_TILES;
    uint32_t burstMotionTiles =
        (uint32_t)MAX(1.0, ceil((double)tileCount *
                                SHARP_H264_FULLFRAME_BURST_RATIO));
    BOOL burstMotion = activityTiles >= burstMotionTiles;
    uint32_t hardBurstMotionTiles =
        (uint32_t)MAX(1.0, ceil((double)tileCount *
                                SHARP_H264_FULLFRAME_HARD_BURST_RATIO));
    /*
     * A large one-frame compositor invalidation is not proof of motion. Text
     * fields commonly invalidate their whole layout when a new line changes
     * height. Only classifier-confirmed motion may bypass the short burst hold;
     * raw activity still enters video when it persists (window drag/scroll).
     */
    BOOL hardBurstMotion = motionTiles >= hardBurstMotionTiles;
    uint32_t sceneMotionTiles =
        (uint32_t)MAX(1.0, ceil((double)tileCount * 0.25));
    BOOL sceneChange = sustainedMotionTiles >= sceneMotionTiles;
    // The episode policy is independent of compositor mode. Small sustained
    // clusters never enter; only a 24-tile cluster can start the wall clock.
    BOOL enterCondition = meaningfulMotion || burstMotion;

    if (_fullFrameActive) {
        _fullFrameModeFrames++;
        BOOL quietCondition =
            sustainedMotionTiles < SHARP_H264_FULLFRAME_MIN_QUIET_TILES &&
            activityTiles < burstMotionTiles;
        if (quietCondition) {
            if (_fullFrameQuietStartNs == 0) {
                _fullFrameQuietStartNs = nowNs;
            }
        } else {
            _fullFrameQuietStartNs = 0;
        }

        uint64_t quietNs = _fullFrameQuietStartNs != 0 &&
                                   nowNs >= _fullFrameQuietStartNs
                               ? nowNs - _fullFrameQuietStartNs
                               : 0;
        uint64_t activeNs = _fullFrameEnteredNs != 0 &&
                                    nowNs >= _fullFrameEnteredNs
                                ? nowNs - _fullFrameEnteredNs
                                : 0;
        if (quietNs >= SHARP_H264_FULLFRAME_EXIT_QUIET_NS &&
            activeNs >= SHARP_H264_FULLFRAME_MIN_DURATION_NS) {
            _fullFrameActive = NO;
            _fullFrameExitRefinePending = YES;
            _fullFrameQuietStartNs = 0;
            _fullFrameMotionStartNs = 0;
            _fullFrameEnteredNs = 0;
            _fullFrameLastExitNs = nowNs;
            _fullFrameExits++;
            [self logFullFrameEvent:"exit"
                              reason:"quiet"
                        motionTiles:motionTiles
                sustainedMotionTiles:sustainedMotionTiles
                        motionRegions:motionRegions
                           tileCount:tileCount
                              heldNs:activeNs
                             quietNs:quietNs];
        }
        return;
    }

    if (enterCondition) {
        if (_fullFrameMotionStartNs == 0) {
            _fullFrameMotionStartNs = nowNs;
        }
    } else {
        _fullFrameMotionStartNs = 0;
    }

    uint64_t heldNs = _fullFrameMotionStartNs != 0 &&
                              nowNs >= _fullFrameMotionStartNs
                          ? nowNs - _fullFrameMotionStartNs
                          : 0;
    uint64_t dwellNs = _fullFrameLastExitNs != 0 &&
                               nowNs >= _fullFrameLastExitNs
                           ? nowNs - _fullFrameLastExitNs
                           : UINT64_MAX;
    BOOL dwellComplete = dwellNs >= SHARP_H264_FULLFRAME_REENTRY_DWELL_NS;
    BOOL heldForEntry = heldNs >= SHARP_H264_FULLFRAME_ENTER_HOLD_NS;
    BOOL heldForSceneChange =
        heldNs >= SHARP_H264_FULLFRAME_SCENE_ENTER_HOLD_NS;
    BOOL heldForBurst = hardBurstMotion ||
                        (burstMotion &&
                         heldNs >= SHARP_H264_FULLFRAME_BURST_HOLD_NS);
    BOOL entryReady = (dwellComplete && heldForEntry) ||
                       (sceneChange && heldForSceneChange) || heldForBurst;
    if (enterCondition && entryReady) {
        const char *reason = heldForBurst
                                 ? "burst"
                                 : (sceneChange && !dwellComplete
                                        ? "scene-change"
                                        : "cluster");
        _fullFrameActive = YES;
        _fullFrameForceKeyframe = YES;
        _fullFrameMotionStartNs = 0;
        _fullFrameQuietStartNs = 0;
        _fullFrameEnteredNs = nowNs;
        _fullFrameEntries++;
        _fullFrameTraceUntilNs = nowNs + 2000000000ULL;
        _fullFrameTraceSendDropsBase = _fullFrameSendDrops;
        _fullFrameTraceKeyframeAttempted = NO;
        [self logFullFrameEvent:"enter"
                          reason:reason
                    motionTiles:motionTiles
            sustainedMotionTiles:sustainedMotionTiles
                    motionRegions:motionRegions
                       tileCount:tileCount
                          heldNs:heldNs
                         quietNs:0];
    }
}

- (void)logFullFrameEvent:(const char *)event
                    reason:(const char *)reason
              motionTiles:(uint32_t)motionTiles
      sustainedMotionTiles:(uint32_t)sustainedMotionTiles
              motionRegions:(uint32_t)motionRegions
                 tileCount:(uint32_t)tileCount
                    heldNs:(uint64_t)heldNs
                   quietNs:(uint64_t)quietNs {
    if (_episodeLog == NULL || event == NULL) {
        return;
    }
    fprintf(_episodeLog,
            "%" PRIu64 "\t%s\t%s\t%u\t%u\t%u\t%u\t%u\t%.0f\t%.0f\t%u\t0\t0\t0\t0\t0\n",
            shtp_now_ns(), event, reason != NULL ? reason : "none", _frameId,
            motionTiles, sustainedMotionTiles, motionRegions, tileCount,
            (double)heldNs / 1000000.0, (double)quietNs / 1000000.0,
            _fullFrameActive ? 1u : 0u);
    fflush(_episodeLog);
}

- (void)traceFullFrameFrameId:(uint32_t)frameId
                 preSubmitted:(BOOL)preSubmitted
                    submitted:(BOOL)submitted
                  forceKeyframe:(BOOL)forceKeyframe {
    if (_episodeLog == NULL || _fullFrameTraceUntilNs == 0) {
        return;
    }
    uint64_t nowNs = shtp_now_ns();
    if (nowNs > _fullFrameTraceUntilNs) {
        _fullFrameTraceUntilNs = 0;
        return;
    }
    uint64_t heldNs = _fullFrameEnteredNs != 0 && nowNs >= _fullFrameEnteredNs
                          ? nowNs - _fullFrameEnteredNs
                          : 0;
    uint64_t sendDropsDelta =
        _fullFrameSendDrops >= _fullFrameTraceSendDropsBase
            ? _fullFrameSendDrops - _fullFrameTraceSendDropsBase
            : 0;
    fprintf(_episodeLog,
            "%" PRIu64 "\tframe\ttrace\t%u\t0\t0\t0\t0\t%.0f\t0\t%u\t%u\t%u\t%" PRIu64 "\t%" PRIu64 "\t%u\n",
            nowNs, frameId, (double)heldNs / 1000000.0,
            _fullFrameActive ? 1u : 0u, preSubmitted ? 1u : 0u,
            submitted ? 1u : 0u, _fullFrameEncodeInFlight, sendDropsDelta,
            forceKeyframe ? 1u : 0u);
    fflush(_episodeLog);
}

- (void)retransmitH264Region:(uint16_t)regionId
                  generation:(uint32_t)generation
                  firstChunk:(uint16_t)firstChunk
                  chunkCount:(uint16_t)chunkCount {
    h264_region_stream_t *stream =
        [self h264StreamForRegion:regionId create:NO frameId:generation];
    h264_resend_generation_t *gen =
        h264_resend_find_generation(_h264Resend, SHARP_H264_RESEND_MAX_GENERATIONS,
                                    regionId, generation);
    if (gen == NULL || chunkCount == 0 || firstChunk >= gen->chunk_count) {
        _h264RetransmitMisses++;
        if (stream != NULL) {
            stream->retransmit_misses++;
        }
        if (_h264ResendTarget < SHARP_H264_RESEND_MAX_GENERATIONS) {
            _h264ResendTarget += 4u;
            if (_h264ResendTarget > SHARP_H264_RESEND_MAX_GENERATIONS) {
                _h264ResendTarget = SHARP_H264_RESEND_MAX_GENERATIONS;
            }
        }
        return;
    }
    gen->repair_active = 1u;
    gen->last_feedback_ns = shtp_now_ns();
    gen->nack_count++;
    uint32_t end = (uint32_t)firstChunk + chunkCount;
    if (end > gen->chunk_count) {
        end = gen->chunk_count;
    }
    int requestHadMiss = 0;
    for (uint32_t i = firstChunk; i < end; i++) {
        h264_resend_chunk_t *chunk = &gen->chunks[i];
        if (chunk->packet == NULL || chunk->len == 0) {
            _h264RetransmitMisses++;
            if (stream != NULL) {
                stream->retransmit_misses++;
            }
            requestHadMiss = 1;
            continue;
        }
        if (send(_fd, chunk->packet, chunk->len, 0) < 0) {
            _h264RetransmitMisses++;
            if (stream != NULL) {
                stream->retransmit_misses++;
            }
            requestHadMiss = 1;
            continue;
        }
        _h264RetransmitPackets++;
        _h264RetransmitBytes += chunk->len;
        if (stream != NULL) {
            stream->retransmit_packets++;
        }
        gen->retransmit_count++;
        [self paceAfterBytes:chunk->len];
    }
    if (!requestHadMiss) {
        gen->repair_active = 0u;
    }
}
@end
