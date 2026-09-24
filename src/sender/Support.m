#import "Internal.h"
volatile sig_atomic_t g_sharp_stop_requested = 0;
void set_h264_709_color_attachments(CVPixelBufferRef pixelBuffer) {
    if (pixelBuffer == NULL) {
        return;
    }
    CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey,
                          kCVImageBufferTransferFunction_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey,
                          kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
}

void h264_resend_generation_clear(h264_resend_generation_t *gen) {
    if (gen == NULL) {
        return;
    }
    if (gen->chunks != NULL) {
        for (uint16_t i = 0; i < gen->chunk_count; i++) {
            free(gen->chunks[i].packet);
        }
    }
    free(gen->chunks);
    memset(gen, 0, sizeof(*gen));
}

void h264_resend_ring_clear(h264_resend_generation_t *ring, size_t cap) {
    if (ring == NULL) {
        return;
    }
    for (size_t i = 0; i < cap; i++) {
        h264_resend_generation_clear(&ring[i]);
    }
}

h264_resend_generation_t *h264_resend_find_generation(
    h264_resend_generation_t *ring, size_t cap, uint16_t region_id,
    uint32_t generation) {
    if (ring == NULL) {
        return NULL;
    }
    for (size_t i = 0; i < cap; i++) {
        if (ring[i].active && ring[i].region_id == region_id &&
            ring[i].generation == generation) {
            return &ring[i];
        }
    }
    return NULL;
}

size_t h264_resend_count_active(const h264_resend_generation_t *ring,
                                       size_t cap) {
    size_t count = 0;
    if (ring == NULL) {
        return 0;
    }
    for (size_t i = 0; i < cap; i++) {
        if (ring[i].active) {
            count++;
        }
    }
    return count;
}

size_t h264_resend_choose_slot(h264_resend_generation_t *ring, size_t cap,
                                      size_t target, uint64_t now_ns) {
    for (size_t i = 0; i < cap; i++) {
        if (!ring[i].active) {
            return i;
        }
    }

    size_t oldest_safe = cap;
    uint64_t oldest_safe_ns = UINT64_MAX;
    size_t oldest_any = 0;
    uint64_t oldest_any_ns = UINT64_MAX;
    size_t active = h264_resend_count_active(ring, cap);
    uint64_t repair_grace_ns = 750000000ULL;
    for (size_t i = 0; i < cap; i++) {
        if (ring[i].stored_ns < oldest_any_ns) {
            oldest_any_ns = ring[i].stored_ns;
            oldest_any = i;
        }
        int repair_recent =
            ring[i].repair_active &&
            now_ns - ring[i].last_feedback_ns < repair_grace_ns;
        if (!repair_recent &&
            (active >= target || now_ns - ring[i].stored_ns > repair_grace_ns)) {
            if (ring[i].stored_ns < oldest_safe_ns) {
                oldest_safe_ns = ring[i].stored_ns;
                oldest_safe = i;
            }
        }
    }
    return oldest_safe < cap ? oldest_safe : oldest_any;
}

h264_resend_generation_t *h264_resend_begin_generation(
    h264_resend_generation_t *ring, size_t cap, size_t target,
    uint16_t region_id, uint32_t generation, uint16_t chunk_count,
    int *evicted_repair_out) {
    if (evicted_repair_out != NULL) {
        *evicted_repair_out = 0;
    }
    if (ring == NULL || cap == 0 || chunk_count == 0 ||
        chunk_count > SHARP_VIDEO_REGION_MAX_CHUNKS) {
        return NULL;
    }
    uint64_t now_ns = shtp_now_ns();
    size_t slot = h264_resend_choose_slot(ring, cap, target, now_ns);
    if (evicted_repair_out != NULL && ring[slot].active &&
        ring[slot].repair_active) {
        *evicted_repair_out = 1;
    }
    h264_resend_generation_clear(&ring[slot]);
    ring[slot].chunks = calloc(chunk_count, sizeof(ring[slot].chunks[0]));
    if (ring[slot].chunks == NULL) {
        memset(&ring[slot], 0, sizeof(ring[slot]));
        return NULL;
    }
    ring[slot].active = 1u;
    ring[slot].region_id = region_id;
    ring[slot].generation = generation;
    ring[slot].chunk_count = chunk_count;
    ring[slot].stored_ns = now_ns;
    return &ring[slot];
}

