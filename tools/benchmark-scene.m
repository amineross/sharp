#import <Cocoa/Cocoa.h>
#import <CoreVideo/CoreVideo.h>

#include "sharp/shtp_net.h"

#include <math.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

typedef struct activity_config {
    unsigned int duration;
    unsigned int motion_duration;
    unsigned int fps;
    unsigned int width;
    unsigned int height;
    const char *mode;
    const char *driver;
    int fullscreen;
    int activate_each_frame;
    const char *trace_log_path;
    const char *start_file_path;
    unsigned int display_id;
} activity_config_t;

@class ActivityApp;

static CVReturn activity_display_link_callback(CVDisplayLinkRef displayLink,
                                               const CVTimeStamp *now,
                                               const CVTimeStamp *outputTime,
                                               CVOptionFlags flagsIn,
                                               CVOptionFlags *flagsOut,
                                               void *displayLinkContext);

static int parse_args(int argc, char **argv, activity_config_t *config) {
    memset(config, 0, sizeof(*config));
    config->duration = 10;
    config->motion_duration = 0;
    config->fps = 60;
    config->width = 640;
    config->height = 360;
    config->mode = "rects";
    config->driver = "timer";
    config->activate_each_frame = 1;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--duration") == 0 && i + 1 < argc) {
            if (shtp_parse_u32(argv[++i], 1, 3600, &config->duration) != 0) {
                return -1;
            }
        } else if (strcmp(argv[i], "--motion-duration") == 0 && i + 1 < argc) {
            if (shtp_parse_u32(argv[++i], 1, 3600, &config->motion_duration) != 0) {
                return -1;
            }
        } else if (strcmp(argv[i], "--fps") == 0 && i + 1 < argc) {
            if (shtp_parse_u32(argv[++i], 1, 120, &config->fps) != 0) {
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
        } else if (strcmp(argv[i], "--mode") == 0 && i + 1 < argc) {
            config->mode = argv[++i];
            if (strcmp(config->mode, "quality") != 0 &&
                strcmp(config->mode, "rects") != 0 &&
                strcmp(config->mode, "broad") != 0 &&
                strcmp(config->mode, "colors") != 0 &&
                strcmp(config->mode, "pages") != 0) {
                return -1;
            }
        } else if (strcmp(argv[i], "--driver") == 0 && i + 1 < argc) {
            config->driver = argv[++i];
            if (strcmp(config->driver, "timer") != 0 &&
                strcmp(config->driver, "displaylink") != 0) {
                return -1;
            }
        } else if (strcmp(argv[i], "--fullscreen") == 0) {
            config->fullscreen = 1;
        } else if (strcmp(argv[i], "--no-frame-activate") == 0) {
            config->activate_each_frame = 0;
        } else if (strcmp(argv[i], "--activate-each-frame") == 0) {
            config->activate_each_frame = 1;
        } else if (strcmp(argv[i], "--trace-log") == 0 && i + 1 < argc) {
            config->trace_log_path = argv[++i];
        } else if (strcmp(argv[i], "--start-file") == 0 && i + 1 < argc) {
            config->start_file_path = argv[++i];
        } else if (strcmp(argv[i], "--display-id") == 0 && i + 1 < argc) {
            if (shtp_parse_u32(argv[++i], 1, UINT32_MAX,
                               &config->display_id) != 0) {
                return -1;
            }
        } else {
            return -1;
        }
    }
    return 0;
}

@interface ActivityView : NSView
@property(nonatomic, assign) uint64_t tick;
@property(nonatomic, assign) uint64_t lastLoggedTick;
@property(nonatomic, assign) uint64_t drawCount;
@property(nonatomic, assign) FILE *traceLog;
@property(nonatomic, assign) BOOL qualityMode;
@property(nonatomic, assign) BOOL broadMode;
@property(nonatomic, assign) BOOL colorsMode;
@property(nonatomic, assign) BOOL pagesMode;
@property(nonatomic, strong) NSImage *pageImage;
@end

