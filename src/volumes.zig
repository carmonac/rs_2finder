// volumes.zig
// Volume and special directory listing operations

const std = @import("std");
const root = @import("fs_ops.zig");
const Io = std.Io;
const Dir = Io.Dir;
const gpa = root.gpa;
const getIo = root.getIo;
const c_getenv = root.c_getenv;
const ZigVolume = root.ZigVolume;
const ZigVolumeList = root.ZigVolumeList;

pub fn zig_get_volumes() callconv(.c) ?*ZigVolumeList {
    return getVolumes() catch null;
}

fn getVolumes() !*ZigVolumeList {
    const io = getIo();
    var list = std.array_list.Managed(ZigVolume).init(gpa);
    errdefer list.deinit();

    var vols_dir = Dir.openDirAbsolute(io, "/Volumes", .{ .iterate = true }) catch {
        return makeEmptyVolumeList();
    };
    defer vols_dir.close(io);

    var it = vols_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.name[0] == '.') continue;
        const path = try std.fmt.allocPrintSentinel(gpa, "/Volumes/{s}", .{entry.name}, 0);
        const name = try gpa.dupeZ(u8, entry.name);
        try list.append(.{ .name = name, .path = path });
    }

    return finishVolumeList(&list);
}

fn makeEmptyVolumeList() !*ZigVolumeList {
    var empty = std.array_list.Managed(ZigVolume).init(gpa);
    return finishVolumeList(&empty);
}

fn finishVolumeList(list: *std.array_list.Managed(ZigVolume)) !*ZigVolumeList {
    const vl = try gpa.create(ZigVolumeList);
    const slice = try list.toOwnedSlice();
    vl.* = .{ .volumes = slice.ptr, .count = slice.len };
    return vl;
}

pub fn zig_get_special_dirs() callconv(.c) ?*ZigVolumeList {
    return getSpecialDirs() catch null;
}

fn getSpecialDirs() !*ZigVolumeList {
    const io = getIo();
    const home_ptr = c_getenv("HOME") orelse return makeEmptyVolumeList();
    const home = std.mem.sliceTo(home_ptr, 0);
    var list = std.array_list.Managed(ZigVolume).init(gpa);
    errdefer list.deinit();

    const dirs = [_]struct { name: []const u8, rel: []const u8 }{
        .{ .name = "Inicio", .rel = "" },
        .{ .name = "Escritorio", .rel = "/Desktop" },
        .{ .name = "Documentos", .rel = "/Documents" },
        .{ .name = "Descargas", .rel = "/Downloads" },
        .{ .name = "Música", .rel = "/Music" },
        .{ .name = "Imágenes", .rel = "/Pictures" },
        .{ .name = "Películas", .rel = "/Movies" },
        .{ .name = "Aplicaciones", .rel = "/Applications" },
    };

    for (dirs) |d| {
        const full = if (d.rel.len == 0)
            try gpa.dupeZ(u8, home)
        else
            try std.fmt.allocPrintSentinel(gpa, "{s}{s}", .{ home, d.rel }, 0);
        // Only add if the directory actually exists
        var dir = Dir.openDirAbsolute(io, std.mem.sliceTo(full, 0), .{}) catch {
            gpa.free(full);
            continue;
        };
        dir.close(io);
        const name = try gpa.dupeZ(u8, d.name);
        try list.append(.{ .name = name, .path = full });
    }

    return finishVolumeList(&list);
}

pub fn zig_free_volume_list(list: ?*ZigVolumeList) callconv(.c) void {
    const l = list orelse return;
    for (l.volumes[0..l.count]) |v| {
        gpa.free(std.mem.sliceTo(v.name, 0));
        gpa.free(std.mem.sliceTo(v.path, 0));
    }
    gpa.free(l.volumes[0..l.count]);
    gpa.destroy(l);
}

// ===========================================================================
// Tests
// ===========================================================================

test "zig_get_volumes returns a non-null list" {
    const vl = zig_get_volumes();
    try std.testing.expect(vl != null);
    zig_free_volume_list(vl);
}

test "zig_get_special_dirs includes home directory" {
    const sl = zig_get_special_dirs() orelse return error.NullList;
    defer zig_free_volume_list(sl);
    try std.testing.expect(sl.count > 0);
}
