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
const dedup = @import("../core/dedup.zig");
const analyzer = @import("../core/analyzer.zig");
const apfs = @import("../core/apfs.zig");
const cleaner = @import("../core/cleaner.zig");
const snapshot = @import("../core/snapshot.zig");
const disks = @import("../core/disks.zig");

const c = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
});

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
    dedup_clusters: ?std.ArrayList(types.DuplicateCluster) = null,
    quick_wins: ?std.ArrayList(analyzer.SmartCleanItem) = null,
    dedup_scroll_y: f64 = 0.0,
    quick_wins_scroll_y: f64 = 0.0,
    baremetal_scroll_y: f64 = 0.0,
    snapshots_scroll_y: f64 = 0.0,
    journal_scroll_y: f64 = 0.0,
    journal_records: ?std.ArrayList(types.CleanOperation) = null,
    snapshot_status: []const u8 = "Ready",

    pub fn init(allocator: std.mem.Allocator) UIState {
        return .{
            .allocator = allocator,
            .selected_indices = std.AutoHashMap(usize, bool).init(allocator),
        };
    }

    pub fn deinit(self: *UIState) void {
        self.selected_indices.deinit();
        self.clearDedup();
        self.clearQuickWins();
        self.clearJournal();
    }

    pub fn clearDedup(self: *UIState) void {
        if (self.dedup_clusters) |*dc| {
            for (dc.items) |*c_item| {
                c_item.items.deinit(self.allocator);
            }
            dc.deinit(self.allocator);
            self.dedup_clusters = null;
        }
    }

    pub fn clearQuickWins(self: *UIState) void {
        if (self.quick_wins) |*qw| {
            qw.deinit(self.allocator);
            self.quick_wins = null;
        }
    }

    pub fn clearJournal(self: *UIState) void {
        if (self.journal_records) |*jr| {
            for (jr.items) |op| {
                self.allocator.free(op.original_path);
                self.allocator.free(op.trash_path);
                if (op.receipt_id.len > 0) self.allocator.free(op.receipt_id);
            }
            jr.deinit(self.allocator);
            self.journal_records = null;
        }
    }

    pub fn refreshDedup(self: *UIState) void {
        const root = self.root_node orelse return;
        self.clearDedup();
        var engine = dedup.DedupEngine.init(self.allocator);
        self.dedup_clusters = engine.findDuplicates(root) catch null;
    }

    pub fn refreshQuickWins(self: *UIState) void {
        const root = self.root_node orelse return;
        self.clearQuickWins();
        var an = analyzer.Analyzer.init(self.allocator);
        self.quick_wins = an.generateSmartCleanRecommendations(root) catch null;
    }

    pub fn refreshJournal(self: *UIState) void {
        self.clearJournal();
        var cl = cleaner.Cleaner.init(self.allocator) catch return;
        defer cl.deinit();

        var list: std.ArrayList(types.CleanOperation) = .{ .items = &.{}, .capacity = 0 };
        for (cl.journal.items) |op| {
            const o_orig = self.allocator.dupe(u8, op.original_path) catch continue;
            const o_trash = self.allocator.dupe(u8, op.trash_path) catch continue;
            const o_rid = if (op.receipt_id.len > 0) (self.allocator.dupe(u8, op.receipt_id) catch continue) else &.{};
            list.append(self.allocator, .{
                .original_path = o_orig,
                .trash_path = o_trash,
                .size_bytes = op.size_bytes,
                .timestamp_ns = op.timestamp_ns,
                .verified_hash = op.verified_hash,
                .blake3 = op.blake3,
                .receipt_id = o_rid,
                .method = op.method,
            }) catch continue;
        }
        self.journal_records = list;
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
        self.dedup_scroll_y = 0.0;
        self.quick_wins_scroll_y = 0.0;
        self.baremetal_scroll_y = 0.0;
        self.snapshots_scroll_y = 0.0;
        self.journal_scroll_y = 0.0;
        self.selected_indices.clearRetainingCapacity();
        self.clearDedup();
        self.clearQuickWins();
        self.clearJournal();
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

// --- 2. Main Stage: Super Finder, Spacetime Visualizer & Workspaces ---------

fn drawSuperFinder(ctx: cocoa.CGContextRef, bounds: cocoa.NSRect, state: *UIState) void {
    const node_opt = state.drill_node orelse state.root_node;
    if (node_opt == null or state.scan_state == .idle) {
        if (state.scan_state == .idle) {
            const center_x = bounds.w / 2.0;
            // Hero Title
            cocoa.drawStringWithColor("SUPER FINDER  —  DEVELOPER DISK EXPLORER", center_x - 170, bounds.h - 40, 0.0, 0.90, 1.0, 1.0);
            cocoa.drawStringWithColor("Select a target directory below or press [ ▶ SCAN TARGET ] above to begin.", center_x - 240, bounds.h - 65, 0.55, 0.60, 0.68, 1.0);

            // Volume Telemetry Card
            const card_w: f64 = @min(660.0, bounds.w - 40.0);
            const card_h: f64 = 96.0;
            const card_x: f64 = (bounds.w - card_w) / 2.0;
            const card_y: f64 = bounds.h - 180.0;
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

            cocoa.drawStringWithColor("PRIMARY VOLUME TELEMETRY: Macintosh HD (APFS)", card_x + 20, card_y + 68, 0.90, 0.93, 0.96, 1.0);

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

            // Presets Header & Cards
            const p_y = bounds.h - 225.0;
            cocoa.drawStringWithColor("QUICK TARGET PRESETS  —  Select location to inspect:", 36, p_y, 0.85, 0.88, 0.94, 1.0);
            renderPresetsGrid(ctx, bounds, state, p_y - 20.0);
        } else if (state.scan_state == .scanning) {
            cocoa.drawStringWithColor("Scanning and indexing directory in background...", bounds.w / 2.0 - 150, bounds.h / 2.0, 0.0, 0.90, 1.0, 1.0);
        } else {
            cocoa.drawStringWithColor("Directory is empty or inaccessible.", bounds.w / 2.0 - 100, bounds.h / 2.0, 0.55, 0.60, 0.68, 1.0);
        }
        return;
    }

    const node = node_opt.?;

    // Sort items according to active sort settings
    sortDiskNodes(node.children.items, state.sort_col, state.sort_dir);

    // 1. Breadcrumb Navigation Bar (Top 36px: bounds.h - 36 to bounds.h)
    const crumb_bar_h: f64 = 36.0;
    const crumb_bar_y: f64 = bounds.h - crumb_bar_h;
    const crumb_bg = cocoa.makeCGColor(0x11141B, 1.0);
    defer cocoa.CGColorRelease(crumb_bg);
    cocoa.CGContextSetFillColorWithColor(ctx, crumb_bg);
    cocoa.CGContextFillRect(ctx, cocoa.NSRect.init(0, crumb_bar_y, bounds.w, crumb_bar_h));

    // Hairline divider
    const div_color = cocoa.makeCGColor(0x282C37, 0.8);
    defer cocoa.CGColorRelease(div_color);
    cocoa.CGContextSetStrokeColorWithColor(ctx, div_color);
    cocoa.CGContextSetLineWidth(ctx, 1.0);
    cocoa.CGContextBeginPath(ctx);
    cocoa.CGContextMoveToPoint(ctx, 0, crumb_bar_y);
    cocoa.CGContextAddLineToPoint(ctx, bounds.w, crumb_bar_y);
    cocoa.CGContextDrawPath(ctx, 2);

    var cur_crumb_x: f64 = 16.0;
    if (state.drill_node != null) {
        // [ ⮌ BACK ] button
        const back_w: f64 = 66.0;
        const back_h: f64 = 24.0;
        const back_y = crumb_bar_y + 6.0;
        const back_rect = cocoa.NSRect.init(cur_crumb_x, back_y, back_w, back_h);

        const b_bg = cocoa.makeCGColor(0x1B2230, 0.95);
        defer cocoa.CGColorRelease(b_bg);
        cocoa.CGContextSetFillColorWithColor(ctx, b_bg);
        cocoa.CGContextFillRect(ctx, back_rect);

        const b_border = cocoa.makeCGColor(0x00E5FF, 0.6);
        defer cocoa.CGColorRelease(b_border);
        cocoa.CGContextSetStrokeColorWithColor(ctx, b_border);
        cocoa.CGContextSetLineWidth(ctx, 1.0);
        cocoa.CGContextStrokeRect(ctx, back_rect);

        cocoa.drawStringWithColor("⮌ BACK", cur_crumb_x + 12, back_y + 6, 0.0, 0.90, 1.0, 1.0);
        cur_crumb_x += back_w + 14.0;
    }

    // Path segments
    var path_slice = node.path;
    if (path_slice.len > 55) {
        path_slice = path_slice[path_slice.len - 55 ..];
    }
    cocoa.drawStringWithColor(path_slice, cur_crumb_x, crumb_bar_y + 11, 0.90, 0.93, 0.96, 1.0);

    // Summary item counts on right
    var summary_buf: [64]u8 = undefined;
    var sz_b: [32]u8 = undefined;
    const sz_str = types.DiskNode.formatSize(node.size_bytes, &sz_b);
    const sum_str = std.fmt.bufPrint(&summary_buf, "{d} items • {s}", .{ node.children.items.len, sz_str }) catch "";
    cocoa.drawStringWithColor(sum_str, bounds.w - 175.0, crumb_bar_y + 11, 0.0, 0.90, 1.0, 1.0);

    // 2. Column Headers Bar (Height 28px: bounds.h - 64 to bounds.h - 36)
    const header_h: f64 = 28.0;
    const header_y: f64 = crumb_bar_y - header_h;
    const h_bg = cocoa.makeCGColor(0x141822, 1.0);
    defer cocoa.CGColorRelease(h_bg);
    cocoa.CGContextSetFillColorWithColor(ctx, h_bg);
    cocoa.CGContextFillRect(ctx, cocoa.NSRect.init(0, header_y, bounds.w, header_h));

    // Column positions
    const fixed_right: f64 = 520.0;
    const name_w: f64 = @max(160.0, bounds.w - 36.0 - fixed_right);
    const name_x: f64 = 36.0;
    const size_x: f64 = name_x + name_w;
    const blocks_x: f64 = size_x + 100.0;
    const cat_x: f64 = blocks_x + 110.0;
    const mod_x: f64 = cat_x + 130.0;
    const perms_x: f64 = mod_x + 110.0;
    _ = perms_x;

    // Header labels with sort arrows
    const name_lbl = if (state.sort_col == .name) (if (state.sort_dir == .ascending) "▲ NAME" else "▼ NAME") else "NAME";
    const size_lbl = if (state.sort_col == .size) (if (state.sort_dir == .ascending) "▲ SIZE" else "▼ SIZE") else "SIZE";
    const blocks_lbl = if (state.sort_col == .blocks) (if (state.sort_dir == .ascending) "▲ BLOCKS" else "▼ BLOCKS") else "BLOCKS (APFS)";
    const cat_lbl = if (state.sort_col == .category) (if (state.sort_dir == .ascending) "▲ CATEGORY" else "▼ CATEGORY") else "CATEGORY";
    const mod_lbl = if (state.sort_col == .modified) (if (state.sort_dir == .ascending) "▲ MODIFIED" else "▼ MODIFIED") else "MODIFIED";

    cocoa.drawStringWithColor(name_lbl, name_x, header_y + 8, 0.70, 0.75, 0.82, 1.0);
    cocoa.drawStringWithColor(size_lbl, size_x, header_y + 8, 0.70, 0.75, 0.82, 1.0);
    cocoa.drawStringWithColor(blocks_lbl, blocks_x, header_y + 8, 0.70, 0.75, 0.82, 1.0);
    cocoa.drawStringWithColor(cat_lbl, cat_x, header_y + 8, 0.70, 0.75, 0.82, 1.0);
    cocoa.drawStringWithColor(mod_lbl, mod_x, header_y + 8, 0.70, 0.75, 0.82, 1.0);

    // 3. Virtualized Table Rows
    const table_top: f64 = header_y;
    const table_h: f64 = table_top;
    const row_h: f64 = 28.0;
    const total_rows: usize = node.children.items.len;
    const total_content_h: f64 = @as(f64, @floatFromInt(total_rows)) * row_h;
    const max_scroll: f64 = @max(0.0, total_content_h - table_h);

    if (state.scroll_offset_y > max_scroll) state.scroll_offset_y = max_scroll;
    if (state.scroll_offset_y < 0.0) state.scroll_offset_y = 0.0;

    const start_row: usize = @as(usize, @intFromFloat(@floor(state.scroll_offset_y / row_h)));
    const visible_count: usize = @as(usize, @intFromFloat(@ceil(table_h / row_h))) + 2;
    const end_row: usize = @min(total_rows, start_row + visible_count);

    const now_ns = types.getRealtimeNs();

    if (total_rows == 0) {
        cocoa.drawStringWithColor("Folder is empty (0 items)", bounds.w / 2.0 - 90.0, table_h / 2.0, 0.45, 0.50, 0.60, 1.0);
    }

    var r_idx = start_row;
    while (r_idx < end_row) : (r_idx += 1) {
        const child = node.children.items[r_idx];
        const row_y = table_top - (@as(f64, @floatFromInt(r_idx)) * row_h - state.scroll_offset_y) - row_h;
        if (row_y + row_h <= 0.0 or row_y >= table_top) continue;

        const is_selected = (state.selected_node == child);

        // Row background
        if (is_selected) {
            const sel_bg = cocoa.makeCGColor(0x00E5FF, 0.16);
            defer cocoa.CGColorRelease(sel_bg);
            cocoa.CGContextSetFillColorWithColor(ctx, sel_bg);
            cocoa.CGContextFillRect(ctx, cocoa.NSRect.init(4, row_y + 1, bounds.w - 8, row_h - 2));

            const sel_marker = cocoa.makeCGColor(0x00E5FF, 1.0);
            defer cocoa.CGColorRelease(sel_marker);
            cocoa.CGContextSetFillColorWithColor(ctx, sel_marker);
            cocoa.CGContextFillRect(ctx, cocoa.NSRect.init(4, row_y + 1, 3, row_h - 2));
        } else if (r_idx % 2 == 1) {
            const alt_bg = cocoa.makeCGColor(0xFFFFFF, 0.02);
            defer cocoa.CGColorRelease(alt_bg);
            cocoa.CGContextSetFillColorWithColor(ctx, alt_bg);
            cocoa.CGContextFillRect(ctx, cocoa.NSRect.init(4, row_y + 1, bounds.w - 8, row_h - 2));
        }

        // Checkbox (Collector Basket toggle)
        const is_checked = state.selected_indices.get(r_idx) orelse false;
        const box_rect = cocoa.NSRect.init(10, row_y + 7, 14, 14);
        const box_border = cocoa.makeCGColor(0x00E5FF, if (is_checked) 1.0 else 0.4);
        defer cocoa.CGColorRelease(box_border);
        cocoa.CGContextSetStrokeColorWithColor(ctx, box_border);
        cocoa.CGContextSetLineWidth(ctx, 1.0);
        cocoa.CGContextStrokeRect(ctx, box_rect);

        if (is_checked) {
            const check_fill = cocoa.makeCGColor(0x00E5FF, 0.95);
            defer cocoa.CGColorRelease(check_fill);
            cocoa.CGContextSetFillColorWithColor(ctx, check_fill);
            cocoa.CGContextFillRect(ctx, cocoa.NSRect.init(13, row_y + 10, 8, 8));
        }

        // Category dot
        const dot_color = cocoa.makeCGColor(child.category.colorHex(), 0.95);
        defer cocoa.CGColorRelease(dot_color);
        cocoa.CGContextSetFillColorWithColor(ctx, dot_color);
        cocoa.CGContextFillEllipseInRect(ctx, cocoa.NSRect.init(34, row_y + 10, 8, 8));

        // Name
        var name_buf: [128]u8 = undefined;
        const is_dir = child.isDirectory();
        const prefix: []const u8 = if (is_dir) "📁 " else "  ";
        const max_name_chars: usize = @intFromFloat(@max(10.0, (name_w - 30.0) / 8.0));
        const child_name = if (child.name.len > max_name_chars) child.name[0..max_name_chars] else child.name;
        const disp_name = std.fmt.bufPrint(&name_buf, "{s}{s}", .{ prefix, child_name }) catch child.name;

        if (is_dir) {
            cocoa.drawStringWithColor(disp_name, 48, row_y + 7, 0.95, 0.96, 0.99, 1.0);
        } else {
            cocoa.drawStringWithColor(disp_name, 48, row_y + 7, 0.82, 0.86, 0.92, 1.0);
        }

        // Logical Size
        var row_sz_b: [32]u8 = undefined;
        const row_sz = types.DiskNode.formatSize(child.size_bytes, &row_sz_b);
        if (child.size_bytes > 1_000_000_000) {
            cocoa.drawStringWithColor(row_sz, size_x, row_y + 7, 0.88, 0.25, 0.98, 1.0); // Purple
        } else if (child.size_bytes > 100_000_000) {
            cocoa.drawStringWithColor(row_sz, size_x, row_y + 7, 1.0, 0.43, 0.25, 1.0); // Coral
        } else {
            cocoa.drawStringWithColor(row_sz, size_x, row_y + 7, 0.0, 0.90, 1.0, 1.0); // Cyan
        }

        // Physical Blocks (APFS CoW indicator)
        var blk_b: [32]u8 = undefined;
        const blk_str = types.DiskNode.formatSize(child.allocated_bytes, &blk_b);
        if (child.allocated_bytes < child.size_bytes and child.size_bytes > 4096) {
            var cow_b: [48]u8 = undefined;
            const cow_s = std.fmt.bufPrint(&cow_b, "{s} [CoW]", .{blk_str}) catch blk_str;
            cocoa.drawStringWithColor(cow_s, blocks_x, row_y + 7, 0.0, 0.90, 0.46, 1.0); // Emerald Green
        } else {
            cocoa.drawStringWithColor(blk_str, blocks_x, row_y + 7, 0.55, 0.60, 0.68, 1.0);
        }

        // Category Tag
        cocoa.drawStringWithColor(child.category.displayName(), cat_x, row_y + 7, 0.70, 0.74, 0.80, 1.0);

        // Modified Relative Date
        const entropy = types.TemporalEntropy.calculate(child.mtime_ns, now_ns);
        var age_b: [32]u8 = undefined;
        const age_str = if (entropy.days_old < 1.0)
            "< 24h ago"
        else if (entropy.days_old < 30.0)
            std.fmt.bufPrint(&age_b, "{d:.0}d ago", .{entropy.days_old}) catch "recent"
        else if (entropy.days_old < 365.0)
            std.fmt.bufPrint(&age_b, "{d:.0}mo ago", .{entropy.days_old / 30.0}) catch "stale"
        else
            std.fmt.bufPrint(&age_b, "{d:.1}y ago", .{entropy.days_old / 365.0}) catch "iceberg";
        cocoa.drawStringWithColor(age_str, mod_x, row_y + 7, 0.55, 0.60, 0.68, 1.0);

        // Row hairline divider
        cocoa.CGContextBeginPath(ctx);
        cocoa.CGContextMoveToPoint(ctx, 4, row_y);
        cocoa.CGContextAddLineToPoint(ctx, bounds.w - 4, row_y);
        cocoa.CGContextDrawPath(ctx, 2);
    }

    // Scrollbar Thumb
    if (total_content_h > table_h) {
        const thumb_h = @max(24.0, (table_h / total_content_h) * table_h);
        const thumb_y = table_top - (state.scroll_offset_y / max_scroll) * (table_h - thumb_h) - thumb_h;
        const thumb_color = cocoa.makeCGColor(0x00E5FF, 0.45);
        defer cocoa.CGColorRelease(thumb_color);
        cocoa.CGContextSetFillColorWithColor(ctx, thumb_color);
        cocoa.CGContextFillRect(ctx, cocoa.NSRect.init(bounds.w - 5, thumb_y, 3, thumb_h));
    }
}

fn onSuperFinderMouseDown(self: cocoa.id, click_point: cocoa.NSPoint, bounds: cocoa.NSRect, state: *UIState, event: cocoa.id) void {
    if (state.scan_state == .idle) {
        handlePresetsClick(click_point, bounds, state, bounds.h - 245.0);
        return;
    }
    const node = state.drill_node orelse state.root_node orelse return;

    // 1. Breadcrumb bar clicks (Top 36px)
    const crumb_bar_h: f64 = 36.0;
    const crumb_bar_y: f64 = bounds.h - crumb_bar_h;
    if (click_point.y >= crumb_bar_y and click_point.y <= bounds.h) {
        if (state.drill_node != null and click_point.x >= 16.0 and click_point.x <= 82.0) {
            // [ ⮌ BACK ] button clicked
            state.drill_node = state.drill_node.?.parent;
            state.selected_node = state.drill_node;
            state.scroll_offset_y = 0.0;
            cocoa.sendVoidBool(self, sel_setNeedsDisplay, true);
            requestRedraw();
            return;
        }
        return;
    }

    // 2. Column Headers Bar clicks (Sort toggles)
    const header_h: f64 = 28.0;
    const header_y: f64 = crumb_bar_y - header_h;
    if (click_point.y >= header_y and click_point.y < crumb_bar_y) {
        const fixed_right: f64 = 520.0;
        const name_w: f64 = @max(160.0, bounds.w - 36.0 - fixed_right);
        const name_x: f64 = 36.0;
        const size_x: f64 = name_x + name_w;
        const blocks_x: f64 = size_x + 100.0;
        const cat_x: f64 = blocks_x + 110.0;
        const mod_x: f64 = cat_x + 130.0;

        if (click_point.x >= name_x and click_point.x < size_x) {
            if (state.sort_col == .name) state.sort_dir = if (state.sort_dir == .ascending) .descending else .ascending else {
                state.sort_col = .name;
                state.sort_dir = .ascending;
            }
        } else if (click_point.x >= size_x and click_point.x < blocks_x) {
            if (state.sort_col == .size) state.sort_dir = if (state.sort_dir == .ascending) .descending else .ascending else {
                state.sort_col = .size;
                state.sort_dir = .descending;
            }
        } else if (click_point.x >= blocks_x and click_point.x < cat_x) {
            if (state.sort_col == .blocks) state.sort_dir = if (state.sort_dir == .ascending) .descending else .ascending else {
                state.sort_col = .blocks;
                state.sort_dir = .descending;
            }
        } else if (click_point.x >= cat_x and click_point.x < mod_x) {
            if (state.sort_col == .category) state.sort_dir = if (state.sort_dir == .ascending) .descending else .ascending else {
                state.sort_col = .category;
                state.sort_dir = .ascending;
            }
        } else if (click_point.x >= mod_x) {
            if (state.sort_col == .modified) state.sort_dir = if (state.sort_dir == .ascending) .descending else .ascending else {
                state.sort_col = .modified;
                state.sort_dir = .descending;
            }
        }
        sortDiskNodes(node.children.items, state.sort_col, state.sort_dir);
        cocoa.sendVoidBool(self, sel_setNeedsDisplay, true);
        return;
    }

    // 3. Table Rows clicks
    if (click_point.y < header_y) {
        const row_h: f64 = 28.0;
        const rel_y = header_y - click_point.y + state.scroll_offset_y;
        if (rel_y < 0.0) return;
        const idx = @as(usize, @intFromFloat(@floor(rel_y / row_h)));
        if (idx < node.children.items.len) {
            const child = node.children.items[idx];
            if (click_point.x <= 30.0) {
                // Checkbox clicked
                const cur = state.selected_indices.get(idx) orelse false;
                state.selected_indices.put(idx, !cur) catch return;
            } else {
                // Row clicked
                const click_count = cocoa.sendGetInt0(event, cocoa.sel_registerName("clickCount"));
                if (child.isDirectory()) {
                    if (click_count >= 2 or state.selected_node == child) {
                        // Double-click or second click drills into folder
                        state.drill_node = child;
                        state.selected_node = child;
                        state.scroll_offset_y = 0.0;
                    } else {
                        // Single-click selects folder to inspect in sidebar
                        state.selected_node = child;
                    }
                } else {
                    // File clicked: selects file to inspect in sidebar
                    state.selected_node = child;
                }
            }
            cocoa.sendVoidBool(self, sel_setNeedsDisplay, true);
            requestRedraw();
        }
    }
}

// --- 3. Spacetime Visualizer (Workspace 6) ----------------------------------

fn drawSpacetimeVisualizer(ctx: cocoa.CGContextRef, bounds: cocoa.NSRect, state: *UIState) void {
    const node_opt = state.drill_node orelse state.root_node;
    if (node_opt == null or state.scan_state == .idle) {
        cocoa.drawStringWithColor("Run disk analysis to view radial spacetime and treemap geometry.", bounds.w / 2.0 - 200, bounds.h / 2.0, 0.55, 0.60, 0.68, 1.0);
        return;
    }
    const node = node_opt.?;

    // Top half: Sunburst
    const sun_bounds = cocoa.NSRect.init(0, bounds.h * 0.45, bounds.w, bounds.h * 0.55);
    const center_x = sun_bounds.w / 2.0;
    const center_y = sun_bounds.y + sun_bounds.h / 2.0;

    var layout = sunburst.SunburstLayout.init(state.allocator);
    layout.center_radius = 40.0;
    layout.ring_thickness = 26.0;

    var arcs = layout.generateLayout(node) catch return;
    defer arcs.deinit(state.allocator);

    for (arcs.items) |arc| {
        cocoa.CGContextBeginPath(ctx);
        cocoa.CGContextAddArc(ctx, center_x, center_y, arc.outer_radius, arc.start_angle_rad, arc.end_angle_rad, 0);
        cocoa.CGContextAddArc(ctx, center_x, center_y, arc.inner_radius, arc.end_angle_rad, arc.start_angle_rad, 1);
        cocoa.CGContextClosePath(ctx);

        const arc_color = cocoa.makeCGColor(arc.color, if (arc.depth == 0) 0.85 else 0.75);
        defer cocoa.CGColorRelease(arc_color);
        cocoa.CGContextSetFillColorWithColor(ctx, arc_color);
        cocoa.CGContextDrawPath(ctx, 0);
    }

    // Bottom half: Treemap
    const tree_h = bounds.h * 0.45 - 10.0;
    var t_layout = treemap.TreemapLayout.init(state.allocator);
    var rects = t_layout.layout(node, 4.0, 4.0, @floatCast(bounds.w - 8.0), @floatCast(tree_h)) catch return;
    defer rects.deinit(state.allocator);

    for (rects.items) |r| {
        const rect = cocoa.NSRect.init(r.x, r.y, r.w, r.h);
        const fill_col = cocoa.makeCGColor(r.color, 0.70);
        defer cocoa.CGColorRelease(fill_col);
        cocoa.CGContextSetFillColorWithColor(ctx, fill_col);
        cocoa.CGContextFillRect(ctx, rect);

        const border_col = cocoa.makeCGColor(0x181B22, 0.95);
        defer cocoa.CGColorRelease(border_col);
        cocoa.CGContextSetStrokeColorWithColor(ctx, border_col);
        cocoa.CGContextSetLineWidth(ctx, 1.0);
        cocoa.CGContextStrokeRect(ctx, rect);
    }
}

fn onSpacetimeMouseDown(self: cocoa.id, click_point: cocoa.NSPoint, bounds: cocoa.NSRect, state: *UIState) void {
    _ = bounds;
    _ = click_point;
    if (state.drill_node != null) {
        state.drill_node = null;
    } else if (state.root_node) |r| {
        if (r.children.items.len > 0) state.drill_node = r.children.items[0];
    }
    cocoa.sendVoidBool(self, sel_setNeedsDisplay, true);
    requestRedraw();
}

// --- Dedup Studio (Workspace 2) --------------------------------------------

fn drawDedupStudio(ctx: cocoa.CGContextRef, bounds: cocoa.NSRect, state: *UIState) void {
    if (state.scan_state == .idle or state.root_node == null) {
        cocoa.drawStringWithColor("Run disk analysis to identify duplicate clusters and APFS CoW savings.", bounds.w / 2.0 - 220.0, bounds.h / 2.0, 0.55, 0.60, 0.68, 1.0);
        return;
    }

    if (state.dedup_clusters == null) {
        state.refreshDedup();
    }

    const clusters_opt = state.dedup_clusters;
    if (clusters_opt == null or clusters_opt.?.items.len == 0) {
        cocoa.drawStringWithColor("✓ Zero duplicate clusters found! All analyzed objects are unique.", bounds.w / 2.0 - 200.0, bounds.h / 2.0, 0.0, 0.90, 0.46, 1.0);
        return;
    }

    const clusters = clusters_opt.?.items;

    // 1. Top Action & Metrics Bar (Height 44px)
    const top_bar_h: f64 = 44.0;
    const top_bar_y: f64 = bounds.h - top_bar_h;
    const bar_bg = cocoa.makeCGColor(0x10131B, 1.0);
    defer cocoa.CGColorRelease(bar_bg);
    cocoa.CGContextSetFillColorWithColor(ctx, bar_bg);
    cocoa.CGContextFillRect(ctx, cocoa.NSRect.init(0, top_bar_y, bounds.w, top_bar_h));

    var total_wasted: u64 = 0;
    var total_dups: usize = 0;
    for (clusters) |cluster| {
        total_wasted += cluster.total_wasted_bytes;
        total_dups += cluster.items.items.len;
    }
    var wst_buf: [32]u8 = undefined;
    const wst_str = types.DiskNode.formatSize(total_wasted, &wst_buf);

    var metric_buf: [128]u8 = undefined;
    const metric_str = std.fmt.bufPrint(&metric_buf, "DEDUP STUDIO  •  {d} Clusters ({d} files)  •  Wasted: {s}", .{ clusters.len, total_dups, wst_str }) catch "";
    cocoa.drawStringWithColor(metric_str, 20.0, top_bar_y + 14.0, 0.0, 0.90, 1.0, 1.0);

    // Button: Clone-All to APFS CoW
    const btn_w: f64 = 180.0;
    const btn_h: f64 = 30.0;
    const btn_x = bounds.w - btn_w - 20.0;
    const btn_y = top_bar_y + 7.0;
    renderButton(ctx, cocoa.NSRect.init(btn_x, btn_y, btn_w, btn_h), "⚡  CLONE-ALL COWs", 0x14202C, 0x00E5FF);

    // 2. Render Virtualized Clusters
    const list_top: f64 = top_bar_y;

    var cur_y: f64 = list_top + state.dedup_scroll_y;
    for (clusters) |cluster| {
        const c_card_h: f64 = 34.0 + @as(f64, @floatFromInt(cluster.items.items.len)) * 32.0 + 8.0;
        const card_top = cur_y;
        cur_y -= c_card_h + 12.0;

        if (card_top - c_card_h > list_top or card_top < 0.0) continue;

        const card_rect = cocoa.NSRect.init(20.0, card_top - c_card_h, bounds.w - 40.0, c_card_h);
        renderCardBg(ctx, card_rect);

        // Cluster header
        var sz_b: [32]u8 = undefined;
        const sz_s = types.DiskNode.formatSize(cluster.size_each, &sz_b);
        var cw_b: [32]u8 = undefined;
        const cw_s = types.DiskNode.formatSize(cluster.total_wasted_bytes, &cw_b);

        var hex_b: [12]u8 = undefined;
        const hex_prefix = std.fmt.bufPrint(&hex_b, "{x:0>8}", .{@as(u32, @truncate(cluster.hash))}) catch "hash";

        var c_hdr_buf: [128]u8 = undefined;
        const c_hdr = std.fmt.bufPrint(&c_hdr_buf, "Cluster #{s}  •  {s} each  •  {d} copies  •  Wasted: {s}", .{ hex_prefix, sz_s, cluster.items.items.len, cw_s }) catch "";
        cocoa.drawStringWithColor(c_hdr, 34.0, card_top - 24.0, 0.0, 0.90, 1.0, 1.0);

        // Items inside cluster
        for (cluster.items.items, 0..) |it, it_idx| {
            const row_y = card_top - 34.0 - @as(f64, @floatFromInt(it_idx + 1)) * 32.0;
            const is_orig = (it_idx == 0);

            // Badge
            if (is_orig) {
                const orig_badge = cocoa.makeCGColor(0x00E676, 0.2);
                defer cocoa.CGColorRelease(orig_badge);
                cocoa.CGContextSetFillColorWithColor(ctx, orig_badge);
                cocoa.CGContextFillRect(ctx, cocoa.NSRect.init(34.0, row_y + 4.0, 85.0, 20.0));
                cocoa.drawStringWithColor("★ ORIGINAL", 40.0, row_y + 7.0, 0.0, 0.90, 0.46, 1.0);
            } else {
                const dup_badge = cocoa.makeCGColor(0x00E5FF, 0.15);
                defer cocoa.CGColorRelease(dup_badge);
                cocoa.CGContextSetFillColorWithColor(ctx, dup_badge);
                cocoa.CGContextFillRect(ctx, cocoa.NSRect.init(34.0, row_y + 4.0, 85.0, 20.0));
                cocoa.drawStringWithColor("DUPLICATE", 44.0, row_y + 7.0, 0.0, 0.90, 1.0, 1.0);

                // Action buttons on right for duplicates
                const rcl_w: f64 = 110.0;
                const rcl_x = bounds.w - 40.0 - rcl_w - 90.0;
                renderButton(ctx, cocoa.NSRect.init(rcl_x, row_y + 3.0, rcl_w, 24.0), "⚡ CoW Clone", 0x14202C, 0x00E5FF);

                const trsh_x = bounds.w - 40.0 - 80.0;
                renderButton(ctx, cocoa.NSRect.init(trsh_x, row_y + 3.0, 70.0, 24.0), "🗑 Trash", 0x221313, 0xFF3D00);
            }

            // Path
            const max_p_chars: usize = @intFromFloat(@max(10.0, (bounds.w - 360.0) / 8.0));
            const it_path = if (it.path.len > max_p_chars) it.path[0..max_p_chars] else it.path;
            cocoa.drawStringWithColor(it_path, 130.0, row_y + 7.0, 0.82, 0.86, 0.92, 1.0);
        }
    }
}

fn onDedupStudioMouseDown(self: cocoa.id, click_point: cocoa.NSPoint, bounds: cocoa.NSRect, state: *UIState) void {
    const clusters_opt = state.dedup_clusters orelse return;
    const top_bar_h: f64 = 44.0;
    const top_bar_y: f64 = bounds.h - top_bar_h;

    // Check "CLONE-ALL COWs" button click
    const btn_w: f64 = 180.0;
    const btn_h: f64 = 30.0;
    const btn_x = bounds.w - btn_w - 20.0;
    const btn_y = top_bar_y + 7.0;
    if (click_point.x >= btn_x and click_point.x <= btn_x + btn_w and
        click_point.y >= btn_y and click_point.y <= btn_y + btn_h)
    {
        var clones_done: usize = 0;
        var bytes_saved: u64 = 0;
        for (clusters_opt.items) |cluster| {
            if (cluster.items.items.len < 2) continue;
            const orig = cluster.items.items[0];
            for (cluster.items.items[1..]) |dup| {
                const res = apfs.ApfsEngine.cloneDeduplicate(orig.path, dup.path, cluster.size_each);
                if (res.success) {
                    clones_done += 1;
                    bytes_saved += cluster.size_each;
                }
            }
        }
        state.status_text = "APFS CoW Batch: Cloned duplicates, reclaimed physical space";
        cocoa.sendVoidBool(self, sel_setNeedsDisplay, true);
        requestRedraw();
        return;
    }

    // Check individual buttons in cluster cards
    const list_top: f64 = top_bar_y;
    var cur_y: f64 = list_top + state.dedup_scroll_y;
    for (clusters_opt.items) |cluster| {
        const c_card_h: f64 = 34.0 + @as(f64, @floatFromInt(cluster.items.items.len)) * 32.0 + 8.0;
        const card_top = cur_y;
        cur_y -= c_card_h + 12.0;

        if (click_point.y > card_top or click_point.y < card_top - c_card_h) continue;

        if (cluster.items.items.len < 2) continue;
        const orig = cluster.items.items[0];

        for (cluster.items.items, 0..) |it, it_idx| {
            if (it_idx == 0) continue;
            const row_y = card_top - 34.0 - @as(f64, @floatFromInt(it_idx + 1)) * 32.0;
            if (click_point.y < row_y + 3.0 or click_point.y > row_y + 27.0) continue;

            const rcl_w: f64 = 110.0;
            const rcl_x = bounds.w - 40.0 - rcl_w - 90.0;
            if (click_point.x >= rcl_x and click_point.x <= rcl_x + rcl_w) {
                // CoW Clone clicked
                const res = apfs.ApfsEngine.cloneDeduplicate(orig.path, it.path, cluster.size_each);
                if (res.success) {
                    state.status_text = "Item deduplicated via APFS CoW clone (100% space saved, zero file loss)";
                } else {
                    state.status_text = "APFS CoW clone failed (cross-device or read-only)";
                }
                cocoa.sendVoidBool(self, sel_setNeedsDisplay, true);
                requestRedraw();
                return;
            }

            const trsh_x = bounds.w - 40.0 - 80.0;
            if (click_point.x >= trsh_x and click_point.x <= trsh_x + 70.0) {
                // Trash clicked
                var cl = cleaner.Cleaner.init(state.allocator) catch return;
                defer cl.deinit();
                _ = cl.safeMoveToTrash(it.path, cluster.size_each, .None) catch {
                    state.status_text = "Failed to move duplicate to Trash";
                    cocoa.sendVoidBool(self, sel_setNeedsDisplay, true);
                    requestRedraw();
                    return;
                };
                state.status_text = "Duplicate moved to Trash (reversible via journal)";
                state.refreshDedup();
                cocoa.sendVoidBool(self, sel_setNeedsDisplay, true);
                requestRedraw();
                return;
            }
        }
    }
}

// --- Quick-Wins Sweeper (Workspace 3) ---------------------------------------

fn drawQuickWinsSweeper(ctx: cocoa.CGContextRef, bounds: cocoa.NSRect, state: *UIState) void {
    if (state.scan_state == .idle or state.root_node == null) {
        cocoa.drawStringWithColor("Run disk analysis to discover quick-win storage reclamation opportunities.", bounds.w / 2.0 - 240.0, bounds.h / 2.0, 0.55, 0.60, 0.68, 1.0);
        return;
    }

    if (state.quick_wins == null) {
        state.refreshQuickWins();
    }

    const items_opt = state.quick_wins;
    if (items_opt == null or items_opt.?.items.len == 0) {
        cocoa.drawStringWithColor("✓ Clean system! No junk caches or stale build artifacts found.", bounds.w / 2.0 - 200.0, bounds.h / 2.0, 0.0, 0.90, 0.46, 1.0);
        return;
    }

    const items = items_opt.?.items;

    // 1. Top Action & Metrics Bar (Height 44px)
    const top_bar_h: f64 = 44.0;
    const top_bar_y: f64 = bounds.h - top_bar_h;
    const bar_bg = cocoa.makeCGColor(0x10131B, 1.0);
    defer cocoa.CGColorRelease(bar_bg);
    cocoa.CGContextSetFillColorWithColor(ctx, bar_bg);
    cocoa.CGContextFillRect(ctx, cocoa.NSRect.init(0, top_bar_y, bounds.w, top_bar_h));

    var total_reclaimable: u64 = 0;
    var safe_reclaimable: u64 = 0;
    for (items) |it| {
        total_reclaimable += it.size_bytes;
        if (it.risk == .Safe_ZeroRisk) {
            safe_reclaimable += it.size_bytes;
        }
    }

    var rcl_buf: [32]u8 = undefined;
    const rcl_str = types.DiskNode.formatSize(total_reclaimable, &rcl_buf);
    var safe_buf: [32]u8 = undefined;
    const safe_str = types.DiskNode.formatSize(safe_reclaimable, &safe_buf);

    var metric_buf: [128]u8 = undefined;
    const metric_str = std.fmt.bufPrint(&metric_buf, "QUICK-WINS SWEEPER  •  {d} Targets  •  Total: {s}  •  Zero-Risk: {s}", .{ items.len, rcl_str, safe_str }) catch "";
    cocoa.drawStringWithColor(metric_str, 20.0, top_bar_y + 14.0, 0.0, 0.90, 0.46, 1.0);

    // Button: Reclaim All Zero-Risk
    const btn_w: f64 = 230.0;
    const btn_h: f64 = 30.0;
    const btn_x = bounds.w - btn_w - 20.0;
    const btn_y = top_bar_y + 7.0;
    renderButton(ctx, cocoa.NSRect.init(btn_x, btn_y, btn_w, btn_h), "⚡  RECLAIM ALL ZERO-RISK", 0x14281E, 0x00E676);

    // 2. Render Cards List
    const list_top: f64 = top_bar_y;
    const card_h: f64 = 62.0;
    const card_margin: f64 = 10.0;

    var cur_y: f64 = list_top + state.quick_wins_scroll_y;
    for (items) |it| {
        const card_top = cur_y;
        cur_y -= card_h + card_margin;

        if (card_top - card_h > list_top or card_top < 0.0) continue;

        const card_rect = cocoa.NSRect.init(20.0, card_top - card_h, bounds.w - 40.0, card_h);
        renderCardBg(ctx, card_rect);

        // Left accent indicator based on risk
        const accent_hex: u32 = switch (it.risk) {
            .Safe_ZeroRisk => 0x00E676,
            .Recommended_Cache => 0x00E5FF,
            .Review_Needed => 0xFFB300,
            .Locked_Danger => 0xFF3D00,
        };
        const acc_col = cocoa.makeCGColor(accent_hex, 1.0);
        defer cocoa.CGColorRelease(acc_col);
        cocoa.CGContextSetFillColorWithColor(ctx, acc_col);
        cocoa.CGContextFillRect(ctx, cocoa.NSRect.init(20.0, card_top - card_h, 4.0, card_h));

        // Risk label
        const risk_lbl = it.risk.label();
        cocoa.drawStringWithColor(risk_lbl, 34.0, card_top - 20.0, if (it.risk == .Safe_ZeroRisk) 0.0 else 0.0, if (it.risk == .Safe_ZeroRisk) 0.90 else 0.85, if (it.risk == .Safe_ZeroRisk) 0.46 else 0.95, 1.0);

        // Title
        cocoa.drawStringWithColor(it.title, 34.0, card_top - 38.0, 0.95, 0.96, 0.99, 1.0);

        // Path
        const max_p_chars: usize = @intFromFloat(@max(10.0, (bounds.w - 320.0) / 8.0));
        const p_disp = if (it.path.len > max_p_chars) it.path[0..max_p_chars] else it.path;
        cocoa.drawStringWithColor(p_disp, 34.0, card_top - 54.0, 0.55, 0.60, 0.68, 1.0);

        // Size badge & Reclaim button on right
        var sz_b: [32]u8 = undefined;
        const sz_s = types.DiskNode.formatSize(it.size_bytes, &sz_b);
        cocoa.drawStringWithColor(sz_s, bounds.w - 240.0, card_top - 36.0, 0.0, 0.90, 1.0, 1.0);

        const rcl_btn_rect = cocoa.NSRect.init(bounds.w - 140.0, card_top - card_h + 16.0, 100.0, 30.0);
        renderButton(ctx, rcl_btn_rect, "🗑  RECLAIM", 0x221313, 0xFF3D00);
    }
}

fn onQuickWinsMouseDown(self: cocoa.id, click_point: cocoa.NSPoint, bounds: cocoa.NSRect, state: *UIState) void {
    const items_opt = state.quick_wins orelse return;
    const top_bar_h: f64 = 44.0;
    const top_bar_y: f64 = bounds.h - top_bar_h;

    // Check "RECLAIM ALL ZERO-RISK" button click
    const btn_w: f64 = 230.0;
    const btn_h: f64 = 30.0;
    const btn_x = bounds.w - btn_w - 20.0;
    const btn_y = top_bar_y + 7.0;
    if (click_point.x >= btn_x and click_point.x <= btn_x + btn_w and
        click_point.y >= btn_y and click_point.y <= btn_y + btn_h)
    {
        var cl = cleaner.Cleaner.init(state.allocator) catch return;
        defer cl.deinit();

        var reclaimed: u64 = 0;
        for (items_opt.items) |it| {
            if (it.risk == .Safe_ZeroRisk) {
                _ = cl.safeMoveToTrash(it.path, it.size_bytes, .None) catch continue;
                reclaimed += it.size_bytes;
            }
        }
        var sz_b: [32]u8 = undefined;
        const sz_s = types.DiskNode.formatSize(reclaimed, &sz_b);
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Reclaimed {s} of zero-risk caches into Trash (reversible)", .{sz_s}) catch "Reclaimed zero-risk caches";
        state.status_text = msg;
        state.refreshQuickWins();
        cocoa.sendVoidBool(self, sel_setNeedsDisplay, true);
        requestRedraw();
        return;
    }

    // Check individual RECLAIM buttons
    const list_top: f64 = top_bar_y;
    const card_h: f64 = 62.0;
    const card_margin: f64 = 10.0;

    var cur_y: f64 = list_top + state.quick_wins_scroll_y;
    for (items_opt.items) |it| {
        const card_top = cur_y;
        cur_y -= card_h + card_margin;

        if (click_point.y > card_top or click_point.y < card_top - card_h) continue;

        const btn_rect_x = bounds.w - 140.0;
        const btn_rect_y = card_top - card_h + 16.0;
        if (click_point.x >= btn_rect_x and click_point.x <= btn_rect_x + 100.0 and
            click_point.y >= btn_rect_y and click_point.y <= btn_rect_y + 30.0)
        {
            var cl = cleaner.Cleaner.init(state.allocator) catch return;
            defer cl.deinit();
            _ = cl.safeMoveToTrash(it.path, it.size_bytes, .None) catch {
                state.status_text = "Failed to move target cache to Trash";
                cocoa.sendVoidBool(self, sel_setNeedsDisplay, true);
                requestRedraw();
                return;
            };
            state.status_text = "Cache moved to Trash safely (reversible via journal)";
            state.refreshQuickWins();
            cocoa.sendVoidBool(self, sel_setNeedsDisplay, true);
            requestRedraw();
            return;
        }
    }
}

// --- Baremetal Editor (Workspace 4) ----------------------------------------

fn drawBaremetalEditor(ctx: cocoa.CGContextRef, bounds: cocoa.NSRect, state: *UIState) void {
    const target = state.selected_node orelse state.drill_node orelse state.root_node;
    if (target == null or state.scan_state == .idle) {
        cocoa.drawStringWithColor("Select any file or folder in Super Finder to inspect baremetal filesystem blocks and raw bytes.", bounds.w / 2.0 - 270.0, bounds.h / 2.0, 0.55, 0.60, 0.68, 1.0);
        return;
    }
    const node = target.?;

    // 1. Top Header Bar
    const top_bar_h: f64 = 44.0;
    const top_bar_y: f64 = bounds.h - top_bar_h;
    const bar_bg = cocoa.makeCGColor(0x10131B, 1.0);
    defer cocoa.CGColorRelease(bar_bg);
    cocoa.CGContextSetFillColorWithColor(ctx, bar_bg);
    cocoa.CGContextFillRect(ctx, cocoa.NSRect.init(0, top_bar_y, bounds.w, top_bar_h));

    var title_buf: [256]u8 = undefined;
    const max_t: usize = @min(node.path.len, 48);
    const title_str = std.fmt.bufPrint(&title_buf, "BAREMETAL BLOCK & HEX INSPECTOR  •  {s}", .{node.path[0..max_t]}) catch "BAREMETAL INSPECTOR";
    cocoa.drawStringWithColor(title_str, 20.0, top_bar_y + 14.0, 0.0, 0.90, 1.0, 1.0);

    // 2. POSIX / APFS Inode Stat Card
    var pz: [4096]u8 = undefined;
    var st: c.struct_stat = undefined;
    var have_stat = false;
    if (node.path.len < pz.len - 1) {
        @memcpy(pz[0..node.path.len], node.path);
        pz[node.path.len] = 0;
        if (c.lstat(@as([*:0]const u8, @ptrCast(&pz)), &st) == 0) {
            have_stat = true;
        }
    }

    const stat_card_y = top_bar_y - 90.0;
    const stat_card_rect = cocoa.NSRect.init(20.0, stat_card_y, bounds.w - 40.0, 80.0);
    renderCardBg(ctx, stat_card_rect);

    if (have_stat) {
        var stat_line1: [128]u8 = undefined;
        const sl1 = std.fmt.bufPrint(&stat_line1, "INODE: {d}  •  DEV: 0x{x}  •  MODE: 0o{o:0>6}  •  NLINK: {d}  •  UID: {d}  •  GID: {d}", .{
            st.st_ino,
            st.st_dev,
            st.st_mode,
            st.st_nlink,
            st.st_uid,
            st.st_gid,
        }) catch "";
        cocoa.drawStringWithColor(sl1, 36.0, stat_card_y + 50.0, 0.0, 0.90, 1.0, 1.0);

        var stat_line2: [128]u8 = undefined;
        const sl2 = std.fmt.bufPrint(&stat_line2, "LOGICAL: {d} bytes  •  BLOCKS ALLOCATED: {d} (512B sectors)  •  SIZE ON DISK: {d} bytes", .{
            st.st_size,
            st.st_blocks,
            @as(u64, @intCast(st.st_blocks)) * 512,
        }) catch "";
        cocoa.drawStringWithColor(sl2, 36.0, stat_card_y + 24.0, 0.82, 0.86, 0.92, 1.0);
    } else {
        cocoa.drawStringWithColor("Unable to read POSIX lstat metrics for path", 36.0, stat_card_y + 36.0, 0.55, 0.60, 0.68, 1.0);
    }

    // 3. Raw Bytes Hex Dump Window (First 512 bytes)
    const hex_top = stat_card_y - 14.0;
    const hex_h = hex_top - 20.0;
    const hex_rect = cocoa.NSRect.init(20.0, 20.0, bounds.w - 40.0, hex_h);
    renderCardBg(ctx, hex_rect);

    cocoa.drawStringWithColor("OFFSET         00 01 02 03 04 05 06 07  08 09 0A 0B 0C 0D 0E 0F    ASCII DECODE", 36.0, hex_top - 24.0, 0.55, 0.60, 0.68, 1.0);

    var raw_buf: [512]u8 = undefined;
    var bytes_read: usize = 0;
    if (node.kind == .file and node.path.len < pz.len - 1) {
        const fd = c.open(@as([*:0]const u8, @ptrCast(&pz)), c.O_RDONLY | c.O_NONBLOCK);
        if (fd >= 0) {
            defer _ = c.close(fd);
            const n = c.read(fd, &raw_buf, raw_buf.len);
            if (n > 0) bytes_read = @intCast(n);
        }
    }

    if (bytes_read == 0) {
        if (node.kind == .directory) {
            cocoa.drawStringWithColor("Directory node — directories have structural catalog blocks managed by APFS container.", 36.0, hex_top - 60.0, 0.55, 0.60, 0.68, 1.0);
        } else {
            cocoa.drawStringWithColor("0-byte empty file or unreadable contents.", 36.0, hex_top - 60.0, 0.55, 0.60, 0.68, 1.0);
        }
        return;
    }

    // Render hex lines (16 bytes per line)
    var line_offset: usize = 0;
    var line_y: f64 = hex_top - 52.0 + state.baremetal_scroll_y;
    while (line_offset < bytes_read and line_y > 30.0) : ({
        line_offset += 16;
        line_y -= 22.0;
    }) {
        if (line_y > hex_top - 36.0) continue;

        const count = @min(16, bytes_read - line_offset);
        const chunk = raw_buf[line_offset .. line_offset + count];

        var hex_str: [80]u8 = [_]u8{' '} ** 80;
        var off_buf: [16]u8 = undefined;
        const off_str = std.fmt.bufPrint(&off_buf, "0x{x:0>8}: ", .{line_offset}) catch "";

        // Format hex octets
        var h_pos: usize = 0;
        for (chunk, 0..) |b, i| {
            if (i == 8) {
                hex_str[h_pos] = ' ';
                h_pos += 1;
            }
            _ = std.fmt.bufPrint(hex_str[h_pos .. h_pos + 3], "{x:0>2} ", .{b}) catch {};
            h_pos += 3;
        }

        // Format ASCII characters
        var asc_str: [18]u8 = [_]u8{'.'} ** 18;
        for (chunk, 0..) |b, i| {
            if (b >= 32 and b <= 126) {
                asc_str[i] = b;
            }
        }
        asc_str[count] = 0;

        var full_line: [128]u8 = undefined;
        const fl = std.fmt.bufPrint(&full_line, "{s} {s}   |{s}|", .{ off_str, hex_str[0..@max(48, h_pos)], asc_str[0..count] }) catch "";
        cocoa.drawStringWithColor(fl, 36.0, line_y, 0.0, 0.90, 1.0, 1.0);
    }
}

fn onBaremetalMouseDown(self: cocoa.id, click_point: cocoa.NSPoint, bounds: cocoa.NSRect, state: *UIState) void {
    _ = self;
    _ = click_point;
    _ = bounds;
    _ = state;
}

// --- Machine Telemetry (Workspace 5) ---------------------------------------

fn drawMachineTelemetry(ctx: cocoa.CGContextRef, bounds: cocoa.NSRect, state: *UIState) void {
    // 1. Top Header Bar
    const top_bar_h: f64 = 44.0;
    const top_bar_y: f64 = bounds.h - top_bar_h;
    const bar_bg = cocoa.makeCGColor(0x10131B, 1.0);
    defer cocoa.CGColorRelease(bar_bg);
    cocoa.CGContextSetFillColorWithColor(ctx, bar_bg);
    cocoa.CGContextFillRect(ctx, cocoa.NSRect.init(0, top_bar_y, bounds.w, top_bar_h));

    cocoa.drawStringWithColor("MACHINE TELEMETRY  •  HARDWARE APFS TOPOLOGY & SYSTEM RUNTIME", 20.0, top_bar_y + 14.0, 0.0, 0.90, 1.0, 1.0);

    // 2. Storage Volume Gauge Card (Height 160px)
    const v_card_y = top_bar_y - 175.0;
    const v_card_rect = cocoa.NSRect.init(20.0, v_card_y, bounds.w - 40.0, 160.0);
    renderCardBg(ctx, v_card_rect);

    var tot_b: [32]u8 = undefined;
    var used_b: [32]u8 = undefined;
    var free_b: [32]u8 = undefined;
    const tot_s = types.DiskNode.formatSize(state.volume_total_bytes, &tot_b);
    const used_s = types.DiskNode.formatSize(state.volume_used_bytes, &used_b);
    const free_s = types.DiskNode.formatSize(state.volume_free_bytes, &free_b);

    const mnt_name = if (state.volume_name_len > 0) state.volume_name[0..state.volume_name_len] else "/";
    var v_hdr_buf: [128]u8 = undefined;
    const v_hdr = std.fmt.bufPrint(&v_hdr_buf, "PRIMARY APFS CONTAINER ({s})  •  Capacity: {s}", .{ mnt_name, tot_s }) catch "";
    cocoa.drawStringWithColor(v_hdr, 36.0, v_card_y + 124.0, 0.95, 0.96, 0.99, 1.0);

    var v_metrics_buf: [128]u8 = undefined;
    const v_met = std.fmt.bufPrint(&v_metrics_buf, "Used Space: {s} ({d:.1}%)    •    Available Free Space: {s}", .{ used_s, state.volume_pct_used, free_s }) catch "";
    cocoa.drawStringWithColor(v_met, 36.0, v_card_y + 94.0, 0.0, 0.90, 1.0, 1.0);

    // Gauge bar
    const bar_x: f64 = 36.0;
    const bar_w: f64 = bounds.w - 40.0 - 72.0;
    const bar_y: f64 = v_card_y + 44.0;
    const bar_h: f64 = 28.0;

    // Background track
    const track_col = cocoa.makeCGColor(0x1B202D, 1.0);
    defer cocoa.CGColorRelease(track_col);
    cocoa.CGContextSetFillColorWithColor(ctx, track_col);
    cocoa.CGContextFillRect(ctx, cocoa.NSRect.init(bar_x, bar_y, bar_w, bar_h));

    // Used portion (Cyan)
    const pct = @min(100.0, @max(0.0, state.volume_pct_used));
    const used_w = bar_w * (@as(f64, @floatCast(pct)) / 100.0);
    if (used_w > 0.0) {
        const used_col = cocoa.makeCGColor(0x00E5FF, 0.85);
        defer cocoa.CGColorRelease(used_col);
        cocoa.CGContextSetFillColorWithColor(ctx, used_col);
        cocoa.CGContextFillRect(ctx, cocoa.NSRect.init(bar_x, bar_y, used_w, bar_h));
    }

    // Border
    const b_col = cocoa.makeCGColor(0x283040, 1.0);
    defer cocoa.CGColorRelease(b_col);
    cocoa.CGContextSetStrokeColorWithColor(ctx, b_col);
    cocoa.CGContextSetLineWidth(ctx, 1.2);
    cocoa.CGContextStrokeRect(ctx, cocoa.NSRect.init(bar_x, bar_y, bar_w, bar_h));

    cocoa.drawStringWithColor("■ Used Container Space (APFS)", bar_x, v_card_y + 16.0, 0.0, 0.90, 1.0, 1.0);
    cocoa.drawStringWithColor("□ Available Unallocated Blocks", bar_x + 220.0, v_card_y + 16.0, 0.55, 0.60, 0.68, 1.0);

    // 3. Engine & Hardware Specs Card
    const e_card_y = v_card_y - 200.0;
    const e_card_rect = cocoa.NSRect.init(20.0, e_card_y, bounds.w - 40.0, 185.0);
    renderCardBg(ctx, e_card_rect);

    cocoa.drawStringWithColor("ENGINE RUNTIME & PLATFORM ARCHITECTURE", 36.0, e_card_y + 148.0, 0.0, 0.90, 0.46, 1.0);
    cocoa.drawStringWithColor("Engine Substrate: Pure-Zig 0.16.0 Native Binary (Mach-O ARM64)", 36.0, e_card_y + 120.0, 0.85, 0.88, 0.92, 1.0);
    cocoa.drawStringWithColor("Zero-Overhead Contract: 0% WebKit, 0% JavaScript, 0% Electron, 0% Chromium overhead", 36.0, e_card_y + 96.0, 0.85, 0.88, 0.92, 1.0);
    cocoa.drawStringWithColor("Graphics Pipeline: Direct QuartzCore CoreGraphics & Darwin AppKit Cocoa event loop", 36.0, e_card_y + 72.0, 0.85, 0.88, 0.92, 1.0);
    cocoa.drawStringWithColor("Continuity Substrate: LatticeVault canonical substrate (proj_ca8e040834bb2b68fe778f499de101bd)", 36.0, e_card_y + 48.0, 0.85, 0.88, 0.92, 1.0);
    cocoa.drawStringWithColor("Memory Footprint: <25 MB RSS resident memory under full interactive inspection", 36.0, e_card_y + 24.0, 0.0, 0.90, 1.0, 1.0);
}

fn onTelemetryMouseDown(self: cocoa.id, click_point: cocoa.NSPoint, bounds: cocoa.NSRect, state: *UIState) void {
    _ = self;
    _ = click_point;
    _ = bounds;
    _ = state;
}

// --- Time-Travel Snapshots (Workspace 7) -----------------------------------

fn drawSnapshotsStudio(ctx: cocoa.CGContextRef, bounds: cocoa.NSRect, state: *UIState) void {
    // 1. Top Header Bar
    const top_bar_h: f64 = 44.0;
    const top_bar_y: f64 = bounds.h - top_bar_h;
    const bar_bg = cocoa.makeCGColor(0x10131B, 1.0);
    defer cocoa.CGColorRelease(bar_bg);
    cocoa.CGContextSetFillColorWithColor(ctx, bar_bg);
    cocoa.CGContextFillRect(ctx, cocoa.NSRect.init(0, top_bar_y, bounds.w, top_bar_h));

    cocoa.drawStringWithColor("TIME-TRAVEL SNAPSHOTS  •  STREAMING ZSNP3 DISK CHURN DELTAS", 20.0, top_bar_y + 14.0, 0.0, 0.90, 1.0, 1.0);

    // Button: Create Snapshot
    const btn_w: f64 = 230.0;
    const btn_h: f64 = 30.0;
    const btn_x = bounds.w - btn_w - 20.0;
    const btn_y = top_bar_y + 7.0;
    renderButton(ctx, cocoa.NSRect.init(btn_x, btn_y, btn_w, btn_h), "📸  CREATE SNAPSHOT", 0x14202C, 0x00E5FF);

    // 2. Info & Status Card
    const info_y = top_bar_y - 120.0;
    const info_rect = cocoa.NSRect.init(20.0, info_y, bounds.w - 40.0, 105.0);
    renderCardBg(ctx, info_rect);

    cocoa.drawStringWithColor("SNAPSHOT STATUS & SPECIFICATION (ZSNP3)", 36.0, info_y + 74.0, 0.0, 0.90, 1.0, 1.0);
    cocoa.drawStringWithColor(state.snapshot_status, 36.0, info_y + 50.0, 0.0, 0.90, 0.46, 1.0);
    cocoa.drawStringWithColor("ZSNP3 files record atomic snapshots with full Blake3 hashes, POSIX mtime, and APFS block clusters.", 36.0, info_y + 24.0, 0.65, 0.70, 0.76, 1.0);

    // 3. Historical Details Card
    const card2_y = info_y - 200.0;
    const card2_rect = cocoa.NSRect.init(20.0, card2_y, bounds.w - 40.0, 185.0);
    renderCardBg(ctx, card2_rect);

    cocoa.drawStringWithColor("TIME-TRAVEL CAPABILITIES", 36.0, card2_y + 148.0, 0.0, 0.90, 0.46, 1.0);
    cocoa.drawStringWithColor("• Instant Delta Diffing: Compare any two snapshots to detect disk bloat, created, shrunk, or deleted files.", 36.0, card2_y + 118.0, 0.85, 0.88, 0.92, 1.0);
    cocoa.drawStringWithColor("• Temporal Decay Heatmaps: Visualizes filesystem age entropy (Fresh <30d, Warm, Cold, Iceberg >1y).", 36.0, card2_y + 90.0, 0.85, 0.88, 0.92, 1.0);
    cocoa.drawStringWithColor("• Zero Tamper Verification: Re-scan snapshots to verify cryptographic Blake3 integrity of all saved nodes.", 36.0, card2_y + 62.0, 0.85, 0.88, 0.92, 1.0);
    cocoa.drawStringWithColor("• Atomic Tempfile Publishing: Snapshots use mkstemp and atomic rename for crash-resilient persistence.", 36.0, card2_y + 34.0, 0.85, 0.88, 0.92, 1.0);
}

fn onSnapshotsMouseDown(self: cocoa.id, click_point: cocoa.NSPoint, bounds: cocoa.NSRect, state: *UIState) void {
    const top_bar_h: f64 = 44.0;
    const top_bar_y: f64 = bounds.h - top_bar_h;

    // Check "CREATE SNAPSHOT" button click
    const btn_w: f64 = 230.0;
    const btn_h: f64 = 30.0;
    const btn_x = bounds.w - btn_w - 20.0;
    const btn_y = top_bar_y + 7.0;

    if (click_point.x >= btn_x and click_point.x <= btn_x + btn_w and
        click_point.y >= btn_y and click_point.y <= btn_y + btn_h)
    {
        const root = state.root_node;
        if (root == null or state.scan_state == .idle) {
            state.snapshot_status = "Run disk analysis first before creating a snapshot.";
            cocoa.sendVoidBool(self, sel_setNeedsDisplay, true);
            requestRedraw();
            return;
        }

        const now = types.getRealtimeNs();
        var path_buf: [1024]u8 = undefined;
        const target = state.getTargetPath();
        const snap_path = if (std.mem.eql(u8, target, "/"))
            std.fmt.bufPrint(&path_buf, "/tmp/.zspace_snapshot_{d}.zsnp3", .{now}) catch {
                state.snapshot_status = "Path buffer overflow";
                return;
            }
        else if (std.mem.endsWith(u8, target, "/"))
            std.fmt.bufPrint(&path_buf, "{s}.zspace_snapshot_{d}.zsnp3", .{ target, now }) catch {
                state.snapshot_status = "Path buffer overflow";
                return;
            }
        else
            std.fmt.bufPrint(&path_buf, "{s}/.zspace_snapshot_{d}.zsnp3", .{ target, now }) catch {
                state.snapshot_status = "Path buffer overflow";
                return;
            };

        var engine = snapshot.SnapshotEngine.init(state.allocator);
        engine.saveSnapshot(root.?, snap_path) catch |err| {
            std.debug.print("Failed to save snapshot: {}\n", .{err});
            state.snapshot_status = "Failed to write snapshot file (permission denied or disk full)";
            cocoa.sendVoidBool(self, sel_setNeedsDisplay, true);
            requestRedraw();
            return;
        };

        state.snapshot_status = "✓ Saved atomic snapshot (ZSNP3 format) with streaming verification";
        state.status_text = "Time-travel snapshot created successfully";
        cocoa.sendVoidBool(self, sel_setNeedsDisplay, true);
        requestRedraw();
    }
}

// --- Audit Journal (Workspace 8) -------------------------------------------

fn drawAuditJournal(ctx: cocoa.CGContextRef, bounds: cocoa.NSRect, state: *UIState) void {
    if (state.journal_records == null) {
        state.refreshJournal();
    }

    // 1. Top Header Bar
    const top_bar_h: f64 = 44.0;
    const top_bar_y: f64 = bounds.h - top_bar_h;
    const bar_bg = cocoa.makeCGColor(0x10131B, 1.0);
    defer cocoa.CGColorRelease(bar_bg);
    cocoa.CGContextSetFillColorWithColor(ctx, bar_bg);
    cocoa.CGContextFillRect(ctx, cocoa.NSRect.init(0, top_bar_y, bounds.w, top_bar_h));

    const records = if (state.journal_records) |*jr| jr.items else &.{};
    var hdr_buf: [128]u8 = undefined;
    const hdr_str = std.fmt.bufPrint(&hdr_buf, "AUDIT JOURNAL  •  Two-Phase Reversible Ledger  •  {d} Operations", .{records.len}) catch "";
    cocoa.drawStringWithColor(hdr_str, 20.0, top_bar_y + 14.0, 0.0, 0.90, 1.0, 1.0);

    // Button: Refresh Journal
    const btn_w: f64 = 170.0;
    const btn_h: f64 = 30.0;
    const btn_x = bounds.w - btn_w - 20.0;
    const btn_y = top_bar_y + 7.0;
    renderButton(ctx, cocoa.NSRect.init(btn_x, btn_y, btn_w, btn_h), "⟳  REFRESH LEDGER", 0x14202C, 0x00E5FF);

    if (records.len == 0) {
        cocoa.drawStringWithColor("✓ Clean audit journal — No trash or dedup operations recorded yet.", bounds.w / 2.0 - 240.0, bounds.h / 2.0, 0.0, 0.90, 0.46, 1.0);
        return;
    }

    // 2. Table Column Headers
    const col_h: f64 = 28.0;
    const col_y: f64 = top_bar_y - col_h;
    const col_bg = cocoa.makeCGColor(0x141822, 1.0);
    defer cocoa.CGColorRelease(col_bg);
    cocoa.CGContextSetFillColorWithColor(ctx, col_bg);
    cocoa.CGContextFillRect(ctx, cocoa.NSRect.init(0, col_y, bounds.w, col_h));

    cocoa.drawStringWithColor("RECEIPT ID", 24.0, col_y + 8.0, 0.70, 0.75, 0.82, 1.0);
    cocoa.drawStringWithColor("METHOD", 220.0, col_y + 8.0, 0.70, 0.75, 0.82, 1.0);
    cocoa.drawStringWithColor("SIZE", 340.0, col_y + 8.0, 0.70, 0.75, 0.82, 1.0);
    cocoa.drawStringWithColor("ORIGINAL FILE PATH", 440.0, col_y + 8.0, 0.70, 0.75, 0.82, 1.0);
    cocoa.drawStringWithColor("ACTION", bounds.w - 120.0, col_y + 8.0, 0.70, 0.75, 0.82, 1.0);

    // 3. Virtualized Operations List
    const row_h: f64 = 36.0;
    const list_top: f64 = col_y;

    var cur_y: f64 = list_top + state.journal_scroll_y;
    for (records) |op| {
        const row_top = cur_y;
        cur_y -= row_h;

        if (row_top > list_top or row_top < 0.0) continue;

        // Alternate row fill
        const alt_bg = cocoa.makeCGColor(0xFFFFFF, 0.02);
        defer cocoa.CGColorRelease(alt_bg);
        cocoa.CGContextSetFillColorWithColor(ctx, alt_bg);
        cocoa.CGContextFillRect(ctx, cocoa.NSRect.init(0, row_top - row_h, bounds.w, row_h - 1.0));

        // Receipt ID (Cyan)
        const rid_disp = if (op.receipt_id.len > 16) op.receipt_id[0..16] else op.receipt_id;
        cocoa.drawStringWithColor(rid_disp, 24.0, row_top - 24.0, 0.0, 0.90, 1.0, 1.0);

        // Method
        const meth_lbl = op.method.label();
        cocoa.drawStringWithColor(meth_lbl, 220.0, row_top - 24.0, 0.85, 0.88, 0.94, 1.0);

        // Size
        var sz_b: [32]u8 = undefined;
        const sz_s = types.DiskNode.formatSize(op.size_bytes, &sz_b);
        cocoa.drawStringWithColor(sz_s, 340.0, row_top - 24.0, 0.82, 0.86, 0.92, 1.0);

        // Path
        const max_p: usize = @intFromFloat(@max(10.0, (bounds.w - 580.0) / 8.0));
        const p_disp = if (op.original_path.len > max_p) op.original_path[0..max_p] else op.original_path;
        cocoa.drawStringWithColor(p_disp, 440.0, row_top - 24.0, 0.95, 0.96, 0.99, 1.0);

        // Action button [ ⮌ UNDO ]
        const u_btn_rect = cocoa.NSRect.init(bounds.w - 120.0, row_top - row_h + 5.0, 95.0, 26.0);
        renderButton(ctx, u_btn_rect, "⮌ UNDO", 0x14202C, 0x00E5FF);
    }
}

fn onAuditJournalMouseDown(self: cocoa.id, click_point: cocoa.NSPoint, bounds: cocoa.NSRect, state: *UIState) void {
    const top_bar_h: f64 = 44.0;
    const top_bar_y: f64 = bounds.h - top_bar_h;

    // Check "REFRESH LEDGER" button click
    const btn_w: f64 = 170.0;
    const btn_h: f64 = 30.0;
    const btn_x = bounds.w - btn_w - 20.0;
    const btn_y = top_bar_y + 7.0;

    if (click_point.x >= btn_x and click_point.x <= btn_x + btn_w and
        click_point.y >= btn_y and click_point.y <= btn_y + btn_h)
    {
        state.refreshJournal();
        state.status_text = "Audit journal refreshed from disk";
        cocoa.sendVoidBool(self, sel_setNeedsDisplay, true);
        requestRedraw();
        return;
    }

    // Check individual UNDO buttons
    const records = if (state.journal_records) |*jr| jr.items else return;
    const col_h: f64 = 28.0;
    const list_top: f64 = top_bar_y - col_h;
    const row_h: f64 = 36.0;

    var cur_y: f64 = list_top + state.journal_scroll_y;
    for (records) |op| {
        const row_top = cur_y;
        cur_y -= row_h;

        if (click_point.y > row_top or click_point.y < row_top - row_h) continue;

        const u_btn_x = bounds.w - 120.0;
        const u_btn_y = row_top - row_h + 5.0;
        if (click_point.x >= u_btn_x and click_point.x <= u_btn_x + 95.0 and
            click_point.y >= u_btn_y and click_point.y <= u_btn_y + 26.0)
        {
            var cl = cleaner.Cleaner.init(state.allocator) catch return;
            defer cl.deinit();

            const restored = cl.undoByReceipt(op.receipt_id) catch |err| {
                std.debug.print("Failed to undo receipt {s}: {}\n", .{ op.receipt_id, err });
                state.status_text = "Undo failed: receipt not found or item altered";
                cocoa.sendVoidBool(self, sel_setNeedsDisplay, true);
                requestRedraw();
                return;
            };
            _ = restored;
            state.status_text = "✓ Restored item from Trash with Blake3 verification!";
            state.refreshJournal();
            cocoa.sendVoidBool(self, sel_setNeedsDisplay, true);
            requestRedraw();
            return;
        }
    }
}

// --- 4. Main Stage View Subclass -------------------------------------------

fn drawStageRect(self: cocoa.id, _: cocoa.SEL, dirty: cocoa.NSRect) callconv(.c) void {
    _ = dirty;
    const ctx = cocoa.getCurrentGraphicsContext() orelse return;
    cocoa.CGContextSaveGState(ctx);
    defer cocoa.CGContextRestoreGState(ctx);

    const bounds = cocoa.sendGetRect(self, sel_bounds);

    // Deep Stage Background #0B0C10
    const bg_color = cocoa.makeCGColor(0x0B0C10, 1.0);
    defer cocoa.CGColorRelease(bg_color);
    cocoa.CGContextSetFillColorWithColor(ctx, bg_color);
    cocoa.CGContextFillRect(ctx, bounds);

    const state = global_ui_state orelse return;
    switch (state.active_tab) {
        .super_finder => drawSuperFinder(ctx, bounds, state),
        .dedup_studio => drawDedupStudio(ctx, bounds, state),
        .quick_wins => drawQuickWinsSweeper(ctx, bounds, state),
        .baremetal_editor => drawBaremetalEditor(ctx, bounds, state),
        .machine_telemetry => drawMachineTelemetry(ctx, bounds, state),
        .spacetime_visualizer => drawSpacetimeVisualizer(ctx, bounds, state),
        .time_travel_snapshots => drawSnapshotsStudio(ctx, bounds, state),
        .audit_journal => drawAuditJournal(ctx, bounds, state),
    }
}

fn onStageMouseDown(self: cocoa.id, _: cocoa.SEL, event: cocoa.id) callconv(.c) void {
    const state = global_ui_state orelse return;
    const sel_location = cocoa.sel_registerName("locationInWindow");
    const F_loc = *const fn (cocoa.id, cocoa.SEL) callconv(.c) cocoa.NSPoint;
    const window_point = @as(F_loc, @ptrCast(&cocoa.objc_msgSend))(event, sel_location);

    const sel_convertPoint = cocoa.sel_registerName("convertPoint:fromView:");
    const click_point = cocoa.sendConvertPointFromView(self, sel_convertPoint, window_point, null);
    const bounds = cocoa.sendGetRect(self, sel_bounds);

    switch (state.active_tab) {
        .super_finder => onSuperFinderMouseDown(self, click_point, bounds, state, event),
        .dedup_studio => onDedupStudioMouseDown(self, click_point, bounds, state),
        .quick_wins => onQuickWinsMouseDown(self, click_point, bounds, state),
        .baremetal_editor => onBaremetalMouseDown(self, click_point, bounds, state),
        .machine_telemetry => onTelemetryMouseDown(self, click_point, bounds, state),
        .spacetime_visualizer => onSpacetimeMouseDown(self, click_point, bounds, state),
        .time_travel_snapshots => onSnapshotsMouseDown(self, click_point, bounds, state),
        .audit_journal => onAuditJournalMouseDown(self, click_point, bounds, state),
    }
}

fn onStageScrollWheel(self: cocoa.id, _: cocoa.SEL, event: cocoa.id) callconv(.c) void {
    const state = global_ui_state orelse return;
    const sel_deltaY = cocoa.sel_registerName("scrollingDeltaY");
    const F_delta = *const fn (cocoa.id, cocoa.SEL) callconv(.c) f64;
    const dy = @as(F_delta, @ptrCast(&cocoa.objc_msgSend))(event, sel_deltaY);

    switch (state.active_tab) {
        .super_finder => state.scroll_offset_y = @max(0.0, state.scroll_offset_y - dy),
        .dedup_studio => state.dedup_scroll_y = @max(0.0, state.dedup_scroll_y - dy),
        .quick_wins => state.quick_wins_scroll_y = @max(0.0, state.quick_wins_scroll_y - dy),
        .baremetal_editor => state.baremetal_scroll_y = @max(0.0, state.baremetal_scroll_y - dy),
        .time_travel_snapshots => state.snapshots_scroll_y = @max(0.0, state.snapshots_scroll_y - dy),
        .audit_journal => state.journal_scroll_y = @max(0.0, state.journal_scroll_y - dy),
        else => {},
    }
    cocoa.sendVoidBool(self, sel_setNeedsDisplay, true);
}

// --- 5. SidebarView: File Inspector & Target Presets -----------------------

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
    const card_x: f64 = 18.0;
    const card_w: f64 = bounds.w - 36.0;

    if (state.scan_state == .idle or (state.root_node == null and state.drill_node == null)) {
        // Presets & Idle HUD
        cocoa.drawStringWithColor("TARGET & TELEMETRY", 24, bounds.h - 35, 0.90, 0.93, 0.96, 1.0);

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

        // Shortcuts Guide
        const sc_y = bounds.h - 400.0;
        const sc_h = 135.0;
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

        cocoa.drawStringWithColor("QUICK SHORTCUTS:", card_x + 16, sc_y + 110, 0.85, 0.88, 0.94, 1.0);
        cocoa.drawStringWithColor("⌘O  —  Choose custom target folder", card_x + 16, sc_y + 88, 0.55, 0.60, 0.68, 1.0);
        cocoa.drawStringWithColor("⌘R  —  Run disk analysis", card_x + 16, sc_y + 68, 0.55, 0.60, 0.68, 1.0);
        cocoa.drawStringWithColor("⌘1..8 — Switch workspace tab", card_x + 16, sc_y + 48, 0.55, 0.60, 0.68, 1.0);
        cocoa.drawStringWithColor("⌘Q  —  Quit ZSpace", card_x + 16, sc_y + 28, 0.55, 0.60, 0.68, 1.0);
        return;
    }

    // Active File Inspector
    const target = state.selected_node orelse (state.drill_node orelse state.root_node.?);
    cocoa.drawStringWithColor("FILE & TARGET INSPECTOR", 24, bounds.h - 35, 0.90, 0.93, 0.96, 1.0);

    // 1. Identity Card
    const id_y = bounds.h - 110.0;
    const id_rect = cocoa.NSRect.init(card_x, id_y, card_w, 68.0);
    renderCardBg(ctx, id_rect);

    const is_dir = target.isDirectory();
    const type_badge: []const u8 = if (is_dir) "DIRECTORY" else "FILE";
    cocoa.drawStringWithColor(type_badge, card_x + 16, id_y + 48, 0.0, 0.90, 1.0, 1.0);

    var name_b: [64]u8 = undefined;
    const max_n: usize = @min(target.name.len, 28);
    const id_name = std.fmt.bufPrint(&name_b, "{s}", .{target.name[0..max_n]}) catch target.name;
    cocoa.drawStringWithColor(id_name, card_x + 16, id_y + 24, 0.95, 0.96, 0.99, 1.0);

    // 2. Full Path Card
    const p_y = bounds.h - 180.0;
    const p_rect = cocoa.NSRect.init(card_x, p_y, card_w, 60.0);
    renderCardBg(ctx, p_rect);
    cocoa.drawStringWithColor("FULL PATH:", card_x + 16, p_y + 40, 0.48, 0.54, 0.62, 1.0);
    const p_len = @min(target.path.len, 34);
    cocoa.drawStringWithColor(target.path[0..p_len], card_x + 16, p_y + 18, 0.75, 0.80, 0.88, 1.0);

    // 3. Storage & APFS Blocks Card
    const s_y = bounds.h - 275.0;
    const s_rect = cocoa.NSRect.init(card_x, s_y, card_w, 85.0);
    renderCardBg(ctx, s_rect);

    cocoa.drawStringWithColor("STORAGE ALLOCATION:", card_x + 16, s_y + 64, 0.48, 0.54, 0.62, 1.0);
    var sz_b: [32]u8 = undefined;
    var blk_b: [32]u8 = undefined;
    const sz_str = types.DiskNode.formatSize(target.size_bytes, &sz_b);
    const blk_str = types.DiskNode.formatSize(target.allocated_bytes, &blk_b);

    var sz_line: [64]u8 = undefined;
    const s_line = std.fmt.bufPrint(&sz_line, "Logical: {s}  •  Blocks: {s}", .{ sz_str, blk_str }) catch "";
    cocoa.drawStringWithColor(s_line, card_x + 16, s_y + 42, 0.0, 0.90, 1.0, 1.0);

    if (target.allocated_bytes < target.size_bytes and target.size_bytes > 4096) {
        var sav_b: [32]u8 = undefined;
        const sav_s = types.DiskNode.formatSize(target.size_bytes - target.allocated_bytes, &sav_b);
        var sav_line: [64]u8 = undefined;
        const sl = std.fmt.bufPrint(&sav_line, "APFS CoW / Sparse: {s} saved", .{sav_s}) catch "";
        cocoa.drawStringWithColor(sl, card_x + 16, s_y + 18, 0.0, 0.90, 0.46, 1.0);
    } else {
        cocoa.drawStringWithColor("Physical blocks match logical size", card_x + 16, s_y + 18, 0.55, 0.60, 0.68, 1.0);
    }

    // 4. Protection & Category
    const pr_y = bounds.h - 355.0;
    const pr_rect = cocoa.NSRect.init(card_x, pr_y, card_w, 70.0);
    renderCardBg(ctx, pr_rect);
    cocoa.drawStringWithColor("STATUS & PROTECTION:", card_x + 16, pr_y + 50, 0.48, 0.54, 0.62, 1.0);

    const prot_lbl = target.protection.label();
    if (target.protection.isProtected()) {
        cocoa.drawStringWithColor(prot_lbl, card_x + 16, pr_y + 26, 1.0, 0.43, 0.25, 1.0); // Coral
    } else {
        cocoa.drawStringWithColor(prot_lbl, card_x + 16, pr_y + 26, 0.0, 0.90, 0.46, 1.0); // Emerald Green
    }

    // 5. Actions Buttons
    const act1_y = bounds.h - 410.0;
    const act1_rect = cocoa.NSRect.init(card_x, act1_y, card_w, 36.0);
    renderButton(ctx, act1_rect, "📋  COPY PATH TO CLIPBOARD", 0x141824, 0x00E5FF);

    const act2_y = bounds.h - 456.0;
    const act2_rect = cocoa.NSRect.init(card_x, act2_y, card_w, 36.0);
    if (target.protection.isProtected()) {
        renderButton(ctx, act2_rect, "🔒  PROTECTED (CANNOT TRASH)", 0x181414, 0x553333);
    } else {
        renderButton(ctx, act2_rect, "🗑  MOVE ITEM TO TRASH", 0x221313, 0xFF3D00);
    }
}

