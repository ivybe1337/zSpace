#!/usr/bin/env bash
# zspace inspect wrapper for AI agents
set -euo pipefail

TARGET="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZSPACE_BIN="${ZSPACE_BIN:-$(command -v zspace || echo "$SCRIPT_DIR/../../../zig-out/bin/zspace")}"
"$ZSPACE_BIN" scan "$TARGET" --format=json
