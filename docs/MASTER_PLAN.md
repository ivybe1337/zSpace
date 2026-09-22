# ZSpace — Unified Master Plan & Complete Engineering Specification

**The Single Canonical Source of Truth.**  
Supersedes, merges, and completely reconciles:
- `docs/MASTER_PLAN.md` (v1.0 & v2.0)
- `docs/GUI_REARCHITECTURE_PLAN.md` (Native AppKit architecture & build order P1–P10)
- `legacy/docs/BUILD_LIST.md` (B-01 through B-12 build gates)
- `legacy/docs/IMPLEMENTATION_PLAN.md` (C01–C20 production improvements & X01–X10 paradigm shifts)
- In-thread directives (interactive selection specs, numbered trash, REPL shortcuts, pure-Zig mandate, daemon mini-menu)
- `README.md` (performance targets, memory architecture, safety invariants)

| Field | Canonical Value |
| :--- | :--- |
| **Project Root** | `/Users/joshua/LocalBuilds/Projects/zspace` |
| **Upstream Git** | `https://github.com/ivybe1337/zspace.git` (branch: `main`) |
| **Target Toolchain** | **Zig 0.16.0** (pinned & verified), macOS 12+ Darwin (`arm64` primary, `x86_64` supported) |
| **Language Policy** | **100% Pure Zig.** No Swift. No Objective-C source files (`.m`/`.mm`). No Tauri. No WebKit. No HTML, CSS, or JavaScript anywhere in the product. |
| **Current Baseline** | `zig build` clean; `zig build test --summary all` **13/13 passed**; CLI/TUI/REPL landed; native AppKit GUI & daemon pending. |

---

## 1. Non-Negotiable Invariants & Settled Architecture Decisions

These architectural decisions are permanently settled. Every implementation step must adhere to these rules without exception.

### 1.1 Language & Framework Sovereignty
* **D1 / U1 — Pure Zig Native AppKit, Permanently:** The GUI is an authentic macOS AppKit/CoreGraphics/QuartzCore application driven directly from Zig using `@cImport` and strict, typed `objc_msgSend` runtime function-pointer casts.
* **U2 — Zero WebKit / Zero Web Technologies:** `src/gui/index.html` is completely deleted. The previous WKWebView container and all HTML/CSS/JavaScript runtime bridges are permanently revoked.
* **U9 — Binary & Dependency Diet:** No framework bloat. `build.zig` links only `Cocoa`, `CoreGraphics`, `QuartzCore`, `CoreAnimation`, and `IOKit`. `WebKit` and `Metal` are eliminated from compilation.
* **D6 — POSIX & Zig 0.16 Normative Standard:** File traversal and low-level I/O execute through standard Darwin POSIX syscalls (`opendir`, `readdir`, `lstat`, `open`, `fstat`) via `@cImport`. Argv parsing uses `std.process.Init` with automatic stripping of macOS `-psn` launch parameters.

### 1.2 Destructive Safety & Rollback Guarantees
* **D3 — Journal as Ground Truth:** The file `~/Library/Application Support/ZSpace/journal.jsonl` is the sole authority for disk operations and undo. In-process memory is merely an ephemeral cache hydrated from disk at initialization.
* **D4 / K4 — Universal Trash & Reversibility:** No file is ever unlinked or deleted outright. All deletions route through `NSFileManager.trashItemAtURL` to generate standard macOS `.TrashInfo` metadata, preserving native Finder "Put Back" capability. Cross-volume deletions (`EXDEV`) fallback to atomic copy+unlink into the destination volume's `.Trashes`.
* **K5 / P0-8 — Instant Undo Across Process Lifecycles:** Every destructive operation generates a cryptographic receipt containing a Blake3 hash of the target. Running `undo <receipt>` or `U` restores the exact file blake3-identically, even across process restarts.
* **Root & Repository Protection Guard:** Cleanup operations strictly forbid targeting `/System`, `/usr`, `/bin`, `/sbin`, `/Library`, `/private/var/vm`, `/System/Volumes/*`, or root dotfiles. `.git` trees and active source repositories are treated as protected zones.

