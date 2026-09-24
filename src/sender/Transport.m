#import "Internal.h"

@implementation SharpScreenSender (Transport)
- (void)sendBye {
    uint32_t finalFrame = _frameId == 0 ? 0 : _frameId - 1u;
    pthread_mutex_lock(&_sendLock);
    if (_verifiedSession) {
        shtp_header_t h={0}; h.magic=SHTP_MAGIC;h.version=SHTP_VERSION;h.header_bytes=SHTP_HEADER_BYTES;
        h.type=SHTP_PACKET_BYE;h.payload_type=SHTP_PAYLOAD_CONTROL;h.frame_id=finalFrame;
        h.sequence=_sequence++;h.flags=SHTP_FLAG_VERIFIED_HYBRID;h.aux_time_ns=_verifiedSession;
        shtp_header_host_to_wire(&h);(void)send(_fd,&h,sizeof(h),0);
    } else (void)sharp_tile_sender_send_bye(_fd, finalFrame, &_sequence);
    pthread_mutex_unlock(&_sendLock);
}

- (void)sendCursorPositionX:(int32_t)x
                          y:(int32_t)y
                        seq:(uint32_t)cursorSeq
               sampleTimeNs:(uint64_t)sampleTimeNs
                    imageId:(uint32_t)imageId
                    visible:(BOOL)visible {
    sharp_cursor_position_t cursor;
    memset(&cursor, 0, sizeof(cursor));
    cursor.seq = htonl(cursorSeq);
    cursor.x = htonl((uint32_t)x);
    cursor.y = htonl((uint32_t)y);
    cursor.stream_width = htons((uint16_t)MIN(_width, UINT16_MAX));
    cursor.stream_height = htons((uint16_t)MIN(_height, UINT16_MAX));
    cursor.hotspot_x = htons(2u);
    cursor.hotspot_y = htons(2u);
    cursor.flags = htonl(visible ? 1u : 0u);
    cursor.sample_time_ns = shtp_htonll(sampleTimeNs);
    cursor.image_id = htonl(imageId);

    uint8_t packet[sizeof(shtp_header_t) + sizeof(cursor)];
    shtp_header_t sh;
    memset(&sh, 0, sizeof(sh));
    sh.magic = SHTP_MAGIC;
    sh.version = SHTP_VERSION;
    sh.header_bytes = SHTP_HEADER_BYTES;
    sh.type = SHTP_PACKET_DATA;
    sh.payload_type = SHTP_PAYLOAD_SYNTH_CURSOR;
    sh.frame_id = _frameId;
    sh.payload_len = (uint32_t)sizeof(cursor);
    sh.send_time_ns = shtp_now_ns();

    pthread_mutex_lock(&_sendLock);
    sh.sequence = _sequence++;
    shtp_header_host_to_wire(&sh);
    memcpy(packet, &sh, sizeof(sh));
    memcpy(packet + sizeof(sh), &cursor, sizeof(cursor));
    (void)send(_fd, packet, sizeof(packet), 0);
    pthread_mutex_unlock(&_sendLock);
}

- (screen_tx_frame_job_t *)mergeMotionPrerollJob:(screen_tx_frame_job_t *)held
                                         withJob:(screen_tx_frame_job_t *)current
                                            bgra:(const uint8_t *)bgra
                                          stride:(uint32_t)stride
                                       tileCount:(uint32_t)tileCount {
    if (bgra == NULL || stride == 0 || tileCount == 0 ||
        _sendSeenScratch == NULL || _sendKindScratch == NULL) {
        if (held != NULL && current != NULL) {
            free(current->motion_mask);
            free(current);
        }
        return held != NULL ? held : current;
    }
    memset(_sendSeenScratch, 0, (size_t)tileCount);
    memset(_sendKindScratch, 0, (size_t)tileCount);
    screen_tx_frame_job_t *jobs[2] = { held, current };
    uint16_t unionCount = 0;
    for (size_t j = 0; j < 2; j++) {
        screen_tx_frame_job_t *job = jobs[j];
        if (job == NULL) {
            continue;
        }
        for (uint16_t i = 0; i < job->tile_count; i++) {
            uint16_t tileId = job->tiles[i].tile_id;
            if (tileId >= tileCount) {
                continue;
            }
            if (!_sendSeenScratch[tileId]) {
                _sendSeenScratch[tileId] = 1u;
                unionCount++;
            }
            _sendKindScratch[tileId] = job->tiles[i].kind;
        }
    }
    if (unionCount == 0) {
        return current;
    }
    size_t bytes = sizeof(screen_tx_frame_job_t) +
                   (size_t)unionCount * sizeof(screen_tx_tile_t);
    screen_tx_frame_job_t *merged = calloc(1, bytes);
    if (merged == NULL) {
        if (held != NULL && current != NULL) {
            free(current->motion_mask);
            free(current);
        }
        return held != NULL ? held : current;
    }
    merged->frame_id = _frameId;
    merged->enqueue_ns = shtp_now_ns();
    for (uint32_t tileId = 0; tileId < tileCount; tileId++) {
        if (!_sendSeenScratch[tileId]) {
            continue;
        }
        screen_tx_tile_t *tile = &merged->tiles[merged->tile_count++];
        tile->tile_id = (uint16_t)tileId;
        tile->kind = _sendKindScratch[tileId] != 0
                         ? _sendKindScratch[tileId]
                         : SCREEN_TX_TILE_STATIC_DETAIL;
        if (sharp_tile_rect_for_id(_width, _height, tile->tile_id,
                                   &tile->rect) != 0) {
            merged->tile_count--;
            continue;
        }
        size_t rowBytes = (size_t)tile->rect.w * 4u;
        const uint8_t *src = bgra + (size_t)tile->rect.y * stride +
                             (size_t)tile->rect.x * 4u;
        for (uint32_t row = 0; row < tile->rect.h; row++) {
            memcpy(tile->bgra + (size_t)row * rowBytes,
                   src + (size_t)row * stride, rowBytes);
        }
        merged->estimated_bytes +=
            (uint64_t)tile->rect.w * (uint64_t)tile->rect.h * 4u;
        if (tile->kind == SCREEN_TX_TILE_REFINEMENT) {
            merged->refine_tiles++;
        } else if (tile->kind == SCREEN_TX_TILE_MOTION_FALLBACK) {
            merged->motion_fallback_tiles++;
        } else {
            merged->static_tiles++;
        }
    }
    merged->expected_patches = merged->tile_count;
    if (held != NULL) {
        free(held->motion_mask);
        free(held);
    }
    if (current != NULL) {
        free(current->motion_mask);
        free(current);
    }
    return merged;
}

