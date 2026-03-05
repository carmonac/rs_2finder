// fs_ops.zig
// All file-system operations exposed to the ObjC layer via the C ABI
// defined in include/bridge.h.
//
// Threading model:
//   • zig_copy_files / zig_move_files spawn a detached thread.
//   • Callbacks are invoked on that thread; ObjC side must dispatch_async
//     to the main queue before touching UI.

const std = @import("std");
const builtin = @import("builtin");

// ---------------------------------------------------------------------------
// Global allocator (thread-safe GPA)
// ---------------------------------------------------------------------------

var gpa_state = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
const gpa = gpa_state.allocator();

pub fn init() void {}

export fn zig_init() void {
    init();
}

// ---------------------------------------------------------------------------
// C types mirroring include/bridge.h
// ---------------------------------------------------------------------------

const ZigDirEntry = extern struct {
    name: [*:0]const u8,
    path: [*:0]const u8,
    is_dir: bool,
    is_symlink: bool,
    size: u64,
    mtime: i64,
};

const ZigDirListing = extern struct {
    entries: [*]ZigDirEntry,
    count: u64,
};

const ZigVolume = extern struct {
    name: [*:0]const u8,
    path: [*:0]const u8,
};

const ZigVolumeList = extern struct {
    volumes: [*]ZigVolume,
    count: u64,
};

const ZigProgressCallback = *const fn (
    ctx: ?*anyopaque,
    progress: f64,
    bytes_transferred: u64,
    total_bytes: u64,
    speed: f64,
    eta_secs: i64,
) callconv(.c) void;

const ZigCompletionCallback = *const fn (
    ctx: ?*anyopaque,
    success: bool,
    error_msg: ?[*:0]const u8,
) callconv(.c) void;

// ---------------------------------------------------------------------------
// zig_list_directory
// ---------------------------------------------------------------------------

export fn zig_list_directory(path: [*:0]const u8) ?*ZigDirListing {
    return listDirectory(path) catch null;
}

fn listDirectory(path: [*:0]const u8) !*ZigDirListing {
    const path_slice = std.mem.sliceTo(path, 0);
    var dir = try std.fs.openDirAbsolute(path_slice, .{ .iterate = true });
    defer dir.close();

    var entries_list = std.array_list.Managed(ZigDirEntry).init(gpa);
    errdefer {
        for (entries_list.items) |e| {
            gpa.free(std.mem.sliceTo(e.name, 0));
            gpa.free(std.mem.sliceTo(e.path, 0));
        }
        entries_list.deinit();
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        // Build full path
        const full_path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ path_slice, entry.name }, 0);
        const name_z = try gpa.dupeZ(u8, entry.name);

        var size: u64 = 0;
        var mtime: i64 = 0;
        var is_symlink = false;

        if (std.fs.openFileAbsolute(full_path, .{})) |f| {
            defer f.close();
            if (f.stat()) |st| {
                size = st.size;
                mtime = @intCast(@divTrunc(st.mtime, std.time.ns_per_s));
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
    const path_slice = std.mem.sliceTo(path, 0);
    const real = std.fs.realpathAlloc(gpa, path_slice) catch return false;
    defer gpa.free(real);
    var d = std.fs.openDirAbsolute(real, .{}) catch return false;
    d.close();
    return true;
}

export fn zig_free_dir_listing(listing: ?*ZigDirListing) void {
    const l = listing orelse return;
    for (l.entries[0..l.count]) |e| {
        gpa.free(std.mem.sliceTo(e.name, 0));
        gpa.free(std.mem.sliceTo(e.path, 0));
    }
    gpa.free(l.entries[0..l.count]);
    gpa.destroy(l);
}

// ---------------------------------------------------------------------------
// zig_get_volumes  (mounted volumes under /Volumes)
// ---------------------------------------------------------------------------

export fn zig_get_volumes() ?*ZigVolumeList {
    return getVolumes() catch null;
}

fn getVolumes() !*ZigVolumeList {
    var list = std.array_list.Managed(ZigVolume).init(gpa);
    errdefer list.deinit();

    var vols_dir = std.fs.openDirAbsolute("/Volumes", .{ .iterate = true }) catch {
        return makeEmptyVolumeList();
    };
    defer vols_dir.close();

    var it = vols_dir.iterate();
    while (try it.next()) |entry| {
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

// ---------------------------------------------------------------------------
// zig_get_special_dirs
// ---------------------------------------------------------------------------

export fn zig_get_special_dirs() ?*ZigVolumeList {
    return getSpecialDirs() catch null;
}

fn getSpecialDirs() !*ZigVolumeList {
    const home = std.posix.getenv("HOME") orelse "/";
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
        var dir = std.fs.openDirAbsolute(std.mem.sliceTo(full, 0), .{}) catch {
            gpa.free(full);
            continue;
        };
        dir.close();
        const name = try gpa.dupeZ(u8, d.name);
        try list.append(.{ .name = name, .path = full });
    }

    return finishVolumeList(&list);
}

export fn zig_free_volume_list(list: ?*ZigVolumeList) void {
    const l = list orelse return;
    for (l.volumes[0..l.count]) |v| {
        gpa.free(std.mem.sliceTo(v.name, 0));
        gpa.free(std.mem.sliceTo(v.path, 0));
    }
    gpa.free(l.volumes[0..l.count]);
    gpa.destroy(l);
}

// ---------------------------------------------------------------------------
// zig_check_collision
// ---------------------------------------------------------------------------

export fn zig_check_collision(
    src_paths: [*]const [*:0]const u8,
    src_count: u64,
    dst_dir: [*:0]const u8,
) bool {
    const dst = std.mem.sliceTo(dst_dir, 0);
    for (src_paths[0..src_count]) |sp| {
        const src = std.mem.sliceTo(sp, 0);
        const basename = std.fs.path.basename(src);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const candidate = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dst, basename }) catch continue;
        std.fs.accessAbsolute(std.mem.sliceTo(candidate, 0), .{}) catch continue;
        return true; // exists
    }
    return false;
}

