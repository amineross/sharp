#import "CursorImage.h"
#include <math.h>
NSImage *SharpCursorImage(NSImage *image, double hue) {
    if (!isfinite(hue)) return image;
    NSRect rect = NSMakeRect(0, 0, image.size.width, image.size.height);
    CGImageRef cg = [image CGImageForProposedRect:&rect context:nil hints:nil];
    if (!cg) return image;
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:cg];
    for (NSInteger y = 0; y < bitmap.pixelsHigh; y++) {
        for (NSInteger x = 0; x < bitmap.pixelsWide; x++) {
            NSColor *color = [[bitmap colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
            CGFloat h, saturation, brightness, alpha;
            [color getHue:&h saturation:&saturation brightness:&brightness alpha:&alpha];
            if (alpha > 0 && saturation > 0.1) {
                h = fmod(h + hue - 0.94 + 1.0, 1.0);
                if (hue < 0.04) {
                    CGFloat blend = MAX(0, hue) / 0.04;
                    saturation *= blend;
                    brightness = brightness * blend + (1 - blend);
                } else if (hue > 0.96) {
                    brightness *= MAX(0, 1 - hue) / 0.04;
                }
                [bitmap setColor:[NSColor colorWithDeviceHue:h saturation:saturation brightness:brightness alpha:alpha] atX:x y:y];
            }
        }
    }
    NSImage *result = [[NSImage alloc] initWithSize:image.size];
    [result addRepresentation:bitmap];
    return result;
}
