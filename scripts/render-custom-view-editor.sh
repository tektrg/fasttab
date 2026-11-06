#!/usr/bin/env bash

set -euo pipefail

# Renders the custom view builder (form + footer) at every command bar width
# (edge-anchored narrow, notch minimal, notch full, Settings sheet), dark
# mode, to PNGs — to check nothing is clipped. Runs the env-gated
# CustomViewEditorRenderSheet test; normal `swift test` skips it.
#
# Usage:
#   scripts/render-custom-view-editor.sh [--out <dir>]

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

OUT_DIR="${repo_root}/.build/custom-view-editor-renders"

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
CUSTOM_VIEW_EDITOR_RENDER_OUT="${OUT_DIR}" swift test --filter CustomViewEditorRenderSheet

echo "==> PNGs: ${OUT_DIR}"