// ---------------------------------------------------------------------------
// Copy / Move  (async, rsync-based)
// ---------------------------------------------------------------------------

const TransferJob = struct {
    src_paths: [][:0]u8,
    dst_dir: [:0]u8,
    overwrite: bool,
    is_move: bool,
    ctx: ?*anyopaque,
    on_progress: ZigProgressCallback,
    on_done: ZigCompletionCallback,
};

export fn zig_copy_files(
    src_paths: [*]const [*:0]const u8,
    src_count: u64,
    dst_dir: [*:0]const u8,
    overwrite: bool,
    ctx: ?*anyopaque,
    on_progress: ZigProgressCallback,
    on_done: ZigCompletionCallback,
) void {
    spawnTransfer(src_paths, src_count, dst_dir, overwrite, false, ctx, on_progress, on_done);
}

export fn zig_move_files(
    src_paths: [*]const [*:0]const u8,
    src_count: u64,
    dst_dir: [*:0]const u8,
    overwrite: bool,
    ctx: ?*anyopaque,
    on_progress: ZigProgressCallback,
    on_done: ZigCompletionCallback,
) void {
    spawnTransfer(src_paths, src_count, dst_dir, overwrite, true, ctx, on_progress, on_done);
}

fn spawnTransfer(
    src_paths: [*]const [*:0]const u8,
    src_count: u64,
    dst_dir: [*:0]const u8,
    overwrite: bool,
    is_move: bool,
    ctx: ?*anyopaque,
    on_progress: ZigProgressCallback,
    on_done: ZigCompletionCallback,
) void {
    var paths = gpa.alloc([:0]u8, src_count) catch {
        on_done(ctx, false, "sin memoria");
        return;
    };
    for (src_paths[0..src_count], 0..) |p, i| {
        paths[i] = gpa.dupeZ(u8, std.mem.sliceTo(p, 0)) catch {
            // free already-allocated paths
            for (paths[0..i]) |prev| gpa.free(prev);
            gpa.free(paths);
            on_done(ctx, false, "sin memoria");
            return;
        };
    }
    const job = gpa.create(TransferJob) catch {
        for (paths) |p| gpa.free(p);
        gpa.free(paths);
        on_done(ctx, false, "sin memoria");
        return;
    };
    job.* = .{
        .src_paths = paths,
        .dst_dir = gpa.dupeZ(u8, std.mem.sliceTo(dst_dir, 0)) catch {
            for (paths) |p| gpa.free(p);
            gpa.free(paths);
            gpa.destroy(job);
            on_done(ctx, false, "sin memoria");
            return;
        },
        .overwrite = overwrite,
        .is_move = is_move,
        .ctx = ctx,
        .on_progress = on_progress,
        .on_done = on_done,
    };
    const thread = std.Thread.spawn(.{}, transferThread, .{job}) catch {
        freeJob(job);
        on_done(ctx, false, "no se pudo crear hilo");
        return;
    };
    thread.detach();
}