int h264_resend_store_packet(h264_resend_generation_t *gen,
                                    uint16_t chunk_id,
                                    const uint8_t *packet, size_t len) {
    if (gen == NULL || packet == NULL || len == 0 ||
        chunk_id >= gen->chunk_count) {
        return -1;
    }
    uint8_t *copy = malloc(len);
    if (copy == NULL) {
        return -1;
    }
    memcpy(copy, packet, len);
    free(gen->chunks[chunk_id].packet);
    gen->chunks[chunk_id].packet = copy;
    gen->chunks[chunk_id].len = len;
    return 0;
}

void sharp_screen_send_signal_handler(int signo) {
    (void)signo;
    g_sharp_stop_requested = 1;
}

void h264_snap_large_envelope(sharp_m2_region_t *region,
                                     uint32_t stream_width,
                                     uint32_t stream_height) {
    if (region == NULL || stream_width == 0 || stream_height == 0) {
        return;
    }
    uint64_t area = (uint64_t)region->w * (uint64_t)region->h;
    uint64_t fullArea = (uint64_t)stream_width * (uint64_t)stream_height;
    if (fullArea > 0 && area * 100u >= fullArea * 45u) {
        region->x = 0;
        region->y = 0;
        region->w = stream_width;
        region->h = stream_height;
    }
}

int32_t h264_target_bitrate(uint32_t width, uint32_t height,
                                   uint32_t fps) {
    double factor = env_double_or_default("SHARP_H264_BITRATE_FACTOR", 0.48);
    double minRate = env_double_or_default("SHARP_H264_BITRATE_MIN", 2000000.0);
    double maxRate = env_double_or_default("SHARP_H264_BITRATE_MAX", 120000000.0);
    if (factor <= 0.0) {
        factor = 0.48;
    }
    if (minRate < 100000.0) {
        minRate = 100000.0;
    }
    if (maxRate < minRate) {
        maxRate = minRate;
    }
    double rate = (double)width * (double)height *
                  (double)(fps > 0 ? fps : 60u) * factor;
    rate = MAX(minRate, MIN(maxRate, rate));
    return (int32_t)rate;
}

int env_flag_enabled(const char *name) {
    const char *value = getenv(name);
    return value != NULL && value[0] != '\0' && strcmp(value, "0") != 0;
}

int env_flag_disabled(const char *name) {
    const char *value = getenv(name);
    return value != NULL && value[0] != '\0' && strcmp(value, "0") == 0;
}

uint8_t sharp_fec_group_count(uint16_t chunk_count) {
    if (chunk_count >= 64u) {
        return 8u;
    }
    if (chunk_count >= 8u) {
        return 4u;
    }
    return 1u;
}

uint8_t sharp_fec_group_for_chunk(uint16_t chunk_id,
                                         uint16_t chunk_count,
                                         uint8_t fec_g) {
    if (chunk_count == 0 || fec_g == 0) {
        return 0u;
    }
    uint32_t group = (((uint32_t)chunk_id + 1u) * fec_g - 1u) / chunk_count;
    return group < fec_g ? (uint8_t)group : (uint8_t)(fec_g - 1u);
}

double env_double_or_default(const char *name, double default_value) {
    const char *value = getenv(name);
    if (value == NULL || value[0] == '\0') {
        return default_value;
    }
    char *end = NULL;
    double parsed = strtod(value, &end);
    return end != value && isfinite(parsed) ? parsed : default_value;
}

void usage(FILE *stream) {
    fprintf(stream,
            "usage: m1-screen-send --target IP [--source IP] [--port PORT]\n"
            "                      [--width PX] [--height PX] [--duration SEC]\n"
            "                      [--fps FPS] [--payload-size BYTES]\n"
            "                      [--stats-interval SEC]\n"
            "                      [--initial-full-frames N]\n"
            "                      [--full-refresh-interval SEC]\n"
            "                      [--pacing-mbps MBPS]\n"
            "                      [--frame-log PATH]\n"
            "                      [--m2-log PATH]\n"
            "                      [--episode-log PATH]\n"
            "                      [--hybrid-h264]\n"
            "                      [--vslice-drop-every N]\n"
            "                      [--check-permission]\n"
            "                      [--request-permission]\n");
}

