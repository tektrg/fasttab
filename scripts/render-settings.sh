#!/usr/bin/env bash

set -euo pipefail

# Renders the Settings window on the Views page (sidebar + page; empty and with saved views)
# light and dark, to PNGs. Runs the env-gated SettingsWindowRenderSheet test;
# normal `swift test` skips it.
#
# Usage:
#   scripts/render-settings.sh [--out <dir>]

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

OUT_DIR="${repo_root}/.build/settings-renders"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      OUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--out <dir>]"
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
SETTINGS_RENDER_OUT="${OUT_DIR}" swift test --filter SettingsWindowRenderSheet

echo "==> PNGs: ${OUT_DIR}"