@implementation ActivityView

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    _drawCount++;
    [[NSColor colorWithCalibratedWhite:0.08 alpha:1.0] setFill];
    NSRectFill(self.bounds);

    CGFloat w = NSWidth(self.bounds);
    CGFloat h = NSHeight(self.bounds);
    if (_qualityMode) {
        const char *scene = getenv("SHARP_TEST_SCENE_IMAGE");
        if (scene) {
            if (!_pageImage) _pageImage = [[NSImage alloc] initWithContentsOfFile:[NSString stringWithUTF8String:scene]];
            [_pageImage drawInRect:self.bounds];
            [[NSColor colorWithSRGBRed:0.15 green:0.55 blue:0.95 alpha:1] setFill];
            NSRectFill(NSMakeRect(fmod(_tick * 12.0, w - 400), 80, 400, 280));
            return;
        }
        // Stable desktop detail above, continuous motion below. No private content.
        for (int i = 0; i < 12; i++) {
            NSColor *color = i % 3 == 0 ? NSColor.whiteColor :
                (i % 3 == 1 ? [NSColor colorWithSRGBRed:0.95 green:0.25 blue:0.3 alpha:1] :
                 [NSColor colorWithSRGBRed:0.2 green:0.65 blue:1 alpha:1]);
            NSDictionary *a = @{NSFontAttributeName:[NSFont monospacedSystemFontOfSize:12 + i % 4 * 2 weight:NSFontWeightRegular], NSForegroundColorAttributeName:color};
            [[NSString stringWithFormat:@"%02d  let pixels = source.capture()  // Sharp desktop text: Aa Bb 0123456789", i]
                drawAtPoint:NSMakePoint(80, h - 65 - i * 25) withAttributes:a];
        }
        for (int x = 0; x < 512; x++) {
            [(x % 2 ? NSColor.redColor : NSColor.blueColor) setFill];
            NSRectFill(NSMakeRect(900 + x, h - 300, 1, 120));
        }
        for (int i = 0; i < 8; i++) {
            [[NSColor colorWithSRGBRed:0.03 + i * 0.02 green:0.05 + i * 0.02 blue:0.09 + i * 0.02 alpha:1] setFill];
            NSRectFill(NSMakeRect(80 + i * 100, h - 460, 100, 60));
        }
        // Compact specimen for honest portrait comparisons: text and vector edges.
        NSRect plate = NSMakeRect(1600, h - 260, 360, 180);
        [[NSColor colorWithSRGBRed:0.98 green:0.98 blue:0.97 alpha:1] setFill];
        NSRectFill(plate);
        NSDictionary *headline = @{NSFontAttributeName:[NSFont systemFontOfSize:20 weight:NSFontWeightSemibold], NSForegroundColorAttributeName:NSColor.blackColor};
        [@"0123456789 Aa Bb Cc" drawAtPoint:NSMakePoint(1616, h - 118) withAttributes:headline];
        NSColor *red = [NSColor colorWithSRGBRed:0.85 green:0.12 blue:0.18 alpha:1];
        NSDictionary *detail = @{NSFontAttributeName:[NSFont systemFontOfSize:13 weight:NSFontWeightRegular], NSForegroundColorAttributeName:red};
        [@"RGB edges / 1 px strokes / 0123456789" drawAtPoint:NSMakePoint(1616, h - 140) withAttributes:detail];
        [red setStroke];
        NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(1620,h-240,70,70)];
        circle.lineWidth=1; [circle stroke];
        NSBezierPath *triangle = [NSBezierPath bezierPath];
        [triangle moveToPoint:NSMakePoint(1734,h-170)]; [triangle lineToPoint:NSMakePoint(1774,h-240)];
        [triangle lineToPoint:NSMakePoint(1694,h-240)]; [triangle closePath]; triangle.lineWidth=1; [triangle stroke];
        [[NSColor colorWithSRGBRed:0.1 green:0.45 blue:0.8 alpha:1] setStroke];
        NSBezierPath *square=[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(1800,h-240,70,70) xRadius:14 yRadius:14];
        square.lineWidth=1; [square stroke];
        for (int i=0;i<8;i++) {
            NSBezierPath *line=[NSBezierPath bezierPath];
            [line moveToPoint:NSMakePoint(1885+i*7,h-240)];
            [line lineToPoint:NSMakePoint(1895+i*7,h-170)]; line.lineWidth=1; [line stroke];
        }
        [[NSColor colorWithSRGBRed:0.15 green:0.55 blue:0.95 alpha:1] setFill];
        NSRectFill(NSMakeRect(fmod(_tick * 12.0, w - 400), 80, 400, 280));
        return;
    }
    if (_colorsMode) {
        const uint8_t colors[][3]={{13,17,23},{22,27,34},{30,45,70},{45,35,65},
            {32,32,32},{96,96,96},{192,192,192},{220,220,220},
            {190,40,30},{30,170,60},{35,70,190},{170,110,45}};
        for(int row=0;row<3;row++) for(int col=0;col<4;col++) {
            const uint8_t *c=colors[row*4+col];
            CGFloat delta=(_tick%2)?2.0:-2.0;
            [[NSColor colorWithSRGBRed:(c[0]+delta)/255.0 green:c[1]/255.0
                                 blue:c[2]/255.0 alpha:1] setFill];
            NSRectFill(NSMakeRect(col*w/4,64+row*(h-64)/3,w/4,(h-64)/3));
        }
        return;
    }
    if (_pagesMode) {
        unsigned page=(unsigned)(_tick/180)%2;
        [[NSColor colorWithSRGBRed:page?0.06:0.05 green:page?0.06:0.07
                             blue:page?0.06:0.10 alpha:1] setFill];
        NSRectFill(self.bounds);
        NSDictionary *attrs=@{NSFontAttributeName:[NSFont monospacedSystemFontOfSize:17 weight:NSFontWeightRegular],
            NSForegroundColorAttributeName:[NSColor colorWithSRGBRed:0.75 green:0.80 blue:0.85 alpha:1]};
        for(int row=0;row<38;row++) {
            NSString *line=page?[NSString stringWithFormat:@"Video %d   A detailed title for this thumbnail and its description",row]:
                [NSString stringWithFormat:@"%03d    func updateTileVersion(frame: UInt32) { cache[frame] = capturedPixels }",row];
            [line drawAtPoint:NSMakePoint(page?w*0.48:100,h-55-row*28) withAttributes:attrs];
        }
        if(page) {
            if (!_pageImage) {
                NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                    pixelsWide:1024 pixelsHigh:1024 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
                    isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:4096 bitsPerPixel:32];
                uint32_t random=42;
                for(int y=0;y<1024;y++) for(int x=0;x<1024;x++) {
                    uint8_t *p=bitmap.bitmapData+y*4096+x*4;
                    for(int c=0;c<3;c++) {
                        random=random*1664525u+1013904223u;
                        p[c]=(uint8_t)(32+((x*(c+1)+y*(3-c))/12)%160+(random>>28));
                    }
                    p[3]=255;
                }
                _pageImage=[[NSImage alloc] initWithSize:NSMakeSize(1024,1024)];
                [_pageImage addRepresentation:bitmap];
            }
            [_pageImage drawInRect:NSMakeRect(0,0,w*0.43,h)];
        }
        return;
    }
    if (_broadMode) {
        for (int row = 0; row < 12; row++) {
            CGFloat shade = 0.10 + (CGFloat)(row % 3) * 0.025;
            [[NSColor colorWithCalibratedWhite:shade alpha:1.0] setFill];
            NSRectFill(NSMakeRect(0.0, (CGFloat)row * h / 12.0, w, h / 12.0));
        }
        CGFloat phase = (CGFloat)(_tick % 360);
        for (int i = 0; i < 5; i++) {
            CGFloat ww = w * (0.30 + (CGFloat)(i % 2) * 0.08);
            CGFloat wh = h * (0.22 + (CGFloat)(i % 3) * 0.04);
            CGFloat speed = 3.2 + (CGFloat)(i % 4) * 0.8;
            CGFloat x = fmod(phase * speed + (CGFloat)i * 173.0,
                             w + ww * 2.0) - ww;
            CGFloat y = fmod(phase * (1.3 + (CGFloat)(i % 4) * 0.35) +
                                 (CGFloat)i * 91.0,
                             h + wh * 2.0) - wh;
            NSRect shadow = NSMakeRect(x + 10.0, y - 10.0, ww, wh);
            [[NSColor colorWithCalibratedWhite:0.0 alpha:0.35] setFill];
            NSRectFill(shadow);
            CGFloat r = 0.18 + (CGFloat)(i % 3) * 0.16;
            CGFloat g = 0.22 + (CGFloat)((i + 1) % 4) * 0.12;
            CGFloat b = 0.34 + (CGFloat)((i + 2) % 5) * 0.09;
            [[NSColor colorWithCalibratedRed:r green:g blue:b alpha:1.0] setFill];
            NSRectFill(NSMakeRect(x, y, ww, wh));
            [[NSColor colorWithCalibratedWhite:0.95 alpha:1.0] setFill];
            NSRectFill(NSMakeRect(x, y + wh - 24.0, ww, 24.0));
        }
        return;
    }

    CGFloat t = (CGFloat)(_tick % 240);
    CGFloat x = fmod(t * 7.0, w + 160.0) - 80.0;
    CGFloat y = h * 0.5 + sin((double)_tick * 0.12) * h * 0.28;

    CGFloat boxW = 240.0;
    CGFloat boxH = 144.0;
    NSRect redRect = NSMakeRect(x, y - boxH * 0.5, boxW, boxH);
    NSRect blueRect = NSMakeRect(w - x - boxW, h - y - boxH * 0.5, boxW, boxH);

    [[NSColor colorWithCalibratedRed:0.95 green:0.18 blue:0.12 alpha:1.0] setFill];
    NSRectFill(redRect);

    [[NSColor colorWithCalibratedRed:0.08 green:0.55 blue:1.0 alpha:1.0] setFill];
    NSRectFill(blueRect);

    NSDictionary *attrs = @{
        NSFontAttributeName : [NSFont monospacedDigitSystemFontOfSize:28.0
                                                               weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName : [NSColor whiteColor],
    };
    NSString *label = [NSString stringWithFormat:@"sharp activity %llu",
                                                 (unsigned long long)_tick];
    [label drawAtPoint:NSMakePoint(24.0, 24.0) withAttributes:attrs];

    if (_traceLog != NULL && _lastLoggedTick != _tick) {
        CGFloat scale = self.window != nil ? self.window.backingScaleFactor : 1.0;
        uint32_t sourceW = (uint32_t)llround(w * scale);
        uint32_t sourceH = (uint32_t)llround(h * scale);
        uint32_t redX = (uint32_t)llround(redRect.origin.x * scale);
        uint32_t redY = (uint32_t)llround((h - NSMaxY(redRect)) * scale);
        uint32_t redW = (uint32_t)llround(redRect.size.width * scale);
        uint32_t redH = (uint32_t)llround(redRect.size.height * scale);
        uint32_t blueX = (uint32_t)llround(blueRect.origin.x * scale);
        uint32_t blueY = (uint32_t)llround((h - NSMaxY(blueRect)) * scale);
        uint32_t blueW = (uint32_t)llround(blueRect.size.width * scale);
        uint32_t blueH = (uint32_t)llround(blueRect.size.height * scale);
        uint64_t wallNs =
            (uint64_t)([NSDate timeIntervalSinceReferenceDate] * 1000000000.0);
        fprintf(_traceLog,
                "%llu\t%" PRIu64 "\t%u\t%u\t%u\t%u\t%u\t%u\t%u\t%u\t%u\t%u\n",
                (unsigned long long)_tick, wallNs, sourceW, sourceH, redX, redY,
                redW, redH, blueX, blueY, blueW, blueH);
        fflush(_traceLog);
        _lastLoggedTick = _tick;
    }
}