fn freeJob(job: *TransferJob) void {
    for (job.src_paths) |p| gpa.free(p);
    gpa.free(job.src_paths);
    gpa.free(job.dst_dir);
    gpa.destroy(job);
}

// Rsync progress2 output line example:
//         32,768  50%   31.25kB/s    0:00:00 (xfr#1, to-chk=0/1)
fn transferThread(job: *TransferJob) void {
    defer freeJob(job);
    runTransfer(job) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "Error: {}", .{err}) catch "error desconocido";
        job.on_done(job.ctx, false, msg.ptr);
    };
}

fn runTransfer(job: *TransferJob) !void {
    const raw_dst = std.mem.sliceTo(job.dst_dir, 0);

    // Destination needs a trailing slash: rsync copies sources *into* the dir.
    const dst_with_slash = if (std.mem.endsWith(u8, raw_dst, "/"))
        try gpa.dupeZ(u8, raw_dst)
    else
        try std.fmt.allocPrintSentinel(gpa, "{s}/", .{raw_dst}, 0);
    defer gpa.free(dst_with_slash);

    var argv = std.array_list.Managed([]const u8).init(gpa);
    defer argv.deinit();

    try argv.append("/usr/bin/rsync");
    try argv.append("-a"); // archive: recursive, preserve attrs/symlinks/perms
    try argv.append("-P"); // --partial --progress per file
    if (!job.overwrite) try argv.append("--ignore-existing");
    if (job.is_move) try argv.append("--remove-source-files"); // atomic move

    for (job.src_paths) |p| try argv.append(std.mem.sliceTo(p, 0));
    try argv.append(std.mem.sliceTo(dst_with_slash, 0));

    var child = std.process.Child.init(argv.items, gpa);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    // Drain stdout and stderr in parallel threads so neither pipe ever fills
    // and deadlocks rsync.
    const DrainCtx = struct {
        file: std.fs.File,
        buf: [8192]u8 = undefined,
        len: usize = 0,
        fn run(ctx: *@This()) void {
            while (true) {
                const space = ctx.buf.len - 1 - ctx.len;
                if (space == 0) {
                    // Buffer full – just discard further output by reading into
                    // a scratch buffer so rsync keeps running.
                    var scratch: [4096]u8 = undefined;
                    const n = ctx.file.read(&scratch) catch break;
                    if (n == 0) break;
                } else {
                    const n = ctx.file.read(ctx.buf[ctx.len .. ctx.len + space]) catch break;
                    if (n == 0) break;
                    ctx.len += n;
                }
            }
        }
    };

    var stdoutCtx = DrainCtx{ .file = child.stdout.? };
    var stderrCtx = DrainCtx{ .file = child.stderr.? };
    const stdoutThread = try std.Thread.spawn(.{}, DrainCtx.run, .{&stdoutCtx});
    const stderrThread = try std.Thread.spawn(.{}, DrainCtx.run, .{&stderrCtx});

    stdoutThread.join();
    stderrThread.join();

    const term = try child.wait();
    const exit_code: u8 = switch (term) {
        .Exited => |c| c,
        else => 255,
    };
    const success = exit_code == 0;

    if (!success) {
        const se = std.mem.trim(u8, stderrCtx.buf[0..stderrCtx.len], " \t\r\n");
        var eb: [512]u8 = undefined;
        const msg = if (se.len > 0)
            std.fmt.bufPrintZ(&eb, "rsync: {s}", .{se}) catch "rsync falló"
        else
            std.fmt.bufPrintZ(&eb, "rsync salió con código {d}", .{exit_code}) catch "rsync falló";
        job.on_done(job.ctx, false, msg.ptr);
        return;
    }

    // For a move, --remove-source-files only removes files (not empty dirs).
    // Clean up leftover empty directories.
    if (job.is_move) {
        for (job.src_paths) |p| {
            const src = std.mem.sliceTo(p, 0);
            var rm_args = [_][]const u8{ "/bin/rm", "-rf", src };
            var rmc = std.process.Child.init(&rm_args, gpa);
            _ = rmc.spawnAndWait() catch {};
        }
    }

    job.on_done(job.ctx, true, null);
}

