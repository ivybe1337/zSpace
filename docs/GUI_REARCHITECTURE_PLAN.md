# zSpace GUI Re-architecture Plan — Pure-Zig Native AppKit

**Status:** Authoritative for all GUI work. Companion to `docs/MASTER_PLAN.md`.
**Date:** 2026-09-22. **Toolchain:** Zig 0.16, macOS 12+ arm64/x86_64.
**Policy: pure Zig only. No Swift. No ObjC source files. No Tauri.
No WKWebView. No HTML/CSS/JS anywhere in the product.**

This file reconciles `docs/MASTER_PLAN.md`, `legacy/docs/*`, and every user
override from review. Any agent picking this up must be able to execute with
zero open questions. When this file and MASTER_PLAN disagree on GUI matters,
this file wins until its contents are merged back into MASTER_PLAN.

---

## 0. Non-negotiable user overrides (highest authority)

U1. **The HTML/WKWebView GUI is dead.** `src/gui/index.html` is deleted, not
    refactored. No web view ever hosts product UI again.
U2. **No Swift, no Tauri, no ObjC files.** AppKit is driven from Zig via
    `@cImport` + C01 typed `objc_msgSend` casts only.
U3. **The GUI must actually open and show real content.** Blank window =
failure. First paint shows either live scan results or an explicit
empty-state with one obvious call to action.
U4. **Dark, professional, futuristic.** Obsidian theme (D2 tokens). No light
    mode work until the dark UI is finished.
U5. **Granular control over everything.** Nothing consequential happens without
    an explicit, inspectable, reversible user action:
    scan inclusion + exclusion lists (paths, keywords, glob patterns);
    per-scan overrides; dedup inclusion/exclusion + bloom-filter size +
    min-size; quick-win accept/deny per item; `trash 2,3,5` list syntax;
    checkboxes + arrow keys + number keys.
U6. **Daemon is optional and cheap.** Fully disableable. Zero storage by
    default. Any index cache is opt-in, bounded, inspectable, and deletable
    from the GUI. The app must work perfectly with the daemon off.
U7. **Daemon mini-menu.** Background activity (scan/index progress, last run,
    next run, errors) is visible and controllable from a mini-menu in the GUI.
U8. **Guided UI.** Every destructive or confusing control gets a tooltip; a
    first-run help overlay plus a permanent `?` help entry explain
    Scan / Visualize / Clean / Dedup in plain language.
U9. **Small, fast binary.** No framework bloat. Frameworks: Cocoa,
    QuartzCore, CoreGraphics. WebKit and Metal are REMOVED from build.zig.
    (The 3D isometric view in `visualizer3d.zig` is CPU-projected ASCII art;
    it needs no Metal.)
---

## 1. What is true today (verified, not assumed)

- `zig build` green; `zig build test --summary all` 13/13. Source: MASTER_PLAN §2.
- GUI today = `src/gui/app.zig` hosting WKWebView + `src/gui/index.html`
  (~48KB web UI with mock/placeholder data). To be fully replaced.
- `build.zig` links Cocoa, Metal, QuartzCore, CoreGraphics, WebKit.
  After this plan: Cocoa, QuartzCore, CoreGraphics only.
- Real engine modules: `src/core/{scanner,cleaner,dedup,analyzer,classifier,
  apfs,snapshot}.zig`, `src/cli/cli.zig`, `src/repl/repl.zig`, `src/mcp/mcp.zig`.
- GUI layout math exists and is KEEP: `src/gui/treemap.zig` (TreemapLayout),
  `src/gui/sunburst.zig` (SunburstLayout + hitTest),
  `src/gui/visualizer3d.zig` (CPU isometric projection; TUI/REPL ASCII only).
- `src/gui/theme.zig` (Palette) and `src/gui/tooltips.zig` (TooltipTopic) are
  KEEP as the single token/content source.
- C01 typed objc_msgSend wrappers live in `src/gui/app.zig`. They move to
  `cocoa.zig` (or a new `objc.zig`) and are extended — never duplicated.
