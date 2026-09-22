//! cocoa.zig — Complete typed Objective-C runtime & AppKit/CoreGraphics bindings for ZSpace.
//!
//! Rule C01: Variadic `objc_msgSend` direct calls are banned. Every call site casts
//! to the exact function pointer signature. On arm64, structs like NSRect/CGRect are passed
//! by value in registers (d0-d3).

const std = @import("std");

// --- Objective-C Runtime Raw Declarations -----------------------------------

pub const id = ?*anyopaque;
pub const Class = ?*anyopaque;
pub const SEL = ?*anyopaque;
pub const IMP = ?*const anyopaque;

pub extern "c" fn objc_getClass(name: [*:0]const u8) Class;
pub extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
pub extern "c" fn objc_msgSend(...) id;
pub extern "c" fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extraBytes: usize) Class;
pub extern "c" fn class_addMethod(cls: Class, name: SEL, imp: IMP, types: [*:0]const u8) bool;
pub extern "c" fn class_addIvar(cls: Class, name: [*:0]const u8, size: usize, alignment: u8, types: [*:0]const u8) bool;
pub extern "c" fn objc_registerClassPair(cls: Class) void;
pub extern "c" fn object_setInstanceVariable(obj: id, name: [*:0]const u8, value: ?*anyopaque) ?*anyopaque;
pub extern "c" fn object_getInstanceVariable(obj: id, name: [*:0]const u8, outValue: *?*anyopaque) ?*anyopaque;
pub extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
pub extern "c" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;

// --- Geometric Types (Darwin arm64/x86_64 ABI compliant) -------------------

pub const NSPoint = extern struct {
    x: f64,
    y: f64,
};

pub const NSSize = extern struct {
    w: f64,
    h: f64,
};

pub const NSRect = extern struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,

    pub fn init(x: f64, y: f64, w: f64, h: f64) NSRect {
        return .{ .x = x, .y = y, .w = w, .h = h };
    }
};

pub const CGPoint = NSPoint;
pub const CGSize = NSSize;
pub const CGRect = NSRect;

// --- CoreGraphics & Quartz C FFI -------------------------------------------

pub const CGContextRef = ?*anyopaque;
pub const CGColorRef = ?*anyopaque;
pub const CGPathRef = ?*anyopaque;
pub const CGColorSpaceRef = ?*anyopaque;

pub extern "c" fn CGColorSpaceCreateDeviceRGB() CGColorSpaceRef;
pub extern "c" fn CGColorSpaceRelease(space: CGColorSpaceRef) void;
pub extern "c" fn CGColorCreate(space: CGColorSpaceRef, components: [*]const f64) CGColorRef;
pub extern "c" fn CGColorRelease(color: CGColorRef) void;

pub extern "c" fn CGContextSaveGState(c: CGContextRef) void;
pub extern "c" fn CGContextRestoreGState(c: CGContextRef) void;
pub extern "c" fn CGContextSetFillColorWithColor(c: CGContextRef, color: CGColorRef) void;
pub extern "c" fn CGContextSetStrokeColorWithColor(c: CGContextRef, color: CGColorRef) void;
pub extern "c" fn CGContextSetLineWidth(c: CGContextRef, width: f64) void;
pub extern "c" fn CGContextFillRect(c: CGContextRef, rect: CGRect) void;
pub extern "c" fn CGContextStrokeRect(c: CGContextRef, rect: CGRect) void;
pub extern "c" fn CGContextFillEllipseInRect(c: CGContextRef, rect: CGRect) void;
pub extern "c" fn CGContextStrokeEllipseInRect(c: CGContextRef, rect: CGRect) void;
pub extern "c" fn CGContextBeginPath(c: CGContextRef) void;
pub extern "c" fn CGContextMoveToPoint(c: CGContextRef, x: f64, y: f64) void;
pub extern "c" fn CGContextAddLineToPoint(c: CGContextRef, x: f64, y: f64) void;
pub extern "c" fn CGContextAddArc(c: CGContextRef, x: f64, y: f64, radius: f64, startAngle: f64, endAngle: f64, clockwise: c_int) void;
pub extern "c" fn CGContextClosePath(c: CGContextRef) void;
pub extern "c" fn CGContextDrawPath(c: CGContextRef, mode: c_int) void; // 0 = fill, 1 = eoFill, 2 = stroke, 3 = fillStroke

pub extern "c" fn NSGraphicsContextCurrentContext() id;

// --- Grand Central Dispatch (GCD) ------------------------------------------

pub extern "c" var _dispatch_main_q: anyopaque;

pub inline fn dispatch_get_main_queue() ?*anyopaque {
    return &_dispatch_main_q;
}

