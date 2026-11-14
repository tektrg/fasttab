#!/usr/bin/env bash
# Keyboard-shortcut open of Fast Tab, dark, drawn offscreen from the real views:
# (a) Recents right after the shortcut, (b) after typing a 2-letter query,
# (c) Settings › Shortcuts → <dir>/sheet.png (default .build/shortcut-open-renders/now).
# Env-gated test `ShortcutOpenRenderSheet` (normal `swift test` skips it).
# Optional <before-dir>: a sheet rendered earlier (e.g. on another commit, with
# that commit's `ShortcutOpenRenderGlue`); writes <dir>/../before-after.png.
#
# Usage: scripts/render-shortcut-open.sh [dir] [before-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-$PWD/.build/shortcut-open-renders/now}"; mkdir -p "$out"; out="$(cd "$out" && pwd)"
before=""
if [[ -n "${2:-}" ]]; then before="$(cd "$2" && pwd)"; fi
label="$(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD)$(git diff --quiet HEAD -- Sources || echo ' (+ uncommitted Sources)')"
SHORTCUT_OPEN_RENDER_OUT="$out" SHORTCUT_OPEN_RENDER_BEFORE="$before" SHORTCUT_OPEN_RENDER_LABEL="$label" \
  swift test --filter ShortcutOpenRenderSheet
echo "$out/sheet.png"
if [[ -n "$before" ]]; then echo "$(dirname "$out")/before-after.png"; fi
