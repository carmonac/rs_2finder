// GoToFolderPanel.h
#import <Cocoa/Cocoa.h>

/// Displays a sheet (or standalone window if no parent) asking for a folder path.
@interface GoToFolderPanel : NSObject

/// Displays the sheet on `window`. Calls `handler(path)` with the entered
/// path (already expanded), or nil if the user cancelled.
+ (void)runAsSheetOnWindow:(NSWindow *)window
         completionHandler:(void (^)(NSString *path))handler;

@end