### 1.3 User Experience & Aesthetic Consistency
* **D2 / U4 — Obsidian Liquid Titanium Dark Theme:** Hardcoded dark-mode tokens:
  - Deep Obsidian Canvas: `#08090D` (NSWindow background), `#0D0D0D` (primary panels), `#1A1A1A` (card layers).
  - Electric Accents: Burnt Orange `#FF6E40` (primary scan/action), Aquamarine `#00E5FF` (intelligence/selection/drilling).
  - Safety Signals: Coral Red `#FF3D00` (waste/destructive), Emerald Green `#00E676` (safe zero-risk clean).
* **U5 — Radical Granular Control:** No automated heuristics ever mutate the filesystem without explicit, inspectable confirmation. The user controls:
  - Inclusion/exclusion lists by exact paths, lowercased basename keywords, and glob patterns (`*`, `?`).
  - Minimum size cutoffs and Bloom filter sizing.
  - Granular selection grammar (`trash 2,3,5`, `select 1-8`, `select safe`, `deny <n>`).
* **U8 — Plain-Language Guidance:** Every complex or destructive control includes a tooltip. First launch provides a dim-card help overlay explaining Scan, Visualize, Clean, and Dedup with zero technical jargon.

### 1.4 Background Daemon & Indexing Discipline
* **U6 / S1 — Default Off & Zero Idle Footprint:** The daemon is completely optional and disabled by default. A fresh install consumes zero background CPU and writes zero background files.
* **S2 — Flat-File Index Cache (No SQLite):** No SQLite runtime is bundled. The index cache format is a lean, versioned binary file (`ZSIX01`) stored at `~/Library/Caches/ZSpace/index-<hash>.zsix` (bounded to 64 MB default with oldest-root eviction).
* **U7 / S3 — Mini-Menu Control:** Daemon state and index caches are managed through a native status bar popover in the GUI showing exact age, size, items, and providing one-click `[Forget Index]` and `[Disable]` toggles.

---

## 2. Verified Baseline & P0 Defect Register

### 2.1 Proven Green Baseline
The following benchmarks and test suites are verified passing offline:
```bash
zig build                               # -> Clean build, exit 0, no warnings
zig build test --summary all            # -> 13/13 tests passed, ~0.9s, MaxRSS 22MB
```

### 2.2 Audited P0 Defect Fixes (Landed in Core Engine)
| # | Defect Identified | Root Cause | Implemented Resolution | Verification Gate |
| :--- | :--- | :--- | :--- | :--- |
| **P0-1** | `--select=safe` selected nothing | `runCleanCmd` passed a dummy closure returning `false`; `runWinsCmd` passed `null`. | Mask is constructed at the callsite via direct `risk == .Safe_ZeroRisk` evaluation. | Hermetic CLI test selecting only safe items. |
| **P0-2** | Journal ring buffer tail corruption | `readJournalTail` emitted `ring[0..len]`, ignoring head offset after wraparound; division by zero on `max_lines == 0`. | Wrap-aware emission starting strictly from `head`; explicit zero guard. | Test with 50 operations wrapping a 10-item ring. |
| **P0-3** | Smart-clean reported 0 B cleanable | `executeDashboard` summed `reclaimable_bytes`, which was unpopulated in `analyzer.zig`. | Summed `size_bytes` across verified candidates in both dashboard and TUI. | TUI and REPL display accurate non-zero cleanable totals. |
| **P0-4** | Duplicate CLI argument parsing arms | Two identical `--interactive` / `--select` blocks in `cli.zig` caused dead code. | Removed unreachable duplicate branch. | Clean single-pass argument tokenizer. |
| **P0-5** | Terminal selector broken arrow keys | Raw mode read blocked on arrow escape sequences; `c_cc` initialized with wrong length `[32]u8` instead of `[20]u8`. | 100ms `VTIME` probe only after ESC decoding `ESC [ A/B/C/D` with `EINTR` retry. | Interactive smoke test with arrow navigation. |
| **P0-6** | Competing selection models | Legacy `SelectableItem` structs in `cli.zig` conflicted with `tui_select.zig`. | Completely purged legacy structs; `tui_select.zig` is the single canonical model. | Unified selection parser for CLI and TUI. |
| **P0-7** | GUI rendered blank window | `sendStringWithUTF8` copied HTML into a 4 KB stack buffer, returning `null` for the 48 KB payload. | Replaced stack buffer with heap allocation via `c_allocator.dupeZ`. | (Superceded by Native AppKit migration). |
| **P0-8** | Undo failed after app restart | `undoByReceipt` only searched in-memory journal, which reset to empty upon restart. | Implemented `hydrateJournalFromDisk()` on startup; excludes already undone receipts. | Restart simulation test: prior session receipt remains undoable. |

