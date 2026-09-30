#!/usr/bin/env bash

set -euo pipefail

# Renders every Mac onboarding hero (Sources/FastTab/OnboardingHeroes) at the
# chosen times, light and dark, into PNGs plus a contact sheet (sheet.png).
# Runs the env-gated HeroRenderSheet test; normal `swift test` skips it.
# Mac only: iOS heroes and IndieMotion cards (pop-in on appear) aren't covered.
#
# Usage:
#   scripts/render-heroes.sh [--out <dir>] [--times 0,0.5,settled]

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

OUT_DIR="${repo_root}/.build/hero-renders"
TIMES="0,0.5,1,1.5,settled"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      OUT_DIR="$2"
      shift 2
      ;;
    --times)
      TIMES="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--out <dir>] [--times 0,0.5,settled]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "${OUT_DIR}"
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"

cd "${repo_root}"
HERO_RENDER_OUT="${OUT_DIR}" HERO_RENDER_TIMES="${TIMES}" \
  swift test --filter HeroRenderSheet

echo "==> Sheet: ${OUT_DIR}/sheet.png"
