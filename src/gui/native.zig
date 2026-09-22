//! native.zig — Pure-Zig Native AppKit GUI Harness for ZSpace.
//!
//! Replaces legacy WKWebView / HTML approach with 100% native Cocoa views.
//! Rule D1: Zero HTML, zero JS, zero WebKit. Direct Darwin AppKit execution.

const std = @import("std");
const types = @import("../core/types.zig");
const cocoa = @import("cocoa.zig");
const components = @import("components.zig");
const theme = @import("theme.zig");

pub fn runGuiApp(allocator: std.mem.Allocator, root_node: *types.DiskNode) !void {
    const pool = cocoa.objc_autoreleasePoolPush();
    defer cocoa.objc_autoreleasePoolPop(pool);

    std.debug.print("\n\x1b[1;36m[ZSpace Native AppKit]\x1b[0m Launching Pure-Zig GUI for: {s}\n", .{root_node.path});

    // 1. Initialize UI State
    var ui_state = components.UIState.init(allocator);
    defer ui_state.deinit();
    ui_state.root_node = root_node;
    ui_state.status_text = "Analysis Ready";
    components.global_ui_state = &ui_state;
    defer components.global_ui_state = null;

    // 2. Register Custom Dynamic NSView Subclasses
    components.registerViewSubclasses();

    // 3. Initialize NSApplication
    const NSApplication = cocoa.objc_getClass("NSApplication");
    const sel_sharedApp = cocoa.sel_registerName("sharedApplication");
    const sel_setActivationPolicy = cocoa.sel_registerName("setActivationPolicy:");
    const sel_activateIgnoringOtherApps = cocoa.sel_registerName("activateIgnoringOtherApps:");
    const sel_run = cocoa.sel_registerName("run");

    const app = cocoa.send0(NSApplication, sel_sharedApp);
    if (app == null) {
        std.debug.print("Error: Could not initialize Cocoa NSApplication.\n", .{});
        return;
    }

    cocoa.sendVoidInt(app, sel_setActivationPolicy, 0); // NSApplicationActivationPolicyRegular

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

    // Header (54px at top: y = win_h - 54)
    const HeaderCls = cocoa.objc_getClass("ZSpaceHeaderView");
    const header_alloc = cocoa.send0(HeaderCls, sel_alloc);
    const header_view = cocoa.sendInitRect(header_alloc, sel_initWithFrame, cocoa.NSRect.init(0, win_h - 54, win_w, 54));
    cocoa.sendVoidInt(header_view, sel_setAutoresizingMask, 2 | 32); // width resizable + stick to top
    cocoa.sendVoid1(root_view, sel_addSubview, header_view);

    // Status Bar (32px at bottom: y = 0)
    const StatusCls = cocoa.objc_getClass("ZSpaceStatusView");
    const status_alloc = cocoa.send0(StatusCls, sel_alloc);
    const status_view = cocoa.sendInitRect(status_alloc, sel_initWithFrame, cocoa.NSRect.init(0, 0, win_w, 32));
    cocoa.sendVoidInt(status_view, sel_setAutoresizingMask, 2); // width resizable
    cocoa.sendVoid1(root_view, sel_addSubview, status_view);

    // Sidebar (fixed 420px width on right: x = win_w - 420, h = win_h - 54 - 32)
    const sidebar_w: f64 = 420.0;
    const content_h: f64 = win_h - 54.0 - 32.0;
    const SidebarCls = cocoa.objc_getClass("ZSpaceSidebarView");
    const sidebar_alloc = cocoa.send0(SidebarCls, sel_alloc);
    const sidebar_view = cocoa.sendInitRect(sidebar_alloc, sel_initWithFrame, cocoa.NSRect.init(win_w - sidebar_w, 32, sidebar_w, content_h));
    cocoa.sendVoidInt(sidebar_view, sel_setAutoresizingMask, 1 | 16); // min-x margin (stick to right) + height resizable
    cocoa.sendVoid1(root_view, sel_addSubview, sidebar_view);

    // Left Visual Stack (Sunburst top 320px + Treemap flex bottom)
    const left_w: f64 = win_w - sidebar_w;
    const sunburst_h: f64 = 340.0;
    const treemap_h: f64 = content_h - sunburst_h;

    // Treemap View (bottom of visual stack: y = 32)
    const TreemapCls = cocoa.objc_getClass("ZSpaceTreemapView");
    const treemap_alloc = cocoa.send0(TreemapCls, sel_alloc);
    const treemap_view = cocoa.sendInitRect(treemap_alloc, sel_initWithFrame, cocoa.NSRect.init(0, 32, left_w, treemap_h));
    cocoa.sendVoidInt(treemap_view, sel_setAutoresizingMask, 2 | 16); // width + height resizable
    cocoa.sendVoid1(root_view, sel_addSubview, treemap_view);

    // Sunburst View (top of visual stack: y = 32 + treemap_h)
    const SunburstCls = cocoa.objc_getClass("ZSpaceSunburstView");
    const sunburst_alloc = cocoa.send0(SunburstCls, sel_alloc);
    const sunburst_view = cocoa.sendInitRect(sunburst_alloc, sel_initWithFrame, cocoa.NSRect.init(0, 32 + treemap_h, left_w, sunburst_h));
    cocoa.sendVoidInt(sunburst_view, sel_setAutoresizingMask, 2 | 8); // width resizable + stick to top
    cocoa.sendVoid1(root_view, sel_addSubview, sunburst_view);

    // 7. Order Front and Launch Runloop
    cocoa.sendVoid0(window, sel_center);
    cocoa.sendVoid1(window, sel_makeKeyAndOrderFront, null);
    cocoa.sendVoidBool(app, sel_activateIgnoringOtherApps, true);

    std.debug.print("✓ ZSpace Native Cocoa Liquid Glass UI mounted.\n", .{});
    cocoa.sendVoid0(app, sel_run);
}

fn setupMenuBar(app: cocoa.id) void {
    const NSMenu = cocoa.objc_getClass("NSMenu");
    const NSMenuItem = cocoa.objc_getClass("NSMenuItem");
    const sel_alloc = cocoa.sel_registerName("alloc");
    const sel_init = cocoa.sel_registerName("init");
    const sel_initWithTitle = cocoa.sel_registerName("initWithTitle:action:keyEquivalent:");
    const sel_setSubmenu = cocoa.sel_registerName("setSubmenu:");
    const sel_addItem = cocoa.sel_registerName("addItem:");
    const sel_setMainMenu = cocoa.sel_registerName("setMainMenu:");
    const sel_terminate = cocoa.sel_registerName("terminate:");

    const menubar = cocoa.send0(cocoa.send0(NSMenu, sel_alloc), sel_init);
    const app_menu_item = cocoa.send0(cocoa.send0(NSMenuItem, sel_alloc), sel_init);
    const app_menu = cocoa.send0(cocoa.send0(NSMenu, sel_alloc), sel_init);

    // Quit Menu Item (Cmd+Q)
    const F_initItem = *const fn (cocoa.id, cocoa.SEL, cocoa.id, cocoa.SEL, cocoa.id) callconv(.c) cocoa.id;
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
    cocoa.sendVoid1(app, sel_setMainMenu, menubar);
}