- (void)enqueueTxFrameJob:(screen_tx_frame_job_t *)job {
    if (job == NULL) {
        return;
    }
    uint32_t offered = atomic_load_explicit(&_txLatestOfferedFrame,
                                            memory_order_relaxed);
    while ((int32_t)(job->frame_id - offered) > 0 &&
           !atomic_compare_exchange_weak_explicit(
               &_txLatestOfferedFrame, &offered, job->frame_id,
               memory_order_release, memory_order_relaxed)) {
    }
    dispatch_async(_txQueue, ^{
      screen_tx_frame_job_t *queuedJob = job;
      if (atomic_load_explicit(&_txStopping, memory_order_acquire)) {
          [self dropTxJob:queuedJob];
          return;
      }
      queuedJob->next = NULL;
      if (queuedJob->enqueue_ns == 0) {
          queuedJob->enqueue_ns = shtp_now_ns();
      }
      [self compactCleanupFromTxJob:&queuedJob nowNs:queuedJob->enqueue_ns];
      if (queuedJob == NULL && _cleanupPendingTiles == 0) {
          return;
      }
      if (queuedJob == NULL) {
          if (!_txPumpScheduled) {
              _txPumpScheduled = 1u;
              [self txPump];
          }
          return;
      }
      if (_fullFrameActive && !_motionMaskEnabled &&
          queuedJob->video_region_count == 0 &&
          queuedJob->tile_count > 0) {
          [self dropTxJob:queuedJob];
          return;
      }
      /*
       * The dirty map advances when capture work is queued, not when packets
       * reach the receiver. Keeping several non-initial jobs and selecting the
       * newest one first leaves older frame ends behind the committed frontier.
       * Coalesce their tiles into the latest-snapshot cleanup lane before
       * enqueueing the new owner. Preserve initial sync and the zero-mask exit
       * boundary because those jobs carry lifecycle state that must stay ordered.
       */
      screen_tx_frame_job_t **pending = &_txHead;
      while (*pending != NULL) {
          screen_tx_frame_job_t *candidate = *pending;
          if (candidate->initial_sync ||
              [self txJobClosesMotionMask:candidate]) {
              pending = &candidate->next;
              continue;
          }
          *pending = candidate->next;
          candidate->next = NULL;
          if (_txPendingJobs > 0) {
              _txPendingJobs--;
          }
          [self coalesceQueuedJobToCleanup:candidate
                                     nowNs:queuedJob->enqueue_ns];
      }
      screen_tx_frame_job_t **tail = &_txHead;
      while (*tail != NULL) {
          tail = &(*tail)->next;
      }
      *tail = queuedJob;
      _txPendingJobs++;
      if (_txPendingJobs > _txMaxPendingJobs) {
          _txMaxPendingJobs = _txPendingJobs;
      }
      if (!_txPumpScheduled) {
          _txPumpScheduled = 1u;
          [self txPump];
      }
    });
}

- (BOOL)txJobClosesMotionMask:(const screen_tx_frame_job_t *)job {
    if (job == NULL || !job->has_motion_mask || job->motion_mask == NULL ||
        job->motion_mask_bytes == 0) {
        return NO;
    }
    for (uint16_t i = 0; i < job->motion_mask_bytes; i++) {
        if (job->motion_mask[i] != 0) {
            return NO;
        }
    }
    return YES;
}

- (void)coalesceQueuedJobToCleanup:(screen_tx_frame_job_t *)job
                              nowNs:(uint64_t)nowNs {
    if (job == NULL) {
        return;
    }
    _txCoalescedJobs++;
    _txDroppedJobs++;
    _txDroppedStaleFrames++;
    _txDroppedTiles += job->tile_count;
    _txDroppedMotionFallbackTiles += job->motion_fallback_tiles;
    _txDroppedRefineTiles += job->refine_tiles;
    for (uint16_t i = 0; i < job->tile_count; i++) {
        [self storeCleanupTile:&job->tiles[i]
                      frameId:job->frame_id
                    enqueueNs:nowNs];
    }
    free(job->motion_mask);
    free(job);
}

