const std = @import("std");

// R2 Finder – macOS Finder clone
// Build with:  zig build
// Run  with:   zig build run
// App bundle:  zig build bundle  →  zig-out/R2 Finder.app
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Executable ───────────────────────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "rs_2finder",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // ── Objective-C source files ─────────────────────────────────────────────
    // Note: -fmodules is intentionally omitted – Zig's bundled float.h conflicts
    // with the macOS 26 SDK module map. Plain #import works fine without it.
    const objc_flags = &[_][]const u8{
        "-fobjc-arc", // ARC memory management
        "-std=gnu11",
        "-fno-sanitize=undefined", // Apple SDK headers (dispatch/once.h) use
        // __builtin_assume() which trips Zig's UBSan in
        // Debug mode. Disable UBSan for ObjC translation
        // units; Zig's own checks remain active.
    };

    exe.addCSourceFiles(.{
        .files = &[_][]const u8{
            "objc/AppDelegate.m",
            "objc/FinderWindowController.m",
            "objc/SidebarViewController.m",
            "objc/FileViewController.m",
            "objc/ProgressWindowController.m",
            "objc/GoToFolderPanel.m",
        },
        .flags = objc_flags,
    });

    // ── Include paths ────────────────────────────────────────────────────────
    exe.addIncludePath(b.path("include"));
    exe.addIncludePath(b.path("objc")); // so .m files can #import each other

    // ── macOS frameworks ─────────────────────────────────────────────────────
    exe.linkFramework("Cocoa");
    exe.linkFramework("Foundation");
    exe.linkFramework("UniformTypeIdentifiers"); // UTTypeCopyDescription
    exe.linkFramework("Quartz");                 // QLPreviewPanel

    // ── libc (required for ObjC runtime) ────────────────────────────────────
    exe.linkLibC();

    // ── Install ──────────────────────────────────────────────────────────────
    b.installArtifact(exe);

    // ── zig build run ────────────────────────────────────────────────────────
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Compilar y ejecutar rs_2finder");
    run_step.dependOn(&run_cmd.step);

    // ── zig build bundle  (creates rs_2finder.app in zig-out/) ───────────────
    const bundle_step = b.step("bundle", "Crear R2 Finder.app en zig-out/");
    const bundle = makeBundleStep(b, exe);
    bundle_step.dependOn(bundle);

    // ── zig build test-fs  (fs_ops unit tests, no ObjC deps needed) ──────────
    const fs_test_mod = b.createModule(.{
        .root_source_file = b.path("src/fs_ops.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fs_tests = b.addTest(.{ .root_module = fs_test_mod });
    const run_fs_tests = b.addRunArtifact(fs_tests);
    const fs_test_step = b.step("test-fs", "Ejecutar los tests unitarios de fs_ops");
    fs_test_step.dependOn(&run_fs_tests.step);

    // ── zig build test ───────────────────────────────────────────────────────
    const unit_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Ejecutar los tests unitarios de Zig");
    test_step.dependOn(&run_tests.step);
}

// ─────────────────────────────────────────────────────────────────────────────
// Bundle helper – builds "R2 Finder.app"/{Contents/{MacOS,Resources},Info.plist}
// ─────────────────────────────────────────────────────────────────────────────
fn makeBundleStep(b: *std.Build, exe: *std.Build.Step.Compile) *std.Build.Step {
    // 1) Write Info.plist
    const plist =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
        \\ "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundleName</key>              <string>R2 Finder</string>
        \\  <key>CFBundleDisplayName</key>       <string>R2 Finder</string>
        \\  <key>CFBundleIdentifier</key>        <string>com.example.r2finder</string>
        \\  <key>CFBundleVersion</key>           <string>1.0</string>
        \\  <key>CFBundleShortVersionString</key><string>1.0</string>
        \\  <key>CFBundleExecutable</key>        <string>rs_2finder</string>
        \\  <key>CFBundleIconFile</key>          <string>AppIcon</string>
        \\  <key>CFBundlePackageType</key>       <string>APPL</string>
        \\  <key>CFBundleSignature</key>         <string>????</string>
        \\  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
        \\  <key>NSHighResolutionCapable</key>   <true/>
        \\  <key>NSPrincipalClass</key>          <string>NSApplication</string>
        \\  <key>NSSupportsAutomaticTermination</key><false/>
        \\  <key>NSAppleEventsUsageDescription</key>
        \\    <string>R2 Finder uses AppleScript to move files to the Trash.</string>
        \\</dict>
        \\</plist>
    ;
    // b.addWriteFile writes to the Zig cache; pipe it through addInstallFile
    // to land it in zig-out/R2 Finder.app/Contents/Info.plist.
    const gen_plist = b.addWriteFile("Info.plist", plist);
    const install_plist = b.addInstallFile(
        gen_plist.getDirectory().path(b, "Info.plist"),
        "R2 Finder.app/Contents/Info.plist",
    );
    install_plist.step.dependOn(&gen_plist.step);

    // 2) Copy executable into bundle
    const copy_exe = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "R2 Finder.app/Contents/MacOS" } },
    });
    copy_exe.step.dependOn(&exe.step);

    // 3) Copy AppIcon.icns into Resources/
    const copy_icon = b.addInstallFile(
        b.path("AppIcon.icns"),
        "R2 Finder.app/Contents/Resources/AppIcon.icns",
    );

    // Combine into a single step via a dummy WriteFile
    const done = b.addWriteFile("R2 Finder.app/.built", "ok");
    done.step.dependOn(&install_plist.step);
    done.step.dependOn(&copy_exe.step);
    done.step.dependOn(&copy_icon.step);
    return &done.step;
}