// ---------------------------------------------------------------------------
// zig_delete_files
// ---------------------------------------------------------------------------

export fn zig_delete_files(
    paths: [*]const [*:0]const u8,
    count: u64,
    err_buf: [*]u8,
    err_buf_len: u64,
) bool {
    for (paths[0..count]) |p| {
        const path_slice = std.mem.sliceTo(p, 0);
        // Try removing via trash first (using AppleScript)
        if (!trashViaApplescript(path_slice)) {
            // Fallback: rm -rf
            var argv = [_][]const u8{ "rm", "-rf", path_slice };
            var child = std.process.Child.init(&argv, gpa);
            const term = child.spawnAndWait() catch {
                _ = std.fmt.bufPrint(err_buf[0..err_buf_len], "no se pudo eliminar: {s}", .{path_slice}) catch {};
                return false;
            };
            switch (term) {
                .Exited => |code| if (code != 0) {
                    _ = std.fmt.bufPrint(err_buf[0..err_buf_len], "rm falló en: {s}", .{path_slice}) catch {};
                    return false;
                },
                else => return false,
            }
        }
    }
    return true;
}

fn trashViaApplescript(path: []const u8) bool {
    var buf: [1024]u8 = undefined;
    const script = std.fmt.bufPrint(&buf,
        \\tell application "Finder" to delete POSIX file "{s}"
    , .{path}) catch return false;
    var argv = [_][]const u8{ "osascript", "-e", script };
    var child = std.process.Child.init(&argv, gpa);
    // Do NOT inherit the caller's stdin/stdout/stderr.  If osascript blocks
    // (e.g. waiting for a macOS Automation permission dialog) while the
    // caller's stdout is a pipe, the pipe would never reach EOF and the
    // reader (zig build / any test harness) would deadlock.
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const term = child.spawnAndWait() catch return false;
    return switch (term) {
        .Exited => |c| c == 0,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// zig_create_directory
// ---------------------------------------------------------------------------

export fn zig_create_directory(path: [*:0]const u8, err_buf: [*]u8, err_buf_len: u64) bool {
    std.fs.makeDirAbsolute(std.mem.sliceTo(path, 0)) catch |err| {
        _ = std.fmt.bufPrint(err_buf[0..err_buf_len], "error: {}", .{err}) catch {};
        return false;
    };
    return true;
}

// ---------------------------------------------------------------------------
// zig_rename
// ---------------------------------------------------------------------------

export fn zig_rename(src: [*:0]const u8, dst: [*:0]const u8, err_buf: [*]u8, err_buf_len: u64) bool {
    std.fs.renameAbsolute(std.mem.sliceTo(src, 0), std.mem.sliceTo(dst, 0)) catch |err| {
        _ = std.fmt.bufPrint(err_buf[0..err_buf_len], "error: {}", .{err}) catch {};
        return false;
    };
    return true;
}

// ===========================================================================
// Unit tests  –  run with:  zig build test-fs
// Each test creates its own subdirectory inside test_dir/, operates on dummy
// files, then cleans up.  test_dir/ itself must exist at the project root.
// ===========================================================================

/// Callback context used by the async copy/move tests.
const DoneCtx = struct {
    mu: std.Thread.Mutex = .{},
    cv: std.Thread.Condition = .{},
    done: bool = false,
    success: bool = false,

    fn onProgress(_: ?*anyopaque, _: f64, _: u64, _: u64, _: f64, _: i64) callconv(.c) void {}

    fn onDone(raw: ?*anyopaque, ok: bool, _: ?[*:0]const u8) callconv(.c) void {
        const self: *DoneCtx = @ptrCast(@alignCast(raw.?));
        self.mu.lock();
        defer self.mu.unlock();
        self.success = ok;
        self.done = true;
        self.cv.signal();
    }

    fn wait(self: *DoneCtx) bool {
        self.mu.lock();
        defer self.mu.unlock();
        while (!self.done) self.cv.wait(&self.mu);
        return self.success;
    }
};

// ---------------------------------------------------------------------------
// zig_create_directory
// ---------------------------------------------------------------------------

test "zig_create_directory creates a new directory" {
    var rb: [std.fs.max_path_bytes]u8 = undefined;
    const base = try std.fs.cwd().realpath("test_dir", &rb);

    var pb: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&pb, "{s}/create_test", .{base});
    std.fs.deleteTreeAbsolute(path) catch {};

    var err_buf: [256]u8 = undefined;
    try std.testing.expect(zig_create_directory(path.ptr, &err_buf, err_buf.len));

    var d = try std.fs.openDirAbsolute(path, .{});
    d.close();

    try std.fs.deleteTreeAbsolute(path);
}

test "zig_create_directory fails on existing path" {
    var rb: [std.fs.max_path_bytes]u8 = undefined;
    const base = try std.fs.cwd().realpath("test_dir", &rb);

    var pb: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&pb, "{s}/create_exists", .{base});
    std.fs.deleteTreeAbsolute(path) catch {};
    try std.fs.makeDirAbsolute(path);
    defer std.fs.deleteTreeAbsolute(path) catch {};

    var err_buf: [256]u8 = undefined;
    try std.testing.expect(!zig_create_directory(path.ptr, &err_buf, err_buf.len));
}

