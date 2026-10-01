# ZSpace — Unified Master Plan & Complete Engineering Specification (v3.0)

**The Canonical Source of Truth and Complete Reconciliation.**  
Supersedes and reconciles:
- `docs/MASTER_PLAN.md` (v1.0 & v2.0)
- `docs/GUI_REARCHITECTURE_PLAN.md` (Native AppKit architecture & build order)
- `legacy/docs/BUILD_LIST.md` (B-01 through B-12)
- `legacy/docs/IMPLEMENTATION_PLAN.md` (C01–C20 production improvements & X01–X10 paradigm shifts)
- User Directives: Enhanced Developer File Viewer ("Super Finder"), Native Deduplication Workspace, Opt-in Visualizations, Liquid Titanium Holographic Glass Aesthetics, Embedded File Previewer, Left Navigation Rail, and Zero Auto-Indexing.

---

## 1. Executive Summary & User Directives Parsing

The user’s critique established clear product and UX requirements for ZSpace:
1. **Visualization Must Be Opt-in, Not Mandatory First Screen**: Raw abstract visualizer blocks (treemap/sunburst) should not dominate the screen automatically upon launch. They belong in a dedicated, explicit **Spacetime Visualizer** tab.
2. **Enhanced Developer File Viewer ("Super Finder")**: The primary browsing experience must be an enriched file explorer rendering developer-critical metadata that standard macOS Finder hides: Git status, iCloud sync status, inode counts, directory depth, aggregate tree weight, and temporal entropy.
3. **Dedicated In-App Workspaces for Core Engine Capabilities**:
   - **Deduplication Studio**: Full GUI interface for C03/X02 Blake3 duplicate clusters, side-by-side comparison, APFS zero-block reflink consolidation (`clonefile`), and selective trashing.
   - **Quick-Wins & System Sweeper**: Visual dashboard for stale caches (DerivedData, `node_modules`, package managers) with safety risk scores and one-click cleanup.
   - **Audit Journal & Undo Timeline**: Interactive chronological activity feed of operations with one-click instant recovery across reboots.
   - **Time-Travel Snapshots & Diff**: Visual delta comparison between `ZSNP2` snapshots.
4. **Embedded In-App File Previewer**: Single files must render live in a right-hand Inspector/Preview pane (syntax-highlighted code, markdown, images, hex preview for binaries) without needing external Finder or QuickLook windows.
5. **Unified Navigation Topology**:
   - Clean Title/Hub screen on launch with storage telemetry and quick presets.
   - Left Navigation Rail with clear icons and tabs for every major capability.
   - Resizable split panes, pop-out inspector drawers, and intuitive sliders.
6. **Aesthetics — Liquid Glass & Holographic AR HUD**:
   - Futuristic, liquid bubbly aesthetic reminiscent of a floating glass HUD.
   - Layered 3D elevation and depth with sharp, non-straining contrast (Obsidian base `#08090D`, Electric Aquamarine `#00E5FF`, Burnt Orange `#FF6E40`).
   - Clean, consolidated controls: primary action button (`[ ▶ SCAN TARGET ]`) up top in the header HUD with zero redundant button duplicates.
7. **Strict Engineering Invariants Maintained**:
   - 100% Pure Zig (Zero Swift, Zero ObjC source files, Zero WebKit/HTML/CSS).
   - Zero auto-indexing or background crawl until explicitly commanded.
   - Hermetic safety: No unlinks without Trash and audit receipts.

---

## 2. Added Value & Architectural "Flair" Innovations

To complement the user's vision, the following specialized features are engineered into the native Zig architecture:

1. **"Developer X-Ray" Column System**:
   - Toggleable column matrix in the file explorer:
     - `Git`: Clean / Modified / Untracked / Ignored + branch name.
     - `Cloud`: Local Pinned / Evicted Dataspaces / iCloud Syncing.
     - `Storage Weight`: Physical disk blocks allocated vs logical bytes (detects sparse files and APFS clones).
     - `Entropy`: Temporal access frequency rating (Hot / Warm / Cold / Stale Iceberg).
2. **Holographic Glass Shader & Layered Depth Engine**:
   - Custom CoreGraphics rendering using translucent glass fills with ambient inner shadows and crisp 1px specular bevels (`#00E5FF` glow at 0.35 opacity).
   - Card elevations rendered with dynamic z-layering, creating an optical illusion of elements floating slightly off the obsidian background.
3. **Instant "QuickLook" In-Memory Preview Pipeline**:
   - Text/Code: Pure Zig UTF-8 syntax detection with line-numbered preview.
   - Images: Direct CoreGraphics image rendering via `CGImageSourceCreateWithURL`.
   - Binaries: Structured hex dump with ASCII sidebar.
