# ZSpace — Master Plan

**The single source of truth.** Supersedes and replaces:
`docs/BUILD_LIST.md` (B-01…B-12), `docs/IMPLEMENTATION_PLAN.md` (C01…C20, X01…X10),
the in-thread feature brief, and the former team task ledger.
All of those are preserved verbatim under `legacy/docs/` for continuity only —
**none of them are authoritative any longer.** When this file and a legacy file
disagree, this file wins.

| Field | Value |
|---|---|
| Project root | `/Users/joshua/LocalBuilds/Projects/zspace` |
| Upstream | `https://github.com/ivybe1337/zspace.git` |
| Toolchain | `zig 0.16.0` (verified), macOS 12+ Darwin, arm64/x86_64 |
| Language policy | **Pure Zig. No Swift. No real Tauri.** |
| Status | Engine real and tested; interactive CLI/REPL layer landed; daemon + packaging open |

---

## 1. Locked decisions

These are settled. Re-litigating them is out of scope.

**D1 — Pure Zig, permanently.** The GUI is a native Objective-C/AppKit shell
driven from Zig through typed `objc_msgSend` casts, hosting a WKWebView that
renders `src/gui/index.html`. This is "Tauri-style" (native shell + web view)
implemented entirely in Zig. The earlier C02 plan item (Swift shell + Zig helper
over NDJSON) is **revoked** and B-09's `swift build` gate is **deleted**. No
`Apps/macOS/`, no `Package.swift`, no `zspace-helper` split, no `swift build` in
any gate.

**D2 — Dark-mode token set is fixed.**
Background `#0D0D0D` / `#1A1A1A`, accents burnt orange `#FF6E40` and
aquamarine `#00E5FF`, with `#FF3D00` (coral) for waste/danger signals.
`src/gui/theme.zig` and the `:root` block in `src/gui/index.html` must agree;
the NSWindow background is the one sanctioned deviation (obsidian `#08090D`).

**D3 — Journal file is the source of truth for undo.** In-process
`Cleaner.journal` is a cache, hydrated from
`~/Library/Application Support/ZSpace/journal.jsonl` at `init`. Undo must work
in a fresh process. (Implemented; see §4 P0-8.)

**D4 — Nothing destructive without a receipt.** Every removal routes through
`Cleaner.safeMoveToTrash` → macOS Trash via `NSFileManager.trashItemAtURL`,
falling back to copy+unlink on `EXDEV`, always writing a journal line with a
Blake3 digest and a stable receipt id.

**D5 — Hermetic tests only.** No test may scan `.`, `$HOME`, or `/`. Fixtures
come from `std.testing.tmpDir`. `zig build test --summary all` must pass
offline with zero network access.

**D6 — Zig 0.16 std API is normative.** `std.io` / `std.fs.cwd().readFileAlloc`
legacy forms are gone. File I/O goes through libc (`open`/`read`/`fstat`) via
`@cImport`, matching the existing `cleaner.zig` / `snapshot.zig` / `scanner.zig`
idiom. `std.process.Init` supplies argv; `-psn` launches are stripped.

---

## 2. Verified baseline

What is **actually proven green** at the time of writing — not claimed, measured:

```
zig build                              -> exit 0
zig build test --summary all           -> 13/13 tests passed, ~0.9s, MaxRSS 22M
```

Evidence for the P0 defect register in §4 additionally comes from live smoke:
`clean --select`, `wins --select`, `snapshot save/diff`, `history`, and
`trash N,M` → `u`/`U` round-trips on scratch trees.

Repo shape (5 274 lines of Zig across 24 source files):

```
src/main.zig              449   entry, argv, hermetic test harness
src/cli/cli.zig          1212   command dispatch, flags, interactive paths
src/core/scanner.zig      242   POSIX traversal, inode map, throttle hooks
src/core/cleaner.zig      970   Trash, journal, hydration, undo, receipts
src/core/analyzer.zig     290   risk model, smart-clean candidates
src/core/dedup.zig        249   T0 size / T1 sparse / T2 Blake3
src/core/snapshot.zig     240   ZSNP2 save/load/diff
src/core/tui_select.zig   247   raw-mode checkbox selector + selection specs
src/core/types.zig        250   DiskNode, ProtectionClass, CleanOperation
src/core/{apfs,classifier,disks,json,out}.zig
src/repl/repl.zig         864   interactive shell
src/tui/tui.zig           240   ANSI tabbed visualizer
src/gui/app.zig           218   AppKit/WKWebView host
src/gui/index.html       1446   view layer (sunburst/treemap/3D)
src/gui/{cocoa,theme,tooltips,sunburst,treemap,visualizer3d}.zig
```