- (void)compactCleanupFromTxJob:(screen_tx_frame_job_t **)jobPtr
                           nowNs:(uint64_t)nowNs {
    if (jobPtr == NULL || *jobPtr == NULL) {
        return;
    }
    screen_tx_frame_job_t *job = *jobPtr;
    if (job->initial_sync || job->tile_count == 0) {
        return;
    }

    uint16_t kept = 0;
    uint16_t staticTiles = 0;
    uint16_t refineTiles = 0;
    uint16_t fallbackTiles = 0;
    for (uint16_t i = 0; i < job->tile_count; i++) {
        screen_tx_tile_t *tile = &job->tiles[i];
        if (tile->kind == SCREEN_TX_TILE_REFINEMENT) {
            [self storeCleanupTile:tile frameId:job->frame_id enqueueNs:nowNs];
            continue;
        }
        if (kept != i) {
            job->tiles[kept] = *tile;
        }
        if (job->tiles[kept].kind == SCREEN_TX_TILE_STATIC_DETAIL ||
            job->tiles[kept].kind == SCREEN_TX_TILE_INITIAL_SYNC) {
            staticTiles++;
        } else if (job->tiles[kept].kind == SCREEN_TX_TILE_REFINEMENT) {
            refineTiles++;
        } else if (job->tiles[kept].kind == SCREEN_TX_TILE_MOTION_FALLBACK) {
            /* Uncovered motion is foreground content, never background repair. */
            fallbackTiles++;
        }
        kept++;
    }

    if (kept != job->tile_count) {
        _txCoalescedJobs++;
    }
    job->tile_count = kept;
    job->static_tiles = staticTiles;
    job->refine_tiles = refineTiles;
    job->motion_fallback_tiles = fallbackTiles;
    job->expected_patches = (uint16_t)(kept + job->video_region_count);
    if (kept == 0 && job->video_region_count == 0 &&
        !job->has_motion_mask) {
        _txDroppedStaleFrames++;
        free(job->motion_mask);
        free(job);
        *jobPtr = NULL;
    }
}

- (void)storeCleanupTile:(const screen_tx_tile_t *)tile
                 frameId:(uint32_t)frameId
               enqueueNs:(uint64_t)enqueueNs {
    if (tile == NULL || tile->tile_id >= _cleanupTileCap || _cleanupRecords == NULL) {
        return;
    }
    screen_tx_cleanup_record_t *record = &_cleanupRecords[tile->tile_id];
    if (record->active &&
        (int32_t)(frameId - record->frame_id) < 0) {
        /* A delayed queue job must never replace a newer repair snapshot. */
        _cleanupCancelledTiles++;
        _cleanupObsoleteTiles++;
        return;
    }
    if (record->active && record->protected_tile &&
        tile->kind == SCREEN_TX_TILE_MOTION_FALLBACK) {
        _cleanupCancelledTiles++;
        _cleanupObsoleteTiles++;
        return;
    }
    if (record->active) {
        _cleanupReplacedTiles++;
        _cleanupCoalescedTiles++;
        if (frameId > record->frame_id) {
            _cleanupObsoleteTiles++;
        }
        _cleanupCancelledTiles++;
    } else {
        _cleanupPendingTiles++;
    }
    record->active = 1u;
    record->kind = tile->kind;
    record->protected_tile =
        tile->kind == SCREEN_TX_TILE_REFINEMENT ? 1u : 0u;
    record->tile_id = tile->tile_id;
    record->frame_id = frameId;
    record->enqueue_ns = enqueueNs;
    record->rect = tile->rect;
    memcpy(record->bgra, tile->bgra, sizeof(record->bgra));
    if (record->protected_tile) {
        _cleanupProtectedTiles++;
    }
}

