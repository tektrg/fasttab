#!/usr/bin/env bash

set -euo pipefail

# Builds a fresh release binary and refreshes dist/FastTab.app in place.
# Preserves the existing bundle's Info.plist, Resources (icon) and embedded
# Sparkle.framework; replaces only the executable and re-signs.
#
# Usage:
#   scripts/build-app.sh [--open]

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

APP="dist/FastTab.app"
SIGN_IDENTITY="${FASTTAB_SIGN_IDENTITY:-Apple Development: luongtattrung@gmail.com (SELAV8N2B9)}"

[[ -d "${APP}" ]] || { echo "build-app: ${APP} not found (expected an existing bundle to refresh)" >&2; exit 1; }

echo "==> swift build -c release"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/FastTab"
[[ -f "${BIN}" ]] || { echo "build-app: built binary not found at ${BIN}" >&2; exit 1; }

echo "==> Installing binary into bundle"
cp "${BIN}" "${APP}/Contents/MacOS/FastTab"

# SwiftPM does not add the bundle's Frameworks dir to the rpath, so the embedded
# Sparkle.framework can't be found at runtime. Add it (idempotent).
if ! otool -l "${APP}/Contents/MacOS/FastTab" | grep -q "@executable_path/../Frameworks"; then
  echo "==> Adding @executable_path/../Frameworks rpath"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "${APP}/Contents/MacOS/FastTab"
fi

echo "==> Re-signing (deep)"
codesign --force --deep --options runtime \
  --sign "${SIGN_IDENTITY}" \
  "${APP}/Contents/Frameworks/Sparkle.framework" 2>/dev/null || true
codesign --force --deep --options runtime \
  --sign "${SIGN_IDENTITY}" \
  "${APP}"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "${APP}"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP}/Contents/Info.plist")"
echo "==> Done. ${APP} refreshed (v${version})"

if [[ "${1:-}" == "--open" ]]; then
  echo "==> Relaunching app"
  pkill -x FastTab 2>/dev/null || true
  open "${APP}"
fi
