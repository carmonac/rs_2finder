// FinderWindowController.h
#import <Cocoa/Cocoa.h>

@interface FinderWindowController : NSWindowController

- (instancetype)initWithPath:(NSString *)path;
- (void)navigateToPath:(NSString *)path;

@end
