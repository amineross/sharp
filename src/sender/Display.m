#import "Internal.h"
SCDisplay *find_main_display(SCShareableContent *content) {
    CGDirectDisplayID mainID = CGMainDisplayID();
    for (SCDisplay *display in content.displays) {
        if (display.displayID == mainID) {
            return display;
        }
    }
    return content.displays.firstObject;
}

SCDisplay *find_display_with_id(SCShareableContent *content,
                                       CGDirectDisplayID displayID) {
    if (displayID != 0u) {
        for (SCDisplay *display in content.displays) {
            if (display.displayID == displayID) {
                return display;
            }
        }
        return nil;
    }
    return find_main_display(content);
}

SCShareableContent *sharp_copy_shareable_content(NSError **errorOut) {
    __block SCShareableContent *shareable = nil;
    __block NSError *shareableError = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [SCShareableContent
        getShareableContentExcludingDesktopWindows:NO
                               onScreenWindowsOnly:YES
                                 completionHandler:^(SCShareableContent *_Nullable content,
                                                     NSError *_Nullable error) {
                                   shareable = content;
                                   shareableError = error;
                                   dispatch_semaphore_signal(semaphore);
                                 }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    if (errorOut != NULL) {
        *errorOut = shareableError;
    }
    return shareable;
}

NSRect sharp_appkit_frame_for_display(CGDirectDisplayID displayID) {
    for (NSScreen *screen in NSScreen.screens) {
        NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
        if (number != nil && number.unsignedIntValue == displayID) {
            return screen.frame;
        }
    }
    NSScreen *mainScreen = NSScreen.mainScreen;
    return mainScreen != nil ? mainScreen.frame : NSZeroRect;
}

/*
 * NSCursor.currentSystemCursor returns a new object on every call, so it never
 * compares equal to NSCursor.IBeamCursor and friends. Recognise cursors by
 * shape instead: a small alpha mask plus the hotspot, scale-independent so a
 * larger pointer size in Accessibility still matches.
 */
#define SHARP_CURSOR_MASK 24
typedef struct {
    uint32_t image_id;
    uint8_t mask[SHARP_CURSOR_MASK * SHARP_CURSOR_MASK];
    double hotspot_x;
    double hotspot_y;
} sharp_cursor_shape_t;

static sharp_cursor_shape_t g_cursor_shapes[32];
static size_t g_cursor_shape_count;

static BOOL sharp_cursor_shape(NSCursor *cursor, sharp_cursor_shape_t *shape) {
    NSImage *image = cursor.image;
    NSSize size = image.size;
    if (image == nil || size.width < 1.0 || size.height < 1.0) {
        return NO;
    }
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:SHARP_CURSOR_MASK pixelsHigh:SHARP_CURSOR_MASK
                   bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                  colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:SHARP_CURSOR_MASK * 4
                    bitsPerPixel:32];
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    if (rep == nil || context == nil) {
        return NO;
    }
    double side = MAX(size.width, size.height);
    double scale = SHARP_CURSOR_MASK / side;
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:context];
    [image drawInRect:NSMakeRect(0, 0, size.width * scale, size.height * scale)
             fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1.0];
    [NSGraphicsContext restoreGraphicsState];
    for (int i = 0; i < SHARP_CURSOR_MASK * SHARP_CURSOR_MASK; i++) {
        shape->mask[i] = rep.bitmapData[i * 4 + 3];
    }
    shape->hotspot_x = cursor.hotSpot.x / side;
    shape->hotspot_y = cursor.hotSpot.y / side;
    return YES;
}

static void sharp_add_cursor_shape(NSCursor *cursor, uint32_t imageId) {
    if (cursor == nil || g_cursor_shape_count >= sizeof(g_cursor_shapes) / sizeof(g_cursor_shapes[0])) {
        return;
    }
    if (sharp_cursor_shape(cursor, &g_cursor_shapes[g_cursor_shape_count])) {
        g_cursor_shapes[g_cursor_shape_count++].image_id = imageId;
    }
}