- (uint16_t)sendCleanupBatch {
    if (_cleanupPendingTiles == 0 || _cleanupRecords == NULL) {
        return 0;
    }

    int wantProtected = 0;
    for (uint32_t i = 0; i < _cleanupTileCap; i++) {
        if (_cleanupRecords[i].active && _cleanupRecords[i].protected_tile) {
            wantProtected = 1;
            break;
        }
    }

    /*
     * A cleanup record owns pixels captured at record->frame_id.  Never copy
     * from the mutable latest-frame buffer here and never stamp records from
     * different snapshots with one newer global generation.  Either behavior
     * lets an unrelated capture race manufacture a tile/frame mismatch.
     */
    uint16_t selected[SHARP_TX_CLEANUP_BATCH_TILES];
    uint16_t selectedCount = 0;
    uint32_t batchFrameId = 0;
    for (uint32_t i = 0;
         i < _cleanupTileCap && selectedCount < SHARP_TX_CLEANUP_BATCH_TILES; i++) {
        screen_tx_cleanup_record_t *record = &_cleanupRecords[i];
        if (!record->active || (int)record->protected_tile != wantProtected) {
            continue;
        }
        selected[selectedCount++] = (uint16_t)i;
        if ((int32_t)(record->frame_id - batchFrameId) > 0) {
            batchFrameId = record->frame_id;
        }
    }
    if (selectedCount == 0) {
        return 0;
    }

    uint64_t oldestNs = UINT64_MAX;
    uint64_t now = shtp_now_ns();
    for (uint16_t i = 0; i < selectedCount; i++) {
        screen_tx_cleanup_record_t *record = &_cleanupRecords[selected[i]];
        if (record->enqueue_ns < oldestNs) {
            oldestNs = record->enqueue_ns;
        }
    }

    uint64_t ageMs = oldestNs < now ? (now - oldestNs) / 1000000ULL : 0;
    if (ageMs > _txMaxJobAgeMs) {
        _txMaxJobAgeMs = ageMs;
    }
    if (ageMs > _txOldestCleanupAgeMs) {
        _txOldestCleanupAgeMs = ageMs;
    }

    sharp_tile_sender_stats_t jobStats;
    memset(&jobStats, 0, sizeof(jobStats));
    sharp_tile_sender_codec_t codec = [self tileCodec];
    uint8_t batchPacket[SHTP_MAX_DATAGRAM];
    sharp_tile_batch_writer_t batchWriter;
    int batchActive = 0;
    if (_tileBatchEnabled &&
        sharp_tile_batch_writer_begin_with_codec(
            &batchWriter, batchPacket, _verifiedSource ? _payloadSize : SHTP_MAX_DATAGRAM - SHTP_HEADER_BYTES,
            &codec) == 0) {
        batchActive = 1;
    }
    uint16_t sentTiles = 0;
    int failed = 0;
    for (uint16_t i = 0; i < selectedCount; i++) {
        screen_tx_cleanup_record_t *record = &_cleanupRecords[selected[i]];
        if (_verifiedSource && batchActive) {
            uint64_t bytesBefore=jobStats.bytes;
            pthread_mutex_lock(&_sendLock);
            int result=sharp_tile_batch_writer_send_pixels(_fd,&batchWriter,batchFrameId,
                record->frame_id,&record->rect,record->bgra,record->rect.w*4u,
                &_sequence,&jobStats);
            pthread_mutex_unlock(&_sendLock);
            if (result!=0) { failed=1; break; }
            sentTiles++;
            [self paceAfterBytes:(size_t)(jobStats.bytes-bytesBefore)];
            continue;
        }
        if (batchActive) {
            int addResult = sharp_tile_batch_writer_add_with_generation(
                &batchWriter, record->frame_id, &record->rect, record->bgra,
                (uint32_t)record->rect.w * 4u);
            if (addResult == 1) {
                uint64_t bytesBefore = jobStats.bytes;
                pthread_mutex_lock(&_sendLock);
                int flushResult = sharp_tile_batch_writer_flush(
                    _fd, &batchWriter, batchFrameId, &_sequence, &jobStats);
                pthread_mutex_unlock(&_sendLock);
                if (flushResult != 0) {
                    failed = 1;
                    break;
                }
                [self paceAfterBytes:(size_t)(jobStats.bytes - bytesBefore)];
                addResult = sharp_tile_batch_writer_add_with_generation(
                    &batchWriter, record->frame_id, &record->rect, record->bgra,
                    (uint32_t)record->rect.w * 4u);
            }
            if (addResult == 0) {
                sentTiles++;
                continue;
            }
            uint64_t bytesBefore = jobStats.bytes;
            pthread_mutex_lock(&_sendLock);
            int flushResult = sharp_tile_batch_writer_flush(
                _fd, &batchWriter, batchFrameId, &_sequence, &jobStats);
            pthread_mutex_unlock(&_sendLock);
            if (flushResult != 0) {
                failed = 1;
                break;
            }
            [self paceAfterBytes:(size_t)(jobStats.bytes - bytesBefore)];
        }
        uint64_t bytesBefore = jobStats.bytes;
        pthread_mutex_lock(&_sendLock);
        if (sharp_tile_sender_send_bgra_tile_pixels_generation(
                _fd, batchFrameId, record->frame_id, &record->rect, record->bgra,
                (uint32_t)record->rect.w * 4u, &_sequence, _payloadSize,
                &jobStats, &codec) != 0) {
            pthread_mutex_unlock(&_sendLock);
            failed = 1;
            break;
        }
        pthread_mutex_unlock(&_sendLock);
        sentTiles++;
        [self paceAfterBytes:(size_t)(jobStats.bytes - bytesBefore)];
    }
    if (!failed && batchActive) {
        uint64_t bytesBefore = jobStats.bytes;
        pthread_mutex_lock(&_sendLock);
        int flushResult = sharp_tile_batch_writer_flush(
            _fd, &batchWriter, batchFrameId, &_sequence, &jobStats);
        pthread_mutex_unlock(&_sendLock);
        if (flushResult != 0) {
            failed = 1;
        } else {
            [self paceAfterBytes:(size_t)(jobStats.bytes - bytesBefore)];
        }
    }

    if (!failed && sentTiles > 0) {
        if ([self sendFrameEndFrameId:batchFrameId
                      expectedPatches:sentTiles
                      videoRegionMask:0
                            motionMask:NULL
                       motionMaskBytes:0] != 0) {
            failed = 1;
        } else {
            _txFrameEnds++;
        }
    }

    if (failed) {
        _txFailures++;
        return 0;
    }

    now = shtp_now_ns();
    uint16_t refinedTiles[SHARP_TX_CLEANUP_BATCH_TILES];
    uint16_t refinedCount = 0;
    for (uint16_t i = 0; i < sentTiles; i++) {
        screen_tx_cleanup_record_t *record = &_cleanupRecords[selected[i]];
        uint64_t latencyMs =
            record->enqueue_ns < now ? (now - record->enqueue_ns) / 1000000ULL : 0;
        if (_cleanupLatencyCount < SHARP_TX_LATENCY_SAMPLES) {
            _cleanupLatencySamples[_cleanupLatencyCount++] = latencyMs;
        }
        if (latencyMs > _cleanupMaxLatencyMs) {
            _cleanupMaxLatencyMs = latencyMs;
        }
        uint64_t sourceLag =
            _frameId > record->frame_id ? (uint64_t)(_frameId - record->frame_id) : 0;
        if (_txLatestSourceLagCount < SHARP_TX_LATENCY_SAMPLES) {
            _txLatestSourceLagSamples[_txLatestSourceLagCount++] = sourceLag;
        }
        if (sourceLag > _txLatestSourceLagMaxFrames) {
            _txLatestSourceLagMaxFrames = sourceLag;
        }
        if (record->kind == SCREEN_TX_TILE_REFINEMENT &&
            refinedCount < SHARP_TX_CLEANUP_BATCH_TILES) {
            refinedTiles[refinedCount++] = record->tile_id;
        }
        memset(record, 0, sizeof(*record));
    }
    if (_cleanupPendingTiles >= sentTiles) {
        _cleanupPendingTiles -= sentTiles;
    } else {
        _cleanupPendingTiles = 0;
    }

    _cleanupSentTiles += sentTiles;
    _txFrames++;
    _txTiles += sentTiles;
    _stats.packets += jobStats.packets;
    _stats.bytes += jobStats.bytes;
    _stats.tiles += jobStats.tiles;
    _stats.batch_packets += jobStats.batch_packets;
    _stats.batch_tiles += jobStats.batch_tiles;
    _stats.solid_tiles += jobStats.solid_tiles;
    _stats.twocolor_tiles += jobStats.twocolor_tiles;
    _stats.sparse_tiles += jobStats.sparse_tiles;
    _stats.rle_tiles += jobStats.rle_tiles;
    _stats.raw_tiles += jobStats.raw_tiles;
    _stats.zstd_tiles += jobStats.zstd_tiles;
    if (_m2Classifier != NULL && refinedCount > 0) {
        sharp_m2_classifier_mark_refined(_m2Classifier, refinedTiles, refinedCount);
    }
    return sentTiles;
}

