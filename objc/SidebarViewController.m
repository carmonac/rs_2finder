// SidebarViewController.m
#import "SidebarViewController.h"
#import "bridge.h"

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Internal model
// ─────────────────────────────────────────────────────────────────────────────

@interface SidebarItem : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) NSImage *icon;
@property (nonatomic) BOOL isHeader;          // section header row
@property (nonatomic, strong) NSMutableArray<SidebarItem *> *children;
@end

@implementation SidebarItem
- (instancetype)initHeader:(NSString *)title {
    self = [super init];
    _name = title;
    _isHeader = YES;
    _children = [NSMutableArray array];
    return self;
}
- (instancetype)initWithName:(NSString *)name path:(NSString *)path icon:(NSImage *)icon {
    self = [super init];
    _name = name;
    _path = path;
    _icon = icon;
    _isHeader = NO;
    _children = [NSMutableArray array];
    return self;
}
@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - SidebarViewController
// ─────────────────────────────────────────────────────────────────────────────

@interface SidebarViewController ()
@property (nonatomic, strong) NSScrollView   *scrollView;
@property (nonatomic, strong) NSOutlineView  *outlineView;
@property (nonatomic, strong) NSMutableArray<SidebarItem *> *sections;
// Set while highlightPath: is executing a programmatic selection so that
// outlineViewSelectionDidChange: doesn't call back into the delegate (and
// hence pushPath:) for a selection change we initiated ourselves.
@property (nonatomic) BOOL isHighlighting;
@end

@implementation SidebarViewController

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 600)];
    self.view.wantsLayer = YES;

    _outlineView = [[NSOutlineView alloc] initWithFrame:self.view.bounds];
    _outlineView.autoresizingMask         = NSViewWidthSizable | NSViewHeightSizable;
    _outlineView.headerView               = nil;
    _outlineView.indentationPerLevel      = 12;
    _outlineView.rowSizeStyle             = NSTableViewRowSizeStyleMedium;
    _outlineView.selectionHighlightStyle  = NSTableViewSelectionHighlightStyleSourceList;
    _outlineView.floatsGroupRows          = NO;
    _outlineView.dataSource               = self;
    _outlineView.delegate                 = self;
    [_outlineView setTarget:self];
    [_outlineView setDoubleAction:@selector(outlineViewDoubleClicked:)];

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"main"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [_outlineView addTableColumn:col];

    _scrollView = [[NSScrollView alloc] initWithFrame:self.view.bounds];
    _scrollView.autoresizingMask       = NSViewWidthSizable | NSViewHeightSizable;
    _scrollView.hasVerticalScroller    = YES;
    _scrollView.drawsBackground        = NO;
    _scrollView.documentView           = _outlineView;

    [self.view addSubview:_scrollView];

    [self buildSections];
    [_outlineView reloadData];
    [_outlineView expandItem:nil expandChildren:YES];

    // Observe workspace notifications for volume mount/unmount
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self
           selector:@selector(volumesChanged:)
               name:NSWorkspaceDidMountNotification
             object:nil];
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self
           selector:@selector(volumesChanged:)
               name:NSWorkspaceDidUnmountNotification
             object:nil];
}

- (void)dealloc {
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
}

// ─────────────
// Build model
// ─────────────

- (void)buildSections {
    _sections = [NSMutableArray array];

    // ── Favourites ────────────────────────────────────────────────────────
    SidebarItem *favHeader = [[SidebarItem alloc] initHeader:@"FAVORITOS"];
    ZigVolumeList *specials = zig_get_special_dirs();
    if (specials) {
        for (uint64_t i = 0; i < specials->count; i++) {
            NSString *name = @(specials->volumes[i].name);
            NSString *path = @(specials->volumes[i].path);
            NSImage  *icon = [self iconForSpecialDir:name defaultPath:path];
            SidebarItem *item = [[SidebarItem alloc] initWithName:name path:path icon:icon];
            [favHeader.children addObject:item];
        }
        zig_free_volume_list(specials);
    }
    [_sections addObject:favHeader];

    // ── Devices / Volumes ─────────────────────────────────────────────────
    SidebarItem *volHeader = [[SidebarItem alloc] initHeader:@"DISPOSITIVOS"];
    [self populateVolumes:volHeader];
    [_sections addObject:volHeader];
}

- (void)populateVolumes:(SidebarItem *)header {
    [header.children removeAllObjects];

    // Always add Macintosh HD (root)
    NSImage *hddIcon = [NSImage imageWithSystemSymbolName:@"internaldrive" accessibilityDescription:nil] ?:
                       [NSImage imageNamed:NSImageNameComputer];
    SidebarItem *root = [[SidebarItem alloc] initWithName:@"Macintosh HD" path:@"/" icon:hddIcon];
    [header.children addObject:root];

    ZigVolumeList *vols = zig_get_volumes();
    if (vols) {
        for (uint64_t i = 0; i < vols->count; i++) {
            NSString *name = @(vols->volumes[i].name);
            NSString *path = @(vols->volumes[i].path);
            // Skip the symlink that points to /
            if ([path isEqualToString:@"/Volumes/Macintosh HD"]) continue;
            NSImage *icon = [NSImage imageWithSystemSymbolName:@"externaldrive" accessibilityDescription:nil] ?:
                            [NSImage imageNamed:NSImageNameMultipleDocuments];
            SidebarItem *item = [[SidebarItem alloc] initWithName:name path:path icon:icon];
            [header.children addObject:item];
        }
        zig_free_volume_list(vols);
    }
}

