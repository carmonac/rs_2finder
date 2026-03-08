// dir_listing.zig
// Directory listing operations: zig_list_directory, zig_free_dir_listing

const std = @import("std");
const root = @import("fs_ops.zig");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const gpa = root.gpa;
const getIo = root.getIo;
const ZigDirEntry = root.ZigDirEntry;
const ZigDirListing = root.ZigDirListing;

pub fn zig_list_directory(path: [*:0]const u8) callconv(.c) ?*ZigDirListing {
    return listDirectory(path) catch null;
}

fn listDirectory(path: [*:0]const u8) !*ZigDirListing {
    const io = getIo();
    const path_slice = std.mem.sliceTo(path, 0);
    var dir = try Dir.openDirAbsolute(io, path_slice, .{ .iterate = true });
    defer dir.close(io);

    var entries_list = std.array_list.Managed(ZigDirEntry).init(gpa);
    errdefer {
        for (entries_list.items) |e| {
            gpa.free(std.mem.sliceTo(e.name, 0));
            gpa.free(std.mem.sliceTo(e.path, 0));
        }
        entries_list.deinit();
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        // Build full path
        const full_path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ path_slice, entry.name }, 0);
        const name_z = try gpa.dupeZ(u8, entry.name);

        var size: u64 = 0;
        var mtime: i64 = 0;
        var is_symlink = false;

        if (Dir.openFileAbsolute(io, full_path, .{})) |f| {
            defer f.close(io);
            if (f.stat(io)) |st| {
                size = st.size;
                mtime = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_s));
            } else |_| {}
        } else |_| {}

        is_symlink = (entry.kind == .sym_link);

        try entries_list.append(.{
            .name = name_z,
            .path = full_path,
            .is_dir = (entry.kind == .directory or (is_symlink and isSymlinkDir(full_path))),
            .is_symlink = is_symlink,
            .size = size,
            .mtime = mtime,
        });
    }

    // Sort: directories first, then alphabetically
    std.mem.sort(ZigDirEntry, entries_list.items, {}, struct {
        fn lessThan(_: void, a: ZigDirEntry, b: ZigDirEntry) bool {
            if (a.is_dir != b.is_dir) return a.is_dir;
            const na = std.mem.sliceTo(a.name, 0);
            const nb = std.mem.sliceTo(b.name, 0);
            return std.ascii.orderIgnoreCase(na, nb) == .lt;
        }
    }.lessThan);

    const listing = try gpa.create(ZigDirListing);
    const slice = try entries_list.toOwnedSlice();
    listing.* = .{ .entries = slice.ptr, .count = slice.len };
    return listing;
}

fn isSymlinkDir(path: [*:0]const u8) bool {
    const io = getIo();
    const path_slice = std.mem.sliceTo(path, 0);
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const len = Dir.realPathFileAbsolute(io, path_slice, &buf) catch return false;
    var d = Dir.openDirAbsolute(io, buf[0..len], .{}) catch return false;
    d.close(io);
    return true;
}

pub fn zig_free_dir_listing(listing: ?*ZigDirListing) callconv(.c) void {
    const l = listing orelse return;
    for (l.entries[0..l.count]) |e| {
        gpa.free(std.mem.sliceTo(e.name, 0));
        gpa.free(std.mem.sliceTo(e.path, 0));
    }
    gpa.free(l.entries[0..l.count]);
    gpa.destroy(l);
}

// ===========================================================================
// Tests
// ===========================================================================

test "zig_list_directory lists entries, dirs first" {
    const io = getIo();
    const base = try root.testBasePath();
    defer gpa.free(base);

    var buf: [Dir.max_path_bytes + 1]u8 = undefined;
    const test_path = try std.fmt.bufPrintZ(&buf, "{s}/list_test", .{base});

    Dir.deleteTree(.cwd(), io, test_path) catch {};
    Dir.createDirAbsolute(io, test_path, File.Permissions.default_dir) catch {};
    defer Dir.deleteTree(.cwd(), io, test_path) catch {};

    // Create a file and a subdirectory
    const sub = try std.fmt.allocPrintSentinel(gpa, "{s}/subdir", .{test_path}, 0);
    defer gpa.free(sub);
    Dir.createDirAbsolute(io, sub, File.Permissions.default_dir) catch {};

    const fpath = try std.fmt.allocPrintSentinel(gpa, "{s}/afile.txt", .{test_path}, 0);
    defer gpa.free(fpath);
    const fh = try Dir.createFileAbsolute(io, fpath, .{});
    fh.close(io);

    const listing = zig_list_directory(test_path) orelse return error.NullListing;
    defer zig_free_dir_listing(listing);

    try std.testing.expect(listing.count >= 2);
    // First entry should be the directory
    try std.testing.expect(listing.entries[0].is_dir);
}

test "zig_list_directory returns null for non-existent path" {
    const result = zig_list_directory("/tmp/__zig_nonexistent_dir__");
    try std.testing.expect(result == null);
}
