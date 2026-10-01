# ZSpace: Plan of Plans v5.0 — The Definitive Engineering Blueprint

**Document Status:** Canonical source of truth. Supersedes all prior plans (v1–v4, MASTER_PLAN v3, GUI_REARCHITECTURE_PLAN).
**Audit Date:** 2026-09-23. **Audited By:** Full codebase read of all 26 source files (8,856 LOC).
**Target:** Build the most capable, fastest, most resource-efficient disk intelligence application on macOS — surpassing DaisyDisk, Gemini 2, CleanMyMac X, CCleaner, DevCleaner, and OmniDiskSweeper in every measurable dimension.
**Core Constraint:** 100% Pure Zig. Zero Swift, zero ObjC source files, zero WebKit, zero Electron, zero runtime dependencies. Native AppKit/CoreGraphics via Zig `@cImport` + typed `objc_msgSend`.

---

## 0. Honesty Audit: What Actually Exists vs. What Was Claimed

> **Rule:** Every claim in this plan must reflect real, buildable capability — not aspirational buzzwords.

### 0.1 Verified Working (13/13 tests pass, builds clean)

| Module | Lines | Status | What It Actually Does |
|:---|:---:|:---:|:---|
| `scanner.zig` | 252 | ✅ SOLID | Recursive POSIX traversal with `opendir`/`readdir`/`lstat`, arena allocation, inode dedup, atomic cancellation, background thread support |
| `dedup.zig` | 250 | ✅ SOLID | 3-tier pipeline: T0 size match → T1 Wyhash 4KB head+tail → T2 streaming Blake3. Selects original by oldest mtime |
| `cleaner.zig` | 1035 | ✅ SOLID | `NSFileManager.trashItemAtURL` with fallback chain, Blake3 receipt IDs, JSONL journal, undo-by-receipt, 10K record hydration cap |
| `apfs.zig` | 73 | ✅ SOLID | `clonefile` with `CLONE_NOFOLLOW`, `statfs` APFS detection, `st_dev` cross-device guard |
| `snapshot.zig` | 241 | ✅ SOLID | ZSNP2 binary format, save/load/diff with added/removed/grown/shrunk detection |
| `types.zig` | 251 | ✅ SOLID | `DiskNode`, `CategoryTag`, `ProtectionClass`, `TemporalEntropy`, monotonic/realtime clocks |
| `analyzer.zig` | 291 | ✅ SOLID | 12-category aggregation, 4-bucket temporal decay, smart-clean heuristics (node_modules, DerivedData, target/, etc.), top-N |
| `classifier.zig` | 136 | ✅ SOLID | Extension-based `CategoryTag` + path-based `ProtectionClass` (locks /System, .ssh, .git) |
| `disks.zig` | 79 | ✅ SOLID | `getmntinfo` volume enumeration, capacity/used/free, autofs/devfs filtering |
| `cli.zig` | 1182 | ✅ SOLID | 20+ commands fully wired: scan, dedup, clean, wins, npkill, drives, decay, 3d, tui, gui, benchmark, snapshot, history, undo, repl, mcp |
| `repl.zig` | 864 | ✅ SOLID | Interactive shell: scan, ls, cd, pwd, dashboard, clean, wins, npkill, dedup, decay, 3d, trash, undo, search, top, categories |
| `mcp.zig` | 885 | ✅ SOLID | JSON-RPC 2.0 stdio server: scan, drives, dedup, clean_propose, clean_apply, history, undo, snapshot, index_status |
| `json.zig` | 67 | ✅ OK | Recursive DiskNode→JSON serializer (50-child cap per level) |

### 0.2 GUI: Honest Gap Analysis

| Component | Lines | Claim | Reality |
|:---|:---:|:---|:---|
| `native.zig` | 663 | Full AppKit window | ✅ Window opens, menubar works, scan triggers, GCD background thread works |
| `components.zig` | 995 | Full multi-tab workspace | ⚠️ **Single fixed layout only.** No tabs, no navigation rail, no view switching. Renders: header, sunburst, treemap, sidebar, status bar — all hardcoded in one layout |
| `cocoa.zig` | 278 | ObjC bindings | ✅ Complete typed wrappers, ABI-correct |
| `theme.zig` | 39 | Color tokens | ✅ Complete Obsidian palette |
| `tooltips.zig` | 38 | Interactive tooltips | ❌ **Defined but completely unused.** No hover tracking, no tooltip rendering |
| `treemap.zig` | 73 | Squarified treemap | ⚠️ Basic slice-and-dice. Not true squarified (no aspect ratio optimization) |
| `sunburst.zig` | 89 | Interactive sunburst | ⚠️ Layout math works, `hitTest` works, but **components.zig ignores hitTest** and blindly drills into `children[0]` |
| `tui.zig` | 240 | Interactive TUI | ❌ **One-shot render only.** No input loop, no keyboard navigation despite rendering tab labels |
| `visualizer3d.zig` | 83 | 3D visualization | ✅ CPU isometric ASCII projection (TUI/REPL only) |
| `app.zig` | 10 | Entry point | ✅ Thin re-export of `native.runGuiApp` |

**Critical Missing GUI Features (zero lines of code exist):**
1. No navigation rail / tab system
2. No file browser / "Super Finder" view
3. No deduplication studio UI
4. No quick-wins sweeper UI
5. No file editor of any kind
6. No machine telemetry HUD
7. No scrolling in sidebar (truncates at window height)
8. No trash/delete action button wired in GUI
9. No resizable split panes
10. No inspector/preview panel
11. No collector basket / staging tray
12. No settings/preferences UI
13. No first-run help overlay

### 0.3 Known Bugs Found During Audit

| ID | Severity | Location | Issue |
|:---|:---:|:---|:---|
| B-01 | Medium | `scanner.zig:125` | Path buffer overflow if root path ≥4096 bytes |
| B-02 | Low | `dedup.zig:105-112` | Claims "cleanest shortest path" selection but only checks `mtime_ns` |
| B-03 | Medium | `components.zig` sunburst | `onSunburstMouseDown` ignores `hitTest()` — drills blindly into `children[0]` |
| B-04 | Medium | `components.zig` sidebar | No scroll implementation — files below window height are invisible |
| B-05 | Low | `tooltips.zig` | Entire tooltip system defined but never rendered |
| B-06 | Low | `treemap.zig` | Not actually squarified — basic slice-and-dice only |
| B-07 | Low | `tui.zig` | Renders tabs [1-6] but has no input loop to switch them |
| B-08 | Low | `classifier.zig` | `indexOf` matching can false-positive (e.g., `/my_tmp/` matches `tmp` rule) |
| B-09 | Low | `json.zig` | 50-child limit silently truncates large directories |
| B-10 | Low | `out.zig` | 8192-byte buffer silently drops overflow output |
| B-11 | Low | `snapshot.zig` | Unreadable files get hash `"0"` — causes false diffs on permission changes |

---

## 1. Competitive Matrix (Grounded in Real Product Analysis)

