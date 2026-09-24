#import "Internal.h"
uint64_t sharp_mach_absolute_to_ns(uint64_t ticks) {
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) {
        mach_timebase_info(&timebase);
    }
    return (uint64_t)((__uint128_t)ticks * timebase.numer / timebase.denom);
}

void dirty_bounds_reset(sharp_dirty_bounds_t *bounds) {
    if (bounds != NULL) {
        memset(bounds, 0, sizeof(*bounds));
    }
}

void dirty_bounds_add(sharp_dirty_bounds_t *bounds, uint32_t x, uint32_t y,
                             uint32_t w, uint32_t h, uint32_t limit_w,
                             uint32_t limit_h) {
    if (bounds == NULL || w == 0 || h == 0 || x >= limit_w || y >= limit_h) {
        return;
    }
    if (x + w > limit_w) {
        w = limit_w - x;
    }
    if (y + h > limit_h) {
        h = limit_h - y;
    }
    if (!bounds->valid) {
        bounds->x = x;
        bounds->y = y;
        bounds->w = w;
        bounds->h = h;
        bounds->valid = 1u;
        return;
    }
    uint32_t x0 = MIN(bounds->x, x);
    uint32_t y0 = MIN(bounds->y, y);
    uint32_t x1 = MAX(bounds->x + bounds->w, x + w);
    uint32_t y1 = MAX(bounds->y + bounds->h, y + h);
    bounds->x = x0;
    bounds->y = y0;
    bounds->w = x1 - x0;
    bounds->h = y1 - y0;
}

void framebuf_copy_rect(sharp_framebuf_t *dst, const sharp_framebuf_t *src,
                               const sharp_dirty_bounds_t *bounds) {
    if (dst == NULL || src == NULL || bounds == NULL || !bounds->valid ||
        dst->pixels == NULL || src->pixels == NULL) {
        return;
    }
    uint32_t x = bounds->x;
    uint32_t y = bounds->y;
    uint32_t w = bounds->w;
    uint32_t h = bounds->h;
    if (x >= dst->width || y >= dst->height || x >= src->width || y >= src->height) {
        return;
    }
    if (x + w > dst->width) {
        w = dst->width - x;
    }
    if (x + w > src->width) {
        w = src->width - x;
    }
    if (y + h > dst->height) {
        h = dst->height - y;
    }
    if (y + h > src->height) {
        h = src->height - y;
    }
    for (uint32_t row = 0; row < h; row++) {
        memcpy(dst->pixels + (size_t)(y + row) * dst->stride + (size_t)x * 4u,
               src->pixels + (size_t)(y + row) * src->stride + (size_t)x * 4u,
               (size_t)w * 4u);
    }
}

int compare_u64_values(const void *a, const void *b) {
    uint64_t av = *(const uint64_t *)a;
    uint64_t bv = *(const uint64_t *)b;
    return (av > bv) - (av < bv);
}

void usage(FILE *stream) {
    fprintf(stream,
            "usage: m1-display-recv --bind IP [--port PORT] [--width PX] [--height PX]\n"
            "                       [--rcvbuf BYTES] [--scale N]\n"
            "                       [--window-width PX --window-height PX]\n"
            "                       [--snapshot PATH] [--presenter-snapshot PATH]\n"
            "                       [--presenter-snapshot-dir DIR]\n"
            "                       [--presenter-snapshot-every N]\n"
            "                       [--presenter-snapshot-max N]\n"
            "                       [--frame-log PATH] [--cursor PATH] [--cursor-dir PATH]\n"
            "                       [--video-texture-mode bgra|decoder|nv12]\n"
            "                       [--bake-video-handoff]\n"
            "                       [--fullscreen] [--keep-open]\n"
            "                       [--expect-synthetic]\n");
}

const char *video_texture_mode_name(sharp_video_texture_mode_t mode) {
    switch (mode) {
    case SHARP_VIDEO_TEXTURE_BGRA:
        return "bgra";
    case SHARP_VIDEO_TEXTURE_DECODER:
        return "decoder";
    case SHARP_VIDEO_TEXTURE_NV12:
        return "nv12";
    }
    return "unknown";
}

int parse_video_texture_mode(const char *text,
                                    sharp_video_texture_mode_t *mode) {
    if (text == NULL || mode == NULL) {
        return -1;
    }
    if (strcmp(text, "bgra") == 0) {
        *mode = SHARP_VIDEO_TEXTURE_BGRA;
        return 0;
    }
    if (strcmp(text, "decoder") == 0) {
        *mode = SHARP_VIDEO_TEXTURE_DECODER;
        return 0;
    }
    if (strcmp(text, "nv12") == 0 || strcmp(text, "yuv") == 0) {
        *mode = SHARP_VIDEO_TEXTURE_NV12;
        return 0;
    }
    return -1;
}