- (NSImage *)iconForSpecialDir:(NSString *)name defaultPath:(NSString *)path {
    static NSDictionary<NSString *, NSString *> *symbolMap = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        symbolMap = @{
            @"Inicio":       @"house",
            @"Escritorio":   @"desktopcomputer",
            @"Documentos":   @"doc",
            @"Descargas":    @"arrow.down.circle",
            @"Música":       @"music.note",
            @"Imágenes":     @"photo",
            @"Películas":    @"film",
            @"Aplicaciones": @"square.grid.2x2",
        };
    });
    NSString *sym = symbolMap[name];
    if (sym) {
        NSImage *img = [NSImage imageWithSystemSymbolName:sym accessibilityDescription:name];
        if (img) return img;
    }
    return [[NSWorkspace sharedWorkspace] iconForFile:path];
}

// ─────────────
// Volume changes
// ─────────────

- (void)volumesChanged:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        SidebarItem *volHeader = self.sections.lastObject;
        [self populateVolumes:volHeader];
        [self.outlineView reloadData];
        [self.outlineView expandItem:nil expandChildren:YES];
    });
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – Public API
// ─────────────────────────────────────────────────────────────────────────────

- (void)highlightPath:(NSString *)path {
    _isHighlighting = YES;
    for (SidebarItem *section in _sections) {
        for (SidebarItem *item in section.children) {
            if ([path hasPrefix:item.path]) {
                NSInteger row = [_outlineView rowForItem:item];
                if (row >= 0) {
                    [_outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row]
                              byExtendingSelection:NO];
                    _isHighlighting = NO;
                    return;
                }
            }
        }
    }
    // No match – deselect
    [_outlineView deselectAll:nil];
    _isHighlighting = NO;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – NSOutlineViewDataSource
// ─────────────────────────────────────────────────────────────────────────────

- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item {
    if (!item) return (NSInteger)_sections.count;
    SidebarItem *si = item;
    return (NSInteger)si.children.count;
}

- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)index ofItem:(id)item {
    if (!item) return _sections[(NSUInteger)index];
    SidebarItem *si = item;
    return si.children[(NSUInteger)index];
}

- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item {
    SidebarItem *si = item;
    return si.children.count > 0;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – NSOutlineViewDelegate
// ─────────────────────────────────────────────────────────────────────────────

- (BOOL)outlineView:(NSOutlineView *)ov isGroupItem:(id)item {
    return ((SidebarItem *)item).isHeader;
}

- (BOOL)outlineView:(NSOutlineView *)ov shouldSelectItem:(id)item {
    return !((SidebarItem *)item).isHeader;
}

- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)col item:(id)item {
    SidebarItem *si = item;

    if (si.isHeader) {
        NSTableCellView *cell = [ov makeViewWithIdentifier:@"HeaderCell" owner:self];
        if (!cell) {
            cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
            cell.identifier = @"HeaderCell";
            NSTextField *tf = [NSTextField labelWithString:@""];
            tf.font        = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
            tf.textColor   = [NSColor tertiaryLabelColor];
            tf.translatesAutoresizingMaskIntoConstraints = NO;
            [cell addSubview:tf];
            cell.textField = tf;
            [NSLayoutConstraint activateConstraints:@[
                [tf.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
                [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            ]];
        }
        cell.textField.stringValue = si.name;
        return cell;
    }

    NSTableCellView *cell = [ov makeViewWithIdentifier:@"ItemCell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = @"ItemCell";

        NSImageView *iv = [[NSImageView alloc] initWithFrame:NSZeroRect];
        iv.translatesAutoresizingMaskIntoConstraints = NO;
        iv.imageScaling = NSImageScaleProportionallyDown;
        [cell addSubview:iv];
        cell.imageView = iv;

        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.font = [NSFont systemFontOfSize:13];
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell addSubview:tf];
        cell.textField = tf;

        [NSLayoutConstraint activateConstraints:@[
            [iv.leadingAnchor  constraintEqualToAnchor:cell.leadingAnchor constant:4],
            [iv.centerYAnchor  constraintEqualToAnchor:cell.centerYAnchor],
            [iv.widthAnchor    constraintEqualToConstant:16],
            [iv.heightAnchor   constraintEqualToConstant:16],
            [tf.leadingAnchor  constraintEqualToAnchor:iv.trailingAnchor constant:6],
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
            [tf.centerYAnchor  constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }
    cell.textField.stringValue = si.name;
    NSImage *icon = si.icon ?: [[NSWorkspace sharedWorkspace] iconForFile:si.path ?: @"/"];
    icon.size = NSMakeSize(16, 16);
    cell.imageView.image = icon;
    return cell;
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification {
    if (_isHighlighting) return;  // programmatic selection – don't push to history
    NSInteger row = _outlineView.selectedRow;
    if (row < 0) return;
    SidebarItem *item = [_outlineView itemAtRow:row];
    if (item.isHeader || !item.path) return;
    [self.delegate sidebar:self didSelectPath:item.path];
}

- (IBAction)outlineViewDoubleClicked:(id)sender {
    // Double-click on sidebar item is same as single select (already handled)
}

@end