- Nothing in the GUI may shell out, fetch network, or use SQLite. No index
  cache exists yet; G-16 gate defines Option B. Default stays memory-only.
---

## 2. Target architecture (final)

```
zspace gui <dir> [--flags...]
  -> src/cli/cli.zig parses flags into ScanRequest (see section 6)
  -> scanner runs on background thread (GCD global queue via dispatch_async_f)
  -> progress callbacks throttle to 10 Hz, main-thread UI update only
  -> DiskNode tree (arena-owned) + flat result rows + dup clusters + wins
  -> GUI renders from ONE Snapshot struct (section 6), never from mocks
```

### 2.1 New/changed files

| File | Action | Contents |
|------|--------|----------|
| `src/gui/index.html` | DELETE | Gone. No replacement. |
| `src/gui/cocoa.zig` | EXTEND (keep existing helpers) | All ObjC/CG/NS imports; NSRect/NSPoint/NSSize/CGRect/CGPoint/CGSize extern structs; every typed send wrapper; NSView-subclass factory (allocateClassPair/addMethod/registerClassPair); NSString/NSColor/NSFont helpers; NSTrackingArea + tooltip helper; dispatch_async_f extern decls. |
| `src/gui/components.zig` | CREATE | All NSView subclasses + drawRect/mouse/key handlers + controllers (sections 3-4). |
| `src/gui/native.zig` | CREATE | NSApplication+NSWindow setup; view-hierarchy assembly; scan orchestration (background thread -> main-thread UI update); menubar; statusline; help overlay wiring; runloop. Replaces `src/gui/app.zig` as the GUI entry. |
| `src/gui/app.zig` | REPLACE with thin re-export | `pub const run = native.runGui;` (+ keep C01 note pointer). Old WKWebView code deleted. |
| `src/gui/theme.zig` | KEEP (minor extend) | Add selection/hover/disabled/border tokens if missing; no value changes to D2. |
| `src/gui/tooltips.zig` | KEEP + EXTEND | Add topics: scan_exclusions, dedup_bloom, daemon_minimenu, quickwin_accept_deny, trash_syntax, treemap_drill, sunburst_drill. |
| `src/gui/{treemap,sunburst,visualizer3d}.zig` | KEEP | Layout math reused by components.zig. No API break. |
| `build.zig` | EDIT | Remove WebKit + Metal frameworks. Keep Cocoa, QuartzCore, CoreGraphics. No other change. |
| `src/cli/cli.zig` | EXTEND | Add flags from section 6 table (no behavior change to existing flags). |
| `src/repl/repl.zig` | EXTEND (optional P1) | Expose same exclusion/dedup controls as slash-commands. |
| `docs/MASTER_PLAN.md` | UPDATE after GUI lands | D1 rewritten (no webview), G-10/G-11/G-12 gates rewritten, new G-18/G-19 GUI gates. See section 9. |
---

## 3. Window layout (1320x860 default, min 960x600, resizable)

```
+------------------------------------------------------------------+
| HEADER 54px: jewel zSpace | Spacetime Disk Intelligence | status |?|
+------------------------------------------------------------------+
| TOOLBAR 44px: [Mode v] [Path............] [Browse] [Scan Now]    |
|   threshold: [--o--] >=100MB   [Exclusions] [Dedup opts]        |
+----------------------------------+-------------------------------+
| VISUAL STACK (left, flex)        | SIDEBAR (right, fixed 420px)  |
| + sunburst 240px (CALayer glow)  | Mode tabs: Files|Dupes|Wins |
| + treemap flex (CG tiles+labels) | rows: [x] icon name size badge|
| + hintline 22px                  | footer: [All][None] [Trash..] |
+----------------------------------+-------------------------------+
| STATUS 30px: phase items/bytes ... | cmd input [trash 2,3,5....] |
|   [Daemon: OFF v] [index: off] [last:--] [help ?] [settings]    |
+------------------------------------------------------------------+
```

### 3.1 Regions and responsibilities