fn renderCardBg(ctx: cocoa.CGContextRef, rect: cocoa.NSRect) void {
    const bg = cocoa.makeCGColor(0x13161F, 0.95);
    defer cocoa.CGColorRelease(bg);
    cocoa.CGContextSetFillColorWithColor(ctx, bg);
    cocoa.CGContextFillRect(ctx, rect);

    const border = cocoa.makeCGColor(0x222834, 0.9);
    defer cocoa.CGColorRelease(border);
    cocoa.CGContextSetStrokeColorWithColor(ctx, border);
    cocoa.CGContextSetLineWidth(ctx, 1.0);
    cocoa.CGContextStrokeRect(ctx, rect);
}

fn renderButton(ctx: cocoa.CGContextRef, rect: cocoa.NSRect, label: []const u8, bg_hex: u32, border_hex: u32) void {
    const bg = cocoa.makeCGColor(bg_hex, 0.95);
    defer cocoa.CGColorRelease(bg);
    cocoa.CGContextSetFillColorWithColor(ctx, bg);
    cocoa.CGContextFillRect(ctx, rect);

    const border = cocoa.makeCGColor(border_hex, 0.9);
    defer cocoa.CGColorRelease(border);
    cocoa.CGContextSetStrokeColorWithColor(ctx, border);
    cocoa.CGContextSetLineWidth(ctx, 1.2);
    cocoa.CGContextStrokeRect(ctx, rect);

    cocoa.drawStringWithColor(label, rect.x + 20.0, rect.y + 10.0, 0.90, 0.93, 0.96, 1.0);
}