---

## 3. Status ledger

Legend: **DONE** verified · **OPEN** not started · **PART** partial ·
**REVOKED** cancelled by decision · **DEFERRED** parked, not scheduled.

### 3.1 Correctness & safety (C-series)

| ID | Item | Priority | Status | Note |
|---|---|---|---|---|
| C01 | Typed ObjC msgSend ABI (NSRect by value) | P0 | **DONE** | commit `b5389bd`; no variadic struct sends remain |
| C02 | Swift shell + Zig helper over NDJSON | P0 | **REVOKED** | violates D1. Replaced by pure-Zig GUI hardening (P0-7, G-10/G-11) |
| C03 | Dedup Tier-2 full-file Blake3 verify | P0 | **DONE** | `bfc9b5c`; `hash_blake3` in cluster; collision fixtures rejected |
| C04 | Real Trash + Put-Back + journal + undo | P0 | **DONE** | `bfc9b5c` + hydration (P0-8) |
| C05 | Background cancellable scan worker | P0 | **DONE** | `851959f` (`scanBackground` thread worker) |
| C06 | Arg handling + machine CLI contract | P0 | **DONE** | `bfc9b5c`; exit codes 0/2/3/4 |
| C10 | Snapshot save/diff work | P1 | **DONE** | ZSNP2 in `bfc9b5c`; real `loadSnapshot` / `compareSnapshots` |
| C11 | Snapshot CLI wiring | P1 | **DONE** | `snapshot save\|diff`, `--format=json`; gate G-08 |
| C12 | Hermetic fixtures, no `.` scanning | P1 | **DONE** | `bfc9b5c`; `test/fixtures/` + tmpDir |
| C14 | Log + telemetry + crash pipeline | P1 | **PART** | JSONL run log + `diagnose --bundle` still to build |
| C16 | Performance: SIMD Blake3, kqueue batch, jobs | P2 | **PART** | throughput already ~7 GB/s; tuning unproven against targets |
| C07 | Memory-bounded streaming scan | P1 | **OPEN** | unbounded inode map + per-dir sort = OOM risk on `/` |
| C08 | Error taxonomy + FDA/TCC onboarding | P1 | **OPEN** | EPERM lumped into `errors_count` |
| C09 | Kill GUI mocks, real data bridge | P1 | **OPEN** | `index.html` still holds mock arrays + `alert()` stubs |
| C13 | Codesign / hardened runtime / notarize / DMG | P1 | **OPEN** | hand-assembled bundle; `spctl` rejects (expected pre-notarization) |
| C15 | APFS safety rails: same-volume, clone verify | P1 | **PART** | clone path exists; cross-device precheck unverified |
| C17 | First-run, empty states, update UX | P2 | **OPEN** | |
| C18 | Accessibility, keyboard map, i18n | P2 | **OPEN** | |
| C19 | Security review: TOCTOU, symlink, xattr | P2 | **PART** | symlink-follow off by default; no adversarial fuzz suite yet |
| C20 | Versioning, SBOM, auto release notes | P2 | **OPEN** | version string hardcoded in `cli.zig` |

### 3.2 Moonshots (X-series)

All X items are **DEFERRED** until §5 stage 6. Recorded here so they are not
lost; none are scheduled.

| ID | Item | Depends on |
|---|---|---|
| X01 | Time-travel disk: snapshot graph + growth forecast | C10, C11 (both DONE) |
| X02 | APFS zero-block cloud: reclaim without delete | C03, C15 |
| X03 | Dormancy futures: decay-scored auto-archive | C14, X01 |
| X04 | Provenance Lens: where did this GB come from | C08 |
| X05 | Trash insurance: infinite undo timeline | C04 (DONE), C09 |
| X06 | Fleet view: one brain, many Macs | X01 |
| X07 | Agent API: MCP + CLI for AI operators | §6 of this plan |
| X08 | Heat-death simulator: what-if sandbox | C09 |
| X09 | Content fingerprint mesh: perceptual near-dup | C03, C16 |
| X10 | Disk carbon ledger: bytes → kWh → gCO2e | C14 |

