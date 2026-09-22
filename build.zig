const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "zspace",
        .root_module = root_mod,
    });

    if (target.result.os.tag == .macos) {
        root_mod.linkFramework("Cocoa", .{});
        root_mod.linkFramework("QuartzCore", .{});
        root_mod.linkFramework("CoreGraphics", .{});
        root_mod.linkFramework("IOKit", .{});
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run ZSpace");
    run_step.dependOn(&run_cmd.step);

    const test_exe = b.addTest(.{
        .root_module = root_mod,
    });
    const run_test = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_test.step);

    // G-13: App Bundle assembly step
    const bundle_step = b.step("bundle", "Assemble macOS ZSpace.app bundle in zig-out/ZSpace.app");
    const bundle_cmd = b.addSystemCommand(&.{
        "sh", "-c",
        \\mkdir -p zig-out/ZSpace.app/Contents/MacOS zig-out/ZSpace.app/Contents/Resources
        \\cp zig-out/bin/zspace zig-out/ZSpace.app/Contents/MacOS/ZSpace
        \\cp dist/ZSpace.app/Contents/Info.plist zig-out/ZSpace.app/Contents/Info.plist
        \\cp assets/AppIcon.icns zig-out/ZSpace.app/Contents/Resources/AppIcon.icns
        \\codesign --force --deep --sign - zig-out/ZSpace.app
    });
    bundle_cmd.step.dependOn(b.getInstallStep());
    bundle_step.dependOn(&bundle_cmd.step);

    // Install to ~/Applications and /Applications
    const install_app_step = b.step("install-app", "Install ZSpace.app into /Applications and ~/Applications");
    const install_app_cmd = b.addSystemCommand(&.{
        "sh", "-c",
        \\mkdir -p /Users/joshua/Applications/ZSpace.app/Contents/MacOS /Users/joshua/Applications/ZSpace.app/Contents/Resources
        \\cp zig-out/bin/zspace /Users/joshua/Applications/ZSpace.app/Contents/MacOS/ZSpace
        \\cp dist/ZSpace.app/Contents/Info.plist /Users/joshua/Applications/ZSpace.app/Contents/Info.plist
        \\cp assets/AppIcon.icns /Users/joshua/Applications/ZSpace.app/Contents/Resources/AppIcon.icns
        \\codesign --force --deep --sign - /Users/joshua/Applications/ZSpace.app
        \\mkdir -p /Applications/ZSpace.app/Contents/MacOS /Applications/ZSpace.app/Contents/Resources 2>/dev/null || true
        \\cp zig-out/bin/zspace /Applications/ZSpace.app/Contents/MacOS/ZSpace 2>/dev/null || true
        \\cp dist/ZSpace.app/Contents/Info.plist /Applications/ZSpace.app/Contents/Info.plist 2>/dev/null || true
        \\cp assets/AppIcon.icns /Applications/ZSpace.app/Contents/Resources/AppIcon.icns 2>/dev/null || true
        \\codesign --force --deep --sign - /Applications/ZSpace.app 2>/dev/null || true
    });
    install_app_cmd.step.dependOn(b.getInstallStep());
    install_app_step.dependOn(&install_app_cmd.step);
}
