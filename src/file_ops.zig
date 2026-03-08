// file_ops.zig
// Basic file operations: delete, create directory, rename

const std = @import("std");
const root = @import("fs_ops.zig");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const gpa = root.gpa;
const getIo = root.getIo;

// ---------------------------------------------------------------------------
// zig_delete_files
// ---------------------------------------------------------------------------

pub fn zig_delete_files(
    paths: [*]const [*:0]const u8,
    count: u64,
    err_buf: [*]u8,
    err_buf_len: u64,
) callconv(.c) bool {
    const io = getIo();
    for (paths[0..count]) |p| {
        const path_slice = std.mem.sliceTo(p, 0);
        var child = std.process.spawn(io, .{
            .argv = &.{ "/bin/rm", "-rf", path_slice },
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch {
            _ = std.fmt.bufPrint(err_buf[0..err_buf_len], "no se pudo eliminar: {s}", .{path_slice}) catch {};
            return false;
        };
        const term = child.wait(io) catch {
            _ = std.fmt.bufPrint(err_buf[0..err_buf_len], "no se pudo eliminar: {s}", .{path_slice}) catch {};
            return false;
        };
        switch (term) {
            .exited => |code| if (code != 0) {
                _ = std.fmt.bufPrint(err_buf[0..err_buf_len], "rm falló en: {s}", .{path_slice}) catch {};
                return false;
            },
            else => return false,
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// zig_create_directory
// ---------------------------------------------------------------------------

pub fn zig_create_directory(path: [*:0]const u8, err_buf: [*]u8, err_buf_len: u64) callconv(.c) bool {
    const io = getIo();
    Dir.createDirAbsolute(io, std.mem.sliceTo(path, 0), File.Permissions.default_dir) catch |err| {
        _ = std.fmt.bufPrint(err_buf[0..err_buf_len], "error: {}", .{err}) catch {};
        return false;
    };
    return true;
}

// ---------------------------------------------------------------------------
// zig_rename
// ---------------------------------------------------------------------------

pub fn zig_rename(src: [*:0]const u8, dst: [*:0]const u8, err_buf: [*]u8, err_buf_len: u64) callconv(.c) bool {
    const io = getIo();
    Dir.renameAbsolute(std.mem.sliceTo(src, 0), std.mem.sliceTo(dst, 0), io) catch |err| {
        _ = std.fmt.bufPrint(err_buf[0..err_buf_len], "error: {}", .{err}) catch {};
        return false;
    };
    return true;
}

// ===========================================================================
// Tests
// ===========================================================================

test "zig_create_directory creates a new directory" {
    const io = getIo();
    const base = try root.testBasePath();
    defer gpa.free(base);

    var buf: [Dir.max_path_bytes + 1]u8 = undefined;
    const test_path = try std.fmt.bufPrintZ(&buf, "{s}/mkdir_test", .{base});
    Dir.deleteTree(.cwd(), io, test_path) catch {};
    defer Dir.deleteTree(.cwd(), io, test_path) catch {};

    var eb: [256]u8 = undefined;
    try std.testing.expect(zig_create_directory(test_path, &eb, eb.len));
    // Should exist now
    var d = try Dir.openDirAbsolute(io, test_path, .{});
    d.close(io);
}

test "zig_create_directory fails on existing path" {
    const io = getIo();
    const base = try root.testBasePath();
    defer gpa.free(base);

    var buf: [Dir.max_path_bytes + 1]u8 = undefined;
    const test_path = try std.fmt.bufPrintZ(&buf, "{s}/mkdir_dup", .{base});
    Dir.deleteTree(.cwd(), io, test_path) catch {};
    Dir.createDirAbsolute(io, test_path, File.Permissions.default_dir) catch {};
    defer Dir.deleteTree(.cwd(), io, test_path) catch {};

    var eb: [256]u8 = undefined;
    try std.testing.expect(!zig_create_directory(test_path, &eb, eb.len));
}

test "zig_rename renames a file" {
    const io = getIo();
    const base = try root.testBasePath();
    defer gpa.free(base);

    const src = try std.fmt.allocPrintSentinel(gpa, "{s}/rename_src.txt", .{base}, 0);
    defer gpa.free(src);
    const dst = try std.fmt.allocPrintSentinel(gpa, "{s}/rename_dst.txt", .{base}, 0);
    defer gpa.free(dst);

    Dir.deleteFileAbsolute(io, src) catch {};
    Dir.deleteFileAbsolute(io, dst) catch {};
    defer Dir.deleteFileAbsolute(io, dst) catch {};

    const fh = try Dir.createFileAbsolute(io, src, .{});
    fh.close(io);

    var eb: [256]u8 = undefined;
    try std.testing.expect(zig_rename(src, dst, &eb, eb.len));
    try Dir.accessAbsolute(io, dst, .{});
    if (Dir.accessAbsolute(io, src, .{})) |_| return error.SrcStillExists else |_| {}
}

test "zig_delete_files removes a file" {
    const io = getIo();
    const base = try root.testBasePath();
    defer gpa.free(base);

    const fpath = try std.fmt.allocPrintSentinel(gpa, "{s}/del_me.txt", .{base}, 0);
    defer gpa.free(fpath);
    const fh = try Dir.createFileAbsolute(io, fpath, .{});
    fh.close(io);

    var eb: [256]u8 = undefined;
    const ptrs = [_][*:0]const u8{fpath.ptr};
    try std.testing.expect(zig_delete_files(&ptrs, 1, &eb, eb.len));
    if (Dir.accessAbsolute(io, fpath, .{})) |_| return error.FileStillExists else |_| {}
}