---

## 3. The 20 Production Improvements (C-Series Matrix)

| ID | Title | Priority | Status | Architecture & Implementation Details |
| :--- | :--- | :---: | :---: | :--- |
| **C01** | **ObjC msgSend ABI Fix** | P0 | **DONE** | Typed function-pointer casting per selector; pass `NSRect`/`NSPoint` by value in registers; wrap GUI entry in autoreleasepool. |
| **C02** | **Pure-Zig Native AppKit GUI** | P0 | **READY** | Replaces former Swift/WebKit plan. Pure Zig dynamically registers AppKit classes via ObjC runtime; zero HTML. |
| **C03** | **Tier-2 Blake3 Dedup Verification** | P0 | **DONE** | 3-tier pipeline: T0 size grouping -> T1 64KB sparse edge hash -> T2 streaming Blake3 full-file verification. |
| **C04** | **Native Trash + Put-Back + JSONL** | P0 | **DONE** | Integrated with `NSFileManager.trashItemAtURL`; persistent audit journal in `Application Support`; instant undo. |
| **C05** | **Cancellable Background Scanner** | P0 | **DONE** | `scanBackground` thread worker with atomic cancellation; progress reporting throttled to 10 Hz; launch-to-window <200ms. |
| **C06** | **Standard CLI Machine Contract** | P0 | **DONE** | Pinned `--format=json\|table`, `--dry-run`, `-v`, `--min-size`. Deterministic exit codes: 0 (clean), 2 (usage), 3 (I/O error), 4 (security guard). |
| **C07** | **Memory-Bounded Streaming Scan** | P1 | **OPEN** | Prevents OOM when scanning root (`/`). LRU inode cache (256k entries); chunked arenas (10k nodes per page); skip sorting on directories > 5k items. |
| **C08** | **Error Taxonomy & FDA Onboarding** | P1 | **OPEN** | Granular classification: `EACCES`, `EPERM`, `ENOENT`, `ELOOP`. First-run Full Disk Access (FDA) onboarding card linking directly to System Settings. |
| **C09** | **Complete Elimination of GUI Mocks** | P1 | **READY** | Purge mock arrays in UI. All visual components (sunburst, treemap, sidebar) hydrate strictly from the unified `Snapshot` data model. |
| **C10** | **Interactive Terminal TUI** | P1 | **DONE** | Termios raw mode, `SIGWINCH` handling, arrow navigation, 1-5 tab switching, clean terminal restoration on exit. |
| **C11** | **Snapshot Save & Diff Engine** | P1 | **DONE** | `ZSNP2` binary format. Scans 100k files in <3s. Computes byte deltas (added, removed, grown, shrunk) with 1-byte granularity. |
| **C12** | **Hermetic Test Harness** | P1 | **DONE** | Tests run strictly within `std.testing.tmpDir` and isolated fixtures. Zero scanning of user home or system directories. |
| **C13** | **Codesigning, Notarization & DMG** | P1 | **OPEN** | Automated `build-app-bundle` step in `build.zig`; hardened runtime entitlements; `notarytool` integration; clean DMG packaging. |
| **C14** | **Structured Logging & Diagnostics** | P1 | **OPEN** | `os_log` integration under subsystem `io.zspace`; structured run log at `~/Library/Logs/ZSpace/runs.jsonl`; `zspace diagnose --bundle` command. |
| **C15** | **APFS Safety Rails & Reflink Guard** | P1 | **OPEN** | Verify `st_dev` equivalence before invoking `clonefile`; assert post-clone Blake3 match; report cross-device actions as `SKIP` rather than error. |
| **C16** | **Parallel Walker & SIMD Throughput** | P2 | **OPEN** | Multi-threaded work-stealing directory traversal; SIMD-accelerated Blake3 hashing; cooperative yielding hooks (`yield_every_dirs`). |
| **C17** | **First-Run UX & Optional Menubar** | P2 | **OPEN** | Zero-configuration initial onboarding; intuitive empty-state cards; optional lightweight status bar menubar monitor showing free disk percentage. |
| **C18** | **Accessibility & Dynamic Localization** | P2 | **OPEN** | VoiceOver accessibility labels for custom canvas elements; full keyboard navigation map; colorblind-safe visualizer palettes. |
| **C19** | **Filesystem Security Hardening** | P2 | **OPEN** | TOCTOU mitigation using `O_NOFOLLOW` and `fstat`; strict preservation of quarantine and extended attributes (`xattrs`); 10k-path fuzz test suite. |
| **C20** | **Reproducible Versioning & SBOM** | P2 | **OPEN** | Single-source `version.zig` generated via git describe; automated CycloneDX SBOM generation; conventional-commit changelog pipeline. |

