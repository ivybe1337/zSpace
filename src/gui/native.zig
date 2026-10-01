//! native.zig — Pure-Zig Native AppKit GUI Harness for ZSpace.
//!
//! Replaces legacy WKWebView / HTML approach with 100% native Cocoa views.
//! Rule D1: Zero HTML, zero JS, zero WebKit. Direct Darwin AppKit execution.

const std = @import("std");
const types = @import("../core/types.zig");
const scanner = @import("../core/scanner.zig");
const cocoa = @import("cocoa.zig");
const components = @import("components.zig");
const theme = @import("theme.zig");
const disks = @import("../core/disks.zig");

const ScanContext = struct {
    scanner: *scanner.Scanner,
    worker: scanner.Scanner.ScanWorker = undefined,
    ui_state: *components.UIState,
    target_path: []const u8,
    status_buf: [128]u8 = [_]u8{0} ** 128,
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn onProgressMain(raw: ?*anyopaque) callconv(.c) void {
    const ctx: *ScanContext = @ptrCast(@alignCast(raw orelse return));
    if (!ctx.active.load(.acquire) or ctx.completed.load(.acquire)) return;

    const prog = ctx.scanner.progress();
    var sz_buf: [32]u8 = undefined;
    const sz_str = types.DiskNode.formatSize(prog.bytes_seen, &sz_buf);

    const formatted = std.fmt.bufPrint(&ctx.status_buf, "Scanning: {d} files, {d} dirs ({s})...", .{
        prog.files_seen,
        prog.dirs_visited,
        sz_str,
    }) catch "Scanning...";

    ctx.ui_state.status_text = formatted;
    components.requestRedraw();
}

fn onCompleteMain(raw: ?*anyopaque) callconv(.c) void {
    const ctx: *ScanContext = @ptrCast(@alignCast(raw orelse return));
    if (!ctx.active.load(.acquire)) return;
    ctx.completed.store(true, .release);

    const root = ctx.worker.result orelse return;
    ctx.ui_state.root_node = root;
    ctx.ui_state.drill_node = null;
    ctx.ui_state.selected_indices.clearRetainingCapacity();

    var sz_buf: [32]u8 = undefined;
    const sz_str = types.DiskNode.formatSize(root.size_bytes, &sz_buf);

    ctx.ui_state.scan_state = switch (ctx.scanner.last_status) {
        .complete => .completed,
        .partial => .partial,
        .cancelled => .cancelled,
        .failed => .failed,
    };
    const formatted: []const u8 = switch (ctx.scanner.last_status) {
        .complete => std.fmt.bufPrint(&ctx.status_buf, "Scan complete — {s} logical ({d} files, {d} dirs)", .{ sz_str, root.file_count, root.dir_count }) catch "Scan complete",
        .partial => std.fmt.bufPrint(&ctx.status_buf, "Partial scan — {s} indexed ({d} files, {d} dirs); inspect errors", .{ sz_str, root.file_count, root.dir_count }) catch "Partial scan",
        .cancelled => std.fmt.bufPrint(&ctx.status_buf, "Scan cancelled — {s} indexed ({d} files, {d} dirs)", .{ sz_str, root.file_count, root.dir_count }) catch "Scan cancelled",
        .failed => "Scan failed — partial data only",
    };

    ctx.ui_state.status_text = formatted;
    components.requestRedraw();
}

fn onErrorMain(raw: ?*anyopaque) callconv(.c) void {
    const ctx: *ScanContext = @ptrCast(@alignCast(raw orelse return));
    if (!ctx.active.load(.acquire)) return;
    ctx.completed.store(true, .release);
    ctx.ui_state.scan_state = .failed;

    ctx.ui_state.status_text = "Scan interrupted or error encountered";
    components.requestRedraw();
}

fn monitorScanLoop(ctx: *ScanContext) void {
    while (ctx.active.load(.acquire) and ctx.scanner.is_scanning.load(.acquire)) {
        var req = std.c.timespec{ .sec = 0, .nsec = 100_000_000 };
        _ = std.c.nanosleep(&req, null);
        if (!ctx.active.load(.acquire) or !ctx.scanner.is_scanning.load(.acquire)) break;
        cocoa.dispatch_async_f(cocoa.dispatch_get_main_queue(), ctx, onProgressMain);
    }

    // Wait for the worker thread to finish
    ctx.worker.thread.join();

    if (ctx.active.load(.acquire)) {
        if (ctx.worker.result != null) {
            cocoa.dispatch_async_f(cocoa.dispatch_get_main_queue(), ctx, onCompleteMain);
        } else {
            cocoa.dispatch_async_f(cocoa.dispatch_get_main_queue(), ctx, onErrorMain);
        }
    }
}

var global_scan_ctx: ?*ScanContext = null;
var global_monitor_thread: ?std.Thread = null;

pub fn triggerScan() void {
    const ctx = global_scan_ctx orelse return;
    if (ctx.scanner.is_scanning.load(.acquire)) {
        std.debug.print("[ZSpace Native] Scan already in progress, ignoring trigger.\n", .{});
        return;
    }

    if (global_monitor_thread) |t| {
        t.join();
        global_monitor_thread = null;
    }

    ctx.target_path = ctx.ui_state.getTargetPath();
    ctx.completed.store(false, .release);
    ctx.active.store(true, .release);
    ctx.ui_state.scan_state = .scanning;
    ctx.ui_state.status_text = "Starting scan...";
    components.requestRedraw();

    std.debug.print("\x1b[1;36m[ZSpace Native]\x1b[0m Explicit scan triggered for: {s}\n", .{ctx.target_path});

    ctx.scanner.scanBackground(ctx.target_path, &ctx.worker) catch |err| {
        std.debug.print("Failed to start background scan: {}\n", .{err});
        ctx.ui_state.scan_state = .failed;
        ctx.ui_state.status_text = "Failed to launch scan";
        components.requestRedraw();
        return;
    };

    global_monitor_thread = std.Thread.spawn(.{}, monitorScanLoop, .{ctx}) catch |err| {
        std.debug.print("Failed to spawn monitor thread: {}\n", .{err});
        ctx.ui_state.scan_state = .failed;
        ctx.ui_state.status_text = "Failed to spawn monitor thread";
        components.requestRedraw();
        return;
    };
}

pub fn triggerChooseTarget() void {
    const ctx = global_scan_ctx orelse return;
    if (ctx.scanner.is_scanning.load(.acquire)) {
        std.debug.print("[ZSpace Native] Cannot change target while scan is running.\n", .{});
        return;
    }

    var buf: [1024]u8 = undefined;
    if (cocoa.openFolderDialog(&buf)) |chosen| {
        ctx.ui_state.setTargetPath(chosen);
        ctx.target_path = ctx.ui_state.getTargetPath();
        ctx.ui_state.status_text = "Target selected — Click [ ▶ SCAN TARGET ] to begin analysis";
        components.requestRedraw();
        std.debug.print("[ZSpace Native] Target changed to: {s}\n", .{chosen});
    }
}

pub fn selectTargetPreset(preset: []const u8) void {
    const ctx = global_scan_ctx orelse return;
    if (ctx.scanner.is_scanning.load(.acquire)) return;

    ctx.ui_state.setTargetPath(preset);
    ctx.target_path = ctx.ui_state.getTargetPath();
    ctx.ui_state.status_text = "Target selected — Click [ ▶ SCAN TARGET ] to begin analysis";
    components.requestRedraw();
    std.debug.print("[ZSpace Native] Preset selected: {s}\n", .{preset});
}

pub fn cancelActiveScan() void {
    const ctx = global_scan_ctx orelse return;
    if (ctx.scanner.is_scanning.load(.acquire)) {
        ctx.scanner.cancel();
        ctx.ui_state.scan_state = .idle;
        ctx.ui_state.status_text = "Scan cancelled by user";
        components.requestRedraw();
        std.debug.print("[ZSpace Native] Scan cancelled by user.\n", .{});
    }
}

pub fn runGuiApp(allocator: std.mem.Allocator, target_path: []const u8) !void {
    const pool = cocoa.objc_autoreleasePoolPush();
    defer cocoa.objc_autoreleasePoolPop(pool);

    std.debug.print("\n\x1b[1;36m[ZSpace Native AppKit]\x1b[0m Launching Pure-Zig GUI for: {s}\n", .{target_path});

    // 1. Initialize UI State with initial placeholder node
    var ui_state = components.UIState.init(allocator);
    defer ui_state.deinit();

    const bname = std.fs.path.basename(target_path);
    var initial_root: types.DiskNode = .{
        .name = if (bname.len > 0) bname else target_path,
        .path = target_path,
        .kind = .directory,
        .category = .Other,
        .protection = .None,
    };
    ui_state.root_node = &initial_root;
    ui_state.scan_state = .idle;
    ui_state.status_text = "Target ready — Click [ ▶ SCAN TARGET ] to begin analysis";
    ui_state.setTargetPath(target_path);
    ui_state.scan_trigger_fn = &triggerScan;
    ui_state.choose_target_fn = &triggerChooseTarget;
    ui_state.preset_select_fn = &selectTargetPreset;

    // Query primary volume storage metrics (instant statfs, 0ms, zero background indexing)
    var dm = disks.DiskMapper.init(allocator);
    var volumes_list = dm.listVolumes() catch null;
    if (volumes_list) |*vl| {
        defer {
            for (vl.items) |v| {
                allocator.free(v.mount_point);
                allocator.free(v.device_name);
                allocator.free(v.fs_type);
            }
            vl.deinit(allocator);
        }
        for (vl.items) |v| {
            if (std.mem.eql(u8, v.mount_point, "/")) {
                ui_state.volume_total_bytes = v.total_bytes;
                ui_state.volume_free_bytes = v.free_bytes;
                ui_state.volume_used_bytes = v.used_bytes;
                ui_state.volume_pct_used = v.percent_used;
                const m_len = @min(v.mount_point.len, ui_state.volume_name.len);
                @memcpy(ui_state.volume_name[0..m_len], v.mount_point[0..m_len]);
                ui_state.volume_name_len = m_len;
                break;
            }
        }
    }

    components.global_ui_state = &ui_state;
    defer components.global_ui_state = null;

    // 2. Register Custom Dynamic NSView Subclasses
    components.registerViewSubclasses();

    // 3. Initialize NSApplication
    const NSApplication = cocoa.objc_getClass("NSApplication");
    const sel_sharedApp = cocoa.sel_registerName("sharedApplication");
    const sel_setActivationPolicy = cocoa.sel_registerName("setActivationPolicy:");
    const sel_activateIgnoringOtherApps = cocoa.sel_registerName("activateIgnoringOtherApps:");
    const sel_finishLaunching = cocoa.sel_registerName("finishLaunching");
    const sel_run = cocoa.sel_registerName("run");

    const app = cocoa.send0(NSApplication, sel_sharedApp);
    if (app == null) {
        std.debug.print("Error: Could not initialize Cocoa NSApplication.\n", .{});
        return;
    }

    cocoa.sendVoidInt(app, sel_setActivationPolicy, 0); // NSApplicationActivationPolicyRegular
    cocoa.sendVoid0(app, sel_finishLaunching);

    // 4. Construct Native Menubar
    setupMenuBar(app);

    // 5. Construct Main Window (1320 x 860)
    const NSWindow = cocoa.objc_getClass("NSWindow");
    const sel_alloc = cocoa.sel_registerName("alloc");
    const sel_initWithContentRect = cocoa.sel_registerName("initWithContentRect:styleMask:backing:defer:");
    const sel_setTitle = cocoa.sel_registerName("setTitle:");
    const sel_makeKeyAndOrderFront = cocoa.sel_registerName("makeKeyAndOrderFront:");
    const sel_center = cocoa.sel_registerName("center");
    const sel_setBackgroundColor = cocoa.sel_registerName("setBackgroundColor:");
    const sel_setContentView = cocoa.sel_registerName("setContentView:");
    const sel_setTitlebarAppearsTransparent = cocoa.sel_registerName("setTitlebarAppearsTransparent:");
    const sel_setMinSize = cocoa.sel_registerName("setMinSize:");

    const win_w: f64 = 1320.0;
    const win_h: f64 = 860.0;

    const window_alloc = cocoa.send0(NSWindow, sel_alloc);
    const window = cocoa.sendInitWindow(
        window_alloc,
        sel_initWithContentRect,
        cocoa.NSRect.init(100.0, 100.0, win_w, win_h),
        15, // Closable | Titled | Resizable | Miniaturizable
        2, // NSBackingStoreBuffered
        0,
    );

    if (window == null) {
        std.debug.print("Error: Failed to instantiate NSWindow.\n", .{});
        return;
    }

    const title_str = cocoa.nsString("ZSpace — Spacetime Disk Intelligence (Pure Zig Native)");
    cocoa.sendVoid1(window, sel_setTitle, title_str);
    cocoa.sendVoidBool(window, sel_setTitlebarAppearsTransparent, true);

    // Minimum window bounds 960x600 per spec
    const F_setMinSize = *const fn (cocoa.id, cocoa.SEL, cocoa.NSSize) callconv(.c) void;
    @as(F_setMinSize, @ptrCast(&cocoa.objc_msgSend))(window, sel_setMinSize, .{ .w = 960.0, .h = 600.0 });

    // Obsidian background #08090D
    const obsidian_bg = cocoa.nsColorFromHex(0x08090D, 1.0);
    if (obsidian_bg != null) {
        cocoa.sendVoid1(window, sel_setBackgroundColor, obsidian_bg);
    }

    // 6. Assemble View Hierarchy
    const NSView = cocoa.objc_getClass("NSView");
    const sel_initWithFrame = cocoa.sel_registerName("initWithFrame:");
    const sel_addSubview = cocoa.sel_registerName("addSubview:");
    const sel_setAutoresizingMask = cocoa.sel_registerName("setAutoresizingMask:");

    // Root Container View
    const root_view_alloc = cocoa.send0(NSView, sel_alloc);
    const root_view = cocoa.sendInitRect(root_view_alloc, sel_initWithFrame, cocoa.NSRect.init(0, 0, win_w, win_h));
    cocoa.sendVoid1(window, sel_setContentView, root_view);

    // Resizing mask constants: 18 = width + height resizable
    cocoa.sendVoidInt(root_view, sel_setAutoresizingMask, 18);

    const sel_bounds = cocoa.sel_registerName("bounds");
    const root_bounds = cocoa.sendGetRect(root_view, sel_bounds);
    const cur_w = if (root_bounds.w > 100.0) root_bounds.w else win_w;
    const cur_h = if (root_bounds.h > 100.0) root_bounds.h else win_h;

    // Header (54px at top: y = cur_h - 54)
    const HeaderCls = cocoa.objc_getClass("ZSpaceHeaderView");
    const header_alloc = cocoa.send0(HeaderCls, sel_alloc);
    const header_view = cocoa.sendInitRect(header_alloc, sel_initWithFrame, cocoa.NSRect.init(0, cur_h - 54, cur_w, 54));
    cocoa.sendVoidInt(header_view, sel_setAutoresizingMask, 2 | 8); // width resizable + stick to top (MinYMargin = 8)
    cocoa.sendVoid1(root_view, sel_addSubview, header_view);

    // Status Bar (32px at bottom: y = 0)
    const StatusCls = cocoa.objc_getClass("ZSpaceStatusView");
    const status_alloc = cocoa.send0(StatusCls, sel_alloc);
    const status_view = cocoa.sendInitRect(status_alloc, sel_initWithFrame, cocoa.NSRect.init(0, 0, cur_w, 32));
    cocoa.sendVoidInt(status_view, sel_setAutoresizingMask, 2 | 32); // width resizable + stick to bottom (MaxYMargin = 32)
    cocoa.sendVoid1(root_view, sel_addSubview, status_view);

    // Workspace rail + Inspector panel frame the central work surface.
    const rail_w: f64 = 190.0;
    const sidebar_w: f64 = 360.0;
    const content_h: f64 = cur_h - 54.0 - 32.0;

    const RailCls = cocoa.objc_getClass("ZSpaceWorkspaceRailView");
    const rail_alloc = cocoa.send0(RailCls, sel_alloc);
    const rail_view = cocoa.sendInitRect(rail_alloc, sel_initWithFrame, cocoa.NSRect.init(0, 32, rail_w, content_h));
    cocoa.sendVoidInt(rail_view, sel_setAutoresizingMask, 16);
    cocoa.sendVoid1(root_view, sel_addSubview, rail_view);

    const SidebarCls = cocoa.objc_getClass("ZSpaceSidebarView");
    const sidebar_alloc = cocoa.send0(SidebarCls, sel_alloc);
    const sidebar_view = cocoa.sendInitRect(sidebar_alloc, sel_initWithFrame, cocoa.NSRect.init(cur_w - sidebar_w, 32, sidebar_w, content_h));
    cocoa.sendVoidInt(sidebar_view, sel_setAutoresizingMask, 1 | 16); // min-x margin (stick to right) + height resizable
    cocoa.sendVoid1(root_view, sel_addSubview, sidebar_view);

    // Left Visual Stack (Sunburst top + Treemap flex bottom)
    const left_w: f64 = cur_w - sidebar_w - rail_w;
    const sunburst_h: f64 = @min(340.0, content_h * 0.55);
    const treemap_h: f64 = content_h - sunburst_h;

    // Treemap View (bottom of visual stack: y = 32)
    const TreemapCls = cocoa.objc_getClass("ZSpaceTreemapView");
    const treemap_alloc = cocoa.send0(TreemapCls, sel_alloc);
    const treemap_view = cocoa.sendInitRect(treemap_alloc, sel_initWithFrame, cocoa.NSRect.init(rail_w, 32, left_w, treemap_h));
    cocoa.sendVoidInt(treemap_view, sel_setAutoresizingMask, 2 | 16); // width + height resizable
    cocoa.sendVoid1(root_view, sel_addSubview, treemap_view);

    // Sunburst View (top of visual stack: y = 32 + treemap_h)
    const SunburstCls = cocoa.objc_getClass("ZSpaceSunburstView");
    const sunburst_alloc = cocoa.send0(SunburstCls, sel_alloc);
    const sunburst_view = cocoa.sendInitRect(sunburst_alloc, sel_initWithFrame, cocoa.NSRect.init(rail_w, 32 + treemap_h, left_w, sunburst_h));
    cocoa.sendVoidInt(sunburst_view, sel_setAutoresizingMask, 2 | 8); // width resizable + stick to top
    cocoa.sendVoid1(root_view, sel_addSubview, sunburst_view);

    components.view_header = header_view;
    components.view_status = status_view;
    components.view_sidebar = sidebar_view;
    components.view_workspace_rail = rail_view;
    components.view_treemap = treemap_view;
    components.view_sunburst = sunburst_view;
    defer {
        components.view_header = null;
        components.view_status = null;
        components.view_sidebar = null;
        components.view_workspace_rail = null;
        components.view_treemap = null;
        components.view_sunburst = null;
    }

    // 7. Order Front and Display Window Instantly (<50ms)
    const sel_orderFrontRegardless = cocoa.sel_registerName("orderFrontRegardless");
    cocoa.sendVoid0(window, sel_center);
    cocoa.sendVoid1(window, sel_makeKeyAndOrderFront, null);
    cocoa.sendVoid0(window, sel_orderFrontRegardless);
    cocoa.sendVoidBool(app, sel_activateIgnoringOtherApps, true);

    const sel_isVisible = cocoa.sel_registerName("isVisible");
    const is_vis = cocoa.send0(window, sel_isVisible);
    std.debug.print("✓ ZSpace Native Cocoa Liquid Glass UI mounted (<50ms). isVisible={?*}\n", .{is_vis});

    // 8. Initialize Scanner Context in Pure-Idle Mode (Rule: Zero auto-indexing on launch)
    var sc = scanner.Scanner.init(allocator, .{});
    defer sc.deinit();

    const scan_ctx = try allocator.create(ScanContext);
    defer allocator.destroy(scan_ctx);

    scan_ctx.* = .{
        .scanner = &sc,
        .ui_state = &ui_state,
        .target_path = target_path,
        .active = std.atomic.Value(bool).init(false),
        .completed = std.atomic.Value(bool).init(false),
    };
    global_scan_ctx = scan_ctx;
    defer {
        global_scan_ctx = null;
        sc.cancel();
        scan_ctx.active.store(false, .release);
        if (global_monitor_thread) |t| {
            t.join();
            global_monitor_thread = null;
        }
    }

    // 9. Run the Cocoa Event Loop
    cocoa.sendVoid0(app, sel_run);
}

fn onMenuChooseFolder(_: cocoa.id, _: cocoa.SEL, _: cocoa.id) callconv(.c) void {
    triggerChooseTarget();
}

fn onMenuScanTarget(_: cocoa.id, _: cocoa.SEL, _: cocoa.id) callconv(.c) void {
    triggerScan();
}

fn onMenuCancelScan(_: cocoa.id, _: cocoa.SEL, _: cocoa.id) callconv(.c) void {
    cancelActiveScan();
}

fn onMenuPresetHome(_: cocoa.id, _: cocoa.SEL, _: cocoa.id) callconv(.c) void {
    const home = components.getHomeDir();
    selectTargetPreset(home);
}

fn onMenuPresetDownloads(_: cocoa.id, _: cocoa.SEL, _: cocoa.id) callconv(.c) void {
    const home = components.getHomeDir();
    var buf: [1024]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/Downloads", .{home}) catch return;
    selectTargetPreset(p);
}

fn onMenuPresetProjects(_: cocoa.id, _: cocoa.SEL, _: cocoa.id) callconv(.c) void {
    const home = components.getHomeDir();
    var buf: [1024]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/LocalBuilds", .{home}) catch return;
    selectTargetPreset(p);
}

fn onMenuPresetApps(_: cocoa.id, _: cocoa.SEL, _: cocoa.id) callconv(.c) void {
    selectTargetPreset("/Applications");
}

fn onMenuPresetRoot(_: cocoa.id, _: cocoa.SEL, _: cocoa.id) callconv(.c) void {
    selectTargetPreset("/");
}

fn setupMenuBar(app: cocoa.id) void {
    const NSMenu = cocoa.objc_getClass("NSMenu");
    const NSMenuItem = cocoa.objc_getClass("NSMenuItem");
    const NSObject = cocoa.objc_getClass("NSObject");

    const sel_alloc = cocoa.sel_registerName("alloc");
    const sel_init = cocoa.sel_registerName("init");
    const sel_initWithTitle = cocoa.sel_registerName("initWithTitle:action:keyEquivalent:");
    const sel_setSubmenu = cocoa.sel_registerName("setSubmenu:");
    const sel_addItem = cocoa.sel_registerName("addItem:");
    const sel_setMainMenu = cocoa.sel_registerName("setMainMenu:");
    const sel_separatorItem = cocoa.sel_registerName("separatorItem");

    const sel_chooseFolder = cocoa.sel_registerName("chooseTargetFolder:");
    const sel_scanTarget = cocoa.sel_registerName("scanTarget:");
    const sel_cancelScan = cocoa.sel_registerName("cancelScan:");
    const sel_presetHome = cocoa.sel_registerName("presetHome:");
    const sel_presetDownloads = cocoa.sel_registerName("presetDownloads:");
    const sel_presetProjects = cocoa.sel_registerName("presetProjects:");
    const sel_presetApps = cocoa.sel_registerName("presetApps:");
    const sel_presetRoot = cocoa.sel_registerName("presetRoot:");
    const sel_terminate = cocoa.sel_registerName("terminate:");
    const sel_hide = cocoa.sel_registerName("hide:");
    const sel_hideOthers = cocoa.sel_registerName("hideOtherApplications:");
    const sel_unhideAll = cocoa.sel_registerName("unhideAllApplications:");
    const sel_performClose = cocoa.sel_registerName("performClose:");

    // 1. Register ZSpaceAppDelegate
    if (cocoa.objc_getClass("ZSpaceAppDelegate") == null) {
        const del_cls = cocoa.objc_allocateClassPair(NSObject, "ZSpaceAppDelegate", 0);
        _ = cocoa.class_addMethod(del_cls, sel_chooseFolder, @ptrCast(&onMenuChooseFolder), "v@:@");
        _ = cocoa.class_addMethod(del_cls, sel_scanTarget, @ptrCast(&onMenuScanTarget), "v@:@");
        _ = cocoa.class_addMethod(del_cls, sel_cancelScan, @ptrCast(&onMenuCancelScan), "v@:@");
        _ = cocoa.class_addMethod(del_cls, sel_presetHome, @ptrCast(&onMenuPresetHome), "v@:@");
        _ = cocoa.class_addMethod(del_cls, sel_presetDownloads, @ptrCast(&onMenuPresetDownloads), "v@:@");
        _ = cocoa.class_addMethod(del_cls, sel_presetProjects, @ptrCast(&onMenuPresetProjects), "v@:@");
        _ = cocoa.class_addMethod(del_cls, sel_presetApps, @ptrCast(&onMenuPresetApps), "v@:@");
        _ = cocoa.class_addMethod(del_cls, sel_presetRoot, @ptrCast(&onMenuPresetRoot), "v@:@");
        cocoa.objc_registerClassPair(del_cls);
    }
    const AppDelCls = cocoa.objc_getClass("ZSpaceAppDelegate");
    const delegate = cocoa.send0(cocoa.send0(AppDelCls, sel_alloc), sel_init);
    cocoa.sendVoid1(app, cocoa.sel_registerName("setDelegate:"), delegate);

    const F_initItem = *const fn (cocoa.id, cocoa.SEL, cocoa.id, cocoa.SEL, cocoa.id) callconv(.c) cocoa.id;
    const F_initMenu = *const fn (cocoa.id, cocoa.SEL, cocoa.id) callconv(.c) cocoa.id;
    const sel_initWithMenuTitle = cocoa.sel_registerName("initWithTitle:");

    const menubar = cocoa.send0(cocoa.send0(NSMenu, sel_alloc), sel_init);

    // --- 1. ZSpace Application Menu ---
    const app_menu_item = cocoa.send0(cocoa.send0(NSMenuItem, sel_alloc), sel_init);
    const app_menu = @as(F_initMenu, @ptrCast(&cocoa.objc_msgSend))(
        cocoa.send0(NSMenu, sel_alloc),
        sel_initWithMenuTitle,
        cocoa.nsString("ZSpace"),
    );

    const about_item = @as(F_initItem, @ptrCast(&cocoa.objc_msgSend))(
        cocoa.send0(NSMenuItem, sel_alloc),
        sel_initWithTitle,
        cocoa.nsString("About ZSpace"),
        cocoa.sel_registerName("orderFrontStandardAboutPanel:"),
        cocoa.nsString(""),
    );
    cocoa.sendVoid1(app_menu, sel_addItem, about_item);
    cocoa.sendVoid1(app_menu, sel_addItem, cocoa.send0(NSMenuItem, sel_separatorItem));

    const hide_item = @as(F_initItem, @ptrCast(&cocoa.objc_msgSend))(
        cocoa.send0(NSMenuItem, sel_alloc),
        sel_initWithTitle,
        cocoa.nsString("Hide ZSpace"),
        sel_hide,
        cocoa.nsString("h"),
    );
    cocoa.sendVoid1(app_menu, sel_addItem, hide_item);

    const hide_others = @as(F_initItem, @ptrCast(&cocoa.objc_msgSend))(
        cocoa.send0(NSMenuItem, sel_alloc),
        sel_initWithTitle,
        cocoa.nsString("Hide Others"),
        sel_hideOthers,
        cocoa.nsString(""),
    );
    cocoa.sendVoid1(app_menu, sel_addItem, hide_others);

    const show_all = @as(F_initItem, @ptrCast(&cocoa.objc_msgSend))(
        cocoa.send0(NSMenuItem, sel_alloc),
        sel_initWithTitle,
        cocoa.nsString("Show All"),
        sel_unhideAll,
        cocoa.nsString(""),
    );
    cocoa.sendVoid1(app_menu, sel_addItem, show_all);
    cocoa.sendVoid1(app_menu, sel_addItem, cocoa.send0(NSMenuItem, sel_separatorItem));

    const quit_item = @as(F_initItem, @ptrCast(&cocoa.objc_msgSend))(
        cocoa.send0(NSMenuItem, sel_alloc),
        sel_initWithTitle,
        cocoa.nsString("Quit ZSpace"),
        sel_terminate,
        cocoa.nsString("q"),
    );
    cocoa.sendVoid1(app_menu, sel_addItem, quit_item);
    cocoa.sendVoid1(app_menu_item, sel_setSubmenu, app_menu);
    cocoa.sendVoid1(menubar, sel_addItem, app_menu_item);

    // --- 2. File Menu (⌘O, ⌘R, ⌘., ⌘W) ---
    const file_menu_item = cocoa.send0(cocoa.send0(NSMenuItem, sel_alloc), sel_init);
    const file_menu = @as(F_initMenu, @ptrCast(&cocoa.objc_msgSend))(
        cocoa.send0(NSMenu, sel_alloc),
        sel_initWithMenuTitle,
        cocoa.nsString("File"),
    );

    const open_item = @as(F_initItem, @ptrCast(&cocoa.objc_msgSend))(
        cocoa.send0(NSMenuItem, sel_alloc),
        sel_initWithTitle,
        cocoa.nsString("Choose Target Folder..."),
        sel_chooseFolder,
        cocoa.nsString("o"),
    );
    cocoa.sendVoid1(file_menu, sel_addItem, open_item);

    const scan_item = @as(F_initItem, @ptrCast(&cocoa.objc_msgSend))(
        cocoa.send0(NSMenuItem, sel_alloc),
        sel_initWithTitle,
        cocoa.nsString("Scan Target"),
        sel_scanTarget,
        cocoa.nsString("r"),
    );
    cocoa.sendVoid1(file_menu, sel_addItem, scan_item);

    const cancel_item = @as(F_initItem, @ptrCast(&cocoa.objc_msgSend))(
        cocoa.send0(NSMenuItem, sel_alloc),
        sel_initWithTitle,
        cocoa.nsString("Cancel Scan"),
        sel_cancelScan,
        cocoa.nsString("."),
    );
    cocoa.sendVoid1(file_menu, sel_addItem, cancel_item);
    cocoa.sendVoid1(file_menu, sel_addItem, cocoa.send0(NSMenuItem, sel_separatorItem));

    const close_item = @as(F_initItem, @ptrCast(&cocoa.objc_msgSend))(
        cocoa.send0(NSMenuItem, sel_alloc),
        sel_initWithTitle,
        cocoa.nsString("Close Window"),
        sel_performClose,
        cocoa.nsString("w"),
    );
    cocoa.sendVoid1(file_menu, sel_addItem, close_item);

    cocoa.sendVoid1(file_menu_item, sel_setSubmenu, file_menu);
    cocoa.sendVoid1(menubar, sel_addItem, file_menu_item);

    // --- 3. Targets Menu (⌘1..⌘5) ---
    const target_menu_item = cocoa.send0(cocoa.send0(NSMenuItem, sel_alloc), sel_init);
    const target_menu = @as(F_initMenu, @ptrCast(&cocoa.objc_msgSend))(
        cocoa.send0(NSMenu, sel_alloc),
        sel_initWithMenuTitle,
        cocoa.nsString("Targets"),
    );

    const t1 = @as(F_initItem, @ptrCast(&cocoa.objc_msgSend))(
        cocoa.send0(NSMenuItem, sel_alloc),
        sel_initWithTitle,
        cocoa.nsString("User Home Profile (~/)"),
        sel_presetHome,
        cocoa.nsString("1"),
    );
    cocoa.sendVoid1(target_menu, sel_addItem, t1);

    const t2 = @as(F_initItem, @ptrCast(&cocoa.objc_msgSend))(
        cocoa.send0(NSMenuItem, sel_alloc),
        sel_initWithTitle,
        cocoa.nsString("Downloads Folder (~/Downloads)"),
        sel_presetDownloads,
        cocoa.nsString("2"),
    );
    cocoa.sendVoid1(target_menu, sel_addItem, t2);

    const t3 = @as(F_initItem, @ptrCast(&cocoa.objc_msgSend))(
        cocoa.send0(NSMenuItem, sel_alloc),
        sel_initWithTitle,
        cocoa.nsString("Developer Projects (~/LocalBuilds)"),
        sel_presetProjects,
        cocoa.nsString("3"),
    );
    cocoa.sendVoid1(target_menu, sel_addItem, t3);

    const t4 = @as(F_initItem, @ptrCast(&cocoa.objc_msgSend))(
        cocoa.send0(NSMenuItem, sel_alloc),
        sel_initWithTitle,
        cocoa.nsString("System Applications (/Applications)"),
        sel_presetApps,
        cocoa.nsString("4"),
    );
    cocoa.sendVoid1(target_menu, sel_addItem, t4);

    const t5 = @as(F_initItem, @ptrCast(&cocoa.objc_msgSend))(
        cocoa.send0(NSMenuItem, sel_alloc),
        sel_initWithTitle,
        cocoa.nsString("Macintosh HD (/)"),
        sel_presetRoot,
        cocoa.nsString("5"),
    );
    cocoa.sendVoid1(target_menu, sel_addItem, t5);

    cocoa.sendVoid1(target_menu_item, sel_setSubmenu, target_menu);
    cocoa.sendVoid1(menubar, sel_addItem, target_menu_item);

    cocoa.sendVoid1(app, sel_setMainMenu, menubar);
}