H1 HeaderView: brand jewel (pulsing CALayer dot #00E5FF) + title NSTextField
   + status text (Ready/Scanning n% (files, MB/s)/Done/Truncated/Cancelled/
   Error) + daemon pill + (?) help button. Drawn bg: obsidian gradient
   #08090D->#101216 + 1px hairline rgba(255,255,255,0.08) bottom.
T1 ToolbarView: NSPopUpButton (Quick/Deep/Dupes/Cleanup), path NSTextField
   (editable, drag-drop accepts folders), Browse (NSOpenPanel
   directory-only), Scan Now (accent NSButton #FF6E40), threshold NSSlider
   1MB..1GB log-scale default 100MB + label, Exclusions button, Dedup button.
V1 SunburstView (custom NSView, layer-backed): SunburstLayout arcs ->
   CGContext wedge paths + category colors; hover ring highlight + tooltip;
   click sector drills in (root=sector node, breadcrumb push); click center
   core ascends; right-click ascends; glow = CABasicAnimation opacity pulse
   on active ring layer. Min tile: skip arcs with span < 0.025 rad (same
   rule as layout code).
V2 TreemapView (custom NSView, non-layered CG): TreemapLayout rects ->
   CGContextFillRect + hairline stroke; hover outline cyan; selection outline
   cyan 2.5px; labels via CTFont only when w>=64 and h>=22 (two lines:
   name truncated, size); click drills; right-click ascends. Row-major manual
   clip: skip rects outside dirtyRect.
V3 Hintline (NSTextField, non-editable): 'Click sector/tile to drill in.
   Right-click to go up. Hover for details.' + current breadcrumb path.
S1 SidebarView: NSScrollView + custom RowsDrawView. Tabs Files/Dupes/Wins.
   Files tab: one row per top-N node (default 500, configurable 100..5000),
   sorted per mode; row = checkbox 16px + kind icon (drawn, no image assets)
   + name truncated + size right-aligned + category badge + age dot.
   Dupes tab: one section per cluster: header row (hash16, copies, wasted)
   + child rows per copy with checkboxes; [Clone via APFS] per cluster.
   Wins tab: quick-win items each with Accept/Deny checkbox + bytes + one-
   line why-safe text; [Select safe only] [Clear] buttons.
S2 Sidebar footer: [Select All] [Select None] [Trash Selected..] (opens
   confirm sheet listing count+bytes; executes clean_propose then clean_apply
   ONLY on confirm) + [APFS Dedup..] (dry-run preview sheet first) +
   [Undo Last] (undoByReceipt of last journal line).
F1 StatusView: left = phase + counts + throughput; right = Daemon pill
   (OFF gray / IDLE green / SCANNING orange + % / INDEXING blue / ERROR red),
   index state (off / on path+bytes), last-run time, (?) help, gear settings.
   Clicking Daemon pill opens the mini-menu popover (section 5).
F2 Command input (NSTextField, bottom-right): accepts `trash 2,3,5`,
   `select 1-8`, `select safe`, `deny 3`, `drill <n>`, `up`, `help`. Enter
   parses; destructive entries ALWAYS show the confirm sheet; Esc clears.
M1 TooltipView: borderless NSPanel floating, obsidian bg + cyan 1px border +
   8px radius, auto-hides 4s or on mouse-exit. Content from TooltipTopic.
M2 HelpOverlayView: full-window dim + centered card with 4 panels
   (Scan/Visualize/Clean/Dedup) + [Get Started] [Skip]. First launch
   auto-shows (flag in ~/.zspace/config.json); (?) reopens.
M3 ConfirmSheet (NSAlert or custom sheet): used for EVERY destructive op.
   Shows exact count + bytes + first 10 paths + '... and N more'.
   Buttons: [Move to Trash] [Cancel]. Never a bare alert() with no action.
---

## 4. ObjC interop rules (C01 — no exceptions)

R1. Every objc_msgSend call site casts to the exact C signature. Variadic
    direct calls are banned. NSRect/NSPoint/NSSize/CGRect/CGPoint/CGSize go
    BY VALUE in registers (arm64). Never split into 4x f64 varargs.
R2. All wrappers live in cocoa.zig. components.zig and native.zig import them;
    no local extern objc_msgSend declarations elsewhere.
R3. NSView subclasses are created at runtime:
    objc_allocateClassPair(NSView) -> class_addMethod per selector ->
    objc_registerClassPair. Method impls are Zig `fn (id, SEL, ...) callconv(.c)`.
    Type encodings: drawRect: = `v@:{CGRect=dddd}`, mouse/key/event handlers =
    `v@:@`, viewDidMoveToWindow = `v@:`, initializers as needed. If a
    drawRect: does not fire, the encoding is the first suspect — verify with a
    log line before touching layout code.
R4. Target-action buttons: setTarget: to a runtime delegate object +
    setAction: to a registered selector. No polling. No timer-driven clicks.
R5. Text: static labels = NSTextField subviews (dark mode free). Canvas tile
    labels = CTFont + CGContextShowTextAtPoint. Path/command inputs =
    NSTextField (editable). Never hand-roll a text editor.
R6. Colors: NSColor colorWithRed:green:blue:alpha: (0..1 f64) for AppKit
    objects; CGColorCreate(deviceRGB, [r,g,b,a]) for CGContext fill/stroke.
    Convert from theme.zig hex via one shared helper; no inline hex math.
R7. Autoreleasepool wraps the whole GUI entry (push at top of runGui, pop
    after [NSApp run] returns). Convenience constructors (stringWithUTF8*)
    are autoreleased — never release them; alloc/init pairs get released or
    handed to a superview/window that owns them.
R8. Main-thread rule: ALL AppKit/CG view mutation + setNeedsDisplay happen on
    the main thread. Background thread touches only engine data + atomics.
    Violation = flaky crash. Enforced by dispatch_async_f to main queue.
---

## 5. Daemon + mini-menu + storage contract (U6/U7)

S1. Default state: daemon OFF, index cache OFF, bloom filter ON at 256KB
    in-memory only. Fresh install writes nothing except ~/.zspace/config.json
    on first settings change (and only then).
S2. No SQLite anywhere. Index cache format = versioned flat file
    (magic `ZSIX01`, header with root+mtime+counts, then node records) OR
    memory-only. File location default:
    ~/Library/Caches/ZSpace/index-<hash-of-root>.zsix. Bounded: max bytes
    setting (default 64MB); evict oldest-root-first when over budget.
    GUI shows exact path + bytes; [Forget index] deletes the file.
S3. Mini-menu contents (clicking Daemon pill): state line (Off/Idle/
    Scanning n% / Indexing n% / Error msg), last completed run (time +
    items + bytes + duration), next scheduled run (or 'manual only'),
    [Start now] [Stop] [Enable/Disable daemon] [Open index folder]
    [Forget index] [Settings..]. Every button works; no dead controls.
S4. Scheduler: GCD timer when app is running only. No launchd agent in v1.
    Interval configurable 1h..168h, default 24h. Missed runs do NOT catch up
    silently — status shows 'last run <time> (scheduled runs only while open)'.
S5. Kill-switch: [Disable daemon] stops timer, cancels in-flight work
    (<500ms), frees cache memory, and leaves zero background threads.
    App with daemon off must show zero CPU in Activity Monitor when idle
    (asserted in G-19 gate).
---

## 6. Data model: ONE Snapshot struct feeds every view

```zig
pub const ScanRequest = struct {
    root_path: []const u8,
    mode: enum { quick, deep, dupes, cleanup },
    min_size_bytes: u64 = 100 * 1024 * 1024,
    include_paths: []const []const u8 = &.{},   // empty = whole root
    exclude_paths: []const []const u8 = &.{},
    exclude_keywords: []const []const u8 = &.{} ,// match on basename lowercase
    exclude_globs: []const []const u8 = &.{} ,   // `*` and `?` only, no `{}`
    dedup_min_size: u64 = 4096,
    dedup_max_bytes: u64 = 1 << 40,              // cap per scan
    bloom_filter_bytes: u32 = 256 * 1024,        // 0 = disabled
    quickwin_accept: []const []const u8 = &.{} , // accepted win ids
    quickwin_deny: []const []const u8 = &.{} ,   // denied win ids (sticky)
};

pub const Snapshot = struct {
    root: *const DiskNode,            // arena-owned, never freed by GUI
    flat_rows: []const Row,           // top-N sorted per mode
    dup_clusters: []const DuplicateCluster,
    wins: []const QuickWin,
    stats: Stats,                     // items, bytes, dups, reclaim, truncated
    request_echo: ScanRequest,        // what produced this (shown in UI)
    truncated: bool,
};
```

CLI flags (extend cli.zig; table + json output both):
--mode quick|deep|dupes|cleanup --min-size 100MB --include <p> (repeatable)
--exclude <p> (repeatable) --exclude-keyword <k> (repeatable)
--exclude-glob <g> (repeatable) --dedup-min-size 4K --dedup-max-bytes 1T
--bloom-bytes 256K (0 disables) --accept-win <id> --deny-win <id>
--rows 500 --format table|json. Deny-wins persist to config.json (sticky).
---

## 7. Interaction spec (keyboard + mouse, final)

K1. Sidebar rows: Up/Down move focus; Space toggles checkbox; Enter opens
    confirm sheet for focused-or-checked set; 0-9 jump to row; / focuses the
    command input; Esc clears focus/selection.
K2. Treemap/sunburst: Left-click drills in; Right-click (or Cmd-click) goes
    up; hover shows tooltip; focus follows mouse (no click-to-focus needed).
K3. Command input grammar: `trash 2,3,5` | `select 1-8` | `select safe` |
    `deny <n>` | `drill <n>` | `up` | `help`. Destructive verbs ALWAYS
    route to the confirm sheet. `help` prints the grammar into the status
    line + opens Help overlay section.
K4. Every destructive action path (button, Enter, command, context menu)
    converges on ONE confirm function. No second implementation.
K5. Undo: [Undo Last] + `u` + REPL `u` all call cleaner.undoByReceipt on the
    newest journal line. Status line prints receipt id + restored path.
---

## 8. Build order (one green commit each; stop on red)

P1. build.zig: drop WebKit + Metal. `zig build` still green (GUI will fail
    at runtime until P4 — that is expected; no test may depend on GUI).
P2. cocoa.zig: imports + extern structs + ALL typed wrappers + subclass
    factory + NSString/NSColor/NSFont/tracking-area/dispatch helpers.
    Unit-testable pure helpers (hex convert, glob match) get tests here.
P3. components.zig skeleton: all six NSView subclasses with distinct flat
    background colors + labels, assembled in a window. Gate: window opens,
    six regions visible, resize works, close works, no crash on 5 open/close
    cycles. This proves R3/R4 before any real drawing.
P4. native.zig: NSApplication + NSWindow + hierarchy + menubar +
    empty-state (no scan yet) + help overlay + tooltip shell. Gate: first
    paint < 200ms, help opens/closes, tooltip shows on hover of header.
P5. Scan wiring: ScanRequest plumbing + background scan + progress +
    Snapshot build + sidebar Files tab with real rows. Gate: scan /tmp
    shows real rows; cancel works <500ms; truncated flag path exercised.
P6. Visuals: sunburst + treemap real drawing from Snapshot + drill/ascend +
    breadcrumb + hover tooltips. Gate: drill 3 deep + back to root, no leak
    growth across 20 drill cycles (leaks --atExit).
P7. Dupes + Wins tabs + dedup controls + quick-win accept/deny + sticky deny
    persistence. Gate: dupes tab matches `dedup --format=json` exactly.
P8. Destructive path: confirm sheet + clean_propose/apply + APFS preview +
    undo + status receipts. Gate: P0-8 regression (trash, quit, relaunch,
    undo restores Blake3-identical) driven FROM THE GUI.
P9. Exclusions UI + command input + keyboard map + status/daemon mini-menu +
    settings persistence. Gate: deny/exclude round-trips through config.json.
P10. app.zig replaced by re-export; index.html deleted; MASTER_PLAN updated
    (section 9); full G-01..G-19 matrix run. Gate: everything green.