- (void)sendFinalLatestFrameRefresh {
    if (_verifiedSource) return;
    uint32_t tileCount = sharp_tile_count(_width, _height);
    if (tileCount == 0 || _latestFrameBgra == NULL) {
        return;
    }
    uint32_t frameId = _frameId == 0 ? 0 : _frameId - 1u;
    sharp_tile_sender_stats_t jobStats;
    memset(&jobStats, 0, sizeof(jobStats));
    sharp_tile_sender_codec_t codec = [self tileCodec];
    uint16_t sentTiles = 0;
    for (uint32_t tileId = 0; tileId < tileCount; tileId++) {
        sharp_tile_rect_t rect;
        if (sharp_tile_rect_for_id(_width, _height, (uint16_t)tileId, &rect) != 0) {
            continue;
        }
        screen_tx_cleanup_record_t record;
        memset(&record, 0, sizeof(record));
        record.tile_id = (uint16_t)tileId;
        record.rect = rect;
        if ([self copyLatestFrameTileForRecord:&record] != 0) {
            continue;
        }
        uint64_t bytesBefore = jobStats.bytes;
        pthread_mutex_lock(&_sendLock);
        if (sharp_tile_sender_send_bgra_tile_pixels_with_codec(
                _fd, frameId, &rect, record.bgra, (uint32_t)rect.w * 4u,
                &_sequence, _payloadSize, &jobStats, &codec) != 0) {
            pthread_mutex_unlock(&_sendLock);
            _txFailures++;
            break;
        }
        pthread_mutex_unlock(&_sendLock);
        sentTiles++;
        [self paceAfterBytes:(size_t)(jobStats.bytes - bytesBefore)];
    }
    if (sentTiles > 0 &&
        [self sendFrameEndFrameId:frameId
                  expectedPatches:sentTiles
                  videoRegionMask:0
                        motionMask:NULL
                   motionMaskBytes:0] == 0) {
        _txFrameEnds++;
        _txFrames++;
        _txTiles += sentTiles;
        _cleanupSentTiles += sentTiles;
        _cleanupProtectedTiles += sentTiles;
        _stats.packets += jobStats.packets;
        _stats.bytes += jobStats.bytes;
        _stats.tiles += jobStats.tiles;
        _stats.batch_packets += jobStats.batch_packets;
        _stats.batch_tiles += jobStats.batch_tiles;
        _stats.solid_tiles += jobStats.solid_tiles;
        _stats.twocolor_tiles += jobStats.twocolor_tiles;
        _stats.sparse_tiles += jobStats.sparse_tiles;
        _stats.rle_tiles += jobStats.rle_tiles;
        _stats.raw_tiles += jobStats.raw_tiles;
        _stats.zstd_tiles += jobStats.zstd_tiles;
        if (_cleanupRecords != NULL && _cleanupTileCap > 0u) {
            memset(_cleanupRecords, 0,
                   (size_t)_cleanupTileCap * sizeof(*_cleanupRecords));
        }
        _cleanupPendingTiles = 0u;
    }
}

- (void)stopTxAndSendFinal {
    atomic_store_explicit(&_txStopping, 1u, memory_order_release);
    while (_txHead != NULL) {
        screen_tx_frame_job_t *job = _txHead;
        _txHead = job->next;
        job->next = NULL;
        if (_txPendingJobs > 0) {
            _txPendingJobs--;
        }
        [self dropTxJob:job];
    }
    _txPumpScheduled = 0u;
    [self sendFinalLatestFrameRefresh];
    [self sendBye];
}

- (void)requestTxStop {
    atomic_store_explicit(&_txStopping, 1u, memory_order_release);
}

- (uint32_t)cleanupPendingTileCount {
    return _cleanupPendingTiles;
}

- (uint64_t)cleanupLatencyPercentile:(double)percentile {
    return percentile_u64(_cleanupLatencySamples, _cleanupLatencyCount, percentile);
}

