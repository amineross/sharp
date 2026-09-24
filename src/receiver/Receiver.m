#import "Internal.h"

int main(int argc, char **argv) {
    display_config_t config;
    if (parse_args(argc, argv, &config) != 0) {
        usage(stderr);
        return 2;
    }
    if (config.check_compatibility) {
        @autoreleasepool {
            NSOpenGLPixelFormatAttribute attrs[] = {
                NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersion3_2Core,
                NSOpenGLPFAAccelerated, 0,
            };
            NSOpenGLPixelFormat *format =
                [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];
            int gl32 = format != nil;
            int h264 = VTIsHardwareDecodeSupported(kCMVideoCodecType_H264);
            fprintf(stdout, "sharp-compat renderer_gl32=%d h264_hw_decode=%d\n",
                    gl32, h264);
            return gl32 ? 0 : 4;
        }
    }
    const char *bakeEnv = getenv("VIDEO_BAKE_HANDOFF");
    if (bakeEnv != NULL && bakeEnv[0] != '\0' && strcmp(bakeEnv, "0") != 0) {
        config.bake_video_handoff = 1;
    }
    const char *netThreadsEnv = getenv("SHARP_NET_THREADS");
    if (netThreadsEnv != NULL && netThreadsEnv[0] != '\0') {
        config.net_threads = strcmp(netThreadsEnv, "0") != 0;
    }
    const char *recvmsgXEnv = getenv("SHARP_RECVMSG_X");
    if (recvmsgXEnv != NULL && recvmsgXEnv[0] != '\0') {
        config.recvmsg_x = strcmp(recvmsgXEnv, "0") != 0;
    }
    const char *drainPacketEnv = getenv("SHARP_NET_DRAIN_PACKET_BUDGET");
    if (drainPacketEnv != NULL && drainPacketEnv[0] != '\0') {
        unsigned int value = 0;
        if (shtp_parse_u32(drainPacketEnv, 1, 65535, &value) == 0) {
            config.net_drain_packet_budget = value;
        }
    }
    const char *drainTimeEnv = getenv("SHARP_NET_DRAIN_TIME_BUDGET_NS");
    if (drainTimeEnv != NULL && drainTimeEnv[0] != '\0') {
        char *end = NULL;
        errno = 0;
        unsigned long long value = strtoull(drainTimeEnv, &end, 10);
        if (errno == 0 && end != drainTimeEnv && *end == '\0' &&
            value > 0 && value <= 1000000000ULL) {
            config.net_drain_time_budget_ns = (uint64_t)value;
        }
    }

    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        SharpDisplayApp *delegate = [[SharpDisplayApp alloc] init];
        delegate.config = config;
        delegate.fd = -1;
        [app setDelegate:delegate];
        [app run];
    }

    return 0;
}