// ---------------------------------------------------------------------------
// zig_rename
// ---------------------------------------------------------------------------

test "zig_rename renames a file" {
    var rb: [std.fs.max_path_bytes]u8 = undefined;
    const base = try std.fs.cwd().realpath("test_dir", &rb);

    var sb: [std.fs.max_path_bytes + 1]u8 = undefined;
    var db: [std.fs.max_path_bytes + 1]u8 = undefined;
    const src = try std.fmt.bufPrintZ(&sb, "{s}/rename_src.txt", .{base});
    const dst = try std.fmt.bufPrintZ(&db, "{s}/rename_dst.txt", .{base});
    std.fs.deleteFileAbsolute(src) catch {};
    std.fs.deleteFileAbsolute(dst) catch {};

    const fh = try std.fs.createFileAbsolute(src, .{});
    fh.close();

    var err_buf: [256]u8 = undefined;
    try std.testing.expect(zig_rename(src.ptr, dst.ptr, &err_buf, err_buf.len));

    // src must be gone, dst must exist
    if (std.fs.accessAbsolute(src, .{})) |_| return error.SrcStillExists else |_| {}
    try std.fs.accessAbsolute(dst, .{});
    std.fs.deleteFileAbsolute(dst) catch {};
}

// ---------------------------------------------------------------------------
// zig_list_directory  +  zig_free_dir_listing
// ---------------------------------------------------------------------------