int parse_args(int argc, char **argv, screen_config_t *config) {
    memset(config, 0, sizeof(*config));
    config->port = SHTP_DEFAULT_PORT + 20u;
    config->width = 512;
    config->height = 320;
    config->duration = 5;
    config->stats_interval = 0;
    config->fps = 60;
    config->payload_size = 1200;
    config->initial_full_frames = 2;
    config->full_refresh_interval = 0.0;
    config->pacing_mbps = 120.0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--target") == 0 && i + 1 < argc) {
            config->target_ip = argv[++i];
        } else if (strcmp(argv[i], "--source") == 0 && i + 1 < argc) {
            config->source_ip = argv[++i];
        } else if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            if (shtp_parse_u32(argv[++i], 1, 65535, &config->port) != 0) {
                return -1;
            }
        } else if (strcmp(argv[i], "--width") == 0 && i + 1 < argc) {
            if (shtp_parse_u32(argv[++i], 64, 8192, &config->width) != 0) {
                return -1;
            }
        } else if (strcmp(argv[i], "--height") == 0 && i + 1 < argc) {
            if (shtp_parse_u32(argv[++i], 64, 8192, &config->height) != 0) {
                return -1;
            }
        } else if (strcmp(argv[i], "--duration") == 0 && i + 1 < argc) {
            if (shtp_parse_u32(argv[++i], 0, 3600, &config->duration) != 0) {
                return -1;
            }
        } else if (strcmp(argv[i], "--stats-interval") == 0 && i + 1 < argc) {
            if (shtp_parse_u32(argv[++i], 0, 3600, &config->stats_interval) != 0) {
                return -1;
            }
        } else if (strcmp(argv[i], "--fps") == 0 && i + 1 < argc) {
            if (shtp_parse_u32(argv[++i], 1, 120, &config->fps) != 0) {
                return -1;
            }
        } else if (strcmp(argv[i], "--payload-size") == 0 && i + 1 < argc) {
            if (shtp_parse_u32(argv[++i], 64, SHTP_MAX_DATAGRAM - SHTP_HEADER_BYTES,
                               &config->payload_size) != 0) {
                return -1;
            }
        } else if (strcmp(argv[i], "--initial-full-frames") == 0 && i + 1 < argc) {
            if (shtp_parse_u32(argv[++i], 0, 120, &config->initial_full_frames) != 0) {
                return -1;
            }
        } else if (strcmp(argv[i], "--full-refresh-interval") == 0 && i + 1 < argc) {
            if (shtp_parse_double(argv[++i], 0.0, 3600.0,
                                  &config->full_refresh_interval) != 0) {
                return -1;
            }
        } else if (strcmp(argv[i], "--pacing-mbps") == 0 && i + 1 < argc) {
            if (shtp_parse_double(argv[++i], 0.0, 1000.0, &config->pacing_mbps) != 0) {
                return -1;
            }
        } else if (strcmp(argv[i], "--frame-log") == 0 && i + 1 < argc) {
            config->frame_log_path = argv[++i];
        } else if (strcmp(argv[i], "--m2-log") == 0 && i + 1 < argc) {
            config->m2_log_path = argv[++i];
        } else if (strcmp(argv[i], "--episode-log") == 0 && i + 1 < argc) {
            config->episode_log_path = argv[++i];
        } else if (strcmp(argv[i], "--hybrid-h264") == 0) {
            config->hybrid_h264 = 1;
        } else if (strcmp(argv[i], "--vslice-drop-every") == 0 && i + 1 < argc) {
            if (shtp_parse_u32(argv[++i], 0, 1000000,
                               &config->vslice_drop_every) != 0) {
                return -1;
            }
        } else if (strcmp(argv[i], "--request-permission") == 0) {
            config->request_permission = 1;
        } else if (strcmp(argv[i], "--check-permission") == 0) {
            config->check_permission = 1;
        } else if (strcmp(argv[i], "--help") == 0) {
            usage(stdout);
            exit(0);
        } else {
            return -1;
        }
    }

    return (config->check_permission || config->target_ip != NULL) ? 0 : -1;
}

