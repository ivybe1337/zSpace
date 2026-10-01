//! components.zig — Native AppKit custom NSView subclasses and widgets for ZSpace.
//!
//! Written in pure Zig. Subclasses are dynamically constructed at runtime via the
//! Objective-C runtime (objc_allocateClassPair, class_addMethod, objc_registerClassPair).
//! All rendering is performed directly through CoreGraphics and QuartzCore.

const std = @import("std");
const types = @import("../core/types.zig");
const cocoa = @import("cocoa.zig");
const theme = @import("theme.zig");
const sunburst = @import("sunburst.zig");
const treemap = @import("treemap.zig");
const tooltips = @import("tooltips.zig");

// --- Global UI State for Native Views --------------------------------------

pub const ActiveTab = enum { super_finder, dedup_studio, quick_wins, baremetal_editor, machine_telemetry, spacetime_visualizer, time_travel_snapshots, audit_journal };
pub const ScanState = enum { idle, scanning, completed, partial, cancelled, failed };
pub const SortColumn = enum { name, size, blocks, category, modified, inode };
pub const SortDirection = enum { ascending, descending };

pub fn sortDiskNodes(children: []*types.DiskNode, col: SortColumn, dir: SortDirection) void {
    const Sorter = struct {
        col: SortColumn,
        dir: SortDirection,
        pub fn lessThan(ctx: @This(), a: *types.DiskNode, b: *types.DiskNode) bool {
            if (a.isDirectory() != b.isDirectory()) {
                return a.isDirectory();
            }
            const is_less: bool = switch (ctx.col) {
                .name => std.mem.lessThan(u8, a.name, b.name),
                .size => a.size_bytes < b.size_bytes,
                .blocks => a.allocated_bytes < b.allocated_bytes,
                .category => @intFromEnum(a.category) < @intFromEnum(b.category),
                .modified => a.mtime_ns < b.mtime_ns,
                .inode => a.size_bytes < b.size_bytes,
            };
            return if (ctx.dir == .ascending) is_less else !is_less;
        }
    };
    std.mem.sort(*types.DiskNode, children, Sorter{ .col = col, .dir = dir }, Sorter.lessThan);
}

pub const UIState = struct {
    allocator: std.mem.Allocator,
    root_node: ?*const types.DiskNode = null,
    drill_node: ?*const types.DiskNode = null,
    active_tab: ActiveTab = .super_finder,
    selected_indices: std.AutoHashMap(usize, bool),
    hovered_node: ?*const types.DiskNode = null,
    status_text: []const u8 = "Ready",
    daemon_enabled: bool = false,
    daemon_status: []const u8 = "OFF",
    command_input: [256]u8 = undefined,
    command_len: usize = 0,
    scan_state: ScanState = .idle,
    target_path_buf: [1024]u8 = undefined,
    target_path_len: usize = 0,
    scan_trigger_fn: ?*const fn () void = null,
    choose_target_fn: ?*const fn () void = null,
    preset_select_fn: ?*const fn ([]const u8) void = null,
    trash_node_fn: ?*const fn (*const types.DiskNode) void = null,
    volume_total_bytes: u64 = 0,
    volume_free_bytes: u64 = 0,
    volume_used_bytes: u64 = 0,
    volume_pct_used: f32 = 0.0,
    volume_name: [64]u8 = [_]u8{0} ** 64,
    volume_name_len: usize = 0,
    sort_col: SortColumn = .size,
    sort_dir: SortDirection = .descending,
    scroll_offset_y: f64 = 0.0,
    sidebar_scroll_offset_y: f64 = 0.0,
    selected_node: ?*const types.DiskNode = null,
    hovered_row: ?usize = null,

    pub fn init(allocator: std.mem.Allocator) UIState {
        return .{
            .allocator = allocator,
            .selected_indices = std.AutoHashMap(usize, bool).init(allocator),
        };
    }

    pub fn deinit(self: *UIState) void {
        self.selected_indices.deinit();
    }

    pub fn getTargetPath(self: *const UIState) []const u8 {
        if (self.target_path_len > 0) {
            return self.target_path_buf[0..self.target_path_len];
        }
        return ".";
    }

    pub fn setTargetPath(self: *UIState, new_path: []const u8) void {
        const len = @min(new_path.len, self.target_path_buf.len);
        @memcpy(self.target_path_buf[0..len], new_path[0..len]);
        self.target_path_len = len;
        self.scan_state = .idle;
        self.root_node = null;
        self.drill_node = null;
        self.selected_node = null;
        self.scroll_offset_y = 0.0;
        self.selected_indices.clearRetainingCapacity();
    }
};

pub extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

pub fn getHomeDir() []const u8 {
    if (getenv("HOME")) |h| {
        return std.mem.span(h);
    }
    return "/Users/joshua";
}

pub var global_ui_state: ?*UIState = null;

pub var view_header: cocoa.id = null;
pub var view_status: cocoa.id = null;
pub var view_sidebar: cocoa.id = null;
pub var view_workspace_rail: cocoa.id = null;
pub var view_stage: cocoa.id = null;
pub var view_treemap: cocoa.id = null;
pub var view_sunburst: cocoa.id = null;

pub fn requestRedraw() void {
    ensureSelectors();
    if (view_header) |v| cocoa.sendVoidBool(v, sel_setNeedsDisplay, true);
    if (view_status) |v| cocoa.sendVoidBool(v, sel_setNeedsDisplay, true);
    if (view_sidebar) |v| cocoa.sendVoidBool(v, sel_setNeedsDisplay, true);
    if (view_workspace_rail) |v| cocoa.sendVoidBool(v, sel_setNeedsDisplay, true);
    if (view_stage) |v| cocoa.sendVoidBool(v, sel_setNeedsDisplay, true);
    if (view_treemap) |v| cocoa.sendVoidBool(v, sel_setNeedsDisplay, true);
    if (view_sunburst) |v| cocoa.sendVoidBool(v, sel_setNeedsDisplay, true);
}

// --- Custom View Selectors & Types -----------------------------------------

var sel_drawRect: cocoa.SEL = null;
var sel_mouseDown: cocoa.SEL = null;
var sel_rightMouseDown: cocoa.SEL = null;
var sel_scrollWheel: cocoa.SEL = null;
var sel_bounds: cocoa.SEL = null;
var sel_setNeedsDisplay: cocoa.SEL = null;

fn ensureSelectors() void {
    if (sel_drawRect != null) return;
    sel_drawRect = cocoa.sel_registerName("drawRect:");
    sel_mouseDown = cocoa.sel_registerName("mouseDown:");
    sel_rightMouseDown = cocoa.sel_registerName("rightMouseDown:");
    sel_scrollWheel = cocoa.sel_registerName("scrollWheel:");
    sel_bounds = cocoa.sel_registerName("bounds");
    sel_setNeedsDisplay = cocoa.sel_registerName("setNeedsDisplay:");
}

// --- 1. HeaderView: Brand Jewel & Status -----------------------------------

