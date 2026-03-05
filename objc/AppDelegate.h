// AppDelegate.h
#import <Cocoa/Cocoa.h>

@interface AppDelegate : NSObject <NSApplicationDelegate>

/// Opens a brand-new Finder window showing the user's home directory.
- (void)openNewWindow;

/// Shows a "Go to Folder" sheet on the frontmost window.
- (void)goToFolder;

@end

/// Called from Zig main() – sets up NSApplication and runs the event loop.
void objc_run_app(void);