fn onSidebarMouseDown(self: cocoa.id, _: cocoa.SEL, event: cocoa.id) callconv(.c) void {
    const state = global_ui_state orelse return;
    const sel_location = cocoa.sel_registerName("locationInWindow");
    const F_loc = *const fn (cocoa.id, cocoa.SEL) callconv(.c) cocoa.NSPoint;
    const window_point = @as(F_loc, @ptrCast(&cocoa.objc_msgSend))(event, sel_location);

    const sel_convertPoint = cocoa.sel_registerName("convertPoint:fromView:");
    const click_point = cocoa.sendConvertPointFromView(self, sel_convertPoint, window_point, null);
    const bounds = cocoa.sendGetRect(self, sel_bounds);

    if (state.scan_state == .idle or (state.root_node == null and state.drill_node == null)) {
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

    const card_x: f64 = 18.0;
    const card_w: f64 = bounds.w - 36.0;
    const target = state.selected_node orelse (state.drill_node orelse state.root_node.?);

    // Action 1: Copy Path
    const act1_y = bounds.h - 410.0;
    if (click_point.x >= card_x and click_point.x <= card_x + card_w and
        click_point.y >= act1_y and click_point.y <= act1_y + 36.0)
    {
        cocoa.copyToClipboard(target.path);
        return;
    }

    // Action 2: Trash item
    const act2_y = bounds.h - 456.0;
    if (click_point.x >= card_x and click_point.x <= card_x + card_w and
        click_point.y >= act2_y and click_point.y <= act2_y + 36.0)
    {
        if (!target.protection.isProtected()) {
            if (state.trash_node_fn) |trash| trash(target);
        }
        return;
    }
}

fn onSidebarScrollWheel(self: cocoa.id, _: cocoa.SEL, event: cocoa.id) callconv(.c) void {
    const state = global_ui_state orelse return;
    const sel_deltaY = cocoa.sel_registerName("scrollingDeltaY");
    const F_delta = *const fn (cocoa.id, cocoa.SEL) callconv(.c) f64;
    const dy = @as(F_delta, @ptrCast(&cocoa.objc_msgSend))(event, sel_deltaY);

    state.sidebar_scroll_offset_y = @max(0.0, state.sidebar_scroll_offset_y - dy);
    cocoa.sendVoidBool(self, sel_setNeedsDisplay, true);
}

// --- Presets Helper --------------------------------------------------------

fn renderPresetsGrid(ctx: cocoa.CGContextRef, bounds: cocoa.NSRect, state: *const UIState, start_y: f64) void {
    const card_w: f64 = (bounds.w - 72.0 - 16.0) / 2.0;
    const card_h: f64 = 52.0;
    const col1_x: f64 = 36.0;
    const col2_x: f64 = 36.0 + card_w + 16.0;
    const row1_y: f64 = start_y - card_h;
    const row2_y: f64 = row1_y - card_h - 12.0;
    const row3_y: f64 = row2_y - 42.0;
    const row3_w: f64 = card_w * 2.0 + 16.0;

    const cur_target = state.getTargetPath();
    const in_dl = std.mem.endsWith(u8, cur_target, "Downloads");
    renderPresetCard(ctx, col1_x, row1_y, card_w, card_h, "📥  Downloads Folder", "~/Downloads • DMGs, ZIPs, installers", in_dl);

    const in_proj = std.mem.endsWith(u8, cur_target, "LocalBuilds") or std.mem.endsWith(u8, cur_target, "Projects");
    renderPresetCard(ctx, col2_x, row1_y, card_w, card_h, "💼  Developer Projects", "~/LocalBuilds • Node_modules, build artifacts", in_proj);

    const in_apps = std.mem.eql(u8, cur_target, "/Applications");
    renderPresetCard(ctx, col1_x, row2_y, card_w, card_h, "💻  System Applications", "/Applications • Installed app bundles", in_apps);

    const in_home = !in_dl and !in_proj and !in_apps and (std.mem.startsWith(u8, cur_target, "/Users/") or std.mem.eql(u8, cur_target, "~"));
    renderPresetCard(ctx, col2_x, row2_y, card_w, card_h, "🏠  User Home Profile", "~/ • Full user profile & caches", in_home);

    const r5_rect = cocoa.NSRect.init(col1_x, row3_y, row3_w, 38.0);
    renderButton(ctx, r5_rect, "📁  Browse Custom Folder or External Drive... (⌘O)", 0x141824, 0x00E5FF);
}

fn handlePresetsClick(click_point: cocoa.NSPoint, bounds: cocoa.NSRect, state: *UIState, start_y: f64) void {
    const card_w: f64 = (bounds.w - 72.0 - 16.0) / 2.0;
    const card_h: f64 = 52.0;
    const col1_x: f64 = 36.0;
    const col2_x: f64 = 36.0 + card_w + 16.0;
    const row1_y: f64 = start_y - card_h;
    const row2_y: f64 = row1_y - card_h - 12.0;
    const row3_y: f64 = row2_y - 42.0;
    const row3_w: f64 = card_w * 2.0 + 16.0;

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
        click_point.y >= row3_y and click_point.y <= row3_y + 38.0)
    {
        if (state.choose_target_fn) |f| f();
        return;
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

// --- 6. StatusView: Metrics & Daemon Indicator -----------------------------

fn drawStatusRect(self: cocoa.id, _: cocoa.SEL, dirty: cocoa.NSRect) callconv(.c) void {
    _ = dirty;
    const ctx = cocoa.getCurrentGraphicsContext() orelse return;
    cocoa.CGContextSaveGState(ctx);
    defer cocoa.CGContextRestoreGState(ctx);

    const bounds = cocoa.sendGetRect(self, sel_bounds);

    const bg_color = cocoa.makeCGColor(0x08090D, 1.0);
    defer cocoa.CGColorRelease(bg_color);
    cocoa.CGContextSetFillColorWithColor(ctx, bg_color);
    cocoa.CGContextFillRect(ctx, bounds);

    const line_color = cocoa.makeCGColor(0x282C37, 0.7);
    defer cocoa.CGColorRelease(line_color);
    cocoa.CGContextSetStrokeColorWithColor(ctx, line_color);
    cocoa.CGContextSetLineWidth(ctx, 1.0);
    cocoa.CGContextBeginPath(ctx);
    cocoa.CGContextMoveToPoint(ctx, 0, bounds.h);
    cocoa.CGContextAddLineToPoint(ctx, bounds.w, bounds.h);
    cocoa.CGContextDrawPath(ctx, 2);

    const state = global_ui_state orelse return;
    cocoa.drawStringWithColor(state.status_text, 18, bounds.h / 2.0 - 7.0, 0.85, 0.88, 0.92, 1.0);

    const pill_color = if (state.daemon_enabled)
        cocoa.makeCGColor(0x00E676, 0.9)
    else
        cocoa.makeCGColor(0x5A6472, 0.7);
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
    state.scroll_offset_y = 0.0;
    if (state.active_tab == .dedup_studio and state.dedup_clusters == null and state.root_node != null) {
        state.refreshDedup();
    }
    if (state.active_tab == .quick_wins and state.quick_wins == null and state.root_node != null) {
        state.refreshQuickWins();
    }
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

    // 2. ZSpaceStageView (Main Stage)
    if (cocoa.objc_getClass("ZSpaceStageView") == null) {
        const cls = cocoa.objc_allocateClassPair(NSView, "ZSpaceStageView", 0);
        _ = cocoa.class_addMethod(cls, sel_drawRect, @ptrCast(&drawStageRect), "v@:{CGRect=dddd}");
        _ = cocoa.class_addMethod(cls, sel_mouseDown, @ptrCast(&onStageMouseDown), "v@:@");
        _ = cocoa.class_addMethod(cls, sel_scrollWheel, @ptrCast(&onStageScrollWheel), "v@:@");
        cocoa.objc_registerClassPair(cls);
    }

    // 3. ZSpaceSidebarView (Inspector)
    if (cocoa.objc_getClass("ZSpaceSidebarView") == null) {
        const cls = cocoa.objc_allocateClassPair(NSView, "ZSpaceSidebarView", 0);
        _ = cocoa.class_addMethod(cls, sel_drawRect, @ptrCast(&drawSidebarRect), "v@:{CGRect=dddd}");
        _ = cocoa.class_addMethod(cls, sel_mouseDown, @ptrCast(&onSidebarMouseDown), "v@:@");
        _ = cocoa.class_addMethod(cls, sel_scrollWheel, @ptrCast(&onSidebarScrollWheel), "v@:@");
        cocoa.objc_registerClassPair(cls);
    }

    // 4. ZSpaceWorkspaceRailView
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
