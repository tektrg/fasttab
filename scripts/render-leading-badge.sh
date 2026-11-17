#!/usr/bin/env bash
# Result rows with the bookmark/history source badge vs the browser logo,
# dark + light: <dir>/sheet.png (default .build/leading-badge-renders).
# Env-gated test `LeadingIconBadgeRenderSheet`; draws the real result row.
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-$PWD/.build/leading-badge-renders}"; mkdir -p "$out"; out="$(cd "$out" && pwd)"
LEADING_BADGE_RENDER_OUT="$out" swift test --filter LeadingIconBadgeRenderSheet
echo "$out/sheet.png"