fn drawHeaderRect(self: cocoa.id, _: cocoa.SEL, dirty: cocoa.NSRect) callconv(.c) void {
    _ = dirty;
    const ctx = cocoa.getCurrentGraphicsContext() orelse return;
    cocoa.CGContextSaveGState(ctx);
    defer cocoa.CGContextRestoreGState(ctx);

    const bounds = cocoa.sendGetRect(self, sel_bounds);

    // Deep Obsidian gradient background #08090D -> #101216
    const bg_color = cocoa.makeCGColor(0x08090D, 1.0);
    defer cocoa.CGColorRelease(bg_color);
    cocoa.CGContextSetFillColorWithColor(ctx, bg_color);
    cocoa.CGContextFillRect(ctx, bounds);

    // Hairline bottom divider rgba(255,255,255,0.08)
    const line_color = cocoa.makeCGColor(0xFFFFFF, 0.08);
    defer cocoa.CGColorRelease(line_color);
    cocoa.CGContextSetStrokeColorWithColor(ctx, line_color);
    cocoa.CGContextSetLineWidth(ctx, 1.0);
    cocoa.CGContextBeginPath(ctx);
    cocoa.CGContextMoveToPoint(ctx, 0, 0);
    cocoa.CGContextAddLineToPoint(ctx, bounds.w, 0);
    cocoa.CGContextDrawPath(ctx, 2); // stroke

    const state = global_ui_state orelse return;

    // Status Jewel: Aquamarine if completed, Orange/Cyan pulse if scanning, Silver if idle
    const jewel_hex: u32 = switch (state.scan_state) {
        .idle => 0x8E9BAE,
        .scanning => 0xFFB300,
        .completed => 0x00E5FF,
        .partial => 0xFF6E40,
        .cancelled => 0x9AA0A6,
        .failed => 0xFF5252,
    };
    const jewel_color = cocoa.makeCGColor(jewel_hex, 0.95);
    defer cocoa.CGColorRelease(jewel_color);
    cocoa.CGContextSetFillColorWithColor(ctx, jewel_color);
    cocoa.CGContextFillEllipseInRect(ctx, cocoa.NSRect.init(18, bounds.h / 2.0 - 5.0, 10, 10));

    // Outer glow ring
    const glow_color = cocoa.makeCGColor(jewel_hex, 0.25);
    defer cocoa.CGColorRelease(glow_color);
    cocoa.CGContextSetStrokeColorWithColor(ctx, glow_color);
    cocoa.CGContextSetLineWidth(ctx, 2.0);
    cocoa.CGContextStrokeEllipseInRect(ctx, cocoa.NSRect.init(15, bounds.h / 2.0 - 8.0, 16, 16));

    // Brand and Mode Title
    cocoa.drawStringWithColor("ZSPACE  //  SPACETIME DISK INTELLIGENCE", 42, bounds.h / 2.0 - 7.0, 0.95, 0.96, 0.98, 1.0);

    // Target Path badge (interactive)
    const target_path_str: []const u8 = state.getTargetPath();
    const badge_x: f64 = 340.0;
    const badge_y: f64 = (bounds.h - 30.0) / 2.0;
    const badge_w: f64 = @max(200.0, @min(360.0, bounds.w - 710.0));
    const badge_h: f64 = 30.0;
    const badge_rect = cocoa.NSRect.init(badge_x, badge_y, badge_w, badge_h);

    const badge_bg = cocoa.makeCGColor(0x11141C, 0.9);
    defer cocoa.CGColorRelease(badge_bg);
    cocoa.CGContextSetFillColorWithColor(ctx, badge_bg);
    cocoa.CGContextFillRect(ctx, badge_rect);

    const badge_border = cocoa.makeCGColor(0x28303E, 0.8);
    defer cocoa.CGColorRelease(badge_border);
    cocoa.CGContextSetStrokeColorWithColor(ctx, badge_border);
    cocoa.CGContextSetLineWidth(ctx, 1.0);
    cocoa.CGContextStrokeRect(ctx, badge_rect);

    const target_display = if (target_path_str.len > 32)
        target_path_str[0..32]
    else
        target_path_str;
    cocoa.drawStringWithColor("Target: ", badge_x + 10, badge_y + 7, 0.45, 0.50, 0.58, 1.0);
    cocoa.drawStringWithColor(target_display, badge_x + 65, badge_y + 7, 0.0, 0.90, 1.0, 1.0);

    // 1. [ 📁 CHOOSE TARGET ] Action Button
    const choose_btn_w: f64 = 150.0;
    const choose_btn_h: f64 = 34.0;
    const choose_btn_x: f64 = bounds.w - 335.0;
    const choose_btn_y: f64 = (bounds.h - choose_btn_h) / 2.0;
    const choose_btn_rect = cocoa.NSRect.init(choose_btn_x, choose_btn_y, choose_btn_w, choose_btn_h);

    const choose_bg = cocoa.makeCGColor(0x161922, 0.9);
    defer cocoa.CGColorRelease(choose_bg);
    cocoa.CGContextSetFillColorWithColor(ctx, choose_bg);
    cocoa.CGContextFillRect(ctx, choose_btn_rect);

    const choose_border = cocoa.makeCGColor(0x3B4455, 0.85);
    defer cocoa.CGColorRelease(choose_border);
    cocoa.CGContextSetStrokeColorWithColor(ctx, choose_border);
    cocoa.CGContextSetLineWidth(ctx, 1.2);
    cocoa.CGContextStrokeRect(ctx, choose_btn_rect);

    cocoa.drawStringWithColor("📁  CHOOSE TARGET", choose_btn_x + 16, choose_btn_y + 9, 0.82, 0.86, 0.92, 1.0);

    // 2. [ ▶ SCAN TARGET ] Action Button
    const scan_btn_w: f64 = 155.0;
    const scan_btn_h: f64 = 34.0;
    const scan_btn_x: f64 = bounds.w - 175.0;
    const scan_btn_y: f64 = (bounds.h - scan_btn_h) / 2.0;
    const scan_btn_rect = cocoa.NSRect.init(scan_btn_x, scan_btn_y, scan_btn_w, scan_btn_h);

    if (state.scan_state == .scanning) {
        // Scanning badge (Amber / In Progress)
        const btn_bg = cocoa.makeCGColor(0x332200, 0.85);
        defer cocoa.CGColorRelease(btn_bg);
        cocoa.CGContextSetFillColorWithColor(ctx, btn_bg);
        cocoa.CGContextFillRect(ctx, scan_btn_rect);

        const btn_border = cocoa.makeCGColor(0xFFB300, 0.9);
        defer cocoa.CGColorRelease(btn_border);
        cocoa.CGContextSetStrokeColorWithColor(ctx, btn_border);
        cocoa.CGContextSetLineWidth(ctx, 1.5);
        cocoa.CGContextStrokeRect(ctx, scan_btn_rect);

        cocoa.drawStringWithColor("SCANNING...", scan_btn_x + 36, scan_btn_y + 9, 1.0, 0.70, 0.0, 1.0);
    } else {
        // Ready / Idle button (Electric Cyan)
        const btn_bg = cocoa.makeCGColor(0x00E5FF, 0.14);
        defer cocoa.CGColorRelease(btn_bg);
        cocoa.CGContextSetFillColorWithColor(ctx, btn_bg);
        cocoa.CGContextFillRect(ctx, scan_btn_rect);

        const btn_border = cocoa.makeCGColor(0x00E5FF, 0.9);
        defer cocoa.CGColorRelease(btn_border);
        cocoa.CGContextSetStrokeColorWithColor(ctx, btn_border);
        cocoa.CGContextSetLineWidth(ctx, 1.5);
        cocoa.CGContextStrokeRect(ctx, scan_btn_rect);

        const btn_label = if (state.scan_state == .completed or state.scan_state == .partial or state.scan_state == .cancelled) "⟳  RE-SCAN" else "▶  SCAN TARGET";
        const label_offset: f64 = if (state.scan_state == .completed or state.scan_state == .partial or state.scan_state == .cancelled) 40.0 else 26.0;
        cocoa.drawStringWithColor(btn_label, scan_btn_x + label_offset, scan_btn_y + 9, 0.0, 0.90, 1.0, 1.0);
    }
}