```
+---------------------------+---------------+---------------+---------------+---------------+---------------+------------------+
| Capability                | DaisyDisk     | Gemini 2      | CleanMyMac X  | CCleaner      | DevCleaner    | ZSpace (Today)   |
|                           | $9.99 1x      | $44.95 1x     | $119.95/$39/y | $29.95/yr     | Free/OSS      | Free/Open        |
+---------------------------+---------------+---------------+---------------+---------------+---------------+------------------+
| Tech Stack                | ObjC/Cocoa    | Swift/CoreML  | Swift/Daemon  | C++/Cocoa     | Swift/SwiftUI | Zig/AppKit (Pure)|
| Scan Method               | getattrlistblk| Standard POSIX| Standard POSIX| Standard POSIX| Targeted dirs | opendir+lstat *  |
| Sunburst/Treemap Viz      | Sunburst 2D   | No            | No            | No            | No            | Both (buggy) ⚠️  |
| Duplicate Detection       | No            | Hash+CoreML   | Basic hash    | Basic match   | No            | 3-Tier Blake3 ✅ |
| Dedup Method              | N/A           | Hard Links ⚠️ | Trash only    | Trash only    | N/A           | APFS clonefile ✅|
| Dev Cache Cleanup         | No            | No            | Basic (Xcode) | No            | Xcode only    | Universal ✅     |
| App Uninstaller           | No            | No            | 7-tentacle ✅ | Basic         | No            | Planned          |
| File Editor               | No            | No            | No            | No            | No            | Planned          |
| Hardware Telemetry        | No            | No            | Menubar daemon| No            | No            | Planned          |
| MCP / AI Agent Interface  | No            | No            | No            | No            | No            | JSON-RPC ✅      |
| Cryptographic Undo        | No (unlinks!) | Trash only    | Trash only    | Trash only    | No            | Blake3 JSONL ✅  |
| Snapshot & Diff           | No            | No            | No            | No            | No            | ZSNP2 ✅         |
| REPL / Interactive Shell  | No            | No            | No            | No            | No            | Full REPL ✅     |
| Collector / Staging Tray  | Yes ✅        | No            | No            | No            | No            | Planned          |
| Hidden/Purgeable Space    | Yes (paid)    | No            | Basic         | No            | No            | Planned          |
| RAM Footprint             | ~50-120 MB    | ~180-300 MB   | ~300-600 MB   | ~80-150 MB    | ~40-80 MB     | ~23 MB ✅        |
| Background CPU (idle)     | 0.0%          | 0.5-2%        | 3-8% (daemon) | 1-2%          | 0.0%          | 0.0% ✅          |
+---------------------------+---------------+---------------+---------------+---------------+---------------+------------------+

* CRITICAL SCANNER UPGRADE: Replace opendir+readdir+lstat with macOS `getattrlistbulk(2)` — reads directory
  entries in 64KB kernel batches (names, sizes, blocks, timestamps in one syscall). DaisyDisk uses this.
  Expected improvement: 100K files/s → 300K+ files/s on Apple Silicon APFS SSD.
```

> **CRITICAL COMPETITIVE INSIGHT: Hard Links vs APFS Clones**
> Gemini 2 and TreeSize use POSIX `link(2)` hard links for deduplication — files share the same inode, so
> **modifying one silently corrupts ALL copies**. Atomic-save apps (`write-temp → rename`) silently break
> the link entirely. ZSpace uses APFS `clonefile(2)` which creates independent inodes sharing physical
> blocks via Copy-on-Write. Editing one file never affects the other. This is ZSpace's strongest
> technical differentiator and should be prominently marketed.

### 1.1 Where ZSpace Already Wins (Defensible Advantages)
1. **23 MB RAM** vs 50-600 MB for all competitors — 3-26x lighter
2. **3-tier Blake3 dedup** — most rigorous duplicate detection in the market
3. **APFS clonefile** — zero-copy CoW deduplication that's SAFE (unlike Gemini 2's hard links)
4. **Full REPL + MCP server** — only disk tool with AI agent integration
5. **Cryptographic undo** — Blake3-verified restoration, not just "check Trash"
6. **Zero background CPU** — CleanMyMac/Gemini/CCleaner all have daemons or polling
7. **No subscription tax** — DaisyDisk is $9.99 1x, CleanMyMac is $120, Gemini is $45. ZSpace is free.

