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

pub const ActiveTab = enum { files, dupes, wins };

pub const UIState = struct {
    allocator: std.mem.Allocator,
    root_node: ?*const types.DiskNode = null,
    drill_node: ?*const types.DiskNode = null,
    active_tab: ActiveTab = .files,
    selected_indices: std.AutoHashMap(usize, bool),
    hovered_node: ?*const types.DiskNode = null,
    status_text: []const u8 = "Ready",
    daemon_enabled: bool = false,
    daemon_status: []const u8 = "OFF",
    command_input: [256]u8 = undefined,
    command_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) UIState {
        return .{
            .allocator = allocator,
            .selected_indices = std.AutoHashMap(usize, bool).init(allocator),
        };
    }

    pub fn deinit(self: *UIState) void {
        self.selected_indices.deinit();
    }
};

pub var global_ui_state: ?*UIState = null;

// --- Custom View Selectors & Types -----------------------------------------

var sel_drawRect: cocoa.SEL = null;
var sel_mouseDown: cocoa.SEL = null;
var sel_rightMouseDown: cocoa.SEL = null;
var sel_bounds: cocoa.SEL = null;
var sel_setNeedsDisplay: cocoa.SEL = null;

fn ensureSelectors() void {
    if (sel_drawRect != null) return;
    sel_drawRect = cocoa.sel_registerName("drawRect:");
    sel_mouseDown = cocoa.sel_registerName("mouseDown:");
    sel_rightMouseDown = cocoa.sel_registerName("rightMouseDown:");
    sel_bounds = cocoa.sel_registerName("bounds");
    sel_setNeedsDisplay = cocoa.sel_registerName("setNeedsDisplay:");
}

// --- 1. HeaderView: Brand Jewel & Status -----------------------------------

fn drawHeaderRect(_: cocoa.id, _: cocoa.SEL, dirty: cocoa.NSRect) callconv(.c) void {
    const ctx = cocoa.getCurrentGraphicsContext() orelse return;
    cocoa.CGContextSaveGState(ctx);
    defer cocoa.CGContextRestoreGState(ctx);

    // Deep Obsidian gradient background #08090D -> #101216
    const bg_color = cocoa.makeCGColor(0x08090D, 1.0);
    defer cocoa.CGColorRelease(bg_color);
    cocoa.CGContextSetFillColorWithColor(ctx, bg_color);
    cocoa.CGContextFillRect(ctx, dirty);

    // Hairline bottom divider rgba(255,255,255,0.08)
    const line_color = cocoa.makeCGColor(0xFFFFFF, 0.08);
    defer cocoa.CGColorRelease(line_color);
    cocoa.CGContextSetStrokeColorWithColor(ctx, line_color);
    cocoa.CGContextSetLineWidth(ctx, 1.0);
    cocoa.CGContextBeginPath(ctx);
    cocoa.CGContextMoveToPoint(ctx, 0, 0);
    cocoa.CGContextAddLineToPoint(ctx, dirty.w, 0);
    cocoa.CGContextDrawPath(ctx, 2); // stroke

    // Pulsing Status Jewel (Electric Aquamarine #00E5FF)
    const jewel_color = cocoa.makeCGColor(0x00E5FF, 0.95);
    defer cocoa.CGColorRelease(jewel_color);
    cocoa.CGContextSetFillColorWithColor(ctx, jewel_color);
    cocoa.CGContextFillEllipseInRect(ctx, cocoa.NSRect.init(18, dirty.h / 2.0 - 5.0, 10, 10));

    // Outer glow ring
    const glow_color = cocoa.makeCGColor(0x00E5FF, 0.25);
    defer cocoa.CGColorRelease(glow_color);
    cocoa.CGContextSetStrokeColorWithColor(ctx, glow_color);
    cocoa.CGContextSetLineWidth(ctx, 2.0);
    cocoa.CGContextStrokeEllipseInRect(ctx, cocoa.NSRect.init(15, dirty.h / 2.0 - 8.0, 16, 16));
}

// --- 2. SunburstView: Radial Spacetime Visualizer ---------------------------