---

## 4. The 10 Paradigm-Shifting Inventions (X-Series Matrix)

| ID | Feature Name | Core Innovation | Technical Architecture |
| :--- | :--- | :--- | :--- |
| **X01** | **Time-Travel Disk Explorer** | Disk tools show current state; ZSpace visualizes trajectory and growth over time. | Connects multiple `ZSNP2` snapshots into a local chronological delta graph. GUI timeline slider visualizes folder swelling and projects future growth (e.g. "DerivedData will consume 45 GB by December"). |
| **X02** | **APFS Zero-Block Reclaim** | Reclaims massive gigabytes without deleting a single file. | Identifies verified duplicate files and converts redundant copies into Copy-on-Write APFS clones (`clonefile`). Physical blocks are freed while all original paths and filenames remain fully intact. |
| **X03** | **Dormancy Futures & Compaction** | Transforms passive disk clutter into automated self-compacting storage. | Heuristic Temporal Entropy categorizes stale directories (>1yr unaccessed) into "Icebergs". Offers 1-click lossless zstd-19 compression into `.zarchive` containers with instant one-click stub restoration. |
| **X04** | **Storage Provenance Lens** | Reveals the origin story of every massive blob on disk. | Scrapes filesystem metadata (`kMDItemWhereFroms`), Homebrew receipts, package manifests, and Git remotes to reveal where files came from (e.g. "42 GB blob created by Docker Desktop v4.31 image pull"). |
| **X05** | **Infinite Undo Timeline** | Removes all anxiety and fear from disk cleanup. | Translates the JSONL journal into an interactive chronological activity feed. Every trash, clone, or archive action is displayed as an inspectable card with a 1-click [Restore] button. |
| **X06** | **Fleet Storage Lens** | Local-first storage telemetry across multiple development Macs. | Synchronizes encrypted snapshot diffs via iCloud Drive or Tailscale. Cross-compares storage waste across multiple machines (e.g. "Redundant Xcode caches detected across 3 Macs = 24 GB fleet waste"). |
| **X07** | **AI Agent Substrate (MCP Server)** | The first disk intelligence engine engineered for AI operators. | Full Model Context Protocol (MCP) server over stdio JSON-RPC. Enables coding agents to safely inspect disk trees, identify duplicate artifacts, and propose cleanups with cryptographic receipt IDs. |
| **X08** | **Heat-Death Sandbox Simulator** | Speculative execution sandbox for aggressive developer cleanup. | "What-if" slider allowing developers to simulate wiping build caches (`node_modules`, `target`, `DerivedData`). Previews exact space reclaimed and computes dependency re-installation times before applying. |
| **X09** | **Content Fingerprint Mesh** | Goes beyond identical bytes to find duplicate creative assets. | Employs perceptual image hashing (dHash/aHash) and code rolling-hash chunking to locate near-identical screenshots, multiple image exports, and duplicated library code. |
| **X10** | **Disk Carbon & Energy Ledger** | Translates stored gigabytes into electrical energy and carbon cost. | Models the continuous energy consumption of idle SSD cells, recurring Time Machine backups, and cloud storage tier costs. Calculates tangible savings (e.g. "Downgrade iCloud 2TB tier to 200GB tier saving $80/year"). |

