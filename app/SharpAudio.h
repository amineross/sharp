#import "../src/platform/CursorImage.h"
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// One route per connection. stop is safe from the main thread and never waits for IO.
@interface SharpAudio : NSObject
- (instancetype)initWithStatus:(void (^)(NSString *state))status;
- (void)receiveOn:(NSString *)address token:(NSString *)token;
- (void)sendFrom:(NSString *)source to:(NSString *)destination token:(NSString *)token;
- (void)stop;
- (void)requestPermission;
@end
NS_ASSUME_NONNULL_END