fn onHeaderMouseDown(self: cocoa.id, _: cocoa.SEL, event: cocoa.id) callconv(.c) void {
    const state = global_ui_state orelse return;

    // Get click location in window coords, then convert to local view coordinates
    const sel_location = cocoa.sel_registerName("locationInWindow");
    const F_loc = *const fn (cocoa.id, cocoa.SEL) callconv(.c) cocoa.NSPoint;
    const window_point = @as(F_loc, @ptrCast(&cocoa.objc_msgSend))(event, sel_location);

    const sel_convertPoint = cocoa.sel_registerName("convertPoint:fromView:");
    const click_point = cocoa.sendConvertPointFromView(self, sel_convertPoint, window_point, null);

    const bounds = cocoa.sendGetRect(self, sel_bounds);

    // 1. Check Choose Target button or Target Badge
    const choose_btn_w: f64 = 150.0;
    const choose_btn_h: f64 = 34.0;
    const choose_btn_x: f64 = bounds.w - 335.0;
    const choose_btn_y: f64 = (bounds.h - choose_btn_h) / 2.0;

    const badge_x: f64 = 340.0;
    const badge_y: f64 = (bounds.h - 30.0) / 2.0;
    const badge_w: f64 = @max(200.0, @min(360.0, bounds.w - 710.0));
    const badge_h: f64 = 30.0;

    const in_choose = (click_point.x >= choose_btn_x and click_point.x <= choose_btn_x + choose_btn_w and
        click_point.y >= choose_btn_y and click_point.y <= choose_btn_y + choose_btn_h);
    const in_badge = (click_point.x >= badge_x and click_point.x <= badge_x + badge_w and
        click_point.y >= badge_y and click_point.y <= badge_y + badge_h);

    if (in_choose or in_badge) {
        if (state.scan_state != .scanning) {
            if (state.choose_target_fn) |choose_fn| {
                choose_fn();
                return;
            }
        }
    }

    // 2. Check Scan Target button
    const scan_btn_w: f64 = 155.0;
    const scan_btn_h: f64 = 34.0;
    const scan_btn_x: f64 = bounds.w - 175.0;
    const scan_btn_y: f64 = (bounds.h - scan_btn_h) / 2.0;

    if (click_point.x >= scan_btn_x and click_point.x <= scan_btn_x + scan_btn_w and
        click_point.y >= scan_btn_y and click_point.y <= scan_btn_y + scan_btn_h)
    {
        if (state.scan_state != .scanning) {
            if (state.scan_trigger_fn) |trigger| {
                trigger();
            }
        }
    }
}

// --- 2. SunburstView: Radial Spacetime Visualizer ---------------------------

fn drawSunburstRect(self: cocoa.id, _: cocoa.SEL, dirty: cocoa.NSRect) callconv(.c) void {
    _ = dirty;
    const ctx = cocoa.getCurrentGraphicsContext() orelse return;
    cocoa.CGContextSaveGState(ctx);
    defer cocoa.CGContextRestoreGState(ctx);

    const bounds = cocoa.sendGetRect(self, sel_bounds);

    // Card background #0D0E12
    const bg_color = cocoa.makeCGColor(0x0D0E12, 1.0);
    defer cocoa.CGColorRelease(bg_color);
    cocoa.CGContextSetFillColorWithColor(ctx, bg_color);
    cocoa.CGContextFillRect(ctx, bounds);
    const center_x = bounds.w / 2.0;
    const center_y = bounds.h / 2.0;

    const state = global_ui_state orelse return;
    if (state.active_tab != .super_finder and state.active_tab != .spacetime_visualizer) {
        drawWorkspacePlaceholder(ctx, bounds, state.active_tab);
        return;
    }
    const node_opt = state.drill_node orelse state.root_node;

    if (node_opt == null or state.scan_state == .idle) {
        if (state.scan_state == .idle) {
            // Hero Title
            cocoa.drawStringWithColor("YOUR STORAGE, IN CLEAR VIEW", center_x - 138, bounds.h - 40, 0.0, 0.90, 1.0, 1.0);
            cocoa.drawStringWithColor("Choose a folder and scan when you are ready. ZSpace stays idle until then.", center_x - 250, bounds.h - 65, 0.55, 0.60, 0.68, 1.0);

            // Volume Telemetry Card
            const card_w: f64 = @min(660.0, bounds.w - 40.0);
            const card_h: f64 = 96.0;
            const card_x: f64 = (bounds.w - card_w) / 2.0;
            const card_y: f64 = (bounds.h - card_h) / 2.0 - 15.0;
            const card_rect = cocoa.NSRect.init(card_x, card_y, card_w, card_h);

            const card_bg = cocoa.makeCGColor(0x12151D, 0.95);
            defer cocoa.CGColorRelease(card_bg);
            cocoa.CGContextSetFillColorWithColor(ctx, card_bg);
            cocoa.CGContextFillRect(ctx, card_rect);

            const card_border = cocoa.makeCGColor(0x222834, 0.9);
            defer cocoa.CGColorRelease(card_border);
            cocoa.CGContextSetStrokeColorWithColor(ctx, card_border);
            cocoa.CGContextSetLineWidth(ctx, 1.2);
            cocoa.CGContextStrokeRect(ctx, card_rect);

            // Title & Mount
            cocoa.drawStringWithColor("PRIMARY VOLUME TELEMETRY: Macintosh HD (APFS)", card_x + 20, card_y + 68, 0.90, 0.93, 0.96, 1.0);

            // Formatted Space String
            var used_b: [32]u8 = undefined;
            var free_b: [32]u8 = undefined;
            var tot_b: [32]u8 = undefined;
            const used_s = types.DiskNode.formatSize(state.volume_used_bytes, &used_b);
            const free_s = types.DiskNode.formatSize(state.volume_free_bytes, &free_b);
            const tot_s = types.DiskNode.formatSize(state.volume_total_bytes, &tot_b);

            var stat_line: [128]u8 = undefined;
            const stat_str = std.fmt.bufPrint(&stat_line, "Used: {s}  •  Available: {s}  •  Total: {s}  ({d:.1}% Allocated)", .{
                used_s,
                free_s,
                tot_s,
                state.volume_pct_used,
            }) catch "Storage stats ready";
            cocoa.drawStringWithColor(stat_str, card_x + 20, card_y + 44, 0.65, 0.70, 0.76, 1.0);

            // Storage Gauge Bar
            const bar_w = card_w - 40.0;
            const bar_h = 10.0;
            const bar_rect = cocoa.NSRect.init(card_x + 20, card_y + 18, bar_w, bar_h);

            const bar_bg = cocoa.makeCGColor(0x1B202A, 1.0);
            defer cocoa.CGColorRelease(bar_bg);
            cocoa.CGContextSetFillColorWithColor(ctx, bar_bg);
            cocoa.CGContextFillRect(ctx, bar_rect);

            const pct = @min(100.0, @max(0.0, state.volume_pct_used));
            const fill_w = bar_w * (@as(f64, @floatCast(pct)) / 100.0);
            const fill_rect = cocoa.NSRect.init(card_x + 20, card_y + 18, fill_w, bar_h);

            const bar_fill = cocoa.makeCGColor(0x00E5FF, 0.85);
            defer cocoa.CGColorRelease(bar_fill);
            cocoa.CGContextSetFillColorWithColor(ctx, bar_fill);
            cocoa.CGContextFillRect(ctx, fill_rect);

            const bar_border = cocoa.makeCGColor(0x2E3646, 0.8);
            defer cocoa.CGColorRelease(bar_border);
            cocoa.CGContextSetStrokeColorWithColor(ctx, bar_border);
            cocoa.CGContextSetLineWidth(ctx, 1.0);
            cocoa.CGContextStrokeRect(ctx, bar_rect);
        } else if (state.scan_state == .scanning) {
            cocoa.drawStringWithColor("Analyzing spacetime radial distribution...", center_x - 130, center_y - 7, 0.0, 0.90, 1.0, 1.0);
        } else {
            cocoa.drawStringWithColor("No files found or empty directory.", center_x - 110, center_y - 7, 0.56, 0.61, 0.68, 1.0);
        }
        return;
    }

    const node = node_opt.?;
    var layout = sunburst.SunburstLayout.init(state.allocator);
    layout.center_radius = 45.0;
    layout.ring_thickness = 28.0;

    var arcs = layout.generateLayout(node) catch return;
    defer arcs.deinit(state.allocator);

    if (arcs.items.len == 0) {
        cocoa.drawStringWithColor("No files found or empty directory.", center_x - 110, center_y - 7, 0.56, 0.61, 0.68, 1.0);
        return;
    }

    for (arcs.items) |arc| {
        cocoa.CGContextBeginPath(ctx);
        // Outer arc
        cocoa.CGContextAddArc(ctx, center_x, center_y, arc.outer_radius, arc.start_angle_rad, arc.end_angle_rad, 0);
        // Inner arc (reverse direction)
        cocoa.CGContextAddArc(ctx, center_x, center_y, arc.inner_radius, arc.end_angle_rad, arc.start_angle_rad, 1);
        cocoa.CGContextClosePath(ctx);

        const arc_color = cocoa.makeCGColor(arc.color, if (arc.depth == 0) 0.85 else 0.75);
        defer cocoa.CGColorRelease(arc_color);
        cocoa.CGContextSetFillColorWithColor(ctx, arc_color);
        cocoa.CGContextDrawPath(ctx, 0); // fill

        // Wedge separator border
        const stroke_color = cocoa.makeCGColor(0x08090D, 0.9);
        defer cocoa.CGColorRelease(stroke_color);
        cocoa.CGContextSetStrokeColorWithColor(ctx, stroke_color);
        cocoa.CGContextSetLineWidth(ctx, 1.0);
        cocoa.CGContextDrawPath(ctx, 2); // stroke
    }

    // Center Core (Drill ascending target)
    const core_color = cocoa.makeCGColor(0x181B22, 1.0);
    defer cocoa.CGColorRelease(core_color);
    cocoa.CGContextSetFillColorWithColor(ctx, core_color);
    cocoa.CGContextFillEllipseInRect(ctx, cocoa.NSRect.init(center_x - 35, center_y - 35, 70, 70));

    const core_ring = cocoa.makeCGColor(0x00E5FF, 0.4);
    defer cocoa.CGColorRelease(core_ring);
    cocoa.CGContextSetStrokeColorWithColor(ctx, core_ring);
    cocoa.CGContextSetLineWidth(ctx, 1.5);
    cocoa.CGContextStrokeEllipseInRect(ctx, cocoa.NSRect.init(center_x - 35, center_y - 35, 70, 70));
}