void h264_output_callback(void *outputCallbackRefCon,
                                 void *sourceFrameRefCon, OSStatus status,
                                 VTEncodeInfoFlags infoFlags,
                                 CMSampleBufferRef sampleBuffer) {
    (void)infoFlags;
    SharpScreenSender *sender = (__bridge SharpScreenSender *)outputCallbackRefCon;
    h264_sample_context_t *context = (h264_sample_context_t *)sourceFrameRefCon;
    if (context != NULL) {
        context->callback_ns = shtp_now_ns();
        [sender recordVtCallbackForFrameId:context->generation
                                 timestamp:context->callback_ns];
    }
    if (status == noErr && sampleBuffer != NULL &&
        CMSampleBufferDataIsReady(sampleBuffer)) {
        CFRetain(sampleBuffer);
        dispatch_queue_t outputQueue = sender.h264OutputQueue;
        if (outputQueue != nil) {
            dispatch_async(outputQueue, ^{
              [sender handleEncodedSample:sampleBuffer context:context];
              CFRelease(sampleBuffer);
            });
            return;
        }
        [sender handleEncodedSample:sampleBuffer context:context];
        CFRelease(sampleBuffer);
    } else {
        if (sender.h264EncodeInFlight > 0) {
            sender.h264EncodeInFlight--;
        }
        if (context != NULL &&
            context->region_id == SHARP_H264_FULLFRAME_ID &&
            sender.fullFrameEncodeInFlight > 0) {
            sender.fullFrameEncodeInFlight--;
        }
        sender.h264EncodeFailures++;
        if (context != NULL) {
            if (context->retained_pixel_buffer != NULL) {
                CVPixelBufferRelease(context->retained_pixel_buffer);
            }
            free(context->motion_mask);
            free(context);
        }
    }
}

void write_be32(uint8_t *p, uint32_t value) {
    p[0] = (uint8_t)(value >> 24u);
    p[1] = (uint8_t)(value >> 16u);
    p[2] = (uint8_t)(value >> 8u);
    p[3] = (uint8_t)value;
}

int compare_u64(const void *a, const void *b) {
    uint64_t av = *(const uint64_t *)a;
    uint64_t bv = *(const uint64_t *)b;
    return (av > bv) - (av < bv);
}

uint64_t percentile_u64(const uint64_t *samples, uint32_t count,
                               double percentile) {
    if (samples == NULL || count == 0) {
        return 0;
    }
    uint64_t *copy = malloc((size_t)count * sizeof(copy[0]));
    if (copy == NULL) {
        return 0;
    }
    memcpy(copy, samples, (size_t)count * sizeof(copy[0]));
    qsort(copy, count, sizeof(copy[0]), compare_u64);
    double pos = percentile * (double)(count - 1u);
    uint32_t index = (uint32_t)llround(pos);
    if (index >= count) {
        index = count - 1u;
    }
    uint64_t value = copy[index];
    free(copy);
    return value;
}

uint64_t sharp_mach_absolute_to_ns(uint64_t ticks) {
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) {
        mach_timebase_info(&timebase);
    }
    if (timebase.denom == 0) {
        return 0;
    }
    return (uint64_t)((__uint128_t)ticks * timebase.numer / timebase.denom);
}

uint64_t sharp_screen_source_time_ns(CMSampleBufferRef sampleBuffer,
                                            uint64_t callbackNs) {
    CFArrayRef attachments =
        CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (attachments != NULL && CFArrayGetCount(attachments) > 0) {
        NSDictionary *info =
            (__bridge NSDictionary *)CFArrayGetValueAtIndex(attachments, 0);
        NSNumber *displayTime = info[SCStreamFrameInfoDisplayTime];
        if (displayTime != nil) {
            uint64_t sourceAbsoluteNs =
                sharp_mach_absolute_to_ns(displayTime.unsignedLongLongValue);
            uint64_t nowAbsoluteNs =
                sharp_mach_absolute_to_ns(mach_absolute_time());
            if (sourceAbsoluteNs != 0) {
                /* SCK can deliver a surface before its scheduled display time.
                 * Preserve that timestamp across clock domains instead of
                 * dropping these (usually fastest) frames from latency data. */
                if (sourceAbsoluteNs > nowAbsoluteNs) {
                    uint64_t leadNs = sourceAbsoluteNs - nowAbsoluteNs;
                    if (leadNs < 1000000000ULL &&
                        callbackNs <= UINT64_MAX - leadNs) {
                        return callbackNs + leadNs;
                    }
                } else {
                    uint64_t ageNs = nowAbsoluteNs - sourceAbsoluteNs;
                    if (ageNs < 1000000000ULL && callbackNs >= ageNs) {
                        return callbackNs - ageNs;
                    }
                }
            }
        }
    }
    return 0;
}