- (uint64_t)txLatestSourceLagPercentile:(double)percentile {
    return percentile_u64(_txLatestSourceLagSamples, _txLatestSourceLagCount,
                          percentile);
}

- (uint64_t)h264FrameBytesPercentile:(double)percentile {
    return percentile_u64(_h264FrameBytesSamples, _h264FrameBytesCount,
                          percentile);
}

- (uint64_t)callbackToProcessLatencyPercentileNs:(double)percentile {
    return percentile_u64(_callbackToProcessSamples, _callbackToProcessCount,
                          percentile);
}

- (uint64_t)processDurationPercentileNs:(double)percentile {
    return percentile_u64(_processDurationSamples, _processDurationCount,
                          percentile);
}

- (uint64_t)fullFrameProcessDurationPercentileNs:(double)percentile {
    return percentile_u64(_fullFrameProcessDurationSamples,
                          _fullFrameProcessDurationCount, percentile);
}

- (uint64_t)fullFrameEncodeSubmitDurationPercentileNs:(double)percentile {
    return percentile_u64(_fullFrameEncodeSubmitSamples,
                          _fullFrameEncodeSubmitCount, percentile);
}

- (uint64_t)fullFrameCopyDurationPercentileNs:(double)percentile {
    return percentile_u64(_fullFrameCopySamples, _fullFrameCopyCount,
                          percentile);
}

- (uint64_t)fullFrameConvertDurationPercentileNs:(double)percentile {
    return percentile_u64(_fullFrameConvertSamples, _fullFrameConvertCount,
                          percentile);
}

- (uint64_t)h264CallbackLatencyPercentileNs:(double)percentile {
    return percentile_u64(_h264CallbackLatencySamples,
                          _h264CallbackLatencyCount, percentile);
}

- (uint64_t)sckStatusCountAtIndex:(unsigned int)index {
    if (index >= SHARP_SCK_STATUS_BUCKETS) {
        return 0;
    }
    return _sckStatusCounts[index];
}

- (uint64_t)sckStatusOtherCount {
    return _sckStatusOther;
}

- (uint64_t)h264EncoderResetCount {
    uint64_t resets = 0;
    for (size_t i = 0; i < SHARP_H264_STREAM_TRACK_SLOTS; i++) {
        resets += _h264Streams[i].encoder_resets;
    }
    return resets;
}

- (void)markH264EmittedRegion:(uint16_t)regionId frameId:(uint32_t)frameId {
    if (regionId == 0 || regionId >= 16u) {
        return;
    }
    uint32_t slot = frameId % SHARP_H264_EMIT_TRACK_SLOTS;
    @synchronized (self) {
        if (_h264EmittedFrameIds[slot] != frameId) {
            _h264EmittedFrameIds[slot] = frameId;
            _h264EmittedMasks[slot] = 0;
        }
        _h264EmittedMasks[slot] |= (uint16_t)(1u << regionId);
    }
}

- (uint16_t)emittedH264MaskForFrame:(uint32_t)frameId {
    uint32_t slot = frameId % SHARP_H264_EMIT_TRACK_SLOTS;
    uint16_t mask = 0;
    @synchronized (self) {
        if (_h264EmittedFrameIds[slot] == frameId) {
            mask = _h264EmittedMasks[slot];
        }
    }
    return mask;
}

- (uint16_t)waitForH264Frame:(uint32_t)frameId
                         mask:(uint16_t)mask
                    timeoutNs:(uint64_t)timeoutNs {
    if (mask == 0) {
        return 0;
    }
    _h264FrameEndWaits++;
    uint64_t startNs = shtp_now_ns();
    for (;;) {
        uint16_t emittedMask = [self emittedH264MaskForFrame:frameId];
        if ((emittedMask & mask) == mask) {
            return emittedMask & mask;
        }
        uint64_t nowNs = shtp_now_ns();
        if (nowNs - startNs >= timeoutNs) {
            _h264FrameEndWaitTimeouts++;
            return emittedMask & mask;
        }
        usleep(250);
    }
}

- (void)dropTxJob:(screen_tx_frame_job_t *)job {
    if (job == NULL) {
        return;
    }
    _txDroppedJobs++;
    _txDroppedStaleFrames++;
    _txDroppedTiles += job->tile_count;
    _txDroppedMotionFallbackTiles += job->motion_fallback_tiles;
    _txDroppedRefineTiles += job->refine_tiles;
    free(job->motion_mask);
    free(job);
}

- (uint64_t)txScoreForJob:(const screen_tx_frame_job_t *)job
                    nowNs:(uint64_t)nowNs {
    (void)nowNs;
    if (job == NULL) {
        return 0;
    }
    uint64_t score = (uint64_t)job->frame_id;
    if (job->initial_sync) {
        score += 1000000000000ULL;
    } else if (job->video_region_count > 0) {
        score += 900000000000ULL;
    } else if (job->static_tiles > 0) {
        score += 600000000000ULL;
    } else if (job->refine_tiles > 0) {
        score += 300000000000ULL;
    } else if (job->motion_fallback_tiles > 0) {
        score += 100000000000ULL;
    }
    return score;
}

- (screen_tx_frame_job_t *)takeNextTxJob {
    if (_txHead == NULL) {
        return NULL;
    }
    screen_tx_frame_job_t *job = _txHead;
    _txHead = job->next;
    job->next = NULL;
    if (_txPendingJobs > 0) {
        _txPendingJobs--;
    }
    return job;
}

