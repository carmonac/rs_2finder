// rs_2finder – entry point

const std = @import("std");

// fs_ops symbols are exported as C functions and called by ObjC code.
pub const fs_ops = @import("fs_ops.zig");

// objc_run_app is implemented in objc/AppDelegate.m; it calls [NSApp run].
extern fn objc_run_app() void;

pub fn main() void {
    fs_ops.init();
    objc_run_app();
}