fn onSunburstMouseDown(self: cocoa.id, _: cocoa.SEL, _: cocoa.id) callconv(.c) void {
    const state = global_ui_state orelse return;
    // Drill logic: toggle drill root or ascend
    if (state.drill_node != null) {
        state.drill_node = null; // ascend back to root
    } else if (state.root_node) |r| {
        if (r.children.items.len > 0) {
            state.drill_node = r.children.items[0]; // drill into largest subtree
        }
    }
    cocoa.sendVoidBool(self, sel_setNeedsDisplay, true);
}

// --- 3. TreemapView: Squarified CoreGraphics Treemap -----------------------

fn drawTreemapRect(self: cocoa.id, _: cocoa.SEL, dirty: cocoa.NSRect) callconv(.c) void {
    _ = dirty;
    const ctx = cocoa.getCurrentGraphicsContext() orelse return;
    cocoa.CGContextSaveGState(ctx);
    defer cocoa.CGContextRestoreGState(ctx);

    const bounds = cocoa.sendGetRect(self, sel_bounds);

    // Background #0B0C10
    const bg_color = cocoa.makeCGColor(0x0B0C10, 1.0);
    defer cocoa.CGColorRelease(bg_color);
    cocoa.CGContextSetFillColorWithColor(ctx, bg_color);
    cocoa.CGContextFillRect(ctx, bounds);
    const state = global_ui_state orelse return;
    if (state.active_tab != .super_finder and state.active_tab != .spacetime_visualizer) {
        drawWorkspacePlaceholder(ctx, bounds, state.active_tab);
        return;
    }
    const node_opt = state.drill_node orelse state.root_node;

    if (node_opt == null or state.scan_state == .idle) {
        if (state.scan_state == .idle) {
            // Section Header
            cocoa.drawStringWithColor("QUICK TARGET PRESETS  —  Select location to inspect:", 36, bounds.h - 35, 0.85, 0.88, 0.94, 1.0);

            const card_w: f64 = (bounds.w - 72.0 - 16.0) / 2.0;
            const card_h: f64 = 52.0;
            const col1_x: f64 = 36.0;
            const col2_x: f64 = 36.0 + card_w + 16.0;
            const row1_y: f64 = bounds.h - 96.0;
            const row2_y: f64 = bounds.h - 156.0;
            const row3_y: f64 = bounds.h - 206.0;
            const row3_w: f64 = card_w * 2.0 + 16.0;
            const row3_h: f64 = 38.0;

            const cur_target = state.getTargetPath();

            // Card 1: 📥 Downloads
            const in_dl = std.mem.endsWith(u8, cur_target, "Downloads");
            renderPresetCard(ctx, col1_x, row1_y, card_w, card_h, "📥  Downloads Folder", "~/Downloads • DMGs, ZIPs, installers", in_dl);

            // Card 2: 💼 Developer Projects
            const in_proj = std.mem.endsWith(u8, cur_target, "LocalBuilds") or std.mem.endsWith(u8, cur_target, "Projects");
            renderPresetCard(ctx, col2_x, row1_y, card_w, card_h, "💼  Developer Projects", "~/LocalBuilds • Node_modules, build artifacts", in_proj);

            // Card 3: 💻 Applications
            const in_apps = std.mem.eql(u8, cur_target, "/Applications");
            renderPresetCard(ctx, col1_x, row2_y, card_w, card_h, "💻  System Applications", "/Applications • Installed app bundles", in_apps);

            // Card 4: 🏠 User Home
            const in_home = !in_dl and !in_proj and !in_apps and (std.mem.startsWith(u8, cur_target, "/Users/") or std.mem.eql(u8, cur_target, "~"));
            renderPresetCard(ctx, col2_x, row2_y, card_w, card_h, "🏠  User Home Profile", "~/ • Full user profile & caches", in_home);

            // Card 5: 📁 Browse Folder
            const r5_rect = cocoa.NSRect.init(col1_x, row3_y, row3_w, row3_h);
            const r5_bg = cocoa.makeCGColor(0x141824, 0.95);
            defer cocoa.CGColorRelease(r5_bg);
            cocoa.CGContextSetFillColorWithColor(ctx, r5_bg);
            cocoa.CGContextFillRect(ctx, r5_rect);

            const r5_border = cocoa.makeCGColor(0x00E5FF, 0.5);
            defer cocoa.CGColorRelease(r5_border);
            cocoa.CGContextSetStrokeColorWithColor(ctx, r5_border);
            cocoa.CGContextSetLineWidth(ctx, 1.2);
            cocoa.CGContextStrokeRect(ctx, r5_rect);

            cocoa.drawStringWithColor("📁  Browse Custom Folder or External Drive... (⌘O)", col1_x + 20, row3_y + 11, 0.0, 0.90, 1.0, 1.0);
        } else if (state.scan_state == .scanning) {
            cocoa.drawStringWithColor("Generating squarified treemap...", bounds.w / 2.0 - 100, bounds.h / 2.0 - 7, 0.0, 0.90, 1.0, 1.0);
        } else {
            cocoa.drawStringWithColor("No files found to visualize in treemap.", bounds.w / 2.0 - 120, bounds.h / 2.0 - 7, 0.56, 0.61, 0.68, 1.0);
        }
        return;
    }

    const node = node_opt.?;
    var layout = treemap.TreemapLayout.init(state.allocator);
    var rects = layout.layout(node, 2.0, 2.0, @floatCast(bounds.w - 4.0), @floatCast(bounds.h - 4.0)) catch return;
    defer rects.deinit(state.allocator);

    if (rects.items.len == 0) {
        cocoa.drawStringWithColor("No files found to visualize in treemap.", bounds.w / 2.0 - 120, bounds.h / 2.0 - 7, 0.56, 0.61, 0.68, 1.0);
        return;
    }

    for (rects.items) |r| {
        const rect = cocoa.NSRect.init(r.x, r.y, r.w, r.h);

        // Fill rectangle
        const fill_col = cocoa.makeCGColor(r.color, 0.70);
        defer cocoa.CGColorRelease(fill_col);
        cocoa.CGContextSetFillColorWithColor(ctx, fill_col);
        cocoa.CGContextFillRect(ctx, rect);

        // Subtle borders
        const border_col = cocoa.makeCGColor(0x181B22, 0.95);
        defer cocoa.CGColorRelease(border_col);
        cocoa.CGContextSetStrokeColorWithColor(ctx, border_col);
        cocoa.CGContextSetLineWidth(ctx, 1.0);
        cocoa.CGContextStrokeRect(ctx, rect);
    }
}