size_t sharp_cursor_shapes_prepare(void) {
    /* AppKit's cursor constants are nil until NSApplication exists. */
    [NSApplication sharedApplication];
    g_cursor_shape_count = 0;
    sharp_add_cursor_shape(NSCursor.arrowCursor, SHARP_CURSOR_IMAGE_ARROW);
    sharp_add_cursor_shape(NSCursor.IBeamCursor, SHARP_CURSOR_IMAGE_IBEAM);
    sharp_add_cursor_shape(NSCursor.IBeamCursorForVerticalLayout, SHARP_CURSOR_IMAGE_IBEAM);
    sharp_add_cursor_shape(NSCursor.pointingHandCursor, SHARP_CURSOR_IMAGE_LINK);
    sharp_add_cursor_shape(NSCursor.dragLinkCursor, SHARP_CURSOR_IMAGE_LINK);
    sharp_add_cursor_shape(NSCursor.crosshairCursor, SHARP_CURSOR_IMAGE_CROSSHAIR);
    sharp_add_cursor_shape(NSCursor.openHandCursor, SHARP_CURSOR_IMAGE_MOVE);
    sharp_add_cursor_shape(NSCursor.closedHandCursor, SHARP_CURSOR_IMAGE_MOVE);
    sharp_add_cursor_shape(NSCursor.operationNotAllowedCursor, SHARP_CURSOR_IMAGE_UNAVAILABLE);
    sharp_add_cursor_shape(NSCursor.dragCopyCursor, SHARP_CURSOR_IMAGE_ALTERNATE);
    sharp_add_cursor_shape(NSCursor.contextualMenuCursor, SHARP_CURSOR_IMAGE_ALTERNATE);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    sharp_add_cursor_shape(NSCursor.resizeLeftRightCursor, SHARP_CURSOR_IMAGE_RESIZE_HORIZONTAL);
    sharp_add_cursor_shape(NSCursor.resizeLeftCursor, SHARP_CURSOR_IMAGE_RESIZE_HORIZONTAL);
    sharp_add_cursor_shape(NSCursor.resizeRightCursor, SHARP_CURSOR_IMAGE_RESIZE_HORIZONTAL);
    sharp_add_cursor_shape(NSCursor.resizeUpDownCursor, SHARP_CURSOR_IMAGE_RESIZE_VERTICAL);
    sharp_add_cursor_shape(NSCursor.resizeUpCursor, SHARP_CURSOR_IMAGE_RESIZE_VERTICAL);
    sharp_add_cursor_shape(NSCursor.resizeDownCursor, SHARP_CURSOR_IMAGE_RESIZE_VERTICAL);
#pragma clang diagnostic pop
    if (@available(macOS 15.0, *)) {
        /* macOS 15 window edges and corners use these system cursors. */
        sharp_add_cursor_shape(NSCursor.columnResizeCursor, SHARP_CURSOR_IMAGE_RESIZE_HORIZONTAL);
        sharp_add_cursor_shape(NSCursor.rowResizeCursor, SHARP_CURSOR_IMAGE_RESIZE_VERTICAL);
        NSCursorFrameResizeDirections all = NSCursorFrameResizeDirectionsAll;
        sharp_add_cursor_shape([NSCursor frameResizeCursorFromPosition:NSCursorFrameResizePositionLeft inDirections:all],
                               SHARP_CURSOR_IMAGE_RESIZE_HORIZONTAL);
        sharp_add_cursor_shape([NSCursor frameResizeCursorFromPosition:NSCursorFrameResizePositionTop inDirections:all],
                               SHARP_CURSOR_IMAGE_RESIZE_VERTICAL);
        sharp_add_cursor_shape([NSCursor frameResizeCursorFromPosition:NSCursorFrameResizePositionTopLeft inDirections:all],
                               SHARP_CURSOR_IMAGE_RESIZE_DIAGONAL_NWSE);
        sharp_add_cursor_shape([NSCursor frameResizeCursorFromPosition:NSCursorFrameResizePositionTopRight inDirections:all],
                               SHARP_CURSOR_IMAGE_RESIZE_DIAGONAL_NESW);
    }
    return g_cursor_shape_count;
}