uint8_t clamp_u8_int(int value) {
    if (value < 0) {
        return 0;
    }
    if (value > 255) {
        return 255;
    }
    return (uint8_t)value;
}

sharp_nv12_matrix_t nv12_matrix_for_pixel_buffer(CVPixelBufferRef pixelBuffer) {
    if (pixelBuffer != NULL) {
        CFTypeRef attachment = CVBufferGetAttachment(
            pixelBuffer, kCVImageBufferYCbCrMatrixKey, NULL);
        if (attachment != NULL &&
            CFEqual(attachment, kCVImageBufferYCbCrMatrix_ITU_R_709_2)) {
            return SHARP_NV12_MATRIX_BT709;
        }
        if (attachment != NULL &&
            CFEqual(attachment, kCVImageBufferYCbCrMatrix_ITU_R_601_4)) {
            return SHARP_NV12_MATRIX_BT601;
        }
    }
    /* Sharp's encoder is always tagged BT.709. Some Intel decoders omit the
     * attachment on individual output buffers; treating absence as BT.601
     * makes the matrix visibly jump from frame to frame during motion. */
    return SHARP_NV12_MATRIX_BT709;
}

void nv12_video_range_to_bgra(uint8_t y, uint8_t u, uint8_t v,
                                     sharp_nv12_matrix_t matrix,
                                     uint8_t *bgra) {
    int c = (int)y - 16;
    int d = (int)u - 128;
    int e = (int)v - 128;
    if (c < 0) {
        c = 0;
    }
    int r = matrix == SHARP_NV12_MATRIX_BT709
                ? (298 * c + 459 * e + 128) >> 8
                : (298 * c + 409 * e + 128) >> 8;
    int g = matrix == SHARP_NV12_MATRIX_BT709
                ? (298 * c - 54 * d - 136 * e + 128) >> 8
                : (298 * c - 100 * d - 208 * e + 128) >> 8;
    int b = matrix == SHARP_NV12_MATRIX_BT709
                ? (298 * c + 540 * d + 128) >> 8
                : (298 * c + 516 * d + 128) >> 8;
    bgra[0] = clamp_u8_int(b);
    bgra[1] = clamp_u8_int(g);
    bgra[2] = clamp_u8_int(r);
    bgra[3] = 255;
}

NSSize fit_size_preserving_aspect(NSSize streamSize, NSSize maxSize) {
    if (streamSize.width <= 0.0 || streamSize.height <= 0.0 ||
        maxSize.width <= 0.0 || maxSize.height <= 0.0) {
        return NSMakeSize(1.0, 1.0);
    }
    CGFloat scale = MIN(maxSize.width / streamSize.width,
                        maxSize.height / streamSize.height);
    return NSMakeSize(floor(streamSize.width * scale),
                      floor(streamSize.height * scale));
}

GLuint compile_shader(GLenum type, const char *source) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    return shader;
}

CVReturn sharp_display_link_callback(CVDisplayLinkRef displayLink,
                                            const CVTimeStamp *now,
                                            const CVTimeStamp *outputTime,
                                            CVOptionFlags flagsIn,
                                            CVOptionFlags *flagsOut,
                                            void *displayLinkContext) {
    (void)displayLink;
    (void)now;
    (void)flagsIn;
    (void)flagsOut;
    SharpDisplayApp *app = (__bridge SharpDisplayApp *)displayLinkContext;
    [app recordDisplayLinkOutputTime:outputTime];
    [app scheduleRenderTick];
    return kCVReturnSuccess;
}

uint32_t read_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24u) | ((uint32_t)p[1] << 16u) |
           ((uint32_t)p[2] << 8u) | (uint32_t)p[3];
}

void h264_decode_callback(void *decompressionOutputRefCon,
                                 void *sourceFrameRefCon, OSStatus status,
                                 VTDecodeInfoFlags infoFlags,
                                 CVImageBufferRef imageBuffer,
                                 CMTime presentationTimeStamp,
                                 CMTime presentationDuration) {
    (void)infoFlags;
    (void)presentationTimeStamp;
    (void)presentationDuration;
    sharp_h264_decode_context_t *context =
        (sharp_h264_decode_context_t *)sourceFrameRefCon;
    SharpDisplayApp *app = (__bridge SharpDisplayApp *)decompressionOutputRefCon;
    if (status != noErr || imageBuffer == NULL || sourceFrameRefCon == NULL) {
        if (app != nil && context != NULL) {
            [app completeVideoDecodeArrival:context->arrival_seq];
        }
        free(context);
        return;
    }
    uint64_t decodeCallbackNs = shtp_now_ns();
    [app recordH264DecodeCallbackSubmitNs:context->submit_ns];
    [app copyDecodedPixelBuffer:(CVPixelBufferRef)imageBuffer
                         header:&context->header
               finalPacketRxNs:context->final_packet_rx_ns
              decodeCallbackNs:decodeCallbackNs session:context->session_id];
    [app completeVideoDecodeArrival:context->arrival_seq];
    free(context);
}