@end

@interface ActivityApp : NSObject <NSApplicationDelegate>
@property(nonatomic, assign) activity_config_t config;
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) ActivityView *view;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) NSTimer *stopTimer;
@property(nonatomic, assign) FILE *traceLog;
@property(nonatomic, assign) BOOL motionStarted;
@property(nonatomic, assign) uint64_t timerFires;
@property(nonatomic, assign) NSTimeInterval startTime;
@property(nonatomic, assign) CVDisplayLinkRef displayLink;
@property(nonatomic, assign) BOOL displayLinkTickPending;
@property(nonatomic, assign) NSTimeInterval lastDisplayLinkFrameTime;
@end

@implementation ActivityApp

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    _startTime = [NSDate timeIntervalSinceReferenceDate];
    NSScreen *screen = nil;
    if (_config.display_id != 0u) {
        for (NSScreen *candidate in NSScreen.screens) {
            NSNumber *number = candidate.deviceDescription[@"NSScreenNumber"];
            if (number != nil &&
                number.unsignedIntValue == _config.display_id) {
                screen = candidate;
                break;
            }
        }
    }
    if (screen == nil && _config.display_id != 0u) {
        fprintf(stderr, "requested display %u is unavailable\n", _config.display_id);
        exit(1);
    }
    if (screen == nil) {
        screen = NSScreen.mainScreen;
    }
    if (screen == nil) {
        fprintf(stderr, "no target screen found\n");
        [NSApp terminate:nil];
        return;
    }
    NSRect frame = _config.fullscreen ? screen.frame
                                      : NSMakeRect(0, 0, _config.width,
                                                   _config.height);
    NSUInteger style = _config.fullscreen
                           ? NSWindowStyleMaskBorderless
                           : (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable);
    _window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:style
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    [_window setTitle:@"sharp lab activity"];
    [_window setLevel:NSStatusWindowLevel];
    [_window setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces |
                                   NSWindowCollectionBehaviorFullScreenAuxiliary];
    if (_config.fullscreen) {
        [_window setFrame:screen.frame display:NO];
    } else {
        [_window center];
    }

    _view = [[ActivityView alloc] initWithFrame:frame];
    _view.qualityMode = strcmp(_config.mode, "quality") == 0;
    _view.broadMode = strcmp(_config.mode, "broad") == 0;
    _view.colorsMode = strcmp(_config.mode, "colors") == 0;
    _view.pagesMode = strcmp(_config.mode, "pages") == 0;
    if (_config.trace_log_path != NULL) {
        _traceLog = fopen(_config.trace_log_path, "w");
        if (_traceLog != NULL) {
            fprintf(_traceLog,
                    "tick\twall_ns\tsource_w\tsource_h\tred_x\tred_y\tred_w\tred_h\tblue_x\tblue_y\tblue_w\tblue_h\n");
            fflush(_traceLog);
            _view.traceLog = _traceLog;
            _view.lastLoggedTick = UINT64_MAX;
        }
    }
    [_window setContentView:_view];
    [_window makeKeyAndOrderFront:nil];
    [_window orderFrontRegardless];
    [NSApp activateIgnoringOtherApps:YES];

    if (strcmp(_config.driver, "displaylink") == 0) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        CVReturn displayLinkStatus = _config.display_id != 0u
                                         ? CVDisplayLinkCreateWithCGDisplay(
                                               _config.display_id, &_displayLink)
                                         : CVDisplayLinkCreateWithActiveCGDisplays(
                                               &_displayLink);
        if (displayLinkStatus == kCVReturnSuccess) {
            CVDisplayLinkSetOutputCallback(_displayLink,
                                           activity_display_link_callback,
                                           (__bridge void *)self);
            CVDisplayLinkStart(_displayLink);
        } else {
            fprintf(stderr, "display link unavailable; using a 60 Hz timer\n");
            _timer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / (double)_config.fps)
                                                     target:self selector:@selector(tick:)
                                                   userInfo:nil repeats:YES];
        }
