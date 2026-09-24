#import <AppKit/AppKit.h>
// Recolor chromatic pixels only; retain the outline, alpha, and cursor geometry.
NSImage * _Nonnull SharpCursorImage(NSImage * _Nonnull image, double hue);
