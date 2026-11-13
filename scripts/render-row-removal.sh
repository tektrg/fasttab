#!/usr/bin/env bash
# Frame-by-frame sheet of a result row being removed (custom view + Recents,
# close button and trackpad swipe), old behaviour vs now: <dir>/sheet.png
# (default .build/row-removal-frames). Env-gated test `RowRemovalFrameSheet`.
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-$PWD/.build/row-removal-frames}"; mkdir -p "$out"; out="$(cd "$out" && pwd)"
ROW_REMOVAL_FRAMES_OUT="$out" swift test --filter RowRemovalFrameSheet
echo "$out/sheet.png"