4. **APFS Zero-Block Reclaim Simulator**:
   - "What-if" preview bar showing physical SSD space freed before executing reflink deduplication or cache trimming.
5. **Interactive AR HUD Tooltips**:
   - Floating glass HUD tooltips anchored dynamically to the cursor with real-time metadata, category descriptions, and keyboard shortcuts.

---

## 3. Comprehensive Reconciliation Across Every Prior Plan

### 3.1 Status of the 20 Production Improvements (C-Series)

| ID | Title | Priority | Status | Implemented Details / Remaining Scope |
| :--- | :--- | :---: | :---: | :--- |
| **C01** | ObjC msgSend ABI Fix | P0 | **DONE** | Typed function pointer casts, NSRect registers, autoreleasepool wrapping. |
| **C02** | Pure-Zig Native AppKit GUI | P0 | **DONE** | Dynamic AppKit class registration, CoreGraphics pipeline, zero HTML/WebKit. |
| **C03** | Tier-2 Blake3 Dedup Verification | P0 | **DONE** | 3-tier pipeline: T0 size, T1 64KB sparse edge, T2 streaming Blake3. |
| **C04** | Native Trash + Put-Back + JSONL | P0 | **DONE** | `NSFileManager.trashItemAtURL`, persistent journal, Blake3 undo receipts. |
| **C05** | Cancellable Background Scanner | P0 | **DONE** | Multi-threaded background scanner with atomic cancellation & 10Hz throttling. |
| **C06** | Standard CLI Machine Contract | P0 | **DONE** | `--format=json\|table`, `--dry-run`, deterministic exit codes. |
| **C07** | Memory-Bounded Streaming Scan | P1 | **OPEN** | LRU inode cache (256k entries) to scan full root volumes without OOM. |
| **C08** | Error Taxonomy & FDA Onboarding | P1 | **OPEN** | Granular POSIX error handling and Full Disk Access permission helper. |
| **C09** | Elimination of GUI Mocks | P1 | **DONE** | All GUI components hydrate from live engine types (`DiskNode`, `Volume`). |
| **C10** | Interactive Terminal TUI | P1 | **DONE** | Termios raw mode, keyboard navigation, clean screen restoration. |
| **C11** | Snapshot Save & Diff Engine | P1 | **DONE** | `ZSNP2` binary format, 1-byte delta detection. |
| **C12** | Hermetic Test Harness | P1 | **DONE** | 13/13 offline tests passing cleanly in temporary test directories. |
| **C13** | Codesigning & Notarization | P1 | **OPEN** | Automated hardened runtime signing and DMG distribution build step. |
| **C14** | Structured Logging & Diagnostics | P1 | **OPEN** | `os_log` integration and diagnostic bundle generator. |
| **C15** | APFS Safety Rails & Reflink Guard | P1 | **DONE** | St_dev check and Blake3 verification before and after `clonefile`. |
| **C16** | Parallel Walker & SIMD Throughput | P2 | **OPEN** | Work-stealing threadpool traversal and AVX2/NEON Blake3 hashing. |
| **C17** | Optional Menubar Monitor Item | P2 | **OPEN** | Optional lightweight NSStatusItem showing disk capacity. |
| **C18** | Accessibility & Dynamic Scaling | P2 | **OPEN** | Contrast-checked palettes and VoiceOver label integration. |
| **C19** | Filesystem Security Hardening | P2 | **OPEN** | `O_NOFOLLOW` symlink guard and quarantine attribute preservation. |
| **C20** | Reproducible Versioning & SBOM | P2 | **OPEN** | Automated CycloneDX SBOM and semver generation. |

---

### 3.2 Status of the 10 Paradigm Shifts (X-Series)

| ID | Feature Name | Core Innovation | Status in GUI |
| :--- | :--- | :--- | :---: |
| **X01** | Time-Travel Disk Explorer | Multi-snapshot chronological delta graph | **PLANNED (Tab 5)** |
| **X02** | APFS Zero-Block Reclaim | Convert identical files into CoW clones via `clonefile` | **READY (Tab 2)** |
| **X03** | Dormancy Futures & Compaction | Identify stale iceberg folders (>1yr unaccessed) | **READY (Tab 3)** |
| **X04** | Storage Provenance Lens | Metadata origins (Docker, Xcode, Homebrew, npm) | **READY (Tab 1 & 3)** |
| **X05** | Infinite Undo Timeline | Chronological interactive rollback activity feed | **READY (Tab 6)** |
| **X06** | Fleet Storage Lens | Multi-Mac snapshot diffing | **OPEN** |
| **X07** | AI Agent Substrate (MCP Server) | stdio JSON-RPC server with two-phase commit | **DONE (Engine)** |
| **X08** | Heat-Death Sandbox Simulator | "What-if" dry-run preview of reclaimed space | **READY (Tab 3)** |
| **X09** | Content Fingerprint Mesh | Near-duplicate image and code chunking | **OPEN** |
| **X10** | Disk Carbon & Energy Ledger | SSD continuous wattage & cloud tier cost translation | **OPEN** |