#pragma clang diagnostic pop
    } else {
        _timer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / (double)_config.fps)
                                                 target:self
                                               selector:@selector(tick:)
                                               userInfo:nil
                                                repeats:YES];
    }
    _stopTimer = [NSTimer scheduledTimerWithTimeInterval:(double)_config.duration
                                                  target:self
                                                selector:@selector(stop:)
                                                userInfo:nil
                                                 repeats:NO];
}

- (void)tick:(NSTimer *)timer {
    (void)timer;
    [self tickFrame];
}

- (void)tickFromDisplayLink {
    @synchronized (self) {
        _displayLinkTickPending = NO;
    }
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    double minInterval = _config.fps > 0 ? 1.0 / (double)_config.fps : 0.0;
    if (_lastDisplayLinkFrameTime != 0.0 && minInterval > 0.0 &&
        now - _lastDisplayLinkFrameTime < minInterval * 0.85) {
        return;
    }
    _lastDisplayLinkFrameTime = now;
    [self tickFrame];
}

- (void)tickFrame {
    _timerFires++;
    if (_config.activate_each_frame) {
        [_window orderFrontRegardless];
        [NSApp activateIgnoringOtherApps:YES];
    }
    if (!_motionStarted && _config.start_file_path != NULL) {
        if (access(_config.start_file_path, F_OK) != 0) {
            [_view setNeedsDisplay:YES];
            return;
        }
    }
    if (!_motionStarted) {
        _motionStarted = YES;
        if (_traceLog != NULL) {
            uint64_t wallNs =
                (uint64_t)([NSDate timeIntervalSinceReferenceDate] *
                           1000000000.0);
            fprintf(_traceLog, "motion_start\t%llu\t%" PRIu64 "\n",
                    (unsigned long long)_view.tick, wallNs);
            fflush(_traceLog);
        }
    }
    uint64_t maxMotionTick =
        _config.motion_duration > 0
            ? (uint64_t)_config.motion_duration * (uint64_t)_config.fps
            : UINT64_MAX;
    if (_view.tick < maxMotionTick) {
        _view.tick++;
    }
    [_view setNeedsDisplay:YES];
}