void rolling_metric_add(sharp_rolling_metric_t *metric,
                               uint64_t observedNs, uint64_t valueNs) {
    if (metric == NULL || observedNs == 0) {
        return;
    }
    uint32_t slot = metric->next++ % SHARP_ROLLING_SAMPLE_CAP;
    metric->observed_ns[slot] = observedNs;
    metric->value_ns[slot] = valueNs;
    if (metric->count < SHARP_ROLLING_SAMPLE_CAP) {
        metric->count++;
    }
}

uint64_t rolling_metric_percentile(const sharp_rolling_metric_t *metric,
                                          uint64_t nowNs, uint64_t windowNs,
                                          double percentile,
                                          uint32_t *countOut) {
    if (countOut != NULL) {
        *countOut = 0;
    }
    if (metric == NULL || metric->count == 0 || nowNs == 0) {
        return 0;
    }
    uint64_t values[SHARP_ROLLING_SAMPLE_CAP];
    uint32_t count = 0;
    uint32_t available = MIN(metric->count, SHARP_ROLLING_SAMPLE_CAP);
    for (uint32_t i = 0; i < available; i++) {
        uint64_t observedNs = metric->observed_ns[i];
        if (observedNs == 0 || observedNs > nowNs ||
            nowNs - observedNs > windowNs) {
            continue;
        }
        values[count++] = metric->value_ns[i];
    }
    if (countOut != NULL) {
        *countOut = count;
    }
    return percentile_u64(values, count, percentile);
}

double rolling_metric_rate(const sharp_rolling_metric_t *metric,
                                  uint64_t nowNs, uint64_t windowNs) {
    if (metric == NULL || metric->count == 0 || nowNs == 0 || windowNs == 0) {
        return 0.0;
    }
    uint64_t total = 0;
    uint64_t oldestNs = nowNs;
    uint32_t available = MIN(metric->count, SHARP_ROLLING_SAMPLE_CAP);
    for (uint32_t i = 0; i < available; i++) {
        uint64_t observedNs = metric->observed_ns[i];
        if (observedNs == 0 || observedNs > nowNs ||
            nowNs - observedNs > windowNs) {
            continue;
        }
        total += metric->value_ns[i];
        oldestNs = MIN(oldestNs, observedNs);
    }
    if (total == 0) {
        return 0.0;
    }
    uint64_t durationNs = nowNs - oldestNs;
    durationNs = MAX(durationNs, 1000000000ULL);
    durationNs = MIN(durationNs, windowNs);
    return (double)total * 1000000000.0 / (double)durationNs;
}

unsigned int sck_status_bucket(NSInteger status) {
    if (status == SCFrameStatusComplete) {
        return 0u;
    }
    if (status == SCFrameStatusIdle) {
        return 1u;
    }
    if (status == SCFrameStatusBlank) {
        return 2u;
    }
    if (status == SCFrameStatusSuspended) {
        return 3u;
    }
    if (status == SCFrameStatusStarted) {
        return 4u;
    }
    if (status == SCFrameStatusStopped) {
        return 5u;
    }
    return SHARP_SCK_STATUS_BUCKETS;
}

int region_contains_tile(const sharp_m2_region_t *region, uint32_t width,
                                uint32_t height, uint16_t tile_id) {
    sharp_tile_rect_t rect;
    if (region == NULL ||
        sharp_tile_rect_for_id(width, height, tile_id, &rect) != 0) {
        return 0;
    }
    return rect.x < region->x + region->w && rect.x + rect.w > region->x &&
           rect.y < region->y + region->h && rect.y + rect.h > region->y;
}