test "zig_list_directory lists entries, dirs first" {
    var rb: [std.fs.max_path_bytes]u8 = undefined;
    const base = try std.fs.cwd().realpath("test_dir", &rb);

    var lb: [std.fs.max_path_bytes + 1]u8 = undefined;
    const list_path = try std.fmt.bufPrintZ(&lb, "{s}/list_test", .{base});
    std.fs.deleteTreeAbsolute(list_path) catch {};
    try std.fs.makeDirAbsolute(list_path);
    defer std.fs.deleteTreeAbsolute(list_path) catch {};

    // create file.txt then subdir/
    const file_path = try std.fmt.allocPrintSentinel(gpa, "{s}/file.txt", .{list_path}, 0);
    defer gpa.free(file_path);
    const f = try std.fs.createFileAbsolute(file_path, .{});
    try f.writeAll("hello");
    f.close();

    const sub_path = try std.fmt.allocPrintSentinel(gpa, "{s}/subdir", .{list_path}, 0);
    defer gpa.free(sub_path);
    try std.fs.makeDirAbsolute(sub_path);

    const listing = zig_list_directory(list_path.ptr);
    try std.testing.expect(listing != null);
    defer zig_free_dir_listing(listing);

    try std.testing.expectEqual(@as(u64, 2), listing.?.count);
    // directory comes first
    try std.testing.expect(listing.?.entries[0].is_dir);
    try std.testing.expect(!listing.?.entries[1].is_dir);
    // file has non-zero size
    try std.testing.expect(listing.?.entries[1].size > 0);
}

test "zig_list_directory returns null for non-existent path" {
    const bad: [*:0]const u8 = "/tmp/__nonexistent_rs2finder_xyz__";
    try std.testing.expect(zig_list_directory(bad) == null);
}

// ---------------------------------------------------------------------------
// zig_check_collision
// ---------------------------------------------------------------------------

test "zig_check_collision detects name clash" {
    var rb: [std.fs.max_path_bytes]u8 = undefined;
    const base = try std.fs.cwd().realpath("test_dir", &rb);

    var db: [std.fs.max_path_bytes + 1]u8 = undefined;
    const dst = try std.fmt.bufPrintZ(&db, "{s}/collision_dst", .{base});
    std.fs.deleteTreeAbsolute(dst) catch {};
    try std.fs.makeDirAbsolute(dst);
    defer std.fs.deleteTreeAbsolute(dst) catch {};

    // place clash.txt inside dst
    const clash = try std.fmt.allocPrintSentinel(gpa, "{s}/clash.txt", .{dst}, 0);
    defer gpa.free(clash);
    const fh = try std.fs.createFileAbsolute(clash, .{});
    fh.close();

    // src has same basename → should collide
    var src1b: [std.fs.max_path_bytes + 1]u8 = undefined;
    const src1 = try std.fmt.bufPrintZ(&src1b, "/tmp/clash.txt", .{});
    const ptrs1 = [_][*:0]const u8{src1.ptr};
    try std.testing.expect(zig_check_collision(&ptrs1, 1, dst.ptr));

    // src with different basename → no collision
    var src2b: [std.fs.max_path_bytes + 1]u8 = undefined;
    const src2 = try std.fmt.bufPrintZ(&src2b, "/tmp/unique_xyz_rs2finder.txt", .{});
    const ptrs2 = [_][*:0]const u8{src2.ptr};
    try std.testing.expect(!zig_check_collision(&ptrs2, 1, dst.ptr));
}

// ---------------------------------------------------------------------------
// zig_get_volumes  +  zig_free_volume_list
// ---------------------------------------------------------------------------

test "zig_get_volumes returns a non-null list" {
    const list = zig_get_volumes();
    try std.testing.expect(list != null);
    zig_free_volume_list(list);
}

// ---------------------------------------------------------------------------
// zig_get_special_dirs
// ---------------------------------------------------------------------------

test "zig_get_special_dirs includes home directory" {
    const list = zig_get_special_dirs();
    try std.testing.expect(list != null);
    defer zig_free_volume_list(list);
    try std.testing.expect(list.?.count > 0);
}

// ---------------------------------------------------------------------------
// zig_copy_files  (async via rsync)
// ---------------------------------------------------------------------------