---

## 5. Pure-Zig Native AppKit GUI Specification

### 5.1 Window Topology & Layout Hierarchy
Default dimensions: **1320 × 860 pt** (Minimum resizable bound: **960 × 600 pt**).

```
+---------------------------------------------------------------------------------------+
| HEADER (54px): Brand Jewel [ZSpace] | Status: Ready / Scanning (MB/s) | [Daemon Pill] | [?] |
+---------------------------------------------------------------------------------------+
| TOOLBAR (44px): [Mode v] [Root Path Input...] [Browse] [Scan Now] | Size Cutoff [==o==] |
|                 [Exclusions...] [Dedup Settings...]                                   |
+-----------------------------------------------------------+---------------------------+
| VISUALIZATION STACK (Flex-Left, min 540px)                | SIDEBAR (Fixed 420px)     |
| + Sunburst Canvas (240px fixed, CALayer glow, drill-down) | Mode Tabs: Files|Dupes|Wins|
| + Squarified Treemap Canvas (Flex fill, CoreGraphics)     | Flat Row View:            |
| + Breadcrumb & Navigation Hintline (22px)                 | [x] Icon Name Size Badge  |
|                                                           | Footer Actions:           |
|                                                           | [Select All] [Trash Sel.] |
+-----------------------------------------------------------+---------------------------+
| STATUS BAR (30px): Items Scanned | Throughput | Daemon Status | CLI Input: [trash 2,3,5] |
+---------------------------------------------------------------------------------------+
```

### 5.2 Component Structure & Subviews
* **HeaderView (`H1`):** Custom layer-backed view with radial gradient background. Features animated aquamarine status jewel (`CALayer`), scan phase readout, and Daemon status pill.
* **ToolbarView (`T1`):** Mode selector (`Quick`, `Deep`, `Dupes`, `Cleanup`), editable path field with drag-and-drop support, directory browser panel, and minimum size slider (1 MB to 1 GB logarithmic scale).
* **SunburstView (`V1`):** Custom `NSView` drawing concentric multi-ring arcs using CoreGraphics paths. Supports hover highlights, radial segment drilling (left-click), and hierarchy ascending (right-click / center-click).
* **TreemapView (`V2`):** High-performance CoreGraphics squarified treemap. Features category color fills, hover bounding boxes, selection highlights, and clipped dual-line typography (filename + formatted size).
* **SidebarView (`S1`):** Keyboard-navigable list containing three functional modes:
  - *Files Tab:* Top-N largest nodes with checkboxes, category badges, and file age indicators.
  - *Dupes Tab:* Grouped duplicate clusters displaying shared waste, copy paths, and 1-click APFS clone consolidation.
  - *Wins Tab:* Smart-cleanup candidates with safety rationales and sticky accept/deny toggles.