uint64_t rect_intersection_area_u64(uint32_t ax, uint32_t ay,
                                           uint32_t aw, uint32_t ah,
                                           uint32_t bx, uint32_t by,
                                           uint32_t bw, uint32_t bh) {
    uint32_t ax1 = ax + aw;
    uint32_t ay1 = ay + ah;
    uint32_t bx1 = bx + bw;
    uint32_t by1 = by + bh;
    uint32_t ix0 = MAX(ax, bx);
    uint32_t iy0 = MAX(ay, by);
    uint32_t ix1 = MIN(ax1, bx1);
    uint32_t iy1 = MIN(ay1, by1);
    if (ix1 <= ix0 || iy1 <= iy0) {
        return 0;
    }
    return (uint64_t)(ix1 - ix0) * (uint64_t)(iy1 - iy0);
}

uint64_t rect_center_distance2_u64(uint32_t ax, uint32_t ay,
                                          uint32_t aw, uint32_t ah,
                                          uint32_t bx, uint32_t by,
                                          uint32_t bw, uint32_t bh) {
    int64_t acx = (int64_t)ax * 2 + (int64_t)aw;
    int64_t acy = (int64_t)ay * 2 + (int64_t)ah;
    int64_t bcx = (int64_t)bx * 2 + (int64_t)bw;
    int64_t bcy = (int64_t)by * 2 + (int64_t)bh;
    int64_t dx = acx - bcx;
    int64_t dy = acy - bcy;
    return (uint64_t)(dx * dx + dy * dy);
}

void h264_region_envelope(const sharp_m2_region_t *region,
                                 uint32_t stream_width, uint32_t stream_height,
                                 sharp_m2_region_t *out) {
    if (region == NULL || out == NULL) {
        return;
    }
    *out = *region;
    uint32_t pad_x = MAX(256u, region->w);
    uint32_t pad_y = MAX(192u, region->h);
    uint32_t x0 = region->x > pad_x ? region->x - pad_x : 0u;
    uint32_t y0 = region->y > pad_y ? region->y - pad_y : 0u;
    uint32_t x1 = region->x + region->w + pad_x;
    uint32_t y1 = region->y + region->h + pad_y;
    if (x1 > stream_width) x1 = stream_width;
    if (y1 > stream_height) y1 = stream_height;

    x0 &= ~15u;
    y0 &= ~15u;
    x1 = (x1 + 15u) & ~15u;
    y1 = (y1 + 15u) & ~15u;
    if (x1 > stream_width) x1 = stream_width;
    if (y1 > stream_height) y1 = stream_height;
    if (x1 <= x0 || y1 <= y0) {
        return;
    }
    out->x = x0;
    out->y = y0;
    out->w = x1 - x0;
    out->h = y1 - y0;
}

void insert_selected_region(sharp_m2_region_t *selected,
                                   uint64_t *selected_scores,
                                   size_t *selected_count,
                                   const sharp_m2_region_t *candidate,
                                   uint64_t score) {
    if (selected == NULL || selected_count == NULL || candidate == NULL ||
        candidate->w == 0 || candidate->h == 0) {
        return;
    }
    size_t pos = *selected_count;
    for (size_t i = 0; i < *selected_count; i++) {
        if (score > selected_scores[i] ||
            (score == selected_scores[i] && candidate->id < selected[i].id)) {
            pos = i;
            break;
        }
    }
    if (pos >= SHARP_H264_MAX_ACTIVE_REGIONS &&
        *selected_count >= SHARP_H264_MAX_ACTIVE_REGIONS) {
        return;
    }
    size_t limit = *selected_count < SHARP_H264_MAX_ACTIVE_REGIONS
                       ? *selected_count
                       : SHARP_H264_MAX_ACTIVE_REGIONS - 1u;
    for (size_t i = limit; i > pos; i--) {
        selected[i] = selected[i - 1u];
        selected_scores[i] = selected_scores[i - 1u];
    }
    selected[pos] = *candidate;
    selected_scores[pos] = score;
    if (*selected_count < SHARP_H264_MAX_ACTIVE_REGIONS) {
        (*selected_count)++;
    }
}