fn drawSunburstRect(self: cocoa.id, _: cocoa.SEL, dirty: cocoa.NSRect) callconv(.c) void {
    const ctx = cocoa.getCurrentGraphicsContext() orelse return;
    cocoa.CGContextSaveGState(ctx);
    defer cocoa.CGContextRestoreGState(ctx);

    // Card background #0D0E12
    const bg_color = cocoa.makeCGColor(0x0D0E12, 1.0);
    defer cocoa.CGColorRelease(bg_color);
    cocoa.CGContextSetFillColorWithColor(ctx, bg_color);
    cocoa.CGContextFillRect(ctx, dirty);

    const bounds = cocoa.sendGetRect(self, sel_bounds);
    const center_x = bounds.w / 2.0;
    const center_y = bounds.h / 2.0;

    const state = global_ui_state orelse return;
    const node = state.drill_node orelse state.root_node orelse return;

    var layout = sunburst.SunburstLayout.init(state.allocator);
    layout.center_radius = 45.0;
    layout.ring_thickness = 28.0;

    var arcs = layout.generateLayout(node) catch return;
    defer arcs.deinit(state.allocator);

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
    const ctx = cocoa.getCurrentGraphicsContext() orelse return;
    cocoa.CGContextSaveGState(ctx);
    defer cocoa.CGContextRestoreGState(ctx);

    // Background #0B0C10
    const bg_color = cocoa.makeCGColor(0x0B0C10, 1.0);
    defer cocoa.CGColorRelease(bg_color);
    cocoa.CGContextSetFillColorWithColor(ctx, bg_color);
    cocoa.CGContextFillRect(ctx, dirty);

    const bounds = cocoa.sendGetRect(self, sel_bounds);
    const state = global_ui_state orelse return;
    const node = state.drill_node orelse state.root_node orelse return;

    var layout = treemap.TreemapLayout.init(state.allocator);
    var rects = layout.layout(node, 2.0, 2.0, @floatCast(bounds.w - 4.0), @floatCast(bounds.h - 4.0)) catch return;
    defer rects.deinit(state.allocator);

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

// --- 4. SidebarView: Custom Draw for Files / Dupes / Wins ------------------

fn drawSidebarRect(_: cocoa.id, _: cocoa.SEL, dirty: cocoa.NSRect) callconv(.c) void {
    const ctx = cocoa.getCurrentGraphicsContext() orelse return;
    cocoa.CGContextSaveGState(ctx);
    defer cocoa.CGContextRestoreGState(ctx);

    // Surface panel #101216
    const bg_color = cocoa.makeCGColor(0x101216, 1.0);
    defer cocoa.CGColorRelease(bg_color);
    cocoa.CGContextSetFillColorWithColor(ctx, bg_color);
    cocoa.CGContextFillRect(ctx, dirty);

    // Left border divider
    const line_color = cocoa.makeCGColor(0x282C37, 0.8);
    defer cocoa.CGColorRelease(line_color);
    cocoa.CGContextSetStrokeColorWithColor(ctx, line_color);
    cocoa.CGContextSetLineWidth(ctx, 1.0);
    cocoa.CGContextBeginPath(ctx);
    cocoa.CGContextMoveToPoint(ctx, 0, 0);
    cocoa.CGContextAddLineToPoint(ctx, 0, dirty.h);
    cocoa.CGContextDrawPath(ctx, 2);

    const state = global_ui_state orelse return;
    const node = state.drill_node orelse state.root_node orelse return;

    // Draw row items
    var y: f64 = dirty.h - 32.0;
    const row_height: f64 = 28.0;

    for (node.children.items, 0..) |child, idx| {
        if (y < 40.0) break; // keep footer space

        const is_selected = state.selected_indices.get(idx) orelse false;

        // Row highlight if selected
        if (is_selected) {
            const row_sel_color = cocoa.makeCGColor(0x00E5FF, 0.15);
            defer cocoa.CGColorRelease(row_sel_color);
            cocoa.CGContextSetFillColorWithColor(ctx, row_sel_color);
            cocoa.CGContextFillRect(ctx, cocoa.NSRect.init(4, y - 2, dirty.w - 8, row_height));
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

        y -= row_height;
    }
}

fn onSidebarMouseDown(self: cocoa.id, _: cocoa.SEL, event: cocoa.id) callconv(.c) void {
    const state = global_ui_state orelse return;
    const node = state.drill_node orelse state.root_node orelse return;

    // Get click coordinates
    const sel_location = cocoa.sel_registerName("locationInWindow");
    const F_loc = *const fn (cocoa.id, cocoa.SEL) callconv(.c) cocoa.NSPoint;
    const click_point = @as(F_loc, @ptrCast(&cocoa.objc_msgSend))(event, sel_location);

    const bounds = cocoa.sendGetRect(self, sel_bounds);
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

fn drawStatusRect(_: cocoa.id, _: cocoa.SEL, dirty: cocoa.NSRect) callconv(.c) void {
    const ctx = cocoa.getCurrentGraphicsContext() orelse return;
    cocoa.CGContextSaveGState(ctx);
    defer cocoa.CGContextRestoreGState(ctx);

    // Deep bar #08090D
    const bg_color = cocoa.makeCGColor(0x08090D, 1.0);
    defer cocoa.CGColorRelease(bg_color);
    cocoa.CGContextSetFillColorWithColor(ctx, bg_color);
    cocoa.CGContextFillRect(ctx, dirty);

    // Top hairline stroke
    const line_color = cocoa.makeCGColor(0x282C37, 0.7);
    defer cocoa.CGColorRelease(line_color);
    cocoa.CGContextSetStrokeColorWithColor(ctx, line_color);
    cocoa.CGContextSetLineWidth(ctx, 1.0);
    cocoa.CGContextBeginPath(ctx);
    cocoa.CGContextMoveToPoint(ctx, 0, dirty.h);
    cocoa.CGContextAddLineToPoint(ctx, dirty.w, dirty.h);
    cocoa.CGContextDrawPath(ctx, 2);

    const state = global_ui_state orelse return;

    // Daemon status pill on right
    const pill_color = if (state.daemon_enabled)
        cocoa.makeCGColor(0x00E676, 0.9) // Active Green
    else
        cocoa.makeCGColor(0x5A6472, 0.7); // Idle Muted Gray
    defer cocoa.CGColorRelease(pill_color);

    cocoa.CGContextSetFillColorWithColor(ctx, pill_color);
    cocoa.CGContextFillEllipseInRect(ctx, cocoa.NSRect.init(dirty.w - 120, dirty.h / 2.0 - 4.0, 8, 8));
}

// --- Class Registration Factory --------------------------------------------

pub fn registerViewSubclasses() void {
    ensureSelectors();
    const NSView = cocoa.objc_getClass("NSView");

    // 1. ZSpaceHeaderView
    if (cocoa.objc_getClass("ZSpaceHeaderView") == null) {
        const cls = cocoa.objc_allocateClassPair(NSView, "ZSpaceHeaderView", 0);
        _ = cocoa.class_addMethod(cls, sel_drawRect, @ptrCast(&drawHeaderRect), "v@:{CGRect=dddd}");
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
        cocoa.objc_registerClassPair(cls);
    }

    // 4. ZSpaceSidebarView
    if (cocoa.objc_getClass("ZSpaceSidebarView") == null) {
        const cls = cocoa.objc_allocateClassPair(NSView, "ZSpaceSidebarView", 0);
        _ = cocoa.class_addMethod(cls, sel_drawRect, @ptrCast(&drawSidebarRect), "v@:{CGRect=dddd}");
        _ = cocoa.class_addMethod(cls, sel_mouseDown, @ptrCast(&onSidebarMouseDown), "v@:@");
        cocoa.objc_registerClassPair(cls);
    }

    // 5. ZSpaceStatusView
    if (cocoa.objc_getClass("ZSpaceStatusView") == null) {
        const cls = cocoa.objc_allocateClassPair(NSView, "ZSpaceStatusView", 0);
        _ = cocoa.class_addMethod(cls, sel_drawRect, @ptrCast(&drawStatusRect), "v@:{CGRect=dddd}");
        cocoa.objc_registerClassPair(cls);
    }
}