### 3.3 Feature brief (this thread)

| Item | Status | Note |
|---|---|---|
| Interactive checkbox selection | **DONE** | `src/core/tui_select.zig`, wired to `clean -i` and `wins -i` |
| Numbered `trash N,M` deletion | **DONE** | REPL numeric branch; comma list, 1-based, range-checked |
| Selection specs `34,12` / `3-7` / `all` / `safe` / `none` | **DONE** | `parseSelectionSpec` + unit tests |
| REPL overhaul (`d`, `t1`–`t5`, fuzzy search, `u`/`U`) | **DONE** | `executeDashboard`, `executeTabShortcut`, `fuzzyNameMatch`, undo pair |
| Background indexer daemon | **OPEN** | see §5 stage 3 |
| Pure-Zig dark GUI | **PART** | renders; mock removal is C09 |
| Agentic surface (MCP/skill) | **OPEN** | see §6 |

---

## 4. P0 defect register

Found by direct code audit of the working tree, each with a decisive fix and a
test gate. This is the register the pre-fix tree failed.

| # | Defect | Impact | Status |
|---|---|---|---|
| P0-1 | `runCleanCmd` passed a placeholder `isSafe` predicate returning `false`; `runWinsCmd` passed `null` | `--select=safe` silently selected **nothing** | **FIXED** — real `risk == .Safe_ZeroRisk` check; mask built at the call site |
| P0-2 | `readJournalTail` ring buffer emitted `ring[0..len]`, ignoring the `head` offset after wrap; no guard for `max_lines == 0` | Wrong "last op" chosen by `U`; division by zero | **FIXED** — wrap-aware emit from `head`; explicit zero guard |
| P0-3 | `executeDashboard` summed `reclaimable_bytes`, which `analyzer.zig` never assigns | Dashboard and TUI smart-clean always showed **0 B** cleanable | **FIXED** — sum `size_bytes` in both call sites |
| P0-4 | `parseCliArgs` had two identical `--interactive`/`--select` arm blocks | Second block dead; latent divergence risk | **FIXED** — duplicate block removed |
| P0-5 | Arrow keys advertised in the selector UI but only `j`/`k` decoded; the first fix initialised `c_cc` as `[32]u8` (it is `[20]u8`) and broke the build | Build red; arrows unusable | **FIXED** — blocking read + post-ESC 100 ms `VTIME` probe decoding `ESC [ A/B`; `EINTR` retried |
| P0-6 | Legacy `SelectableItem` / `SelectionState` / `parseSelectionIndices` / `isIndexSelected` duplicated `tui_select` | Two competing selection models | **FIXED** — legacy block deleted; `tui_select` is canonical |
| P0-7 | `sendStringWithUTF8` copied into a 4 096-byte stack buffer and returned `null` when larger; `index.html` is 48 093 bytes | GUI silently rendered **blank** | **FIXED** — `std.heap.c_allocator.dupeZ`, freed after the ObjC call |
| P0-8 | `undoByReceipt` searched only the in-memory journal, empty in a fresh process | `undo <receipt>` and `U` failed after quit — the undo window silently closed on every restart | **FIXED** — strict sequential JSONL parser + `hydrateJournalFromDisk` at init; undone receipts excluded; capped at 10 000 records |

**Test coverage added for this register:** journal parser round-trip of escaped
values; the anti-substring-search property (a value containing `"dst":"/evil"`
must not hijack the field); malformed-input rejection; `hexToDigest` contract
(all-zeros on any deviation); and an end-to-end restart simulation asserting a
prior-session receipt is undoable while an already-undone one is excluded.
Suite went **7 → 13**.

**Checked and rejected as non-defects:** `parseSelectionSpec` returning `[]bool`
via `toOwnedSlice`; the `--select` range check `hi > n`; `c_allocator` free after
`stringWithUTF8String:` (NSString copies its input); `hexToDigest` returning
zeros for the `"0"` placeholder that directories legitimately carry.

---

## 5. Remaining work, in execution order

### Stage 1 — Land what is proven (now)