fn renderPresetCard(ctx: cocoa.CGContextRef, x: f64, y: f64, w: f64, h: f64, title: []const u8, sub: []const u8, selected: bool) void {
    const rect = cocoa.NSRect.init(x, y, w, h);
    const bg_hex: u32 = if (selected) 0x14202C else 0x11141B;
    const bg_color = cocoa.makeCGColor(bg_hex, 0.95);
    defer cocoa.CGColorRelease(bg_color);
    cocoa.CGContextSetFillColorWithColor(ctx, bg_color);
    cocoa.CGContextFillRect(ctx, rect);

    const border_hex: u32 = if (selected) 0x00E5FF else 0x222834;
    const border_color = cocoa.makeCGColor(border_hex, if (selected) 0.95 else 0.8);
    defer cocoa.CGColorRelease(border_color);
    cocoa.CGContextSetStrokeColorWithColor(ctx, border_color);
    cocoa.CGContextSetLineWidth(ctx, if (selected) 1.5 else 1.0);
    cocoa.CGContextStrokeRect(ctx, rect);

    cocoa.drawStringWithColor(title, x + 16, y + 29, if (selected) 0.0 else 0.90, if (selected) 0.90 else 0.93, 1.0, 1.0);
    cocoa.drawStringWithColor(sub, x + 16, y + 10, 0.55, 0.60, 0.68, 1.0);

    if (selected) {
        cocoa.drawStringWithColor("● SELECTED", x + w - 95, y + 29, 0.0, 0.90, 1.0, 1.0);
    }
}

fn onTreemapMouseDown(self: cocoa.id, _: cocoa.SEL, event: cocoa.id) callconv(.c) void {
    const state = global_ui_state orelse return;
    if (state.scan_state != .idle) return;

    const sel_location = cocoa.sel_registerName("locationInWindow");
    const F_loc = *const fn (cocoa.id, cocoa.SEL) callconv(.c) cocoa.NSPoint;
    const window_point = @as(F_loc, @ptrCast(&cocoa.objc_msgSend))(event, sel_location);

    const sel_convertPoint = cocoa.sel_registerName("convertPoint:fromView:");
    const click_point = cocoa.sendConvertPointFromView(self, sel_convertPoint, window_point, null);

    const bounds = cocoa.sendGetRect(self, sel_bounds);
    const card_w: f64 = (bounds.w - 72.0 - 16.0) / 2.0;
    const card_h: f64 = 52.0;
    const col1_x: f64 = 36.0;
    const col2_x: f64 = 36.0 + card_w + 16.0;
    const row1_y: f64 = bounds.h - 96.0;
    const row2_y: f64 = bounds.h - 156.0;
    const row3_y: f64 = bounds.h - 206.0;
    const row3_w: f64 = card_w * 2.0 + 16.0;
    const row3_h: f64 = 38.0;

    const home = getHomeDir();

    // Card 1: Downloads
    if (click_point.x >= col1_x and click_point.x <= col1_x + card_w and
        click_point.y >= row1_y and click_point.y <= row1_y + card_h)
    {
        var buf: [1024]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/Downloads", .{home}) catch return;
        if (state.preset_select_fn) |f| f(p);
        return;
    }

    // Card 2: Developer Projects
    if (click_point.x >= col2_x and click_point.x <= col2_x + card_w and
        click_point.y >= row1_y and click_point.y <= row1_y + card_h)
    {
        var buf: [1024]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/LocalBuilds", .{home}) catch return;
        if (state.preset_select_fn) |f| f(p);
        return;
    }

    // Card 3: Applications
    if (click_point.x >= col1_x and click_point.x <= col1_x + card_w and
        click_point.y >= row2_y and click_point.y <= row2_y + card_h)
    {
        if (state.preset_select_fn) |f| f("/Applications");
        return;
    }

    // Card 4: User Home
    if (click_point.x >= col2_x and click_point.x <= col2_x + card_w and
        click_point.y >= row2_y and click_point.y <= row2_y + card_h)
    {
        if (state.preset_select_fn) |f| f(home);
        return;
    }

    // Card 5: Browse Folder
    if (click_point.x >= col1_x and click_point.x <= col1_x + row3_w and
        click_point.y >= row3_y and click_point.y <= row3_y + row3_h)
    {
        if (state.choose_target_fn) |f| f();
        return;
    }
}

// --- 4. SidebarView: Custom Draw for Files / Dupes / Wins ------------------

