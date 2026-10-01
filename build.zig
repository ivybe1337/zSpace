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

    const run_step = b.step("run", "Run zSpace");
    run_step.dependOn(&run_cmd.step);

    const test_exe = b.addTest(.{
        .root_module = root_mod,
    });
    const run_test = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_test.step);

    // G-13: App Bundle assembly step
    const bundle_step = b.step("bundle", "Assemble macOS zSpace.app bundle in zig-out/zSpace.app");
    const bundle_cmd = b.addSystemCommand(&.{
        "sh", "-c",
        \\mkdir -p zig-out/zSpace.app/Contents/MacOS zig-out/zSpace.app/Contents/Resources
        \\cp zig-out/bin/zspace zig-out/zSpace.app/Contents/MacOS/zSpace
        \\cp dist/zSpace.app/Contents/Info.plist zig-out/zSpace.app/Contents/Info.plist
        \\cp assets/AppIcon.icns zig-out/zSpace.app/Contents/Resources/AppIcon.icns
        \\codesign --force --deep --sign - zig-out/zSpace.app
    });
    bundle_cmd.step.dependOn(b.getInstallStep());
    bundle_step.dependOn(&bundle_cmd.step);

    // Install to ~/Applications and /Applications
    const install_app_step = b.step("install-app", "Install zSpace.app into /Applications and ~/Applications");
    const install_app_cmd = b.addSystemCommand(&.{
        "sh", "-c",
        \\mkdir -p /Users/joshua/Applications/zSpace.app/Contents/MacOS /Users/joshua/Applications/zSpace.app/Contents/Resources
        \\cp zig-out/bin/zspace /Users/joshua/Applications/zSpace.app/Contents/MacOS/zSpace
        \\cp dist/zSpace.app/Contents/Info.plist /Users/joshua/Applications/zSpace.app/Contents/Info.plist
        \\cp assets/AppIcon.icns /Users/joshua/Applications/zSpace.app/Contents/Resources/AppIcon.icns
        \\codesign --force --deep --sign - /Users/joshua/Applications/zSpace.app
        \\mkdir -p /Applications/zSpace.app/Contents/MacOS /Applications/zSpace.app/Contents/Resources 2>/dev/null || true
        \\cp zig-out/bin/zspace /Applications/zSpace.app/Contents/MacOS/zSpace 2>/dev/null || true
        \\cp dist/zSpace.app/Contents/Info.plist /Applications/zSpace.app/Contents/Info.plist 2>/dev/null || true
        \\cp assets/AppIcon.icns /Applications/zSpace.app/Contents/Resources/AppIcon.icns 2>/dev/null || true
        \\codesign --force --deep --sign - /Applications/zSpace.app 2>/dev/null || true
    });
    install_app_cmd.step.dependOn(b.getInstallStep());
    install_app_step.dependOn(&install_app_cmd.step);
}
