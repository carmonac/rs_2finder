// FinderWindowController.m
#import "FinderWindowController.h"
#import "SidebarViewController.h"
#import "FileViewController.h"
#import "GoToFolderPanel.h"

@interface FinderWindowController () <SidebarViewControllerDelegate, FileViewControllerDelegate, NSToolbarDelegate>

@property (nonatomic, strong) NSSplitViewController *splitVC;
@property (nonatomic, strong) SidebarViewController *sidebarVC;
@property (nonatomic, strong) FileViewController    *fileVC;

// Navigation stack
@property (nonatomic, strong) NSMutableArray<NSString *> *history;
@property (nonatomic)         NSInteger                   historyIndex;

// Toolbar items
@property (nonatomic, strong) NSSegmentedControl *navControl;   // back / forward segments
@property (nonatomic, strong) NSSegmentedControl *viewModeControl;
@property (nonatomic, strong) NSTextField        *pathLabel;

@end

@implementation FinderWindowController

- (instancetype)initWithPath:(NSString *)path {
    // Create window programmatically
    NSRect frame = NSMakeRect(0, 0, 1000, 650);
    NSWindowStyleMask style = NSWindowStyleMaskTitled
                            | NSWindowStyleMaskClosable
                            | NSWindowStyleMaskMiniaturizable
                            | NSWindowStyleMaskResizable
                            | NSWindowStyleMaskFullSizeContentView;

    NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
                                               styleMask:style
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    win.title = @"R2 Finder";
    win.minSize = NSMakeSize(640, 400);
    [win center];

    self = [super initWithWindow:win];
    if (!self) return nil;

    _history       = [NSMutableArray array];
    _historyIndex  = -1;

    [self setupToolbar];
    [self setupContentWithPath:path];
    [self pushPath:path updateContent:NO];

    return self;
}

// ───────────────────────────────────────────────
#pragma mark – Toolbar
// ───────────────────────────────────────────────

- (void)setupToolbar {
    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"MainToolbar"];
    toolbar.delegate = self;
    toolbar.allowsUserCustomization = NO;
    toolbar.displayMode           = NSToolbarDisplayModeIconOnly;
    [self.window setToolbar:toolbar];
    self.window.titlebarAppearsTransparent = NO;
}

// ───────────────────────────────────────────────
#pragma mark – Content
// ───────────────────────────────────────────────

- (void)setupContentWithPath:(NSString *)path {
    _sidebarVC = [[SidebarViewController alloc] init];
    _sidebarVC.delegate = self;

    _fileVC = [[FileViewController alloc] initWithPath:path];
    _fileVC.delegate = self;

    _splitVC = [[NSSplitViewController alloc] init];

    NSSplitViewItem *sideItem = [NSSplitViewItem sidebarWithViewController:_sidebarVC];
    sideItem.minimumThickness = 180;
    sideItem.maximumThickness = 280;

    NSSplitViewItem *contentItem = [NSSplitViewItem splitViewItemWithViewController:_fileVC];
    contentItem.minimumThickness = 300;

    [_splitVC addSplitViewItem:sideItem];
    [_splitVC addSplitViewItem:contentItem];

    self.window.contentViewController = _splitVC;
}

// ───────────────────────────────────────────────
#pragma mark – Navigation
// ───────────────────────────────────────────────

- (void)pushPath:(NSString *)path updateContent:(BOOL)update {
    // Truncate forward history
    if (_historyIndex < (NSInteger)_history.count - 1) {
        NSRange range = NSMakeRange((NSUInteger)(_historyIndex + 1),
                                    _history.count - (NSUInteger)(_historyIndex + 1));
        [_history removeObjectsInRange:range];
    }
    [_history addObject:path];
    _historyIndex = (NSInteger)_history.count - 1;
    [self updateToolbarState];
    if (update) [_fileVC loadPath:path];
    self.window.title = path.lastPathComponent ?: path;
    [self updatePathLabel:path];
}

- (void)navigateToPath:(NSString *)path {
    [self pushPath:path updateContent:YES];
    [_sidebarVC highlightPath:path];
}

- (IBAction)goBack:(id)sender {
    if (_historyIndex > 0) {
        _historyIndex--;
        NSString *path = _history[(NSUInteger)_historyIndex];
        [_fileVC loadPath:path];
        self.window.title = path.lastPathComponent ?: path;
        [self updatePathLabel:path];
        [_sidebarVC highlightPath:path];
        [self updateToolbarState];
    }
}

- (IBAction)goForward:(id)sender {
    if (_historyIndex < (NSInteger)_history.count - 1) {
        _historyIndex++;
        NSString *path = _history[(NSUInteger)_historyIndex];
        [_fileVC loadPath:path];
        self.window.title = path.lastPathComponent ?: path;
        [self updatePathLabel:path];
        [_sidebarVC highlightPath:path];
        [self updateToolbarState];
    }
}

- (void)updateToolbarState {
    [_navControl setEnabled:(_historyIndex > 0)                                    forSegment:0];
    [_navControl setEnabled:(_historyIndex < (NSInteger)_history.count - 1)        forSegment:1];
}

- (void)updatePathLabel:(NSString *)path {
    _pathLabel.stringValue = path ?: @"";
}

// ───────────────────────────────────────────────
#pragma mark – NSToolbarDelegate
// ───────────────────────────────────────────────

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[@"BackForward", @"ViewMode", NSToolbarFlexibleSpaceItemIdentifier, @"PathLabel", NSToolbarFlexibleSpaceItemIdentifier, @"NewFolder", @"GoToFolder"];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return [self toolbarDefaultItemIdentifiers:toolbar];
}