test "zig_copy_files copies file to destination" {
    var rb: [std.fs.max_path_bytes]u8 = undefined;
    const base = try std.fs.cwd().realpath("test_dir", &rb);

    var srcb: [std.fs.max_path_bytes + 1]u8 = undefined;
    var dstb: [std.fs.max_path_bytes + 1]u8 = undefined;
    const src_dir = try std.fmt.bufPrintZ(&srcb, "{s}/copy_src", .{base});
    const dst_dir = try std.fmt.bufPrintZ(&dstb, "{s}/copy_dst", .{base});
    std.fs.deleteTreeAbsolute(src_dir) catch {};
    std.fs.deleteTreeAbsolute(dst_dir) catch {};
    try std.fs.makeDirAbsolute(src_dir);
    try std.fs.makeDirAbsolute(dst_dir);
    defer std.fs.deleteTreeAbsolute(src_dir) catch {};
    defer std.fs.deleteTreeAbsolute(dst_dir) catch {};

    const src_file = try std.fmt.allocPrintSentinel(gpa, "{s}/hello.txt", .{src_dir}, 0);
    defer gpa.free(src_file);
    const fh = try std.fs.createFileAbsolute(src_file, .{});
    try fh.writeAll("hello from rs_2finder\n");
    fh.close();

    var ctx = DoneCtx{};
    const ptrs = [_][*:0]const u8{src_file.ptr};
    zig_copy_files(&ptrs, 1, dst_dir.ptr, true, &ctx, DoneCtx.onProgress, DoneCtx.onDone);
    try std.testing.expect(ctx.wait());

    // dst has the copy
    const dst_file = try std.fmt.allocPrintSentinel(gpa, "{s}/hello.txt", .{dst_dir}, 0);
    defer gpa.free(dst_file);
    try std.fs.accessAbsolute(dst_file, .{});
    // original still present
    try std.fs.accessAbsolute(src_file, .{});
}

test "zig_copy_files respects overwrite=false" {
    var rb: [std.fs.max_path_bytes]u8 = undefined;
    const base = try std.fs.cwd().realpath("test_dir", &rb);

    var srcb: [std.fs.max_path_bytes + 1]u8 = undefined;
    var dstb: [std.fs.max_path_bytes + 1]u8 = undefined;
    const src_dir = try std.fmt.bufPrintZ(&srcb, "{s}/copy_noow_src", .{base});
    const dst_dir = try std.fmt.bufPrintZ(&dstb, "{s}/copy_noow_dst", .{base});
    std.fs.deleteTreeAbsolute(src_dir) catch {};
    std.fs.deleteTreeAbsolute(dst_dir) catch {};
    try std.fs.makeDirAbsolute(src_dir);
    try std.fs.makeDirAbsolute(dst_dir);
    defer std.fs.deleteTreeAbsolute(src_dir) catch {};
    defer std.fs.deleteTreeAbsolute(dst_dir) catch {};

    const src_file = try std.fmt.allocPrintSentinel(gpa, "{s}/data.txt", .{src_dir}, 0);
    defer gpa.free(src_file);
    const dst_file = try std.fmt.allocPrintSentinel(gpa, "{s}/data.txt", .{dst_dir}, 0);
    defer gpa.free(dst_file);

    // write "original" to dst first
    const pre = try std.fs.createFileAbsolute(dst_file, .{});
    try pre.writeAll("original");
    pre.close();

    // write "new" to src
    const sf = try std.fs.createFileAbsolute(src_file, .{});
    try sf.writeAll("new");
    sf.close();

    var ctx = DoneCtx{};
    const ptrs = [_][*:0]const u8{src_file.ptr};
    // overwrite = false → rsync --ignore-existing
    zig_copy_files(&ptrs, 1, dst_dir.ptr, false, &ctx, DoneCtx.onProgress, DoneCtx.onDone);
    try std.testing.expect(ctx.wait());

    // dst content should still be "original"
    const df = try std.fs.openFileAbsolute(dst_file, .{});
    defer df.close();
    var content: [64]u8 = undefined;
    const n = try df.readAll(&content);
    try std.testing.expectEqualStrings("original", content[0..n]);
}

// ---------------------------------------------------------------------------
// zig_move_files  (async via rsync --remove-source-files)
// ---------------------------------------------------------------------------