uint32_t sharp_cursor_image_id(NSCursor *cursor) {
    sharp_cursor_shape_t shape;
    if (cursor == nil || !sharp_cursor_shape(cursor, &shape)) {
        return SHARP_CURSOR_IMAGE_ARROW;
    }
    uint32_t best = SHARP_CURSOR_IMAGE_ARROW;
    double bestDistance = DBL_MAX;
    for (size_t i = 0; i < g_cursor_shape_count; i++) {
        const sharp_cursor_shape_t *candidate = &g_cursor_shapes[i];
        double distance = 0.0;
        for (int p = 0; p < SHARP_CURSOR_MASK * SHARP_CURSOR_MASK; p++) {
            distance += abs((int)shape.mask[p] - (int)candidate->mask[p]);
        }
        distance /= SHARP_CURSOR_MASK * SHARP_CURSOR_MASK;
        distance += 100.0 * (fabs(shape.hotspot_x - candidate->hotspot_x) +
                             fabs(shape.hotspot_y - candidate->hotspot_y));
        if (distance < bestDistance) {
            bestDistance = distance;
            best = candidate->image_id;
        }
    }
    /* Identical system art scores 0; the closest distinct pair scores ~16.
     * Anything else is an app's custom cursor: draw the arrow. */
    return bestDistance <= 8.0 ? best : SHARP_CURSOR_IMAGE_ARROW;
}

int sharp_virtual_display_api_available(void) {
    Class descriptor = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class display = NSClassFromString(@"CGVirtualDisplay");
    Class mode = NSClassFromString(@"CGVirtualDisplayMode");
    Class settings = NSClassFromString(@"CGVirtualDisplaySettings");
    return descriptor != Nil && display != Nil && mode != Nil && settings != Nil &&
           [display instancesRespondToSelector:NSSelectorFromString(
                                                  @"initWithDescriptor:")] &&
           [display instancesRespondToSelector:NSSelectorFromString(
                                                  @"applySettings:")] &&
           [mode instancesRespondToSelector:NSSelectorFromString(
                                               @"initWithWidth:height:refreshRate:")];
}

id sharp_create_virtual_display(uint32_t width,
                                       uint32_t height,
                                       double refreshRate,
                                       CGDirectDisplayID *displayIdOut) {
    if (displayIdOut != NULL) {
        *displayIdOut = 0u;
    }
    if (!sharp_virtual_display_api_available() || width == 0u || height == 0u ||
        refreshRate < 1.0) {
        return nil;
    }
    @try {
        Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
        Class displayClass = NSClassFromString(@"CGVirtualDisplay");
        Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
        Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
        id descriptor = [[descriptorClass alloc] init];
        uint32_t serial = 0x53000000u ^ (width << 8u) ^ height;
        [descriptor setValue:@(0x5348u) forKey:@"vendorID"];
        [descriptor setValue:@(0u) forKey:@"productID"];
        [descriptor setValue:@(serial) forKey:@"serialNum"];
        if ([descriptor respondsToSelector:NSSelectorFromString(@"setSerialNumber:")]) {
            [descriptor setValue:@(serial) forKey:@"serialNumber"];
        }
        [descriptor setValue:[NSString stringWithFormat:@"sharp %ux%u", width, height]
                       forKey:@"name"];
        [descriptor setValue:@(width) forKey:@"maxPixelsWide"];
        [descriptor setValue:@(height) forKey:@"maxPixelsHigh"];
        double millimetersWide = (double)width * 25.4 / 110.0;
        double millimetersHigh = (double)height * 25.4 / 110.0;
        [descriptor setValue:[NSValue valueWithSize:NSMakeSize(
                                                        millimetersWide,
                                                        millimetersHigh)]
                       forKey:@"sizeInMillimeters"];
        /*
         * These panel chromaticities are not decorative. On Monterey, an
         * incomplete descriptor can return a nonzero display ID and accept
         * settings while remaining a 1x1 ScreenCaptureKit placeholder. Use
         * the same complete sRGB-like descriptor shape as Chromium's macOS
         * virtual-display implementation.
         */
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.3125, 0.3291)]
                       forKey:@"whitePoint"];
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.1494, 0.0557)]
                       forKey:@"bluePrimary"];
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.2559, 0.6983)]
                       forKey:@"greenPrimary"];
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.6797, 0.3203)]
                       forKey:@"redPrimary"];
        [descriptor setValue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)
                       forKey:@"queue"];
        if ([descriptor respondsToSelector:NSSelectorFromString(
                                                   @"setTerminationHandler:")]) {
            [descriptor setValue:nil forKey:@"terminationHandler"];
        }

        SEL modeInit = NSSelectorFromString(@"initWithWidth:height:refreshRate:");
        typedef id (*sharp_mode_init_fn)(id, SEL, unsigned int, unsigned int,
                                         double);
        id mode = ((sharp_mode_init_fn)objc_msgSend)(
            [modeClass alloc], modeInit, width, height, refreshRate);
        id settings = [[settingsClass alloc] init];
        [settings setValue:@0 forKey:@"hiDPI"];
        if ([settings respondsToSelector:NSSelectorFromString(@"setRotation:")]) {
            [settings setValue:@0 forKey:@"rotation"];
        }
        [settings setValue:@[ mode ] forKey:@"modes"];

        typedef id (*sharp_id_arg_fn)(id, SEL, id);
        id virtualDisplay = ((sharp_id_arg_fn)objc_msgSend)(
            [displayClass alloc], NSSelectorFromString(@"initWithDescriptor:"),
            descriptor);
        if (virtualDisplay == nil) {
            return nil;
        }
        BOOL applied = ((BOOL(*)(id, SEL, id))objc_msgSend)(
            virtualDisplay, NSSelectorFromString(@"applySettings:"), settings);
        if (!applied) {
            return nil;
        }
        CGDirectDisplayID displayID = 0u;
        SEL displayIdSelector = NSSelectorFromString(@"displayID");
        if ([virtualDisplay respondsToSelector:displayIdSelector]) {
            displayID = ((unsigned int (*)(id, SEL))objc_msgSend)(
                virtualDisplay, displayIdSelector);
        }
        /*
         * CGDisplayIsOnline can deadlock in SkyLight on Monterey immediately
         * after CGVirtualDisplay applies its settings. A nonzero display ID is
         * enough here. The caller waits until ScreenCaptureKit itself exposes
         * this exact ID before it creates the capture filter.
         */
        if (displayID == 0u) {
            return nil;
        }
        if (displayIdOut != NULL) {
            *displayIdOut = displayID;
        }
        return virtualDisplay;
    } @catch (NSException *exception) {
        fprintf(stderr, "virtual display creation exception: %s\n",
                exception.reason.UTF8String);
        return nil;
    }
}