// FinderWindowController is the toolbar delegate
- (void)toolbar:(NSToolbar *)toolbar willAddItem:(NSToolbarItem *)item {}  // no-op conformance
- (void)toolbar:(NSToolbar *)toolbar didRemoveItem:(NSToolbarItem *)item {} // no-op conformance

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar
     itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier
 willBeInsertedIntoToolbar:(BOOL)flag {

    if ([itemIdentifier isEqualToString:@"BackForward"]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
        // NSSegmentSwitchTrackingMomentary: each click ALWAYS fires the action
        // with a valid selectedSegment (0 or 1). No toggle confusion.
        _navControl = [NSSegmentedControl
            segmentedControlWithImages:@[
                [NSImage imageWithSystemSymbolName:@"chevron.left"  accessibilityDescription:@"Atr\u00e1s"],
                [NSImage imageWithSystemSymbolName:@"chevron.right" accessibilityDescription:@"Adelante"],
            ]
            trackingMode:NSSegmentSwitchTrackingMomentary
                  target:self
                  action:@selector(backForwardAction:)];
        _navControl.segmentStyle = NSSegmentStyleSeparated;
        [_navControl setEnabled:NO forSegment:0];
        [_navControl setEnabled:NO forSegment:1];
        item.view = _navControl;
        return item;
    }

    if ([itemIdentifier isEqualToString:@"ViewMode"]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
        _viewModeControl = [NSSegmentedControl
            segmentedControlWithImages:@[
                [NSImage imageWithSystemSymbolName:@"square.grid.2x2"   accessibilityDescription:@"Iconos"],
                [NSImage imageWithSystemSymbolName:@"list.bullet"       accessibilityDescription:@"Lista"],
                [NSImage imageWithSystemSymbolName:@"rectangle.split.3x1" accessibilityDescription:@"Columnas"],
                [NSImage imageWithSystemSymbolName:@"squares.below.rectangle" accessibilityDescription:@"Galería"],
            ]
            trackingMode:NSSegmentSwitchTrackingSelectOne
                  target:self
                  action:@selector(viewModeAction:)];
        _viewModeControl.selectedSegment = 1; // default = list
        [_viewModeControl setEnabled:YES forSegment:0]; // icon
        [_viewModeControl setEnabled:YES forSegment:1]; // list
        [_viewModeControl setEnabled:NO  forSegment:2]; // columns (not yet)
        [_viewModeControl setEnabled:NO  forSegment:3]; // gallery (not yet)
        item.view = _viewModeControl;
        return item;
    }

    if ([itemIdentifier isEqualToString:@"PathLabel"]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
        _pathLabel = [NSTextField labelWithString:@""];
        _pathLabel.textColor      = [NSColor secondaryLabelColor];
        _pathLabel.font           = [NSFont systemFontOfSize:12];
        _pathLabel.alignment      = NSTextAlignmentCenter;
        _pathLabel.lineBreakMode  = NSLineBreakByTruncatingMiddle;
        _pathLabel.preferredMaxLayoutWidth = 400;
        item.view = _pathLabel;
        return item;
    }

    if ([itemIdentifier isEqualToString:@"NewFolder"]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
        item.image  = [NSImage imageWithSystemSymbolName:@"folder.badge.plus" accessibilityDescription:@"Nueva carpeta"];
        item.label  = @"Nueva carpeta";
        item.target = self;
        item.action = @selector(createNewFolder:);
        return item;
    }

    if ([itemIdentifier isEqualToString:@"GoToFolder"]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
        item.image  = [NSImage imageWithSystemSymbolName:@"arrow.right.circle" accessibilityDescription:@"Ir a carpeta"];
        item.label  = @"Ir a carpeta";
        item.target = self;
        item.action = @selector(goToFolderAction:);
        return item;
    }

    return nil;
}

- (IBAction)viewModeAction:(NSSegmentedControl *)seg {
    _fileVC.viewMode = (FileViewMode)seg.selectedSegment;
}

- (IBAction)backForwardAction:(NSSegmentedControl *)seg {
    if (seg.selectedSegment == 0) [self goBack:seg];
    else                          [self goForward:seg];
}

- (IBAction)createNewFolder:(id)sender {
    // Use the FileViewController's own currentPath — it is always up to date
    // even if the history stack and the file view diverge momentarily.
    NSString *current = _fileVC.currentPath ?: (_historyIndex >= 0 ? _history[(NSUInteger)_historyIndex] : nil);
    if (!current) return;
    [_fileVC createNewFolderInPath:current];
}

- (IBAction)goToFolderAction:(id)sender {
    __weak typeof(self) wself = self;
    [GoToFolderPanel runAsSheetOnWindow:self.window completionHandler:^(NSString *path) {
        if (path) [wself navigateToPath:path];
    }];
}

// ───────────────────────────────────────────────
#pragma mark – SidebarViewControllerDelegate
// ───────────────────────────────────────────────

- (void)sidebar:(SidebarViewController *)sidebar didSelectPath:(NSString *)path {
    [self pushPath:path updateContent:YES];
}

// ───────────────────────────────────────────────
#pragma mark – FileViewControllerDelegate
// ───────────────────────────────────────────────

- (void)fileViewController:(FileViewController *)vc didNavigateToPath:(NSString *)path {
    [self pushPath:path updateContent:NO]; // content already updated by fileVC
    [_sidebarVC highlightPath:path];
}

@end
