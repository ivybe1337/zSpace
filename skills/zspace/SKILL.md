---
name: zspace
description: High-throughput disk intelligence, space reclamation, APFS deduplication, and spacetime storage analysis in pure Zig.
---

# ZSpace Agent Skill

Use this skill when interacting with the ZSpace disk intelligence engine to analyze storage, identify large caches and build artifacts, find duplicate files, inspect APFS volume geometry, or safely reclaim space.

## Capabilities & Tool Modes

ZSpace provides two primary agentic interfaces:
1. **MCP Server over Stdio (`zspace mcp`)**: Standard Model Context Protocol JSON-RPC 2.0 interface.
2. **Direct CLI (`zspace <command> [options]`)**: Fast, machine-parseable terminal suite with `--format=json`.

---

## 1. Safety Invariants (Crucial)

- **Non-Destructive by Default**: zSpace never deletes files directly. Deletions strictly route to macOS `~/.Trash` via native `NSFileManager.trashItemAtURL` with `.TrashInfo` metadata so Finder "Put Back" remains functional.
- **Audit Journal & Receipts**: Every cleanup operation writes a cryptographic Blake3 hash and timestamp to `~/Library/Application Support/zSpace/journal.jsonl`.
- **Reversibility**: Any cleanup operation can be rolled back immediately via `zspace undo <receipt-id>`.
- **Protected Zones**: zSpace strictly protects `/System`, `/usr`, `/bin`, `/sbin`, `/Library/Preferences`, `/Library/Keychains`, active `.git` repositories, and critical user configuration (`.ssh`, `.gnupg`, `.aws`).

---

## 2. Command Reference

### High-Speed Directory Scan
```bash
zspace scan <path> --format=json
```
Returns a hierarchical breakdown of node sizes, categories (Code, Build, Media, Docs, Archives), and file counts.

### Duplicate Detection (3-Tier Sparse & Streaming Hash)
```bash
zspace dedup <path> [--min-size=1MB] [--format=json]
```
Performs zero-allocation size grouping (T0), 64KB sparse edge sampling (T1), and full Blake3 streaming verification (T2).

### Smart Cleanup Candidates & Build Artifacts
```bash
zspace clean <path> --dry-run
zspace wins <path> [--format=json]
```
Scans for regenerable build artifacts (`node_modules`, `target`, `.zig-cache`, `DerivedData`, `.venv`) and caches.

### Interactive & Batch Cleanup Grammar
```bash
zspace clean <path> --select=safe --dry-run    # Preview zero-risk items
zspace clean <path> --select=safe --yes        # Move zero-risk items to Trash
zspace clean <path> --select=1,2,5 --yes       # Specific indices
```

### Undo Last Deletion or Specific Receipt
```bash
zspace history                                 # List recent journal receipts
zspace undo <receipt-id>                       # Revert operation by receipt ID
```

### Spacetime Temporal Decay & Dormancy Heatmap
```bash
zspace decay <path>
```
Categorizes disk consumption by last modification age:
- Hot (<30d)
- Warm (30–180d)
- Cold (180–365d)
- Dormant Icebergs (>1yr)

---

## 3. MCP Server Configuration

To register zSpace in your MCP configuration:

```json
{
  "mcpServers": {
    "zspace": {
      "command": "zspace",
      "args": ["mcp"]
    }
  }
}
```

### MCP Tools Available:
- `scan`: Traverses directory trees with depth limits.
- `drives`: Maps all APFS containers, partitions, and SIP locks.
- `dedup`: Finds duplicate files with hash verification.
- `clean_propose`: Non-mutating proposal of stale caches and reclaimable bytes.
- `clean_apply`: Applies proposed trash movements (requires explicit `allow_write: true`).
- `history`: Lists recent journal operations with receipts.
- `undo`: Restores files by receipt ID (requires `allow_write: true`).
- `snapshot`: Saves or diffs `ZSNP3` snapshots (`action: 'save' | 'diff'`).
- `index_status`: Reports the state of the background cache.