pub extern "c" fn dispatch_get_global_queue(identifier: isize, flags: usize) ?*anyopaque;
pub extern "c" fn dispatch_async_f(queue: ?*anyopaque, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;

// --- Typed Dispatch Wrappers ----------------------------------------------

pub inline fn send0(target: id, sel: SEL) id {
    const F = *const fn (id, SEL) callconv(.c) id;
    return @as(F, @ptrCast(&objc_msgSend))(target, sel);
}

pub inline fn sendVoid0(target: id, sel: SEL) void {
    const F = *const fn (id, SEL) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(target, sel);
}

pub inline fn send1(target: id, sel: SEL, arg1: id) id {
    const F = *const fn (id, SEL, id) callconv(.c) id;
    return @as(F, @ptrCast(&objc_msgSend))(target, sel, arg1);
}

pub inline fn sendVoid1(target: id, sel: SEL, arg1: id) void {
    const F = *const fn (id, SEL, id) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(target, sel, arg1);
}

pub inline fn sendVoidBool(target: id, sel: SEL, flag: bool) void {
    const F = *const fn (id, SEL, u8) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(target, sel, if (flag) 1 else 0);
}

pub inline fn sendVoidInt(target: id, sel: SEL, val: isize) void {
    const F = *const fn (id, SEL, isize) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(target, sel, val);
}

pub inline fn sendInitRect(target: id, sel: SEL, rect: NSRect) id {
    const F = *const fn (id, SEL, NSRect) callconv(.c) id;
    return @as(F, @ptrCast(&objc_msgSend))(target, sel, rect);
}

pub inline fn sendInitWindow(target: id, sel: SEL, rect: NSRect, style: isize, backing: isize, defer_flag: u8) id {
    const F = *const fn (id, SEL, NSRect, isize, isize, u8) callconv(.c) id;
    return @as(F, @ptrCast(&objc_msgSend))(target, sel, rect, style, backing, defer_flag);
}

pub inline fn sendColor(cls: Class, sel: SEL, r: f64, g: f64, b: f64, a: f64) id {
    const F = *const fn (Class, SEL, f64, f64, f64, f64) callconv(.c) id;
    return @as(F, @ptrCast(&objc_msgSend))(cls, sel, r, g, b, a);
}

pub inline fn sendGetRect(target: id, sel: SEL) NSRect {
    const F = *const fn (id, SEL) callconv(.c) NSRect;
    return @as(F, @ptrCast(&objc_msgSend))(target, sel);
}

// --- Convenience Object Helpers --------------------------------------------

pub fn nsString(cstr: []const u8) id {
    const NSString = objc_getClass("NSString");
    const sel = sel_registerName("stringWithUTF8String:");
    // Allocate null-terminated string
    const z = std.heap.c_allocator.dupeZ(u8, cstr) catch return null;
    defer std.heap.c_allocator.free(z);
    const F = *const fn (Class, SEL, [*c]const u8) callconv(.c) id;
    return @as(F, @ptrCast(&objc_msgSend))(NSString, sel, z.ptr);
}

pub fn nsColor(r: f64, g: f64, b: f64, a: f64) id {
    const NSColor = objc_getClass("NSColor");
    const sel = sel_registerName("colorWithRed:green:blue:alpha:");
    return sendColor(NSColor, sel, r, g, b, a);
}

pub fn nsColorFromHex(hex: u32, alpha: f64) id {
    const r = @as(f64, @floatFromInt((hex >> 16) & 0xFF)) / 255.0;
    const g = @as(f64, @floatFromInt((hex >> 8) & 0xFF)) / 255.0;
    const b = @as(f64, @floatFromInt(hex & 0xFF)) / 255.0;
    return nsColor(r, g, b, alpha);
}

pub fn makeCGColor(hex: u32, alpha: f64) CGColorRef {
    const space = CGColorSpaceCreateDeviceRGB();
    defer CGColorSpaceRelease(space);
    const r = @as(f64, @floatFromInt((hex >> 16) & 0xFF)) / 255.0;
    const g = @as(f64, @floatFromInt((hex >> 8) & 0xFF)) / 255.0;
    const b = @as(f64, @floatFromInt(hex & 0xFF)) / 255.0;
    const components = [4]f64{ r, g, b, alpha };
    return CGColorCreate(space, &components);
}

pub fn getCurrentGraphicsContext() CGContextRef {
    const NSGraphicsContext = objc_getClass("NSGraphicsContext");
    const sel_currentContext = sel_registerName("currentContext");
    const sel_CGContext = sel_registerName("CGContext");
    const ctx = send0(NSGraphicsContext, sel_currentContext);
    if (ctx == null) return null;
    const F = *const fn (id, SEL) callconv(.c) CGContextRef;
    return @as(F, @ptrCast(&objc_msgSend))(ctx, sel_CGContext);
}

pub fn drawStringAtPoint(text: []const u8, x: f64, y: f64) void {
    const str = nsString(text) orelse return;
    const sel_drawAtPoint = sel_registerName("drawAtPoint:withAttributes:");
    const F = *const fn (id, SEL, NSPoint, id) callconv(.c) void;
    @as(F, @ptrCast(&objc_msgSend))(str, sel_drawAtPoint, .{ .x = x, .y = y }, null);
}