int rect_from_metadata_value(id value, NSRect *rect_out) {
    if (rect_out == NULL) {
        return 0;
    }
    if ([value isKindOfClass:[NSValue class]]) {
        *rect_out = [value rectValue];
        return 1;
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        CGRect cgRect = CGRectZero;
        if (CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)value,
                                                   &cgRect)) {
            *rect_out = NSRectFromCGRect(cgRect);
            return 1;
        }
    }
    return 0;
}

NSRect rect_from_info(NSDictionary *info, SCStreamFrameInfo key) {
    id value = info[key];
    NSRect rect = NSZeroRect;
    (void)rect_from_metadata_value(value, &rect);
    return rect;
}

size_t collect_dirty_rects(NSDictionary *info, uint32_t width, uint32_t height,
                                  sharp_dirty_rect_t *out, size_t out_cap,
                                  int *metadata_present, int *scaled_out,
                                  uint64_t *clipped_out) {
    if (metadata_present != NULL) {
        *metadata_present = 0;
    }
    if (info == nil || out == NULL || out_cap == 0) {
        return 0;
    }

    NSArray *values = info[SCStreamFrameInfoDirtyRects];
    if (values == nil || ![values isKindOfClass:[NSArray class]]) {
        return 0;
    }
    if (metadata_present != NULL) {
        *metadata_present = 1;
    }
    if (scaled_out != NULL) {
        *scaled_out = 0;
    }
    if (clipped_out != NULL) {
        *clipped_out = 0;
    }

    CGFloat maxX = 0.0;
    CGFloat maxY = 0.0;
    for (id value in values) {
        NSRect rect = NSZeroRect;
        if (!rect_from_metadata_value(value, &rect)) {
            continue;
        }
        maxX = MAX(maxX, NSMaxX(rect));
        maxY = MAX(maxY, NSMaxY(rect));
    }

    NSNumber *contentScaleNumber = info[SCStreamFrameInfoContentScale];
    CGFloat contentScale =
        contentScaleNumber != nil ? (CGFloat)contentScaleNumber.doubleValue : 0.0;
    NSRect contentRect = rect_from_info(info, SCStreamFrameInfoContentRect);
    int scaleFromSource =
        (maxX > (CGFloat)width || maxY > (CGFloat)height) && contentScale > 0.0;
    if (scaleFromSource && scaled_out != NULL) {
        *scaled_out = 1;
    }

    size_t count = 0;
    for (id value in values) {
        NSRect rect = NSZeroRect;
        if (!rect_from_metadata_value(value, &rect)) {
            continue;
        }
        if (rect.size.width <= 0.0 || rect.size.height <= 0.0) {
            continue;
        }
        if (scaleFromSource) {
            rect.origin.x = contentRect.origin.x + rect.origin.x * contentScale;
            rect.origin.y = contentRect.origin.y + rect.origin.y * contentScale;
            rect.size.width *= contentScale;
            rect.size.height *= contentScale;
        }

        CGFloat minXf = floor(NSMinX(rect));
        CGFloat minYf = floor(NSMinY(rect));
        CGFloat maxXf = ceil(NSMaxX(rect));
        CGFloat maxYf = ceil(NSMaxY(rect));
        if (maxXf <= 0.0 || maxYf <= 0.0 ||
            minXf >= (CGFloat)width || minYf >= (CGFloat)height) {
            continue;
        }

        if (minXf < 0.0) {
            minXf = 0.0;
            if (clipped_out != NULL) {
                (*clipped_out)++;
            }
        }
        if (minYf < 0.0) {
            minYf = 0.0;
            if (clipped_out != NULL) {
                (*clipped_out)++;
            }
        }
        if (maxXf > (CGFloat)width) {
            maxXf = (CGFloat)width;
            if (clipped_out != NULL) {
                (*clipped_out)++;
            }
        }
        if (maxYf > (CGFloat)height) {
            maxYf = (CGFloat)height;
            if (clipped_out != NULL) {
                (*clipped_out)++;
            }
        }

        if (count < out_cap && maxXf > minXf && maxYf > minYf) {
            out[count].x = (uint32_t)minXf;
            out[count].y = (uint32_t)minYf;
            out[count].w = (uint32_t)(maxXf - minXf);
            out[count].h = (uint32_t)(maxYf - minYf);
            count++;
        }
    }
    return count;
}