1. Move legacy plans to `legacy/docs/`; this file becomes `docs/MASTER_PLAN.md`.
2. Commit the verified tree. Split, in this order:
   - `fix(core): journal hydration, ring-tail order, zero-line guard` — `cleaner.zig`
   - `feat(cli): interactive selection specs + honest safe predicate` — `cli.zig`, `tui_select.zig`
   - `feat(repl): dashboard, tab shortcuts, fuzzy search, undo` — `repl.zig`, `tui.zig`
   - `fix(gui): heap-terminate HTML for WKWebView (blank-render fix)` — `app.zig`
   - `docs: consolidate plans into MASTER_PLAN.md` — `docs/`, `legacy/docs/`
   Each commit must leave `zig build` and `zig build test` green on its own.

### Stage 2 — C09: kill the GUI mocks

Remove every hardcoded array and `alert()` stub; drive the view from real data.

- Raise `serializeNodeJson` limits to depth 8 / 200 children with an explicit
  `total_truncated` flag in the payload.
- Replace mock `dupes[3]`, `drives[3]`, `decayScore = (size % 97) + 15` with real
  `dedup`, `disks`, and `TemporalEntropy` values.
- Gate G-11: `grep -c 'alert(' src/gui/index.html` returns 0 for mutating paths;
  the GUI duplicate list byte-for-byte matches `zspace dedup --format=json`.

### Stage 3 — Background indexer daemon

Ship the **lighter Option B first**: a persisted ZSNP2 snapshot cache plus
on-demand incremental rescan — no long-lived process, no launchd, no socket.

- Cache at `~/Library/Caches/ZSpace/index.zsnap` plus a sidecar mtime/version stamp.
- CLI surface: `zspace index [path]` (refresh), `zspace index --status` (age,
  entries, coverage), `zspace index --forget`.
- Reuse the `yield_every_dirs` / `yield_sleep_ns` throttle hooks already present
  in `ScannerConfig` so a background refresh stays under ~5% CPU.
- REPL and GUI consult the index when it is fresh, else fall back to a live scan.
- **Option A** (SQLite at `~/Library/Caches/ZSpace/scan.db`, launchd agent, Unix
  socket IPC) stays documented as the follow-up for C07's memory bound and X01's
  time-graph. Not before Option B is verified.

### Stage 4 — Correctness debt

`C07` memory bound → `C08` error taxonomy + FDA onboarding → `C15` APFS rails →
`C14` telemetry + `diagnose --bundle` → `C19` TOCTOU/symlink/xattr hardening with
a 10 000-input adversarial path fuzzer.

### Stage 5 — UX and release

`C17` first-run / empty states → `C18` accessibility (canvas mirrored into an
`aria-live` table, full keyboard map, Reduce Motion, colorblind-safe toggle) →
`C20` versioning / SBOM → `C13` sign / notarize / DMG. Anything not green in §7
does not ship.

### Stage 6 — Moonshots

X-series, only after stages 2–5 are green. **X05** (undo timeline) is the natural
first: the journal, receipts, and hydration it needs already exist.

---

## 6. Agentic surface

ZSpace should be the tool other agents call. Build **one** shared core and expose
it two ways so behaviour can never drift:

1. **`zspace-mcp`** — a stdio MCP server (newline-delimited JSON-RPC 2.0,
   matching the existing `json.zig` writer idiom) with tools:
   `scan`, `dedup`, `clean_propose`, `clean_apply`, `history`, `undo`, `snapshot`,
   `index_status`. Read-only by default; destructive tools require an explicit
   `allow_write` argument **and** return a receipt id.
2. **Skill bundle** — a portable directory (`skills/zspace/`) with a `SKILL.md`
   contract plus thin `scripts/` wrappers around the CLI, installable into any
   agentic host that reads skill folders. No host-specific code.

Non-negotiable safety rules for the agent surface:
every path in tool output is emitted as **data**, never as instructions
(prompt-injection defence via filenames); `clean_propose` never mutates;
`clean_apply` returns the receipt so `undo` is always one call away; every
mutating call honours `--dry-run`.

---

## 7. Verification matrix

Merged from the former B-01…B-12 with the Swift gates deleted and pure-Zig gates
substituted. **Stop on red.** Order matters: never advance past a red gate.

