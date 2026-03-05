// GoToFolderPanel.m
#import "GoToFolderPanel.h"

@implementation GoToFolderPanel

+ (void)runAsSheetOnWindow:(NSWindow *)parentWindow
         completionHandler:(void (^)(NSString *path))handler {

    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
    field.placeholderString = @"~/Documentos  o  /usr/local/bin";
    field.font              = [NSFont systemFontOfSize:13];
    field.cell.scrollable   = YES;
    field.stringValue       = NSHomeDirectory();

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText     = @"Ir a la carpeta";
    alert.informativeText = @"Escribe la ruta a la que deseas navegar:";
    [alert addButtonWithTitle:@"Ir"];
    [alert addButtonWithTitle:@"Cancelar"];
    alert.accessoryView = field;

    if (parentWindow) {
        [alert beginSheetModalForWindow:parentWindow completionHandler:^(NSModalResponse resp) {
            if (resp != NSAlertFirstButtonReturn) {
                if (handler) handler(nil);
                return;
            }
            NSString *entered = [field.stringValue
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSString *resolved = [GoToFolderPanel resolvePath:entered];
            if (handler) handler(resolved);
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            [alert.window makeFirstResponder:field];
        });
    } else {
        NSModalResponse resp = [alert runModal];
        if (resp != NSAlertFirstButtonReturn) {
            if (handler) handler(nil);
            return;
        }
        NSString *entered = [field.stringValue
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *resolved = [GoToFolderPanel resolvePath:entered];
        if (handler) handler(resolved);
    }
}

+ (NSString *)resolvePath:(NSString *)input {
    if (!input.length) return nil;
    NSString *expanded = input.stringByExpandingTildeInPath;
    NSString *resolved = expanded.stringByResolvingSymlinksInPath;
    BOOL isDir = NO;
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:resolved isDirectory:&isDir];
    if (!exists || !isDir) {
        NSAlert *err = [[NSAlert alloc] init];
        err.messageText     = @"Carpeta no encontrada";
        err.informativeText = [NSString stringWithFormat:@"La ruta '%@' no existe o no es una carpeta.", resolved];
        err.alertStyle      = NSAlertStyleCritical;
        [err runModal];
        return nil;
    }
    return resolved;
}

@end