void *sharp_socket_thread_main(void *arg) {
    @autoreleasepool {
        [(__bridge SharpDisplayApp *)arg socketThreadMain];
    }
    return NULL;
}

void *sharp_video_thread_main(void *arg) {
    @autoreleasepool {
        [(__bridge SharpDisplayApp *)arg videoThreadMain];
    }
    return NULL;
}

void *sharp_tile_thread_main(void *arg) {
    @autoreleasepool {
        [(__bridge SharpDisplayApp *)arg tileThreadMain];
    }
    return NULL;
}

int parse_args(int argc, char **argv, display_config_t *config) {
    memset(config, 0, sizeof(*config));
    config->port = SHTP_DEFAULT_PORT + 10u;
    config->width = 512;
    config->height = 320;
    config->rcvbuf = 128 * 1024 * 1024;
    config->video_texture_mode = SHARP_VIDEO_TEXTURE_NV12;
    config->net_threads = 1;
    config->recvmsg_x = 1;
    config->net_drain_packet_budget = SHARP_NET_DRAIN_PACKET_BUDGET_DEFAULT;
    config->net_drain_time_budget_ns = SHARP_NET_DRAIN_TIME_BUDGET_NS_DEFAULT;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--bind") == 0 && i + 1 < argc) {
            config->bind_ip = argv[++i];
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
        } else if (strcmp(argv[i], "--rcvbuf") == 0 && i + 1 < argc) {
            if (shtp_parse_u32(argv[++i], 65536, 128 * 1024 * 1024, &config->rcvbuf) != 0) {
                return -1;
            }
        } else if (strcmp(argv[i], "--scale") == 0 && i + 1 < argc) {
            if (shtp_parse_u32(argv[++i], 1, 8, &config->scale) != 0) {
                return -1;
            }
        } else if (strcmp(argv[i], "--window-width") == 0 && i + 1 < argc) {
            if (shtp_parse_u32(argv[++i], 64, 16384, &config->window_width) != 0) {
                return -1;
            }
        } else if (strcmp(argv[i], "--window-height") == 0 && i + 1 < argc) {
            if (shtp_parse_u32(argv[++i], 64, 16384, &config->window_height) != 0) {
                return -1;
            }
        } else if (strcmp(argv[i], "--snapshot") == 0 && i + 1 < argc) {
            config->snapshot_path = argv[++i];
        } else if (strcmp(argv[i], "--presenter-snapshot") == 0 &&
                   i + 1 < argc) {
            config->presenter_snapshot_path = argv[++i];
        } else if (strcmp(argv[i], "--presenter-snapshot-dir") == 0 &&
                   i + 1 < argc) {
            config->presenter_snapshot_dir = argv[++i];
        } else if (strcmp(argv[i], "--presenter-snapshot-every") == 0 &&
                   i + 1 < argc) {
            if (shtp_parse_u32(argv[++i], 1, 10000,
                               &config->presenter_snapshot_every) != 0) {
                return -1;
            }
        } else if (strcmp(argv[i], "--presenter-snapshot-max") == 0 &&
                   i + 1 < argc) {
            if (shtp_parse_u32(argv[++i], 0, 10000,
                               &config->presenter_snapshot_max) != 0) {
                return -1;
            }
        } else if (strcmp(argv[i], "--frame-log") == 0 && i + 1 < argc) {
            config->frame_log_path = argv[++i];
        } else if (strcmp(argv[i], "--cursor") == 0 && i + 1 < argc) {
            config->cursor_path = argv[++i];
        } else if (strcmp(argv[i], "--cursor-dir") == 0 && i + 1 < argc) {
            config->cursor_dir = argv[++i];
        } else if (strcmp(argv[i], "--video-texture-mode") == 0 &&
                   i + 1 < argc) {
            if (parse_video_texture_mode(argv[++i],
                                         &config->video_texture_mode) != 0) {
                return -1;
            }
        } else if (strcmp(argv[i], "--bake-video-handoff") == 0) {
            config->bake_video_handoff = 1;
        } else if (strcmp(argv[i], "--fullscreen") == 0) {
            config->fullscreen = 1;
        } else if (strcmp(argv[i], "--keep-open") == 0) {
            config->keep_open = 1;
        } else if (strcmp(argv[i], "--check-compatibility") == 0) {
            config->check_compatibility = 1;
        } else if (strcmp(argv[i], "--expect-synthetic") == 0) {
            config->expect_synthetic = 1;
        } else if (strcmp(argv[i], "--help") == 0) {
            usage(stdout);
            exit(0);
        } else {
            return -1;
        }
    }

    return config->bind_ip != NULL || config->check_compatibility ? 0 : -1;
}