fn drawSidebarRect(self: cocoa.id, _: cocoa.SEL, dirty: cocoa.NSRect) callconv(.c) void {
    _ = dirty;
    const ctx = cocoa.getCurrentGraphicsContext() orelse return;
    cocoa.CGContextSaveGState(ctx);
    defer cocoa.CGContextRestoreGState(ctx);

    const bounds = cocoa.sendGetRect(self, sel_bounds);

    // Surface panel #101216
    const bg_color = cocoa.makeCGColor(0x101216, 1.0);
    defer cocoa.CGColorRelease(bg_color);
    cocoa.CGContextSetFillColorWithColor(ctx, bg_color);
    cocoa.CGContextFillRect(ctx, bounds);

    // Left border divider
    const line_color = cocoa.makeCGColor(0x282C37, 0.8);
    defer cocoa.CGColorRelease(line_color);
    cocoa.CGContextSetStrokeColorWithColor(ctx, line_color);
    cocoa.CGContextSetLineWidth(ctx, 1.0);
    cocoa.CGContextBeginPath(ctx);
    cocoa.CGContextMoveToPoint(ctx, 0, 0);
    cocoa.CGContextAddLineToPoint(ctx, 0, bounds.h);
    cocoa.CGContextDrawPath(ctx, 2);

    const state = global_ui_state orelse return;
    const node_opt = state.drill_node orelse state.root_node;

    if (node_opt == null or state.scan_state == .idle) {
        if (state.scan_state == .idle) {
            // Header
            cocoa.drawStringWithColor("TARGET & TELEMETRY", 24, bounds.h - 35, 0.90, 0.93, 0.96, 1.0);

            const card_x: f64 = 18.0;
            const card_w: f64 = bounds.w - 36.0;

            // Target Info Card
            const t_rect = cocoa.NSRect.init(card_x, bounds.h - 120.0, card_w, 70.0);
            const t_bg = cocoa.makeCGColor(0x13161F, 0.95);
            defer cocoa.CGColorRelease(t_bg);
            cocoa.CGContextSetFillColorWithColor(ctx, t_bg);
            cocoa.CGContextFillRect(ctx, t_rect);

            const t_border = cocoa.makeCGColor(0x222834, 0.9);
            defer cocoa.CGColorRelease(t_border);
            cocoa.CGContextSetStrokeColorWithColor(ctx, t_border);
            cocoa.CGContextSetLineWidth(ctx, 1.0);
            cocoa.CGContextStrokeRect(ctx, t_rect);

            cocoa.drawStringWithColor("SELECTED DIRECTORY:", card_x + 16, bounds.h - 96.0, 0.45, 0.50, 0.58, 1.0);
            const cur_tgt = state.getTargetPath();
            const tgt_disp = if (cur_tgt.len > 28) cur_tgt[0..28] else cur_tgt;
            cocoa.drawStringWithColor(tgt_disp, card_x + 16, bounds.h - 114.0, 0.0, 0.90, 1.0, 1.0);

            // Action Button 1: Begin Analysis
            const btn1_y = bounds.h - 175.0;
            const btn1_h = 42.0;
            const btn1_rect = cocoa.NSRect.init(card_x, btn1_y, card_w, btn1_h);

            const btn1_bg = cocoa.makeCGColor(0x00E5FF, 0.20);
            defer cocoa.CGColorRelease(btn1_bg);
            cocoa.CGContextSetFillColorWithColor(ctx, btn1_bg);
            cocoa.CGContextFillRect(ctx, btn1_rect);

            const btn1_border = cocoa.makeCGColor(0x00E5FF, 0.95);
            defer cocoa.CGColorRelease(btn1_border);
            cocoa.CGContextSetStrokeColorWithColor(ctx, btn1_border);
            cocoa.CGContextSetLineWidth(ctx, 1.5);
            cocoa.CGContextStrokeRect(ctx, btn1_rect);

            cocoa.drawStringWithColor("▶   BEGIN ANALYSIS (⌘R)", card_x + (card_w - 200.0) / 2.0, btn1_y + 13.0, 0.0, 0.90, 1.0, 1.0);

            // Action Button 2: Choose Target Folder
            const btn2_y = bounds.h - 228.0;
            const btn2_h = 38.0;
            const btn2_rect = cocoa.NSRect.init(card_x, btn2_y, card_w, btn2_h);

            const btn2_bg = cocoa.makeCGColor(0x161A24, 0.95);
            defer cocoa.CGColorRelease(btn2_bg);
            cocoa.CGContextSetFillColorWithColor(ctx, btn2_bg);
            cocoa.CGContextFillRect(ctx, btn2_rect);

            const btn2_border = cocoa.makeCGColor(0x3B4455, 0.85);
            defer cocoa.CGColorRelease(btn2_border);
            cocoa.CGContextSetStrokeColorWithColor(ctx, btn2_border);
            cocoa.CGContextSetLineWidth(ctx, 1.2);
            cocoa.CGContextStrokeRect(ctx, btn2_rect);

            cocoa.drawStringWithColor("📁   CHOOSE TARGET (⌘O)", card_x + (card_w - 190.0) / 2.0, btn2_y + 11.0, 0.85, 0.88, 0.94, 1.0);

            // System Engine Properties Card
            const eng_y = bounds.h - 350.0;
            const eng_h = 100.0;
            const eng_rect = cocoa.NSRect.init(card_x, eng_y, card_w, eng_h);
            const eng_bg = cocoa.makeCGColor(0x10131A, 0.95);
            defer cocoa.CGColorRelease(eng_bg);
            cocoa.CGContextSetFillColorWithColor(ctx, eng_bg);
            cocoa.CGContextFillRect(ctx, eng_rect);

            const eng_border = cocoa.makeCGColor(0x1E232E, 0.85);
            defer cocoa.CGColorRelease(eng_border);
            cocoa.CGContextSetStrokeColorWithColor(ctx, eng_border);
            cocoa.CGContextSetLineWidth(ctx, 1.0);
            cocoa.CGContextStrokeRect(ctx, eng_rect);

            cocoa.drawStringWithColor("ENGINE INVARIANTS:", card_x + 16, eng_y + 74, 0.85, 0.88, 0.94, 1.0);
            cocoa.drawStringWithColor("• No scan starts at launch", card_x + 16, eng_y + 54, 0.55, 0.60, 0.68, 1.0);
            cocoa.drawStringWithColor("• Traversal errors remain visible", card_x + 16, eng_y + 36, 0.55, 0.60, 0.68, 1.0);
            cocoa.drawStringWithColor("• Cleanup safety work is in progress", card_x + 16, eng_y + 18, 0.55, 0.60, 0.68, 1.0);

            // Shortcuts Guide Card
            const sc_y = bounds.h - 475.0;
            const sc_h = 105.0;
            const sc_rect = cocoa.NSRect.init(card_x, sc_y, card_w, sc_h);
            const sc_bg = cocoa.makeCGColor(0x10131A, 0.95);
            defer cocoa.CGColorRelease(sc_bg);
            cocoa.CGContextSetFillColorWithColor(ctx, sc_bg);
            cocoa.CGContextFillRect(ctx, sc_rect);

            const sc_border = cocoa.makeCGColor(0x1E232E, 0.85);
            defer cocoa.CGColorRelease(sc_border);
            cocoa.CGContextSetStrokeColorWithColor(ctx, sc_border);
            cocoa.CGContextSetLineWidth(ctx, 1.0);
            cocoa.CGContextStrokeRect(ctx, sc_rect);

            cocoa.drawStringWithColor("QUICK SHORTCUTS:", card_x + 16, sc_y + 80, 0.85, 0.88, 0.94, 1.0);
            cocoa.drawStringWithColor("⌘O  —  Choose custom target folder", card_x + 16, sc_y + 60, 0.55, 0.60, 0.68, 1.0);
            cocoa.drawStringWithColor("⌘R  —  Run disk analysis", card_x + 16, sc_y + 42, 0.55, 0.60, 0.68, 1.0);
            cocoa.drawStringWithColor("⌘1..5 — Quick switch presets", card_x + 16, sc_y + 24, 0.55, 0.60, 0.68, 1.0);
            cocoa.drawStringWithColor("⌘Q  —  Quit ZSpace", card_x + 16, sc_y + 6, 0.55, 0.60, 0.68, 1.0);
        } else if (state.scan_state == .scanning) {
            cocoa.drawStringWithColor("Scanning directory in background...", 34, bounds.h / 2.0, 0.0, 0.90, 1.0, 1.0);
        } else {
            cocoa.drawStringWithColor("Empty directory.", 34, bounds.h / 2.0, 0.56, 0.61, 0.68, 1.0);
        }
        return;
    }

    const node = node_opt.?;
    if (node.children.items.len == 0) {
        cocoa.drawStringWithColor("Empty directory.", 34, bounds.h / 2.0, 0.56, 0.61, 0.68, 1.0);
        return;
    }

    // Draw row items
    var y: f64 = bounds.h - 32.0;
    const row_height: f64 = 28.0;

    for (node.children.items, 0..) |child, idx| {
        if (y < 40.0) break; // keep footer space

        const is_selected = state.selected_indices.get(idx) orelse false;

        // Row highlight if selected
        if (is_selected) {
            const row_sel_color = cocoa.makeCGColor(0x00E5FF, 0.15);
            defer cocoa.CGColorRelease(row_sel_color);
            cocoa.CGContextSetFillColorWithColor(ctx, row_sel_color);
            cocoa.CGContextFillRect(ctx, cocoa.NSRect.init(4, y - 2, bounds.w - 8, row_height));
        }

        // Custom drawn Checkbox (14x14)
        const box_rect = cocoa.NSRect.init(12, y + 4, 14, 14);
        const box_border = cocoa.makeCGColor(0x00E5FF, if (is_selected) 1.0 else 0.5);
        defer cocoa.CGColorRelease(box_border);
        cocoa.CGContextSetStrokeColorWithColor(ctx, box_border);
        cocoa.CGContextSetLineWidth(ctx, 1.2);
        cocoa.CGContextStrokeRect(ctx, box_rect);

        if (is_selected) {
            const check_fill = cocoa.makeCGColor(0x00E5FF, 0.9);
            defer cocoa.CGColorRelease(check_fill);
            cocoa.CGContextSetFillColorWithColor(ctx, check_fill);
            cocoa.CGContextFillRect(ctx, cocoa.NSRect.init(15, y + 7, 8, 8));
        }

        // Category indicator dot
        const dot_color = cocoa.makeCGColor(child.category.colorHex(), 0.9);
        defer cocoa.CGColorRelease(dot_color);
        cocoa.CGContextSetFillColorWithColor(ctx, dot_color);
        cocoa.CGContextFillEllipseInRect(ctx, cocoa.NSRect.init(34, y + 7, 8, 8));

        // File/Folder Name
        const name_slice = if (child.name.len > 26) child.name[0..26] else child.name;
        cocoa.drawStringWithColor(name_slice, 50, y + 4, 0.90, 0.92, 0.96, 1.0);

        // Size String on Right
        var sz_buf: [32]u8 = undefined;
        const sz_str = types.DiskNode.formatSize(child.size_bytes, &sz_buf);
        cocoa.drawStringWithColor(sz_str, bounds.w - 90, y + 4, 0.0, 0.90, 1.0, 1.0);

        y -= row_height;
    }
}