- (void)stop:(NSTimer *)timer {
    (void)timer;
    [NSApp terminate:self];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    if (_displayLink != NULL) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        CVDisplayLinkStop(_displayLink);
        CVDisplayLinkRelease(_displayLink);
#pragma clang diagnostic pop
        _displayLink = NULL;
    }
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    double seconds = now > _startTime ? now - _startTime : 0.0;
    double drawFps = seconds > 0.0 ? (double)_view.drawCount / seconds : 0.0;
    double timerFps = seconds > 0.0 ? (double)_timerFires / seconds : 0.0;
    fprintf(stdout,
            "lab-screen-activity mode=%s size=%ux%u fullscreen=%u "
            "driver=%s activate_each_frame=%u "
            "timer_fires=%" PRIu64 " draws=%" PRIu64
            " seconds=%.3f source_timer_fps=%.2f source_tick_fps=%.2f "
            "source_draw_fps=%.2f\n",
            _config.mode, _config.width, _config.height,
            _config.fullscreen ? 1u : 0u, _config.driver,
            _config.activate_each_frame ? 1u : 0u, _timerFires,
            _view.drawCount, seconds, timerFps, timerFps, drawFps);
    fflush(stdout);
    if (_traceLog != NULL) {
        fclose(_traceLog);
        _traceLog = NULL;
    }
}