---

## 4. Unified Application Topology & Window Layout

The application utilizes a **Left Navigation Rail + Main Stage + Right Inspector** layout with mouse-draggable dividers and liquid glass styling:

```
+---------------------------------------------------------------------------------------------------------+
| [●][●][●]  ZSpace — Spacetime Disk Intelligence [HUD]        Target: [/Users/joshua]  [📁 CHOOSE] [▶ SCAN]|
+-----+---------------------------------------------------------------------+-----------------------------+
| N   | MAIN STAGE (Context-Sensitive to Active Tab)                         | RIGHT INSPECTOR / PREVIEW   |
| A   |                                                                     |                             |
| V   | [TAB 1: SUPER FINDER]                                               | [File / Folder Inspector]   |
|     |  Columns: [Name ▲] [Size] [Type] [Modified] [Git] [Cloud] [Entropy] |  Preview Window:            |
| R   |  📁 Documents/        4.2 GB   Dir     Today      main   Local   Warm   |  • Syntax-highlighted text  |
| A   |  📁 Projects/        38.1 GB   Dir     2 hrs ago  dirty  Local   Hot    |  • Image thumbnail / dimensions|
| I   |  📄 bundle.tar.gz     1.4 GB   Archive Sep 12     -      iCloud  Cold   |  • Hex dump (binaries)      |
| L   |                                                                     |                             |
|     | [TAB 2: DEDUPLICATION STUDIO]                                       |  Metadata Card:             |
| [1] |  Clusters: 142  |  Duplicate Waste: 18.4 GB                         |  • Physical Blocks vs Bytes |
| 📁  |  [▼] Cluster 0x8F32 (Blake3) — 3 Copies (1.2 GB waste)              |  • Inodes & Permissions     |
| [2] |      [x] /Users/.../video_render_v1.mp4 (400 MB)                    |  • Created / Modified Dates |
| 🧬  |      [ ] /Users/.../video_render_final.mp4 (400 MB)                 |  • Git commit & status      |
| [3] |      Actions: [APFS Reflink Consolidate (0-Block)]  [Trash Checked] |                             |
| ⚡  |                                                                     |  Action Bar:                |
| [4] | [TAB 3: QUICK-WINS & SWEEPER]                                       |  [Open in Default App]      |
| 🌌  |  Xcode DerivedData: 24.2 GB [Safe] [Review]                         |  [Reveal in Terminal]       |
| [5] |  Node.js Modules:   18.7 GB [Safe] [Review]                         |  [Move to Trash (Undoable)] |
| ⏳  |  Homebrew Caches:    4.1 GB [Safe] [Review]                         |                             |
| [6] |                                                                     |                             |
| 📜  | [TAB 4: SPACETIME VISUALIZER]                                       |                             |
| [7] |  Mode: [Squarified Treemap] [Concentric Sunburst] [3D Elevation]   |                             |
| ⚙️  |  Interactive AR HUD overlay on hover with drill-down navigation     |                             |
+-----+---------------------------------------------------------------------+-----------------------------+
| STATUS BAR: Ready • Volume: 98.4% Full (3.68 GB free) • Engine: 0.0% CPU • Daemon: OFF • [Terminal HUD >]|
+---------------------------------------------------------------------------------------------------------+
```

---

## 5. Architectural Blueprint for Core Tabs

### 5.1 Tab 1: Enhanced Developer File Viewer ("Super Finder")
- **Direct Access**: Instantly browse target directory without requiring full system indexing.
- **Tree/Flat Dual View**: Toggle between expandable hierarchical folder tree and flat top-N size ranking.
- **Column Customizer**:
  - `Name` (with filetype icon)
  - `Size` (formatted with physical allocation badge)
  - `Type` (System category + MIME/extension)
  - `Date Modified` / `Date Created`
  - `Git Status` (Clean / Modified / Untracked / Ignored)
  - `Cloud Status` (iCloud Pinned vs Evictable)
  - `Temporal Entropy` (Hot, Warm, Cold, Stale)
- **Folder Aggregates**: Displays item count, subtree weight, and max child depth.

### 5.2 Tab 2: Deduplication Studio
- **Cluster Hierarchy**: Expandable clusters grouped by exact Blake3 hash.
- **Waste Calculation**: Computes reclaimable physical bytes per cluster.
- **Two Resolution Strategies**:
  1. *APFS Zero-Block Consolidation (`clonefile`)*: Replaces duplicate physical storage with Copy-on-Write APFS clones. Files remain at their original paths, zero risk of broken links.
  2. *Cryptographic Safe Trashing*: Select redundant copies to move to macOS Trash with full undo receipts.