* **ConfirmSheet (`M3`):** Modal dialog intercepting all destructive operations. Displays item count, exact byte total, path preview list, and requires explicit confirmation.

### 5.3 Objective-C Runtime Interoperability Rules (C01 Compliant)
1. **R1 — Strict Typed Calls:** Every `objc_msgSend` invocation must cast to the precise C signature. NSRect, NSPoint, and NSSize structures are passed by value in CPU registers (`arm64`), never decomposed into varargs.
2. **R2 — Centralized Wrappers:** All runtime bindings, selector caches, and type encodings reside exclusively in `src/gui/cocoa.zig`.
3. **R3 — Dynamic Class Registration:** Custom `NSView` subclasses are constructed at initialization using `objc_allocateClassPair`, registered via `objc_registerClassPair`, with method implementations following `callconv(.c)`.
4. **R7 — Autoreleasepool Encapsulation:** The entire GUI lifecycle is wrapped in a top-level autorelease pool to guarantee zero memory leaks during event pumping.
5. **R8 — Main Thread Enforcement:** All AppKit view hierarchy mutations and `setNeedsDisplay` triggers occur strictly on the main thread via `dispatch_async_f`. Background scanner threads interact exclusively with thread-safe atomics.

---

## 6. Unified Data Model & CLI Grammar

### 6.1 Unified Core Structures
Every view (GUI, TUI, REPL, MCP) is driven by a single canonical data structure:

```zig
pub const ScanRequest = struct {
    root_path: []const u8,
    mode: enum { quick, deep, dupes, cleanup } = .deep,
    min_size_bytes: u64 = 100 * 1024 * 1024,
    include_paths: []const []const u8 = &.{},
    exclude_paths: []const []const u8 = &.{},
    exclude_keywords: []const []const u8 = &.{},
    exclude_globs: []const []const u8 = &.{},
    dedup_min_size: u64 = 4096,
    dedup_max_bytes: u64 = 1 << 40,
    bloom_filter_bytes: u32 = 256 * 1024,
    quickwin_accept: []const []const u8 = &.{},
    quickwin_deny: []const []const u8 = &.{},
};

pub const Snapshot = struct {
    root: *const DiskNode,
    flat_rows: []const Row,
    dup_clusters: []const DuplicateCluster,
    wins: []const QuickWin,
    stats: Stats,
    request_echo: ScanRequest,
    truncated: bool,
};
```

### 6.2 CLI & REPL Command Grammar
* `zspace scan <path> [--mode <m>] [--min-size <bytes>] [--exclude-glob <pattern>]`
* `zspace clean <path> [--select=<spec>] [--dry-run] [--interactive]`
* `zspace dedup <path> [--consolidate] [--min-size <bytes>] [--dry-run]`
* `zspace snapshot save <path> -o <file.zsnap>`
* `zspace snapshot diff <a.zsnap> <b.zsnap> [--format=json]`
* `zspace history [--undo <receipt-id>]`
* `zspace tui <path>`
* `zspace gui <path>`
* `zspace mcp` (stdio JSON-RPC server)

**Interactive Grammar (CLI / GUI Bottom Bar / REPL):**
* `trash 1,2,5` — Move items 1, 2, and 5 to Trash.
* `select 1-10` — Select range of items.
* `select safe` — Automatically select all zero-risk smart-cleanup candidates.
* `deny 3` — Persist item 3 to sticky exclusion list.
* `u <receipt>` / `U` — Revert operation by receipt ID or revert most recent deletion.

---

## 7. AI Agent Substrate (`zspace-mcp` & Skill Package)

ZSpace serves as a foundational substrate for autonomous coding agents via a standardized Model Context Protocol (MCP) server.