int sharp_mirror_physical_display_from_virtual(
    CGDirectDisplayID physicalDisplayID,
    CGDirectDisplayID virtualDisplayID) {
    if (physicalDisplayID == 0u || virtualDisplayID == 0u ||
        physicalDisplayID == virtualDisplayID) {
        return 0;
    }
    CGDisplayConfigRef configuration = NULL;
    CGError error = CGBeginDisplayConfiguration(&configuration);
    if (error != kCGErrorSuccess || configuration == NULL) {
        fprintf(stderr, "virtual mirror begin failed error=%d\n", (int)error);
        return 0;
    }
    /*
     * The virtual display is the master so WindowServer composes at the
     * receiver's aspect ratio. The physical panel mirrors that master, just as
     * it would when the external display's mode is selected in macOS Displays.
     * ForAppOnly restores the original arrangement whenever the sender exits.
     */
    error = CGConfigureDisplayMirrorOfDisplay(configuration,
                                              physicalDisplayID,
                                              virtualDisplayID);
    if (error == kCGErrorSuccess) {
        error = CGCompleteDisplayConfiguration(configuration,
                                               kCGConfigureForAppOnly);
    } else {
        CGCancelDisplayConfiguration(configuration);
    }
    if (error != kCGErrorSuccess) {
        fprintf(stderr, "virtual mirror apply failed physical=%u virtual=%u error=%d\n",
                physicalDisplayID, virtualDisplayID, (int)error);
        return 0;
    }
    return 1;
}

int sharp_select_display_mode(CGDirectDisplayID displayID,
                              uint32_t width,
                              uint32_t height) {
    /*
     * Above roughly 3200x1800, macOS brings a new virtual display up in a
     * 1920x1080 mode even when the requested mode is its only native one.
     * Select the 1x mode explicitly; ForAppOnly reverts it when we exit.
     */
    NSDictionary *options = @{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES};
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(displayID, (__bridge CFDictionaryRef)options);
    if (modes == NULL) {
        return 0;
    }
    CGDisplayModeRef match = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        if (CGDisplayModeGetWidth(mode) == width && CGDisplayModeGetHeight(mode) == height &&
            CGDisplayModeGetPixelWidth(mode) == width &&
            CGDisplayModeGetPixelHeight(mode) == height) {
            match = mode;
            break;
        }
    }
    int selected = 0;
    CGDisplayConfigRef configuration = NULL;
    if (match != NULL && CGBeginDisplayConfiguration(&configuration) == kCGErrorSuccess &&
        configuration != NULL) {
        CGError error = CGConfigureDisplayWithDisplayMode(configuration, displayID, match, NULL);
        if (error == kCGErrorSuccess) {
            error = CGCompleteDisplayConfiguration(configuration, kCGConfigureForAppOnly);
        } else {
            CGCancelDisplayConfiguration(configuration);
        }
        selected = error == kCGErrorSuccess;
    }
    CFRelease(modes);
    return selected;
}