fn onSidebarMouseDown(self: cocoa.id, _: cocoa.SEL, event: cocoa.id) callconv(.c) void {
    const state = global_ui_state orelse return;

    // Get click coordinates
    const sel_location = cocoa.sel_registerName("locationInWindow");
    const F_loc = *const fn (cocoa.id, cocoa.SEL) callconv(.c) cocoa.NSPoint;
    const window_point = @as(F_loc, @ptrCast(&cocoa.objc_msgSend))(event, sel_location);

    const sel_convertPoint = cocoa.sel_registerName("convertPoint:fromView:");
    const click_point = cocoa.sendConvertPointFromView(self, sel_convertPoint, window_point, null);

    const bounds = cocoa.sendGetRect(self, sel_bounds);

    if (state.scan_state == .idle) {
        const card_x: f64 = 18.0;
        const card_w: f64 = bounds.w - 36.0;

        // Button 1: Begin Analysis (⌘R)
        const btn1_y = bounds.h - 175.0;
        const btn1_h = 42.0;
        if (click_point.x >= card_x and click_point.x <= card_x + card_w and
            click_point.y >= btn1_y and click_point.y <= btn1_y + btn1_h)
        {
            if (state.scan_trigger_fn) |trigger| trigger();
            return;
        }

        // Button 2: Choose Target (⌘O)
        const btn2_y = bounds.h - 228.0;
        const btn2_h = 38.0;
        if (click_point.x >= card_x and click_point.x <= card_x + card_w and
            click_point.y >= btn2_y and click_point.y <= btn2_y + btn2_h)
        {
            if (state.choose_target_fn) |choose| choose();
            return;
        }
        return;
    }

    const node = state.drill_node orelse state.root_node orelse return;
    const row_height: f64 = 28.0;
    const rel_y = bounds.h - click_point.y;

    if (rel_y > 0 and rel_y < bounds.h - 40.0) {
        const clicked_idx = @as(usize, @intFromFloat(@floor(rel_y / row_height)));
        if (clicked_idx < node.children.items.len) {
            const current = state.selected_indices.get(clicked_idx) orelse false;
            state.selected_indices.put(clicked_idx, !current) catch return;
            cocoa.sendVoidBool(self, sel_setNeedsDisplay, true);
        }
    }
}

// --- 5. StatusView: Metrics, Daemon Pill & Command Line ---------------------

fn drawStatusRect(self: cocoa.id, _: cocoa.SEL, dirty: cocoa.NSRect) callconv(.c) void {
    _ = dirty;
    const ctx = cocoa.getCurrentGraphicsContext() orelse return;
    cocoa.CGContextSaveGState(ctx);
    defer cocoa.CGContextRestoreGState(ctx);

    const bounds = cocoa.sendGetRect(self, sel_bounds);

    // Deep bar #08090D
    const bg_color = cocoa.makeCGColor(0x08090D, 1.0);
    defer cocoa.CGColorRelease(bg_color);
    cocoa.CGContextSetFillColorWithColor(ctx, bg_color);
    cocoa.CGContextFillRect(ctx, bounds);

    // Top hairline stroke
    const line_color = cocoa.makeCGColor(0x282C37, 0.7);
    defer cocoa.CGColorRelease(line_color);
    cocoa.CGContextSetStrokeColorWithColor(ctx, line_color);
    cocoa.CGContextSetLineWidth(ctx, 1.0);
    cocoa.CGContextBeginPath(ctx);
    cocoa.CGContextMoveToPoint(ctx, 0, bounds.h);
    cocoa.CGContextAddLineToPoint(ctx, bounds.w, bounds.h);
    cocoa.CGContextDrawPath(ctx, 2);

    const state = global_ui_state orelse return;

    // Status text on left
    cocoa.drawStringWithColor(state.status_text, 18, bounds.h / 2.0 - 7.0, 0.85, 0.88, 0.92, 1.0);

    // Daemon status pill on right
    const pill_color = if (state.daemon_enabled)
        cocoa.makeCGColor(0x00E676, 0.9) // Active Green
    else
        cocoa.makeCGColor(0x5A6472, 0.7); // Idle Muted Gray
    defer cocoa.CGColorRelease(pill_color);

    cocoa.CGContextSetFillColorWithColor(ctx, pill_color);
    cocoa.CGContextFillEllipseInRect(ctx, cocoa.NSRect.init(bounds.w - 120, bounds.h / 2.0 - 4.0, 8, 8));
    cocoa.drawStringWithColor(state.daemon_status, bounds.w - 105, bounds.h / 2.0 - 7.0, 0.65, 0.70, 0.76, 1.0);
}

const workspace_names = [_][]const u8{
    "Super Finder",
    "Dedup Studio",
    "Quick-Wins Sweeper",
    "Baremetal Editor",
    "Machine Telemetry",
    "Spacetime Visualizer",
    "Time-Travel Snapshots",
    "Audit Journal",
};