### 7.1 MCP Server Protocol Specifications
* **Transport:** Stdio newline-delimited JSON-RPC 2.0.
* **Security Model:**
  - Read-only operations (`scan`, `dedup`, `history`, `snapshot`, `index_status`) execute immediately.
  - Destructive tools (`clean_propose`, `clean_apply`) enforce a mandatory two-phase commit: `clean_propose` produces an inspectable receipt proposal with zero side effects; `clean_apply` requires explicit `allow_write: true` and issues a permanent audit receipt.
  - **Prompt Injection Defense:** All filesystem paths are emitted strictly within JSON data fields and sanitized to prevent instruction hijacking.

### 7.2 Portable Skill Bundle (`skills/zspace/`)
A self-contained agent skill package containing:
- `SKILL.md`: Standard instructions detailing ZSpace capabilities, safety constraints, and JSON-RPC tool schemas.
- `scripts/`: Direct wrapper utilities enabling command-line execution by agentic workflows.

---

## 8. Complete Phased Build Order (P1 – P10)

Execution proceeds sequentially. Each step requires a green build and zero test regressions before advancing.

```
P1: build.zig Clean Framework Linkage
    └── P2: cocoa.zig Typed ObjC & CoreGraphics Bindings
        └── P3: components.zig Native NSView Subclasses Skeleton
            └── P4: native.zig NSApplication, Window & Menu Assembly
                └── P5: Background Scan Engine & Snapshot Plumbing
                    └── P6: CoreGraphics Sunburst & Treemap Visualizers
                        └── P7: Deduplication & Quick-Wins Functional Tabs
                            └── P8: Destructive Pipeline, Modal Sheet & Receipts
                                └── P9: Filter Controls, Keyboard Grammar & Daemon Menu
                                    └── P10: Deprecation of Legacy Code & Final Verification
```

### Milestone Specifications
* **Phase P1 (Build Configuration):** Update `build.zig` to link `Cocoa`, `CoreGraphics`, `QuartzCore`, `CoreAnimation`, and `IOKit`. Purge `WebKit` and `Metal`. Verify `zig build` compiles cleanly.
* **Phase P2 (Runtime Bridge):** Create `src/gui/cocoa.zig`. Define typed function-pointer wrappers for `objc_msgSend`, `NSRect` structures, runtime class allocation helpers, and CoreGraphics drawing utilities.
* **Phase P3 (Component Skeletons):** Implement `src/gui/components.zig`. Construct dynamic `NSView` subclasses (`HeaderView`, `ToolbarView`, `SunburstView`, `TreemapView`, `SidebarView`, `StatusView`) with distinct background fills to verify layout geometry.
* **Phase P4 (Window & Lifecycle):** Build `src/gui/native.zig`. Construct `NSApplication`, menubar menus, main window, and initialize event runloop. Verify clean window presentation in under 200ms.
* **Phase P5 (Engine Plumbing):** Wire `ScanRequest` and `scanBackground` into `native.zig`. Marshal progress events to the main thread via `dispatch_async_f` and construct the `Snapshot` model.
* **Phase P6 (Visualizer Implementation):** Integrate mathematical layout engines from `sunburst.zig` and `treemap.zig` into native CoreGraphics drawing pipelines with hover rings and click-to-drill interaction.
* **Phase P7 (Sidebar Workflows):** Implement `Files`, `Dupes`, and `Wins` tabs with custom drawn checkbox rows, category badges, and APFS clone actions.
* **Phase P8 (Safety & Confirmations):** Connect the `ConfirmSheet` modal to `clean_propose` and `clean_apply`. Verify that trashing files generates audit journal lines and that undoing restores files identically.
* **Phase P9 (Granular Filtering & Daemon):** Implement exclusion rules, keyboard shortcuts, bottom-bar command input, and the daemon popover mini-menu.
* **Phase P10 (Final Polish & Cleanup):** Permanently delete `src/gui/index.html`. Replace `src/gui/app.zig` with a re-export pointing to `native.zig`. Run the complete G-01 through G-19 verification suite.

