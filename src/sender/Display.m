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

BOOL sharp_cursor_matches(NSCursor *cursor, NSCursor *candidate) {
    return cursor != nil && candidate != nil &&
           (cursor == candidate || [cursor isEqual:candidate]);
}

uint32_t sharp_cursor_image_id(NSCursor *cursor) {
    if (sharp_cursor_matches(cursor, NSCursor.IBeamCursor)) {
        return SHARP_CURSOR_IMAGE_IBEAM;
    }
    if (sharp_cursor_matches(cursor, NSCursor.pointingHandCursor) ||
        sharp_cursor_matches(cursor, NSCursor.dragLinkCursor)) {
        return SHARP_CURSOR_IMAGE_LINK;
    }
    if (sharp_cursor_matches(cursor, NSCursor.crosshairCursor)) {
        return SHARP_CURSOR_IMAGE_CROSSHAIR;
    }
    if (sharp_cursor_matches(cursor, NSCursor.openHandCursor) ||
        sharp_cursor_matches(cursor, NSCursor.closedHandCursor)) {
        return SHARP_CURSOR_IMAGE_MOVE;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (sharp_cursor_matches(cursor, NSCursor.resizeLeftRightCursor) ||
        sharp_cursor_matches(cursor, NSCursor.resizeLeftCursor) ||
        sharp_cursor_matches(cursor, NSCursor.resizeRightCursor)) {
        return SHARP_CURSOR_IMAGE_RESIZE_HORIZONTAL;
    }
    if (sharp_cursor_matches(cursor, NSCursor.resizeUpDownCursor) ||
        sharp_cursor_matches(cursor, NSCursor.resizeUpCursor) ||
        sharp_cursor_matches(cursor, NSCursor.resizeDownCursor)) {
        return SHARP_CURSOR_IMAGE_RESIZE_VERTICAL;
    }
#pragma clang diagnostic pop
    if (sharp_cursor_matches(cursor, NSCursor.operationNotAllowedCursor)) {
        return SHARP_CURSOR_IMAGE_UNAVAILABLE;
    }
    if (sharp_cursor_matches(cursor, NSCursor.dragCopyCursor) ||
        sharp_cursor_matches(cursor, NSCursor.contextualMenuCursor)) {
        return SHARP_CURSOR_IMAGE_ALTERNATE;
    }
    return SHARP_CURSOR_IMAGE_ARROW;
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