- (void)txPump {
    if (atomic_load_explicit(&_txStopping, memory_order_acquire)) {
        _txPumpScheduled = 0u;
        return;
    }
    screen_tx_frame_job_t *job = [self takeNextTxJob];
    if (job == NULL) {
        if (_cleanupPendingTiles > 0) {
            (void)[self sendCleanupBatch];
        }
        if (_txHead != NULL || _cleanupPendingTiles > 0) {
            dispatch_async(_txQueue, ^{
              [self txPump];
            });
        } else {
            _txPumpScheduled = 0u;
        }
        return;
    }

    uint64_t now = shtp_now_ns();
    if (_fullFrameActive && !_motionMaskEnabled &&
        job->video_region_count == 0 && job->tile_count > 0) {
        [self dropTxJob:job];
        dispatch_async(_txQueue, ^{
          [self txPump];
        });
        return;
    }
    uint64_t age = now > job->enqueue_ns ? now - job->enqueue_ns : 0;
    uint64_t ageMs = age / 1000000ULL;
    if (ageMs > _txMaxJobAgeMs) {
        _txMaxJobAgeMs = ageMs;
    }

    sharp_tile_sender_stats_t jobStats;
    memset(&jobStats, 0, sizeof(jobStats));
    sharp_tile_sender_codec_t codec = [self tileCodec];
    uint8_t batchPacket[SHTP_MAX_DATAGRAM];
    sharp_tile_batch_writer_t batchWriter;
    int batchActive = 0;
    if (_tileBatchEnabled &&
        sharp_tile_batch_writer_begin_with_codec(
            &batchWriter, batchPacket, _verifiedSource ? _payloadSize : SHTP_MAX_DATAGRAM - SHTP_HEADER_BYTES,
            &codec) == 0) {
        batchActive = 1;
    }
    int failed = 0;
    int preempted = 0;
    uint16_t sentTiles = 0;
    uint16_t tileIndex = 0;
    BOOL canPreempt = !job->initial_sync && !job->has_motion_mask;
    for (; tileIndex < job->tile_count; tileIndex++) {
        uint32_t latestOffered =
            atomic_load_explicit(&_txLatestOfferedFrame, memory_order_acquire);
        BOOL stopRequested =
            atomic_load_explicit(&_txStopping, memory_order_acquire) != 0;
        if ((stopRequested ||
             (canPreempt &&
              (int32_t)(latestOffered - job->frame_id) > 0)) &&
            (!batchActive || batchWriter.tile_count == 0)) {
            preempted = 1;
            break;
        }
        screen_tx_tile_t *tile = &job->tiles[tileIndex];
        if (batchActive) {
            int addResult = sharp_tile_batch_writer_add(
                &batchWriter, &tile->rect, tile->bgra,
                (uint32_t)tile->rect.w * 4u);
            if (addResult == 1) {
                uint64_t bytesBefore = jobStats.bytes;
                pthread_mutex_lock(&_sendLock);
                int flushResult = sharp_tile_batch_writer_flush(
                    _fd, &batchWriter, job->frame_id, &_sequence, &jobStats);
                pthread_mutex_unlock(&_sendLock);
                if (flushResult != 0) {
                    failed = 1;
                    break;
                }
                [self paceAfterBytes:(size_t)(jobStats.bytes - bytesBefore)];
                latestOffered = atomic_load_explicit(
                    &_txLatestOfferedFrame, memory_order_acquire);
                stopRequested = atomic_load_explicit(
                    &_txStopping, memory_order_acquire) != 0;
                if (stopRequested ||
                    (canPreempt &&
                     (int32_t)(latestOffered - job->frame_id) > 0)) {
                    preempted = 1;
                    break;
                }
                addResult = sharp_tile_batch_writer_add(
                    &batchWriter, &tile->rect, tile->bgra,
                    (uint32_t)tile->rect.w * 4u);
            }
            if (addResult == 0) {
                sentTiles++;
                continue;
            }
            uint64_t bytesBefore = jobStats.bytes;
            pthread_mutex_lock(&_sendLock);
            int flushResult = sharp_tile_batch_writer_flush(
                _fd, &batchWriter, job->frame_id, &_sequence, &jobStats);
            pthread_mutex_unlock(&_sendLock);
            if (flushResult != 0) {
                failed = 1;
                break;
            }
            [self paceAfterBytes:(size_t)(jobStats.bytes - bytesBefore)];
        }
        uint64_t bytesBefore = jobStats.bytes;
        pthread_mutex_lock(&_sendLock);
        if (sharp_tile_sender_send_bgra_tile_pixels_with_codec(
                _fd, job->frame_id, &tile->rect, tile->bgra,
                (uint32_t)tile->rect.w * 4u, &_sequence, _payloadSize,
                &jobStats, &codec) != 0) {
            pthread_mutex_unlock(&_sendLock);
            failed = 1;
            break;
        }
        pthread_mutex_unlock(&_sendLock);
        sentTiles++;
        [self paceAfterBytes:(size_t)(jobStats.bytes - bytesBefore)];
    }
    if (!failed && !preempted && batchActive) {
        uint64_t bytesBefore = jobStats.bytes;
        pthread_mutex_lock(&_sendLock);
        int flushResult = sharp_tile_batch_writer_flush(
            _fd, &batchWriter, job->frame_id, &_sequence, &jobStats);
        pthread_mutex_unlock(&_sendLock);
        if (flushResult != 0) {
            failed = 1;
        } else {
            [self paceAfterBytes:(size_t)(jobStats.bytes - bytesBefore)];
        }
    }

    if (preempted) {
        uint16_t remaining = (uint16_t)(job->tile_count - tileIndex);
        BOOL stopping =
            atomic_load_explicit(&_txStopping, memory_order_acquire) != 0;
        if (!stopping) {
            uint64_t enqueueNs = shtp_now_ns();
            for (uint16_t i = tileIndex; i < job->tile_count; i++) {
                [self storeCleanupTile:&job->tiles[i]
                              frameId:job->frame_id
                            enqueueNs:enqueueNs];
            }
        }
        _txCoalescedJobs++;
        _txDroppedJobs++;
        _txDroppedStaleFrames++;
        _txDroppedTiles += remaining;
        _txDroppedMotionFallbackTiles += job->motion_fallback_tiles;
        _txDroppedRefineTiles += job->refine_tiles;
        _txTiles += jobStats.tiles;
        _stats.packets += jobStats.packets;
        _stats.bytes += jobStats.bytes;
        _stats.tiles += jobStats.tiles;
        _stats.batch_packets += jobStats.batch_packets;
        _stats.batch_tiles += jobStats.batch_tiles;
        _stats.solid_tiles += jobStats.solid_tiles;
        _stats.twocolor_tiles += jobStats.twocolor_tiles;
        _stats.sparse_tiles += jobStats.sparse_tiles;
        _stats.rle_tiles += jobStats.rle_tiles;
        _stats.raw_tiles += jobStats.raw_tiles;
        _stats.zstd_tiles += jobStats.zstd_tiles;
        free(job->motion_mask);
        free(job);
        if (!stopping) {
            dispatch_async(_txQueue, ^{
              [self txPump];
            });
        } else {
            _txPumpScheduled = 0u;
        }
        return;
    }

    uint16_t videoRegionMask = job->video_region_mask;
    uint16_t videoRegionCount = job->video_region_count;
    if (videoRegionMask != 0) {
        uint16_t emittedMask =
            [self waitForH264Frame:job->frame_id
                               mask:videoRegionMask
                          timeoutNs:30000000ULL];
        if (emittedMask != videoRegionMask) {
            uint16_t droppedMask = (uint16_t)(videoRegionMask & ~emittedMask);
            uint16_t droppedCount = (uint16_t)__builtin_popcount((unsigned)droppedMask);
            _h264FrameEndVideoDrops += droppedCount;
            videoRegionMask = emittedMask;
            videoRegionCount = (uint16_t)__builtin_popcount((unsigned)emittedMask);
        }
    }
    uint16_t expectedPatches = (uint16_t)(sentTiles + videoRegionCount);
    if (!failed && (expectedPatches > 0 || job->has_motion_mask)) {
        if ([self sendFrameEndFrameId:job->frame_id
                      expectedPatches:expectedPatches
                      videoRegionMask:videoRegionMask
                            motionMask:job->has_motion_mask ? job->motion_mask : NULL
                       motionMaskBytes:job->has_motion_mask
                                           ? job->motion_mask_bytes
                                           : 0] != 0) {
            failed = 1;
        } else {
            _txFrameEnds++;
        }
    } else if (!failed && expectedPatches == 0) {
        _txDroppedStaleFrames++;
    }

    if (failed) {
        _txFailures++;
    } else {
        BOOL closingMotionMask = job->has_motion_mask;
        for (uint16_t i = 0; closingMotionMask &&
                             i < job->motion_mask_bytes; i++) {
            if (job->motion_mask[i] != 0) {
                closingMotionMask = NO;
            }
        }
        if (closingMotionMask) {
            uint64_t cleanupEnqueueNs = shtp_now_ns();
            for (uint16_t i = 0; i < job->tile_count; i++) {
                if (job->tiles[i].kind == SCREEN_TX_TILE_REFINEMENT) {
                    [self storeCleanupTile:&job->tiles[i]
                                  frameId:job->frame_id
                                enqueueNs:cleanupEnqueueNs];
                }
            }
        }
        _txFrames++;
        _txTiles += sentTiles;
        _stats.packets += jobStats.packets;
        _stats.bytes += jobStats.bytes;
        _stats.tiles += jobStats.tiles;
        _stats.batch_packets += jobStats.batch_packets;
        _stats.batch_tiles += jobStats.batch_tiles;
        _stats.solid_tiles += jobStats.solid_tiles;
        _stats.twocolor_tiles += jobStats.twocolor_tiles;
        _stats.sparse_tiles += jobStats.sparse_tiles;
        _stats.rle_tiles += jobStats.rle_tiles;
        _stats.raw_tiles += jobStats.raw_tiles;
        _stats.zstd_tiles += jobStats.zstd_tiles;
    }
    free(job->motion_mask);
    free(job);
    if (_cleanupPendingTiles > 0) {
        (void)[self sendCleanupBatch];
    }
    if (_txHead != NULL || _cleanupPendingTiles > 0) {
        dispatch_async(_txQueue, ^{
          [self txPump];
        });
    } else {
        _txPumpScheduled = 0u;
    }
}

- (void)paceAfterTile:(uint16_t)tileId {
    if (_pacingMbps <= 0.0) {
        return;
    }
    sharp_tile_rect_t rect;
    if (sharp_tile_rect_for_id(_width, _height, tileId, &rect) != 0) {
        return;
    }
    double bytes = (double)rect.w * (double)rect.h * 4.0 * 1.08;
    useconds_t sleepUs = (useconds_t)((bytes * 8.0) / _pacingMbps);
    if (sleepUs > 0) {
        usleep(sleepUs);
    }
}
@end
