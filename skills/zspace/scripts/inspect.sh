#!/usr/bin/env bash
# zspace inspect wrapper for AI agents
set -euo pipefail

TARGET="${1:-.}"
/Users/joshua/LocalBuilds/Projects/zspace/zig-out/bin/zspace scan "$TARGET" --format=json