### 5.3 Tab 3: Quick-Wins & Sweeper
- **Categorized Bloat Detection**:
  - Build artifacts (`target/`, `build/`, `DerivedData`, `.next`, `dist/`).
  - Dependency caches (`node_modules`, CocoaPods, pip, cargo, go cache).
  - System and browser caches (`~/Library/Caches/`, Google Chrome, Slack).
- **Safety Rating System**:
  - `Safe_ZeroRisk`: Pure ephemeral caches that rebuild automatically.
  - `RequiresReview`: Dormant project dependencies.
- **Selective Dry-Run Execution**: "What-If" simulator computes time saved and disk recovered before mutation.

### 5.4 Tab 4: Spacetime Visualizer (Opt-in)
- **View Sub-Modes**:
  1. *Squarified Treemap*: core layout with category palette coloring and selection highlights.
  2. *Concentric Sunburst*: Radial hierarchical visualization with interactive depth drilling.
  3. *3D Elevation Map*: Isometric projection rendering file size as vertical elevation peaks.
- **Interactive AR HUD Tooltips**: Floating glass card anchored to mouse hover displaying path, exact size, category, and children count.

### 5.5 Tab 5: Time-Travel Snapshots & Diff
- **Snapshot Manager**: Create and label `.zsnap` snapshots.
- **Visual Delta Comparator**: View byte deltas (added, removed, grown, shrunk) with colour-coded change heatmaps.

### 5.6 Tab 6: Audit Journal & Undo Timeline
- **Chronological Feed**: Visual timeline of every cleanup action hydrated from `journal.jsonl`.
- **Single-Click Undo**: Instant restoration of trashed items with byte-identical Blake3 verification.

### 5.7 Tab 7: Engine Settings & Daemon HUD
- **Scan Invariants**: Exclusions by exact path, keyword, or glob (`*.tmp`, `node_modules`).
- **Deduplication Thresholds**: Min size slider, Bloom filter memory tuning.
- **Daemon Control**: Toggle background daemon, inspect flat-file cache size, and one-click `[Purge Cache]`.

---

## 6. Complete Phased Implementation Roadmap

Execution proceeds in structured phases with verified test gates:

### Phase 1: Navigation Rail & Main Stage Multi-Tab Container
- Build `LeftNavView` AppKit class with 7 tab icons (`📁`, `🧬`, `⚡`, `🌌`, `⏳`, `📜`, `⚙️`).
- Refactor `native.zig` to host an active tab state switching the main stage content.
- Consolidate action buttons to the top header HUD.

### Phase 2: Enhanced Developer File Viewer ("Super Finder")
- Implement `SuperFinderView` with multi-column table rendering.
- Integrate Darwin `statfs`/`fstat` attributes (physical blocks, modified, permissions).
- Integrate Git status detector (reads `.git/HEAD` and index for active repositories).

### Phase 3: Embedded Inspector & QuickLook File Previewer
- Implement `InspectorView` on the right-hand panel.
- Implement text/code syntax viewer for text-based files.
- Implement image preview using `CGImageSourceCreateWithURL`.
- Implement hex dump viewer for binary files.

### Phase 4: Native Deduplication Studio Tab
- Implement `DedupStudioView` consuming `dedup.DuplicateCluster`.
- Wire `clonefile` APFS reflink consolidation directly to UI buttons.
- Connect selective trashing to `cleaner.trashItemAtURL` with instant undo receipts.

### Phase 5: Quick-Wins & Sweeper Tab
- Implement `QuickWinsView` displaying categorized cleanable items with risk badges.
- Wire dry-run preview and batch execution.

### Phase 6: Opt-in Spacetime Visualizer with Interactive AR HUD
- Move Sunburst and Treemap canvases into Tab 4.
- Implement floating glass AR HUD tooltips displaying node metadata on mouse hover.
- Implement 3D isometric elevation render mode.

### Phase 7: Liquid Titanium Glass Aesthetics & Mouse-Resizable Splitters
- Implement custom CoreGraphics glass shader with specular highlights and inner shadows.
- Add mouse drag dividers between Navigation Rail, Main Stage, and Inspector.
- Final validation against G-01 through G-19 gates.

---

## 7. Verification Gates & Pass Criteria

- **G-01 Toolchain**: Zig `0.16.0` verified.
- **G-02 Clean Build**: `zig build` compiles with 0 errors and 0 warnings.
- **G-03 Test Suite**: `zig build test --summary all` passes 13/13 unit tests.
- **G-18 GUI Responsiveness**: Window renders in <200ms with 0.0% idle CPU usage.
- **G-19 Zero Auto-Indexing**: Zero background disk crawl until user commands a scan.