---

## 9. Comprehensive Verification Matrix (G-01 through G-19)

**Stop on Red.** No phase may advance if its corresponding gate fails.

| Gate | Target Domain | Execution Command | Pass Verification Criteria |
| :---: | :--- | :--- | :--- |
| **G-01** | Toolchain Pin | `zig version` | Outputs exactly `0.16.0`. |
| **G-02** | Clean Build | `zig build` | Exit code 0 with zero warnings. |
| **G-03** | Unit Test Suite | `zig build test --summary all` | All unit tests pass offline (minimum 13 tests). |
| **G-04** | CLI Machine Contract | `zspace scan ~ --format=json \| jq .` | Valid JSON parse; exit code 0; `-psn` flags stripped. |
| **G-05** | Destructive Safety | `zspace clean <dir> --dry-run` | Zero filesystem mutation; journal records dry-run status. |
| **G-06** | Persistent Undo | Trash a file, kill process, run `zspace undo <id>` | File restored with identical Blake3 hash across process restart. |
| **G-07** | Selection Grammar | `zspace clean <dir> --select=safe` | Evaluates and selects only zero-risk items; invalid input errors safely. |
| **G-08** | Snapshot Roundtrip | `snapshot save` ×2, mutate 1 byte, `snapshot diff` | 100k files scanned <3s; exactly 1-byte delta detected. |
| **G-09** | TUI & REPL Smoke | `zspace tui <dir>`; `zspace repl <dir>` | Terminal raw mode clean; `q` restores screen without escape artifacting. |
| **G-10** | ObjC ABI & Leaks | 100-launch stress loop; `leaks --atExit -- zspace gui` | Zero crashes, zero `EXC_BAD_ACCESS`, zero memory leaks reported. |
| **G-11** | Zero GUI Mocks | `grep -rn "alert(" src/gui/` | Zero results. All UI states hydrate from `Snapshot`. |
| **G-12** | Theme Adherence | Verify color constants against D2 specification | Obsidian `#08090D`, Burnt Orange `#FF6E40`, Aquamarine `#00E5FF`. |
| **G-13** | Bundle Assembly | `zig build build-app-bundle` | Generates self-contained `.app` with Info.plist and multi-res `.icns`. |
| **G-14** | Code Signing | `codesign --options runtime -vvv ZSpace.app` | Hardened runtime flag verified; timestamped signature valid. |
| **G-15** | Release Packaging | `spctl -a -vvv ZSpace.app`; `hdiutil create` | Gatekeeper accepts binary; DMG contains valid SBOM and license. |
| **G-16** | Bounded Index Cache | `zspace index <dir>`; verify file size | Flat binary file generated under `~/Library/Caches/ZSpace/` capped at 64 MB. |
| **G-17** | MCP Stdio Protocol | Initialize handshake via stdio | Lists all tools; validates JSON-RPC schema compliance. |
| **G-18** | Native GUI Rendering | Launch `zspace gui ~` | Window displays in <200ms; CoreGraphics sunburst and treemap draw without lag. |
| **G-19** | Zero Idle Footprint | Activity Monitor inspection with daemon idle | CPU usage drops to 0.0% when window is idle or daemon is inactive. |

---

## 10. Release Engineering & Documentation Hierarchy

1. **Commit Discipline:** Every change is committed as a single atomic unit matching conventional commits (`feat:`, `fix:`, `docs:`, `chore:`). Every commit must independently pass G-02 and G-03.
2. **Document Supremacy:** This file ([`docs/MASTER_PLAN.md`](file:///Users/joshua/LocalBuilds/Projects/zspace/docs/MASTER_PLAN.md)) is the supreme, authoritative plan for ZSpace.
3. **Legacy Preservation:** Former plan fragments in `legacy/docs/` and `docs/GUI_REARCHITECTURE_PLAN.md` are historical lineage records; when discrepancies arise, this document prevails.