fn drawWorkspacePlaceholder(ctx: cocoa.CGContextRef, bounds: cocoa.NSRect, tab: ActiveTab) void {
    const tab_index: usize = @intFromEnum(tab);
    const title = workspace_names[tab_index];
    const accent = cocoa.makeCGColor(0x00E5FF, 0.16);
    defer cocoa.CGColorRelease(accent);
    cocoa.CGContextSetFillColorWithColor(ctx, accent);
    cocoa.CGContextFillRect(ctx, cocoa.NSRect.init(24, bounds.h - 94, 3, 44));
    cocoa.drawStringWithColor(title, 42, bounds.h - 68, 0.91, 0.94, 0.98, 1.0);
    cocoa.drawStringWithColor("Planned workspace", 42, bounds.h - 100, 0.48, 0.54, 0.62, 1.0);
    cocoa.drawStringWithColor("This section is not available yet. No scan results or actions are implied.", 42, bounds.h - 122, 0.66, 0.70, 0.76, 1.0);
}

fn drawWorkspaceRailRect(self: cocoa.id, _: cocoa.SEL, dirty: cocoa.NSRect) callconv(.c) void {
    _ = dirty;
    const ctx = cocoa.getCurrentGraphicsContext() orelse return;
    cocoa.CGContextSaveGState(ctx);
    defer cocoa.CGContextRestoreGState(ctx);
    const bounds = cocoa.sendGetRect(self, sel_bounds);
    const background = cocoa.makeCGColor(0x0B0D12, 1.0);
    defer cocoa.CGColorRelease(background);
    cocoa.CGContextSetFillColorWithColor(ctx, background);
    cocoa.CGContextFillRect(ctx, bounds);
    cocoa.drawStringWithColor("WORKSPACES", 16, bounds.h - 30, 0.48, 0.54, 0.63, 1.0);
    const state = global_ui_state orelse return;
    for (workspace_names, 0..) |name, index| {
        const row_y = bounds.h - 92.0 - @as(f64, @floatFromInt(index)) * 56.0;
        const selected = @intFromEnum(state.active_tab) == index;
        if (selected) {
            const selected_bg = cocoa.makeCGColor(0x00E5FF, 0.10);
            defer cocoa.CGColorRelease(selected_bg);
            cocoa.CGContextSetFillColorWithColor(ctx, selected_bg);
            cocoa.CGContextFillRect(ctx, cocoa.NSRect.init(8, row_y, bounds.w - 16, 46));
            const marker = cocoa.makeCGColor(0x00E5FF, 1.0);
            defer cocoa.CGColorRelease(marker);
            cocoa.CGContextSetFillColorWithColor(ctx, marker);
            cocoa.CGContextFillRect(ctx, cocoa.NSRect.init(8, row_y, 2, 46));
        }
        cocoa.drawStringWithColor(name, 20, row_y + 17, if (selected) 0.91 else 0.65, if (selected) 0.94 else 0.69, if (selected) 0.98 else 0.75, 1.0);
    }
    const divider = cocoa.makeCGColor(0xFFFFFF, 0.08);
    defer cocoa.CGColorRelease(divider);
    cocoa.CGContextSetStrokeColorWithColor(ctx, divider);
    cocoa.CGContextSetLineWidth(ctx, 1.0);
    cocoa.CGContextBeginPath(ctx);
    cocoa.CGContextMoveToPoint(ctx, bounds.w - 0.5, 0);
    cocoa.CGContextAddLineToPoint(ctx, bounds.w - 0.5, bounds.h);
    cocoa.CGContextDrawPath(ctx, 2);
}

fn onWorkspaceRailMouseDown(self: cocoa.id, _: cocoa.SEL, event: cocoa.id) callconv(.c) void {
    const state = global_ui_state orelse return;
    const location = cocoa.sel_registerName("locationInWindow");
    const F_loc = *const fn (cocoa.id, cocoa.SEL) callconv(.c) cocoa.NSPoint;
    const window_point = @as(F_loc, @ptrCast(&cocoa.objc_msgSend))(event, location);
    const local = cocoa.sendConvertPointFromView(self, cocoa.sel_registerName("convertPoint:fromView:"), window_point, null);
    const row = @floor((cocoa.sendGetRect(self, sel_bounds).h - 48.0 - local.y) / 56.0);
    if (row < 0 or row >= workspace_names.len) return;
    state.active_tab = @enumFromInt(@as(u8, @intFromFloat(row)));
    requestRedraw();
}

// --- Class Registration Factory --------------------------------------------

pub fn registerViewSubclasses() void {
    ensureSelectors();
    const NSView = cocoa.objc_getClass("NSView");

    // 1. ZSpaceHeaderView
    if (cocoa.objc_getClass("ZSpaceHeaderView") == null) {
        const cls = cocoa.objc_allocateClassPair(NSView, "ZSpaceHeaderView", 0);
        _ = cocoa.class_addMethod(cls, sel_drawRect, @ptrCast(&drawHeaderRect), "v@:{CGRect=dddd}");
        _ = cocoa.class_addMethod(cls, sel_mouseDown, @ptrCast(&onHeaderMouseDown), "v@:@");
        cocoa.objc_registerClassPair(cls);
    }

    // 2. ZSpaceSunburstView
    if (cocoa.objc_getClass("ZSpaceSunburstView") == null) {
        const cls = cocoa.objc_allocateClassPair(NSView, "ZSpaceSunburstView", 0);
        _ = cocoa.class_addMethod(cls, sel_drawRect, @ptrCast(&drawSunburstRect), "v@:{CGRect=dddd}");
        _ = cocoa.class_addMethod(cls, sel_mouseDown, @ptrCast(&onSunburstMouseDown), "v@:@");
        cocoa.objc_registerClassPair(cls);
    }

    // 3. ZSpaceTreemapView
    if (cocoa.objc_getClass("ZSpaceTreemapView") == null) {
        const cls = cocoa.objc_allocateClassPair(NSView, "ZSpaceTreemapView", 0);
        _ = cocoa.class_addMethod(cls, sel_drawRect, @ptrCast(&drawTreemapRect), "v@:{CGRect=dddd}");
        _ = cocoa.class_addMethod(cls, sel_mouseDown, @ptrCast(&onTreemapMouseDown), "v@:@");
        cocoa.objc_registerClassPair(cls);
    }

    // 4. ZSpaceSidebarView
    if (cocoa.objc_getClass("ZSpaceSidebarView") == null) {
        const cls = cocoa.objc_allocateClassPair(NSView, "ZSpaceSidebarView", 0);
        _ = cocoa.class_addMethod(cls, sel_drawRect, @ptrCast(&drawSidebarRect), "v@:{CGRect=dddd}");
        _ = cocoa.class_addMethod(cls, sel_mouseDown, @ptrCast(&onSidebarMouseDown), "v@:@");
        cocoa.objc_registerClassPair(cls);
    }

    if (cocoa.objc_getClass("ZSpaceWorkspaceRailView") == null) {
        const cls = cocoa.objc_allocateClassPair(NSView, "ZSpaceWorkspaceRailView", 0);
        _ = cocoa.class_addMethod(cls, sel_drawRect, @ptrCast(&drawWorkspaceRailRect), "v@:{CGRect=dddd}");
        _ = cocoa.class_addMethod(cls, sel_mouseDown, @ptrCast(&onWorkspaceRailMouseDown), "v@:@");
        cocoa.objc_registerClassPair(cls);
    }

    // 5. ZSpaceStatusView
    if (cocoa.objc_getClass("ZSpaceStatusView") == null) {
        const cls = cocoa.objc_allocateClassPair(NSView, "ZSpaceStatusView", 0);
        _ = cocoa.class_addMethod(cls, sel_drawRect, @ptrCast(&drawStatusRect), "v@:{CGRect=dddd}");
        cocoa.objc_registerClassPair(cls);
    }
}