@end

int main(int argc, char **argv) {
    activity_config_t config;
    if (parse_args(argc, argv, &config) != 0) {
        fprintf(stderr,
                "usage: lab-screen-activity [--duration SEC] [--fps FPS] "
                "[--motion-duration SEC] [--width PX] [--height PX] "
                "[--mode rects|broad|colors|pages|quality] [--driver timer|displaylink] "
                "[--fullscreen] [--no-frame-activate] "
                "[--trace-log PATH] [--start-file PATH]\n");
        return 2;
    }

    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        ActivityApp *delegate = [[ActivityApp alloc] init];
        delegate.config = config;
        [app setDelegate:delegate];
        [app run];
    }
    return 0;
}

static CVReturn activity_display_link_callback(CVDisplayLinkRef displayLink,
                                               const CVTimeStamp *now,
                                               const CVTimeStamp *outputTime,
                                               CVOptionFlags flagsIn,
                                               CVOptionFlags *flagsOut,
                                               void *displayLinkContext) {
    (void)displayLink;
    (void)now;
    (void)outputTime;
    (void)flagsIn;
    (void)flagsOut;
    ActivityApp *app = (__bridge ActivityApp *)displayLinkContext;
    BOOL shouldDispatch = NO;
    @synchronized (app) {
        if (!app.displayLinkTickPending) {
            app.displayLinkTickPending = YES;
            shouldDispatch = YES;
        }
    }
    if (shouldDispatch) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [app tickFromDisplayLink];
        });
    }
    return kCVReturnSuccess;
}
