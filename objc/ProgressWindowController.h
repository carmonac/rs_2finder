// ProgressWindowController.h
#import <Cocoa/Cocoa.h>

/// Shows a floating window with a progress bar while rsync is running.
@interface ProgressWindowController : NSWindowController

- (instancetype)initWithTitle:(NSString *)title
            destinationFolder:(NSString *)dst
             refreshCallback:(void (^)(void))refresh;

- (void)updateProgress:(double)progress
      bytesTransferred:(uint64_t)bytesDone
            totalBytes:(uint64_t)total
                 speed:(double)bytesPerSec
               etaSecs:(int64_t)eta;

- (void)finishWithSuccess:(BOOL)success errorMessage:(NSString *)msg;

@end