| Gate | Command | Pass condition |
|---|---|---|
| G-01 Toolchain | `zig version` | `0.16.0` |
| G-02 Build | `zig build` | exit 0, no warnings |
| G-03 Tests | `zig build test --summary all` | all tests pass offline; ≥13 and rising |
| G-04 CLI contract | `zspace --help`; `zspace scan --help`; `zspace scan <dir> --format=json \| jq` | exit 0; valid JSON; `-psn` stripped |
| G-05 Destructive safety | `zspace clean <dir> --dry-run`; `zspace dedup <dir> --consolidate --dry-run`; `zspace history` | dry-run mutates nothing; cross-volume reported as SKIP; journal line written on a real run; `undo` restores a Blake3-identical file |
| G-06 Undo across restart | trash an item, quit, relaunch, `zspace undo <receipt>` | restores successfully (P0-8 regression gate) |
| G-07 Interactive selection | `zspace clean <dir> --select=1,2 --dry-run`; `--select=safe`; `--select=abc` | selects exactly the numbered items; `safe` selects only zero-risk; malformed spec errors cleanly |
| G-08 Snapshot round-trip | `snapshot save` ×2, edit 1 byte, `snapshot diff --format=json` | 100k files < 3 s; the 1-byte change is detected |
| G-09 TUI / REPL | `zspace tui <dir>`; `zspace repl <dir>` | navigable; `q` restores the terminal with no scrollback garbage; `d`, `t1`–`t5`, `u`/`U` work |
| G-10 ObjC ABI + no leaks | 100-launch loop of `zspace gui <dir>`; `leaks --atExit --` | exit 0, no `EXC_BAD_ACCESS`, leaks clean, window < 200 ms with progress |
| G-11 GUI has no mocks | `grep -n 'alert(' src/gui/index.html`; compare dupes to `dedup --format=json` | 0 mutating `alert()`; lists match the CLI exactly |
| G-12 Theme tokens | `theme.zig` vs `index.html` `:root` | identical values per D2 |
| G-13 Bundle assemble | `zig build build-app-bundle` (to add); `plutil -lint`; `sips -g all` | self-contained `Contents/{MacOS,Resources,Info.plist,PkgInfo}`; icon 16…1024 |
| G-14 Sign + notarize | `codesign --options runtime --timestamp`; `spctl -a -vvv`; `stapler validate` | runtime flag present, timestamped, `spctl` accepts |
| G-15 Release artifact | `hdiutil create`; `zspace version --json` | fresh Mac opens the DMG with no Gatekeeper block; DMG ships `VERSION.json` + SBOM |
| G-16 Index cache (Option B) | `zspace index <dir>`; `index --status`; `index --forget` | cache written/read/evicted; refresh CPU under ~5%; REPL prefers a fresh index |
| G-17 Agent surface | `zspace-mcp` handshake; `clean_propose` → `clean_apply` → `undo` | tools list correctly; propose never mutates; apply returns a receipt that undo accepts |

---

## 8. Commit and release discipline

- One logical change per commit; every commit independently green under G-02/G-03.
- Never commit with tests skipped, faked, or weakened to pass.
- Never ship a gate that has not been run on this machine against this tree.
- The daemon Option A, the remaining C-series backlog, and every X-series item are
  explicitly **not** part of any release until their gates exist and pass.

---

## Appendix — lineage of superseded documents

| Superseded | Formerly | Now |
|---|---|---|
| B-01…B-08 | `docs/BUILD_LIST.md` | §7 G-01…G-10 |
| B-09 | Swift shell + live bridge | **deleted** (violates D1); replaced by G-10, G-11, G-12 |
| B-10 | Bundle assemble | §7 G-13 (pure-Zig `build-app-bundle`) |
| B-11, B-12 | Sign/notarize, DMG | §7 G-14, G-15 |
| C01…C20 | `docs/IMPLEMENTATION_PLAN.md` Part A | §3.1 ledger + §5 stages 2–5 |
| X01…X10 | `docs/IMPLEMENTATION_PLAN.md` Part B | §3.2, §5 stage 6 |
| Feature brief | in-thread request | §3.3 |
| Team ledger | `task_0001`…`task_0009` | §3.1–§3.3 |

Originals are archived under `legacy/docs/` for continuity. They are historical
artifacts and carry no authority.

Also relocated: the stale pre-Sep-3 fork formerly at
`Projects/SpaceTime/ZSpace` now lives at
`Projects/SpaceTime/Legacy/ZSpace-sep03-freeze`. It is ~3–5× smaller than this
tree, is not a git repo, contains nothing unique except an 8-line `test_fs.zig`
throwaway, and must never be merged back.
