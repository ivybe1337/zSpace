//! app.zig — GUI entry re-export pointing to native.zig.
//!
//! Rule D1: WKWebView and HTML/JS frontend have been permanently replaced
//! by the pure-Zig native AppKit implementation in native.zig.

const std = @import("std");
const types = @import("../core/types.zig");
const native = @import("native.zig");

pub const runGuiApp = native.runGuiApp;
