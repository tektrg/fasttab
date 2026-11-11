#!/usr/bin/env bash
# Render the tightest Mac onboarding steps (regular + compact window, light +
# dark) to one contact sheet: <dir>/sheet.png (default .build/onboarding-renders).
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(cd "$(dirname "${1:-.build/onboarding-renders}/x")" 2>/dev/null && pwd || true)"
out="${1:-$PWD/.build/onboarding-renders}"; mkdir -p "$out"; out="$(cd "$out" && pwd)"
ONBOARDING_RENDER_OUT="$out" swift test --filter OnboardingStepRenderSheet
echo "$out/sheet.png"