### 1.2 Where ZSpace Loses Today (Must Fix)
1. **No functional GUI beyond basic visualizer** — competitors have full, polished UIs
2. **No file browser** — DaisyDisk, CleanMyMac all have rich file exploration
3. **No app uninstaller** — CleanMyMac's killer feature (#1 reason people pay $120)
4. **No real-time monitoring** — CleanMyMac has menubar HUD
5. **No file preview** — macOS QuickLook integration is table stakes
6. **No collector tray** — DaisyDisk's beloved drag-to-basket staging pattern
7. **Visualization is broken** — sunburst click ignores hitTest, treemap isn't squarified
8. **Scanner is slow** — using opendir+lstat instead of getattrlistbulk (DaisyDisk's secret weapon)
9. **No hidden/purgeable space detection** — DaisyDisk's "Hidden Space" slice is popular

---

## 2. Architecture: The 8-Workspace Application

The GUI transforms from a single fixed layout into an 8-workspace tabbed application with a left navigation rail.

### 2.1 Window Layout (1320×860 default, min 960×600)

```
+---------------------------------------------------------------------------------------------------------------+
| [●][●][●]  ZSpace — Disk Intelligence              Target: /Users/joshua   [📁 CHOOSE]  [▶ SCAN]  [⏹ STOP]  |
+------+---------------------------------------------------------------------------+----------------------------+
| NAV  | MAIN STAGE (switches per active tab)                                      | INSPECTOR (collapsible)    |
|      |                                                                           |                            |
| [1]  | Content rendered by the active workspace module.                          | Context-sensitive panel:    |
| 📁   | Each workspace owns its own draw function, mouse handlers,                | • File metadata card       |
|      | and keyboard shortcuts.                                                   | • Live preview (code/img)  |
| [2]  |                                                                           | • Hex dump (binaries)      |
| 🧬   | The stage receives the full UIState and renders accordingly.              | • Dedup cluster detail     |
|      |                                                                           | • Action buttons           |
| [3]  |                                                                           |                            |
| ⚡   |                                                                           |                            |
| [4]  |                                                                           |                            |
| 📝   |                                                                           |                            |
| [5]  |                                                                           |                            |
| 📊   |                                                                           |                            |
| [6]  |                                                                           |                            |
| 🌌   |                                                                           |                            |
| [7]  |                                                                           |                            |
| ⏳   |                                                                           |                            |
| [8]  |                                                                           |                            |
| 📜   |                                                                           |                            |
+------+---------------------------------------------------------------------------+----------------------------+
| STATUS: Ready • /dev/disk3s1 APFS • 496 GB / 500 GB (99.2%) • Scan: 312K files/s • RSS: 23 MB • CPU: 0.0%   |
+---------------------------------------------------------------------------------------------------------------+
```

### 2.2 The 8 Workspaces

| # | Icon | Name | What It Does | Engine Dependency |
|:---:|:---:|:---|:---|:---|
| 1 | 📁 | **Super Finder** | Enhanced file browser with dev-critical columns (git, cloud, entropy, physical blocks). In-app browsing — no Finder needed | `scanner.zig`, `classifier.zig` |
| 2 | 🧬 | **Dedup Studio** | Blake3 cluster cards, side-by-side comparison, APFS clone consolidation, selective trash with undo | `dedup.zig`, `apfs.zig`, `cleaner.zig` |
| 3 | ⚡ | **Quick-Wins Sweeper** | Categorized dev cache/junk detection with safety ratings, "What-If" dry-run preview, batch cleanup | `analyzer.zig`, `cleaner.zig` |
| 4 | 📝 | **Baremetal Editor** | mmap-backed file viewer/editor for JSONL, CSV, Parquet, code files. Piece-table edits, syntax highlighting | NEW (planned) |
| 5 | 📊 | **Machine Telemetry** | Real-time hardware HUD: CPU cores, RAM pressure, swap, GPU, disk IOPS, network I/O via Mach/IOKit | NEW (planned) |
| 6 | 🌌 | **Spacetime Visualizer** | Opt-in sunburst, squarified treemap, 3D elevation. Interactive drill-down with AR HUD tooltips | `treemap.zig`, `sunburst.zig`, `visualizer3d.zig` |
| 7 | ⏳ | **Time-Travel Snapshots** | Create, label, compare ZSNP2 snapshots. Visual delta heatmap showing what grew/shrunk/appeared/vanished | `snapshot.zig` |
| 8 | 📜 | **Audit Journal** | Chronological feed of every operation from `journal.jsonl`. Single-click Blake3-verified undo | `cleaner.zig` |

### 2.3 Shared Components (Used Across All Workspaces)

| Component | Purpose | Implementation |
|:---|:---|:---|
| **Header HUD** | Target path, scan trigger, stop button, scan progress, operation metrics | CoreGraphics custom draw |
| **Navigation Rail** | 8 tab icons, active highlight, keyboard shortcuts ⌘1-⌘8 | Custom NSView with hit regions |
| **Inspector Panel** | Right-side collapsible panel: metadata card, file preview, action buttons | Custom NSView, toggled by ⌘I |
| **Status Bar** | Volume stats, scan velocity, RSS, CPU, daemon status | CoreGraphics text draw |
| **Collector Basket** | Bottom slide-up tray for staging files across workspaces before batch action | Custom NSView with drag targets |
| **Confirm Sheet** | Every destructive action routes through ONE confirmation dialog showing count + bytes + paths | NSAlert or custom sheet |

---

## 3. Workspace Specifications (Upgraded from v4.0)

### 3.1 Super Finder (Tab 1) — Beating DaisyDisk's File View + OmniDiskSweeper's Density

**What v4.0 had:** Column list concept.
**v5.0 upgrade:** Full in-app file browser that makes Finder unnecessary for developers.

**Column Grid (user-toggleable, drag-to-reorder, drag-to-resize, Finder-style column selector):**

| Column | Source | Why It Matters |
|:---|:---|:---|
| Name | `DiskNode.name` | File/folder name with drawn filetype icon (no image assets — pure CoreGraphics glyphs) |
| Size | `DiskNode.size` | Logical bytes, formatted (KB/MB/GB). Color-coded: >1GB purple, >100MB red, >10MB orange |
| Physical Blocks | `stat.st_blocks × 512` | Reveals sparse files and APFS clones (physical ≠ logical). Badge: `CLONE` when physical < logical |
| Type | `classifier.classifyCategory()` | Semantic category (Code, Media, Archive, Cache, etc.) with colored dot |
| Modified | `stat.st_mtime` | Relative timestamps for recent ("2 hrs ago"), absolute for old ("Sep 12, 2024") |
| Created | `stat.st_birthtime` | macOS creation timestamp (unique to HFS+/APFS). Same relative/absolute formatting |
| Git Status | Read `.git/HEAD` + `git status --porcelain` cache | Clean / Modified / Untracked / Ignored + branch name. Dot colors: green/yellow/red/gray |
| Cloud Status | `getxattr("com.apple.fileprovider.domain#com.apple.CloudDocs")` + `NSURL.getResourceValue(.ubiquitousItemDownloadingStatusKey)` | iCloud: Local ✅ / Evicted ☁️ / Downloading ↓ / Uploading ↑ |
| Entropy | `TemporalEntropy.calculate()` | Hot 🔴 / Warm 🟡 / Cold 🔵 / Stale ⚪ — decay score badge |
| Permissions | `stat.st_mode` | Unix permission string (rwxr-xr-x). Red highlight if world-writable |
| Inodes | `stat.st_ino` | Inode number. Badge: `HARDLINK` when `st_nlink > 1` |
| Last Accessed | `stat.st_atime` | Reveals files never accessed since copy/download |

**Folder Aggregates (shown inline when folder row is selected):**
- Total children count (files + dirs separately)
- Recursive size (with physical vs logical delta if clones present)
- Tree depth (max nesting level)
- Number of git repos inside (count `.git` directories)
- Oldest and newest file modification dates
- Top 3 categories by size (e.g., "72% Code, 18% Media, 10% Archive")

**Navigation:**
- Click folder → drill in (push to breadcrumb stack)
- Breadcrumb bar at top of stage for path navigation — each segment clickable to jump back
- Back button / right-click / Backspace / ⌫ to ascend
- Sort by any column (click header, cycle: ascending → descending → unsorted)
- **Column resize:** Drag column separator handles. Double-click separator to auto-fit.
- **Column reorder:** Drag column headers to rearrange.
- Search/filter bar (⌘F) — instant substring filter on visible rows. Supports glob patterns (`*.json`, `node_*`)
- **Keyboard navigation:** ↑/↓ move selection, ← collapse or ascend, → expand or drill, ⏎ drill into selected, Space toggle checkbox, Tab cycle focus between stage/inspector

**Context Menu (Right-click on file/folder):**
- Open in Default App
- Open in Terminal (iTerm2/Terminal.app)
- Reveal in Finder
- Copy Path to Clipboard
- Move to Collector Basket
- Move to Trash (via confirm sheet)
- Create Snapshot of This Directory
- Run Dedup on This Directory
- Properties (show full inspector)

**Drag & Drop:**
- Drag files/folders to Collector Basket (bottom tray)
- Drag files to Trash icon in sidebar (with confirm)
- Drag external files/folders INTO ZSpace window to set as scan target

**Inspector Preview (Right Panel — expanded):**
- Text/Code files: Syntax-highlighted first 500 lines with line numbers (pure Zig UTF-8 tokenizer: keywords, strings, comments, numbers, types)
- Images: `CGImageSourceCreateWithURL` inline rendering with dimensions overlay (WxH px), file size, color space, DPI
- Markdown: Split rendered preview (headers, bold, lists, code blocks, links)
- PDF: First-page render via `CGPDFDocument` + page count badge
- Audio/Video: Metadata card (duration, codec, bitrate, dimensions) — no playback, just info
- Binaries: Structured hex dump with ASCII sidebar, Mach-O header detection for executables
- Folders: Aggregate stats card + category breakdown mini-chart + temporal distribution

### 3.2 Dedup Studio (Tab 2) — Beating Gemini 2 (and Exposing Hard-Link Danger)

**What v4.0 had:** Cluster list concept.
**v5.0 upgrade:** Full deduplication workflow from detection to resolution, with unique APFS CoW advantage.

**Cluster List View:**
- Each cluster = expandable card showing Blake3 hash (first 16 hex chars), copy count, total wasted bytes
- Inside each cluster: file rows with checkboxes, paths, sizes, modification dates, parent directory context
- "Original" badge selection logic (fix B-02): `mtime_ns` oldest → shortest clean path tiebreak → file NOT containing `(copy)` or `(1)` in name
- Waste meter bar showing how much SSD space this cluster wastes (physical blocks, not logical)
- **Search/filter bar:** Filter clusters by path substring, minimum waste size, file extension
- **Sort clusters:** By waste (largest first), by copy count, by file size, by oldest date

**Side-by-Side Visual Diff (NEW — beating Gemini 2's diff inspector):**
- Select any two files in a cluster → opens split-pane comparison view
- Text files: Line-by-line diff (should be identical for exact dupes — useful for near-dupes in future)
- Images: Side-by-side thumbnail with metadata overlay (dimensions, format, EXIF)
- Binaries: Hex diff highlighting any divergent bytes
- Metadata comparison: size, dates, permissions, path depth, git status, iCloud status

**Resolution Actions (per cluster or batch — across ALL clusters):**
1. **APFS Zero-Block Consolidate**: Replace physical duplicate blocks with CoW clones via `clonefile`. All paths remain intact, zero risk of broken references. Shows "What-If" preview first with exact bytes to be reclaimed.
2. **Trash Selected**: Move checked copies to macOS Trash with Blake3 undo receipt. Always via confirm sheet.
3. **Skip/Ignore**: Mark cluster as reviewed, persist to `~/.zspace/dedup_ignore.json` so it doesn't reappear on next scan.
4. **Batch Actions:** "Consolidate ALL Safe Clusters" — processes every cluster where Smart Select has ≥2 copies and no ambiguity. Shows aggregate preview first.

**Smart Select Heuristics (deterministic, transparent, no black-box "AI"):**
- Keep oldest (by `mtime_ns`) — the original is usually the first copy made
- Keep file in active git repo (detect `.git` in parent chain) — don't delete tracked source
- Keep shortest clean path (fewest directory segments) — likely the canonical location
- Auto-select copies with `(copy)`, `(1)`, `-backup`, `_old` suffixes
- User can override any selection — Smart Select is a suggestion, not a mandate

**Metrics Dashboard:**
- Total clusters found / total files in clusters
- Total waste (physical bytes reclaimable)
- Reclaimable via clonefile (non-destructive) vs reclaimable via trash (destructive)
- Historical trend: waste detected per scan session (stored in journal)

**Future Roadmap (Post-v5, documented for transparency):**
- Perceptual image hashing (dHash/pHash) for camera bursts and re-encoded photos — requires building a pure-Zig image decoder or linking CoreImage, significant effort
- Audio fingerprinting for duplicate music files — same complexity concern
- These are NOT in v5 scope. Exact-hash dedup covers 95%+ of real-world duplicates.

### 3.3 Quick-Wins Sweeper (Tab 3) — Beating DevCleaner + CCleaner

**What v4.0 had:** Category list.
**v5.0 upgrade:** Universal developer cache purger with safety-first UX.

**Detection Categories (from `analyzer.zig` heuristics, extended):**

| Category | Targets | Safety Rating |
|:---|:---|:---|
| Xcode | `DerivedData/`, `Archives/`, DeviceSupport symbols, Simulator runtimes, CoreSimulator caches | Safe (rebuilds on next build) |
| Node.js | `node_modules/` (>90 days untouched), `.next/cache`, `.turbo`, npm/yarn/pnpm global caches | Safe if project has `package.json` lockfile |
| Rust | `target/` directories, `~/.cargo/registry/cache` | Safe (rebuilds via `cargo build`) |
| Go | `~/go/pkg/mod/cache` | Safe (rebuilds via `go mod download`) |
| Python | `__pycache__/`, `.venv/` (>180 days), pip cache | Safe / Review |
| Containers | Docker dangling images, stopped containers, buildx cache layers | Review (may contain needed layers) |
| Homebrew | `~/Library/Caches/Homebrew/downloads` | Safe |
| Browser Caches | Chrome/Safari/Firefox cache directories | Safe |
| System Caches | `~/Library/Caches/*` (non-system, >30 days) | Review |
| Log Files | `~/Library/Logs/*`, `*.log` files >100MB | Safe to trim |

**"What-If" Simulator:** Before any mutation, show exact bytes reclaimable per category with a stacked bar chart. User checkboxes which categories to include. Only then does `[Execute Cleanup]` become active.

**Deep App Uninstaller (NEW — beating CleanMyMac X):**
- Select an app from `/Applications` → scans these 7 "tentacle" locations:
  1. `~/Library/Application Support/<app>`
  2. `~/Library/Caches/<app>`
  3. `~/Library/Preferences/<bundle-id>.plist`
  4. `~/Library/Saved Application State/<bundle-id>.savedState/`
  5. `~/Library/Containers/<bundle-id>/`
  6. `~/Library/Group Containers/<group-id>/`
  7. `~/Library/LaunchAgents/*<app>*`, `/Library/LaunchDaemons/*<app>*`
- Shows total remnant size + file count
- Batch trash with undo receipts

**Git Shrink-Ray (NEW):**
- Detect `.git/objects/pack` files >100MB
- Show packfile size vs repo working tree size ratio
- Offer `git gc --prune=now --aggressive` with confirmation
- Report bytes reclaimed

### 3.4 Baremetal Editor (Tab 4) — Unique to ZSpace, Zero Competitors

**What v4.0 had:** mmap concept.
**v5.0 upgrade:** Fully specced implementation with real editing operations.

**Supported Formats:**

| Category | Formats | Rendering |
|:---|:---|:---|
| Tabular Data | CSV, TSV, JSONL | Virtual row grid with auto-detected column alignment, column resize, column sort |
| Structured Data | JSON, YAML, TOML, Plist (XML & binary) | Syntax-highlighted tree view with collapsible nodes |
| Binary Data | Parquet, Arrow (IPC), Protocol Buffers | Read-only schema browser showing field names/types + first 1000 rows sampled |
| Documentation | Markdown | Split-pane: source (left, editable) + rendered preview (right, live-updating) |
| Code | Zig, C, Python, Go, JS/TS, Rust, Shell, Swift | Syntax-highlighted editor with line numbers, current-line highlight |

**Core Engine: mmap + Piece Table**

The editor opens files via Darwin `mmap(PROT_READ, MAP_PRIVATE)` for zero-copy access. A piece table (standard text editor data structure — used by VS Code's Monaco engine and Sublime Text) tracks insertions and deletions as metadata without modifying the underlying mmap'd buffer.

- **Opening:** `mmap` the file read-only. Background thread scans for line-start byte offsets (a `[]u64` index). A 50GB JSONL file's index costs ~400MB of offset memory (8 bytes × 50M lines) — bounded and predictable.
- **Viewing:** Only the 40-80 visible rows in the viewport are decoded and rendered. Scrolling updates the viewport window into the offset index. No full-file parsing ever.
- **Editing:** Insertions/deletions recorded in a piece table. Original mmap buffer never modified. Dirty lines re-rendered on next frame. Undo/redo via piece table operation stack (bounded at 10,000 operations).
- **Saving:** Atomic write to a temporary file → `rename()` to replace original. On APFS, the old file's blocks are preserved as a snapshot until the rename commits. Auto-snapshot before save for instant recovery.
- **Chunked mmap for huge files:** Files >1GB use sliding 256MB `mmap` windows with `MADV_DONTNEED` on out-of-viewport chunks to avoid page fault storms.

**Editing Operations:**
- **Find:** ⌘F — incremental search with match count, highlight all occurrences, ⌘G next match
- **Find & Replace:** ⌘⇧F — with preview of all replacements before committing
- **Go to Line:** ⌘L — jump to line number (essential for multi-million-line files)
- **Undo/Redo:** ⌘Z / ⌘⇧Z — backed by piece table operation stack
- **Select All:** ⌘A — with byte count in status bar
- **Copy/Cut/Paste:** Standard clipboard operations via `NSPasteboard`
- **Indent/Outdent:** Tab / ⇧Tab — configurable tab width (2/4/8 spaces or hard tab)

**CSV/TSV-Specific Operations:**
- Auto-detect delimiter (comma, tab, pipe, semicolon) on file open
- Column-aligned grid view with frozen header row
- Sort by column (click header)
- Filter rows by column value (dropdown per column header)
- Column statistics: min/max/mean for numeric columns, unique count for text columns
- Export filtered view as new CSV/JSONL

**JSONL-Specific Operations:**
- Each line is a collapsible JSON record
- Filter records by key-value match (e.g., `status == "error"`, `size > 1000000`)
- Schema inference: detect common keys across records, show type distribution
- Navigate by record number (go to record #50,000,000 instantly via offset index)

**What this is NOT (honest scope boundary):** Not a VS Code replacement. No LSP, no autocomplete, no extensions ecosystem, no multi-cursor, no split editor panes. It's a fast, zero-dependency file viewer/editor for quick inspections and data file manipulation that can handle files VS Code chokes on.

### 3.5 Machine Telemetry HUD (Tab 5) — Beating Activity Monitor

**What v4.0 had:** API list.
**v5.0 upgrade:** Specific syscalls and rendering approach.

| Metric | Source API | Update Rate | Rendering |
|:---|:---|:---|:---|
| CPU per-core utilization | `host_processor_info(HOST_CPU_LOAD_INFO)` via Mach | 2 Hz (adaptive) | Horizontal bar per core, P/E labeled |
| RAM pressure | `vm_statistics64` via Mach host port | 2 Hz | Stacked bar: Wired/Active/Inactive/Compressed/Free |
| Memory pressure level | `dispatch_source_create(MEMORYPRESSURE)` | Event-driven | Badge: Normal (green) / Warning (yellow) / Critical (red) |
| Swap usage | `sysctl(VM_SWAPUSAGE)` | 2 Hz | Single bar with used/total |
| GPU utilization | `IOServiceGetMatchingServices` + `IOAccelerator` | 2 Hz | Bar + percentage |
| Disk I/O | `IOBlockStorageDriver` statistics | 2 Hz | Read/Write MB/s sparkline |
| Network I/O | `sysctl(NET_RT_IFLIST2)` per interface | 2 Hz | In/Out Mbps per interface |
| Process footprint | `mach_task_basic_info` (self) | 2 Hz | RSS and virtual size |
| Display info | `CGGetActiveDisplayList` + `CGDisplayModeGetPixelWidth` | On-demand | Resolution, refresh rate, scale factor |

**Adaptive Throttling (fixing Red Team T-07):**
- Window focused: 2 Hz polling
- Window unfocused: 0.5 Hz polling
- Window minimized or hidden: 0 Hz (polling stops completely)
- Telemetry thread uses a single `dispatch_source_timer` — cancellable, no busy loops

### 3.6 Spacetime Visualizer (Tab 6) — Opt-In Only

**What v4.0 had:** Treemap + sunburst + 3D.
**v5.0 upgrade:** Fix the broken implementations, make them actually interactive.

**Fixes Required:**
1. **Fix B-03:** Wire `sunburst.hitTest()` into `onSunburstMouseDown` — replace blind `children[0]` drill with actual radial coordinate hit detection
2. **Fix B-06:** Implement true squarified treemap algorithm (Bruls-Huizing-van Wijk 2000) — optimize for aspect ratio ≈1.0 instead of basic slice-and-dice
3. **Wire tooltip rendering:** Connect `tooltips.zig` definitions to actual mouse tracking (`NSTrackingArea`) and floating `NSPanel` rendering

**View Modes:**
1. **Squarified Treemap:** Category-colored rectangles, proportional to size, with labels on tiles ≥64×22px. Click to drill, right-click to ascend.
2. **Concentric Sunburst:** Radial sectors proportional to size, depth rings for hierarchy levels. Click sector to drill, click center to ascend.
3. **3D Elevation Map:** Isometric projection (already works in `visualizer3d.zig` for ASCII). Port to CoreGraphics with colored elevation peaks.

**AR HUD Tooltips:** Floating borderless `NSPanel` anchored to cursor, showing: file path, exact size, category, children count, temporal entropy, git status. Auto-hide after 3 seconds or on mouse-exit.

### 3.7 Time-Travel Snapshots (Tab 7)

**What exists:** `snapshot.zig` can save, load, and diff ZSNP2 snapshots.
**v5.0 upgrade:** GUI wrapper with visual delta rendering.

- **Snapshot List:** Table of saved snapshots with label, date, file count, total size
- **Create Snapshot:** Button that runs `SnapshotEngine.saveSnapshot()` with a user-provided label
- **Compare:** Select two snapshots → visual diff showing Added (green), Removed (red), Grown (orange ↑), Shrunk (blue ↓) with exact byte deltas
- **Fix B-11:** Handle unreadable files by storing hash as `"UNREADABLE"` instead of `"0"` to prevent false diffs

### 3.8 Audit Journal (Tab 8)

**What exists:** `cleaner.zig` maintains `journal.jsonl` with full operation history.
**v5.0 upgrade:** Visual timeline with one-click undo.

- **Chronological Feed:** Scrollable list of operations (trash, restore, clone) with timestamps, paths, sizes, receipt IDs
- **Undo Button:** Per-entry `[↩ Undo]` button that calls `cleaner.undoByReceipt(receipt_id)` with Blake3 verification
- **Undo All Session:** Batch undo of all operations from the current session
- **Export:** Export journal as CSV or JSON for audit compliance

---

## 4. Inspector Panel & In-App File Preview

The right-side Inspector panel replaces the need for Finder QuickLook or external apps.

### 4.1 Preview Pipeline

| File Type | Detection | Preview Method |
|:---|:---|:---|
| Text/Code | UTF-8 detection + extension match | Line-numbered syntax-highlighted view (first 500 lines) |
| Images | `.png`, `.jpg`, `.gif`, `.webp`, `.svg`, `.heic` | `CGImageSourceCreateWithURL` → render scaled to fit |
| Markdown | `.md` extension | Rendered preview (bold, headers, lists, code blocks) |
| PDF | `.pdf` extension | First-page render via `CGPDFDocument` |
| Binary/Unknown | Everything else | Hex dump: 16 bytes/row, hex + ASCII columns |
| Folders | `is_dir` flag | Stats card: item count, total size, category breakdown |

### 4.2 Metadata Card (Always Visible)

| Field | Source |
|:---|:---|
| Full path | `DiskNode.name` + parent traversal |
| Logical size | `DiskNode.size` |
| Physical allocation | `stat.st_blocks × 512` |
| APFS clone | Physical < Logical indicates CoW clone |
| File type / MIME | Extension + category tag |
| Created / Modified | `st_birthtime` / `st_mtime` |
| Permissions | `st_mode` formatted as rwx string |
| Inode | `st_ino` |
| Protection class | `classifier.classifyProtection()` |
| Git status | `.git/HEAD` reader (if in repo) |

---

## 5. Operation Metrics & Performance Benchmarks

Every operation in ZSpace is self-benchmarked with nanosecond precision.

### 5.1 Scan Metrics (displayed in Header HUD during scan)

| Metric | Computation | Display |
|:---|:---|:---|
| Files/sec | `atomic_file_count / elapsed_seconds` | `312,450 files/s` |
| MB/sec throughput | `atomic_total_bytes / elapsed_seconds` | `2.41 GB/s` |
| Directories/sec | `atomic_dir_count / elapsed_seconds` | `48,200 dirs/s` |
| Elapsed time | `getMonotonicNs() - start_ns` | `00:03.241` |
| Errors | `atomic_error_count` | `2 errors` |
| Total items | `atomic_file_count + atomic_dir_count` | `1,247,832 items` |

### 5.2 Operation Benchmarks (logged per operation)

| Operation | Metric |
|:---|:---|
| Dedup analysis | Time to complete 3-tier pipeline, clusters found, bytes reclaimable |
| APFS clonefile | Per-file clone latency (μs), total bytes consolidated |
| Trash operation | Per-file trash latency (μs), journal write latency |
| Snapshot save | Time to serialize tree + hash all files, snapshot file size |
| Snapshot diff | Time to compare two snapshots, delta count |

### 5.3 Benchmark Command (`zspace benchmark`)

Already exists in CLI. Upgrade to also measure:
- Sequential `readdir` + `lstat` calls per second on target directory
- Blake3 hashing throughput (MB/s) on a 1GB temp file
- `clonefile` latency on APFS volume
- JSONL journal append latency

Report format: Table with operation, throughput, latency p50/p95/p99.

---

## 6. Aesthetics: Liquid Titanium Glass Design System

### 6.1 Color Tokens (from `theme.zig`, extended)

| Token | Hex | Usage |
|:---|:---|:---|
| `obsidian_base` | `#08090D` | Window background, deep layer |
| `obsidian_surface` | `#101216` | Card surfaces, nav rail background |
| `obsidian_elevated` | `#1A1D24` | Hover states, raised panels |
| `electric_aqua` | `#00E5FF` | Primary accent, active tab, selection highlight |
| `burnt_orange` | `#FF6E40` | Action buttons (Scan, Execute), warnings |
| `emerald` | `#00E676` | Safe indicators, success states |
| `crimson` | `#FF1744` | Destructive actions, critical warnings |
| `ghost_white` | `#E8EAED` | Primary text |
| `ghost_dim` | `#9AA0A6` | Secondary text, disabled states |
| `specular_border` | `#FFFFFF` @ 0.08 | 1px hairline borders between panels |
| `glass_fill` | `#00E5FF` @ 0.06 | Frosted glass panel fill |

### 6.2 Depth & Elevation System

| Layer | Z-Index | Technique |
|:---|:---|:---|
| Base | 0 | Flat `obsidian_base` fill |
| Surface | 1 | `obsidian_surface` with 1px `specular_border` top edge |
| Card | 2 | `obsidian_elevated` with 2px inner shadow (bottom-right, black @ 0.3) |
| Floating | 3 | Tooltip/panel with 4px blur shadow + `electric_aqua` @ 0.12 glow border |
| Modal | 4 | Full-window dim overlay (black @ 0.5) + centered card |

### 6.3 Interaction States

| State | Visual Treatment |
|:---|:---|
| Default | Base colors, no border highlight |
| Hover | Background shifts to `obsidian_elevated`, 1px `electric_aqua` @ 0.3 border |
| Active/Selected | 2px `electric_aqua` border, subtle inner glow |
| Focused | Dotted 1px `electric_aqua` outline (keyboard navigation) |
| Disabled | 50% opacity, no hover response |
| Destructive Hover | `crimson` @ 0.15 background tint |

### 6.4 Resizable Split Panes

Three draggable dividers:
1. **Nav Rail ↔ Main Stage**: Min nav 48px (icons only) / max 200px (icons + labels)
2. **Main Stage ↔ Inspector**: Min inspector 0px (collapsed) / max 400px
3. **Collector Basket**: Slide-up from bottom, 0px (hidden) to 200px

Implementation: Custom `NSSplitView`-equivalent using CoreGraphics divider bars with mouse tracking (`NSTrackingArea` + `mouseDragged:` handler). Divider visual: 1px `specular_border` line with 4px invisible hit region.

---

## 7. Red Team Security & Reliability Audit

### 7.1 Threat Model

| ID | Threat | Severity | Current Status | Mitigation |
|:---|:---|:---:|:---|:---|
| T-01 | **Symlink TOCTOU Race** | Critical | `scanner.zig` uses `lstat` ✅ but `cleaner.zig` doesn't verify pre-trash | Add `O_NOFOLLOW` + `fstatat(AT_SYMLINK_NOFOLLOW)` check in `safeMoveToTrash` before any operation |
| T-02 | **Path Traversal via crafted filenames** | High | `classifier.zig` uses `indexOf` which can match substrings incorrectly (B-08) | Switch to exact basename matching or anchored path component checks |
| T-03 | **Protection Class Bypass** | Critical | `cleaner.zig` checks ProtectionClass ✅ | Verify: test that `/System`, `/usr/bin`, `~/.ssh` are all blocked. Add test cases. |
| T-04 | **APFS Cross-Device clonefile** | Medium | `apfs.zig` checks `statfs` APFS + `st_dev` ✅ | Already mitigated. Add test. |
| T-05 | **Journal Corruption** | Medium | JSONL append-only, but no fsync | Add `fsync` after journal write to guarantee crash-safe persistence |
| T-06 | **mmap OOM on huge files** | Medium | Editor not yet built | Implement sliding 256MB windows with `MADV_DONTNEED` on evicted chunks |
| T-07 | **Telemetry CPU drain** | Low | Telemetry not yet built | Implement adaptive polling: 2Hz focused → 0Hz minimized |
| T-08 | **AppKit main-thread deadlock** | High | Scanner uses `dispatch_async_f` ✅ | All future GUI code must follow same pattern. Never block main thread. |
| T-09 | **Unbounded arena growth** | Medium | Scanner arena grows with tree size | Implement LRU cap or arena size budget for extremely large scans (>10M files) |
| T-10 | **Accidental system file deletion** | Critical | ProtectionClass guards exist ✅ | Extend: add explicit deny-list for `/Applications/Safari.app`, Mail.app, system frameworks. Log all protection-class rejections to journal. |

### 7.2 Reliability Invariants

| ID | Invariant | Enforcement |
|:---|:---|:---|
| R-01 | No file is ever deleted — only moved to macOS Trash | `NSFileManager.trashItemAtURL` is the only deletion path. `unlink`/`remove` are banned. |
| R-02 | Every trash operation produces a Blake3 receipt | Receipt ID = Blake3 hash of (path + size + mtime). Stored in JSONL journal. |
| R-03 | Every destructive GUI action routes through ONE confirm dialog | `showConfirmSheet()` function — the only path. No inline deletes. |
| R-04 | Zero background activity when idle | No timers, no polling, no daemon threads when user hasn't triggered an action. Verified by 0.0% CPU in Activity Monitor. |
| R-05 | Crash-safe journal | `fsync` after every append. Journal is append-only, never rewritten. |
| R-06 | Zero auto-indexing | App never crawls disk until user explicitly presses Scan. No startup scan. |

---

## 8. Agent-First Architecture & Audit Trails

ZSpace is designed as an agent-first tool — every operation is programmatically accessible and auditable.

### 8.1 MCP Server (Already Built — `mcp.zig`)

9 tools already implemented via JSON-RPC 2.0 over stdio:

| Tool | Description | Destructive? |
|:---|:---|:---:|
| `scan` | Scan a target directory | No |
| `drives` | List mounted volumes | No |
| `dedup` | Find duplicate clusters | No |
| `clean_propose` | Preview what would be trashed | No |
| `clean_apply` | Execute proposed cleanup (requires `confirm: true`) | Yes |
| `history` | Read journal entries | No |
| `undo` | Restore a trashed file by receipt ID | Yes |
| `snapshot` | Create or compare snapshots | No |
| `index_status` | Check cache/index state | No |

### 8.2 Planned MCP Extensions

| Tool | Description |
|:---|:---|
| `analyze` | Run category/temporal/top-N analysis |
| `quick_wins` | List detected cache/junk with safety ratings |
| `benchmark` | Run performance benchmark suite |
| `app_uninstall_scan` | Find app remnants across ~/Library |
| `file_preview` | Get file metadata + first N lines/bytes |

### 8.3 Audit Trail Format

Every operation is logged to `~/.zspace/journal.jsonl` with:
```json
{
  "timestamp": "2026-09-23T15:30:00.000Z",
  "operation": "trash",
  "path": "/Users/joshua/old_backup.tar.gz",
  "size_bytes": 1073741824,
  "receipt_id": "b3_a1b2c3d4e5f6...",
  "blake3_hash": "a1b2c3d4...",
  "protection_class": "UserData",
  "source": "gui|cli|repl|mcp",
  "agent_id": "optional-agent-identifier",
  "session_id": "optional-session-identifier",
  "undone": false,
  "undo_timestamp": null
}
```

---

## 9. Phased Execution Roadmap

### Phase 1: Fix Bugs, Scanner Upgrade & Tab Foundation (Est. 3-4 sessions)
**Goal:** Fix all known bugs, upgrade scanner to getattrlistbulk, establish multi-tab architecture.

- [ ] **SCANNER UPGRADE:** Replace `opendir`+`readdir`+`lstat` with `getattrlistbulk(2)` batched kernel reads — DaisyDisk's speed secret. Single syscall returns name+size+blocks+timestamps for hundreds of entries in one 64KB buffer. Expected 3x scan speed improvement.
- [ ] Fix B-03: Wire `sunburst.hitTest()` into mouse handler
- [ ] Fix B-04: Implement sidebar scrolling (virtual scroll with offset tracking)
- [ ] Fix B-05: Implement tooltip rendering with `NSTrackingArea` + floating `NSPanel`
- [ ] Fix B-06: Implement true squarified treemap algorithm
- [ ] Fix B-07: Add input loop to TUI for tab switching
- [ ] Fix B-08: Switch classifier to exact basename matching
- [ ] Fix B-11: Use `"UNREADABLE"` hash instead of `"0"` in snapshots
- [ ] Create `ActiveTab` enum with 8 variants in `components.zig`
- [ ] Build `LeftNavRailView` with 8 icon buttons and active highlight
- [ ] Implement tab switching: clicking nav icon swaps the main stage draw function
- [ ] Wire ⌘1-⌘8 keyboard shortcuts via `keyDown:` handler
- [ ] Add APFS purgeable space detection: query `fs_snapshot_list`, local Time Machine snapshots (`tmutil listlocalsnapshots /`), and VM swap/sleepimage sizes
- [ ] **Gate:** Window opens with nav rail, clicking tabs changes main stage content, scanner benchmarks ≥200K files/s

### Phase 2: Super Finder File Browser (Est. 3-4 sessions)
**Goal:** In-app file browsing that makes Finder unnecessary.

- [ ] Build `SuperFinderView` draw function with column headers and row rendering
- [ ] Implement virtual scrolling for file rows (handle 100K+ files without lag)
- [ ] Wire `stat` calls for physical blocks, permissions, birthtime
- [ ] Implement column sort (click header to toggle asc/desc)
- [ ] Implement breadcrumb navigation bar
- [ ] Build click-to-drill and right-click-to-ascend
- [ ] Implement search/filter bar (⌘F)
- [ ] Implement folder aggregate stats
- [ ] **Gate:** Can browse entire home directory with smooth scrolling, sort by any column

### Phase 3: Inspector & File Preview (Est. 2-3 sessions)
**Goal:** Right-side preview panel with live file inspection.

- [ ] Build `InspectorView` as collapsible right panel
- [ ] Implement resizable divider between stage and inspector
- [ ] Build metadata card (always visible when file selected)
- [ ] Implement text/code preview with line numbers
- [ ] Implement image preview via `CGImageSourceCreateWithURL`
- [ ] Implement hex dump view for binary files
- [ ] Wire ⌘I to toggle inspector visibility
- [ ] **Gate:** Selecting any file in Super Finder shows preview + metadata

### Phase 4: Dedup Studio (Est. 2-3 sessions)
**Goal:** Full deduplication workflow in the GUI.

- [ ] Build `DedupStudioView` consuming `dedup.DuplicateCluster`
- [ ] Render cluster cards with expandable file lists
- [ ] Wire APFS clonefile consolidation button with "What-If" preview
- [ ] Wire selective trash with confirm sheet and undo receipts
- [ ] Implement Smart Select heuristics (oldest, shortest path, in-git-repo)
- [ ] Show dedup metrics bar (total clusters, waste, reclaimable)
- [ ] **Gate:** Can detect dupes, preview consolidation, execute clone, undo trash

### Phase 5: Quick-Wins Sweeper & App Uninstaller (Est. 2-3 sessions)
**Goal:** One-click developer cache cleanup with safety ratings.

- [ ] Build `QuickWinsView` with categorized sections
- [ ] Wire `analyzer.generateSmartCleanRecommendations()` to GUI
- [ ] Implement safety rating badges (Safe / Review / Risky)
- [ ] Build "What-If" simulator showing bytes reclaimable per category
- [ ] Implement batch execution with confirm sheet
- [ ] Build App Uninstaller: scan ~/Library tentacles for selected app
- [ ] Build Git Shrink-Ray: detect bloated .git packfiles
- [ ] **Gate:** Can detect, preview, and safely clean dev caches with undo

### Phase 6: Spacetime Visualizer & Snapshots (Est. 2 sessions)
**Goal:** Fix visualizations, add snapshot GUI.

- [ ] Move sunburst/treemap into Tab 6 (opt-in only)
- [ ] Implement AR HUD tooltips with mouse tracking
- [ ] Port 3D elevation to CoreGraphics rendering
- [ ] Build `SnapshotView` with create/compare/diff UI
- [ ] Implement visual delta heatmap
- [ ] **Gate:** All three viz modes work with correct drill-down, snapshots can be created and compared

### Phase 7: Audit Journal & Collector Basket (Est. 1-2 sessions)
**Goal:** Operation history timeline and staging tray.

- [ ] Build `AuditJournalView` as scrollable timeline
- [ ] Wire per-entry undo buttons
- [ ] Build bottom slide-up Collector Basket
- [ ] Implement drag-to-basket from any workspace
- [ ] Implement batch action on basket contents
- [ ] **Gate:** Can view all operations, undo any, stage files across workspaces

### Phase 8: Baremetal Editor (Est. 3-4 sessions)
**Goal:** mmap-backed file viewer/editor.

- [ ] Implement mmap file opening with background line-offset indexer
- [ ] Build virtual row scroller (viewport window into offset index)
- [ ] Implement syntax tokenizer for code files (keyword/string/comment/number)
- [ ] Implement piece table for in-place editing
- [ ] Implement atomic save (tmpfile + rename)
- [ ] Build CSV/TSV column-aligned grid view
- [ ] Build JSONL row-by-row viewer
- [ ] Implement sliding mmap windows for files >1GB
- [ ] **Gate:** Can open, view, edit, and save a 1GB JSONL file without lag or OOM

### Phase 9: Machine Telemetry HUD (Est. 2-3 sessions)
**Goal:** Real-time hardware monitoring.

- [ ] Implement Mach API bindings for CPU, RAM, swap
- [ ] Implement IOKit bindings for GPU, disk I/O
- [ ] Implement sysctl bindings for network I/O
- [ ] Build telemetry dashboard with per-metric visualizations
- [ ] Implement adaptive polling throttle
- [ ] **Gate:** All metrics display correctly, 0.0% CPU when minimized

### Phase 10: Glass Aesthetics & Polish (Est. 2-3 sessions)
**Goal:** Liquid Titanium Glass visual treatment across all workspaces.

- [ ] Implement glass fill + specular border rendering across all panels
- [ ] Implement card elevation shadows
- [ ] Implement all interaction states (hover, active, focused, disabled)
- [ ] Implement resizable split panes for all three dividers
- [ ] Final accessibility pass: contrast ratios, VoiceOver labels
- [ ] Codesign + notarization build step
- [ ] Full G-01 through G-19 verification gate run
- [ ] **Gate:** Studio-quality visual polish, all gates pass

---

## 10. Verification Gates

| ID | Gate | Pass Criteria |
|:---|:---|:---|
| G-01 | Toolchain | Zig 0.16.0 verified |
| G-02 | Clean Build | `zig build` — 0 errors, 0 warnings |
| G-03 | Test Suite | `zig build test --summary all` — all tests pass |
| G-04 | Binary Size | Release binary <10 MB |
| G-05 | Launch Time | First paint <200ms (measured) |
| G-06 | Idle CPU | 0.0% CPU in Activity Monitor when idle (no scan running) |
| G-07 | RAM Footprint | <30 MB RSS at idle, <100 MB during full home directory scan |
| G-08 | Scan Speed | >200K files/sec on APFS SSD |
| G-09 | No Auto-Index | Zero background disk activity until user triggers scan |
| G-10 | Destructive Safety | Every trash/delete routes through confirm sheet |
| G-11 | Undo Works | Trash + quit + relaunch + undo restores Blake3-identical file |
| G-12 | No Symlink Follow | `lstat` + `O_NOFOLLOW` on all destructive paths |
| G-13 | Protection Class | Cannot trash files in /System, /usr, /bin, ~/.ssh, ~/.git |
| G-14 | Journal Crash-Safe | Kill -9 during trash → journal contains the operation on restart |
| G-15 | MCP Compliance | All 9 tools respond correctly to JSON-RPC 2.0 |
| G-16 | REPL Parity | Every CLI command available in REPL |
| G-17 | GUI Tab Navigation | All 8 tabs render content, ⌘1-⌘8 work |
| G-18 | GUI Scroll | Super Finder handles 100K+ files without lag |
| G-19 | Sunburst HitTest | Click on correct sector drills into that sector's node |

---

## 11. What Was Intentionally Removed from v4.0

| v4.0 Item | Why Removed |
|:---|:---|
| "AI Heuristic Smart Select" | Misleading — it's rule-based logic (oldest/shortest/in-repo), not AI. Renamed to "Smart Select Heuristics" |
| "Similar Files & Photo Burst Detection (dHash/aHash)" | Requires image processing pipeline that doesn't exist. Deferred to post-v5. Would need CoreImage or custom perceptual hash — significant effort for marginal gain vs exact-hash dedup |
| "APFS DeepRay Hidden Space" | Renamed to simpler "APFS Purgeable Space Scanner" — the "DeepRay" branding was pure marketing with no technical meaning |
| "Content Fingerprint Mesh" | Near-duplicate code chunking via rolling hash — complex, unproven at our scale, deferred |
| "Disk Carbon & Energy Ledger" | SSD wattage estimation is speculative guesswork. Removed until grounded methodology exists |
| "Fleet Storage Lens" | Multi-Mac diffing requires network transport. Out of scope for v5 |
| "Dormancy Futures & Compaction" | Temporal entropy already built. "Compaction" was vague — what does it actually compact? Removed the buzzword, kept the entropy scoring |
| Numbered "C-Series" and "X-Series" IDs | Replaced with workspace-scoped task lists. The C01-C20/X01-X10 numbering added complexity without value |

---

## 12. What Was Added in v5.0 That v4.0 Didn't Have

| Addition | Justification |
|:---|:---|
| Honest gap analysis (Section 0) | v4.0 claimed things that don't exist. v5.0 starts with truth. |
| Known bugs list with IDs | B-01 through B-11 — must fix before building new features |
| Deep App Uninstaller | CleanMyMac X's most popular feature. Required to compete. |
| Git Shrink-Ray | Unique to ZSpace — no competitor offers git packfile analysis |
| Inspector panel spec | v4.0 mentioned "preview" but never specified how |
| Piece table editor spec | v4.0 said "mmap" but didn't specify the editing data structure |
| Agent audit trail format | v4.0 said "agent-first" but didn't define the journal schema |
| Adaptive telemetry throttle | Solves the "telemetry drains CPU" problem concretely |
| Verification gates expanded | G-01 to G-19 with measurable pass criteria |
| Intentional removal log | Documents what was cut and why — no silent deletions |