test "zig_move_files moves file, removes source" {
    var rb: [std.fs.max_path_bytes]u8 = undefined;
    const base = try std.fs.cwd().realpath("test_dir", &rb);

    var srcb: [std.fs.max_path_bytes + 1]u8 = undefined;
    var dstb: [std.fs.max_path_bytes + 1]u8 = undefined;
    const src_dir = try std.fmt.bufPrintZ(&srcb, "{s}/move_src", .{base});
    const dst_dir = try std.fmt.bufPrintZ(&dstb, "{s}/move_dst", .{base});
    std.fs.deleteTreeAbsolute(src_dir) catch {};
    std.fs.deleteTreeAbsolute(dst_dir) catch {};
    try std.fs.makeDirAbsolute(src_dir);
    try std.fs.makeDirAbsolute(dst_dir);
    defer std.fs.deleteTreeAbsolute(src_dir) catch {};
    defer std.fs.deleteTreeAbsolute(dst_dir) catch {};

    const src_file = try std.fmt.allocPrintSentinel(gpa, "{s}/move_me.txt", .{src_dir}, 0);
    defer gpa.free(src_file);
    const fh = try std.fs.createFileAbsolute(src_file, .{});
    try fh.writeAll("move me\n");
    fh.close();

    var ctx = DoneCtx{};
    const ptrs = [_][*:0]const u8{src_file.ptr};
    zig_move_files(&ptrs, 1, dst_dir.ptr, true, &ctx, DoneCtx.onProgress, DoneCtx.onDone);
    try std.testing.expect(ctx.wait());

    // dst has the file
    const dst_file = try std.fmt.allocPrintSentinel(gpa, "{s}/move_me.txt", .{dst_dir}, 0);
    defer gpa.free(dst_file);
    try std.fs.accessAbsolute(dst_file, .{});
    // src file is gone
    if (std.fs.accessAbsolute(src_file, .{})) |_| return error.SrcFileStillExists else |_| {}
}

// ---------------------------------------------------------------------------
// zig_delete_files
// ---------------------------------------------------------------------------

test "zig_delete_files removes a file" {
    var rb: [std.fs.max_path_bytes]u8 = undefined;
    const base = try std.fs.cwd().realpath("test_dir", &rb);
    var pb: [std.fs.max_path_bytes + 1]u8 = undefined;
    const del_file = try std.fmt.bufPrintZ(&pb, "{s}/delete_me.txt", .{base});

    const fh = try std.fs.createFileAbsolute(del_file, .{});
    fh.close();

    // zig_delete_files calls osascript to move the file to Trash. On first
    // run with a new binary path macOS shows an Automation permission dialog
    // for Finder, which blocks osascript indefinitely until the user clicks
    // Allow.  Run the call in a thread and bail out after 8 s so the suite
    // never hangs.  Once the permission is granted (System Settings →
    // Privacy & Security → Automation → Finder) the test completes normally.
    var done = std.atomic.Value(bool).init(false);
    var ok_val = std.atomic.Value(bool).init(false);

    const thread = try std.Thread.spawn(.{}, struct {
        fn f(path: [:0]const u8, d: *std.atomic.Value(bool), r: *std.atomic.Value(bool)) void {
            var err_buf: [256]u8 = undefined;
            const ptrs = [_][*:0]const u8{path.ptr};
            r.store(zig_delete_files(&ptrs, 1, &err_buf, err_buf.len), .release);
            d.store(true, .release);
        }
    }.f, .{ del_file, &done, &ok_val });
    thread.detach();

    const deadline = std.time.nanoTimestamp() + 8 * std.time.ns_per_s;
    while (!done.load(.acquire)) {
        if (std.time.nanoTimestamp() > deadline) {
            std.debug.print(
                "\n[WARN] zig_delete_files timed out – accept the macOS Automation dialog " ++
                    "or grant Finder access in System Settings → Privacy & Security → Automation\n",
                .{},
            );
            return; // skip rather than hang
        }
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }

    try std.testing.expect(ok_val.load(.acquire));
    if (std.fs.accessAbsolute(del_file, .{})) |_| return error.FileStillExists else |_| {}
}
