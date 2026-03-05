// FileViewController.h
#import <Cocoa/Cocoa.h>

@class FileViewController;

@protocol FileViewControllerDelegate <NSObject>
- (void)fileViewController:(FileViewController *)vc didNavigateToPath:(NSString *)path;
@end

@interface FileViewController : NSViewController

@property (nonatomic, weak)   id<FileViewControllerDelegate> delegate;
@property (nonatomic, readonly, copy) NSString *currentPath;

- (instancetype)initWithPath:(NSString *)path;
- (void)loadPath:(NSString *)path;
- (void)createNewFolderInPath:(NSString *)path;

@end