int sharp_probe_virtual_display_creation(CGDirectDisplayID *displayIdOut) {
    if (displayIdOut != NULL) {
        *displayIdOut = 0;
    }
    if (!sharp_virtual_display_api_available()) {
        return 0;
    }
    @try {
        Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
        Class displayClass = NSClassFromString(@"CGVirtualDisplay");
        Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
        Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
        id descriptor = [[descriptorClass alloc] init];
        [descriptor setValue:@(0x5348u) forKey:@"vendorID"];
        [descriptor setValue:@(0u) forKey:@"productID"];
        [descriptor setValue:@(0x53485031u) forKey:@"serialNum"];
        if ([descriptor respondsToSelector:NSSelectorFromString(@"setSerialNumber:")]) {
            [descriptor setValue:@(0x53485031u) forKey:@"serialNumber"];
        }
        [descriptor setValue:@"sharp capability probe" forKey:@"name"];
        [descriptor setValue:@(800u) forKey:@"maxPixelsWide"];
        [descriptor setValue:@(600u) forKey:@"maxPixelsHigh"];
        [descriptor setValue:[NSValue valueWithSize:NSMakeSize(160.0, 120.0)]
                       forKey:@"sizeInMillimeters"];
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.3125, 0.3291)]
                       forKey:@"whitePoint"];
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.1494, 0.0557)]
                       forKey:@"bluePrimary"];
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.2559, 0.6983)]
                       forKey:@"greenPrimary"];
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.6797, 0.3203)]
                       forKey:@"redPrimary"];
        [descriptor setValue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)
                       forKey:@"queue"];
        if ([descriptor respondsToSelector:NSSelectorFromString(
                                                   @"setTerminationHandler:")]) {
            [descriptor setValue:nil forKey:@"terminationHandler"];
        }

        SEL modeInit = NSSelectorFromString(@"initWithWidth:height:refreshRate:");
        typedef id (*sharp_mode_init_fn)(id, SEL, unsigned int, unsigned int,
                                         double);
        id mode = ((sharp_mode_init_fn)objc_msgSend)(
            [modeClass alloc], modeInit, 800u, 600u, 60.0);
        id settings = [[settingsClass alloc] init];
        [settings setValue:@0 forKey:@"hiDPI"];
        if ([settings respondsToSelector:NSSelectorFromString(@"setRotation:")]) {
            [settings setValue:@0 forKey:@"rotation"];
        }
        [settings setValue:@[ mode ] forKey:@"modes"];

        SEL displayInit = NSSelectorFromString(@"initWithDescriptor:");
        typedef id (*sharp_id_arg_fn)(id, SEL, id);
        id virtualDisplay = ((sharp_id_arg_fn)objc_msgSend)(
            [displayClass alloc], displayInit, descriptor);
        if (virtualDisplay == nil) {
            return 0;
        }
        BOOL applied = ((BOOL(*)(id, SEL, id))objc_msgSend)(
            virtualDisplay, NSSelectorFromString(@"applySettings:"), settings);
        if (!applied) {
            return 0;
        }
        CGDirectDisplayID displayId = 0;
        SEL displayIdSelector = NSSelectorFromString(@"displayID");
        if ([virtualDisplay respondsToSelector:displayIdSelector]) {
            displayId = ((unsigned int (*)(id, SEL))objc_msgSend)(
                virtualDisplay, displayIdSelector);
        }
        if (displayIdOut != NULL) {
            *displayIdOut = displayId;
        }
        return displayId != 0u ? 1 : 0;
    } @catch (NSException *exception) {
        fprintf(stderr, "virtual display probe exception: %s\n",
                exception.reason.UTF8String);
        return 0;
    }
}
