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
ENTITLEMENTS="dist/FastTab.entitlements"
SIGN_IDENTITY="${FASTTAB_SIGN_IDENTITY:-SELAV8N2B9}"

[[ -d "${APP}" ]] || { echo "build-app: ${APP} not found (expected an existing bundle to refresh)" >&2; exit 1; }

echo "==> swift build -c release"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/FastTab"
[[ -f "${BIN}" ]] || { echo "build-app: built binary not found at ${BIN}" >&2; exit 1; }

# Terminate any running instance and WAIT for it to actually exit before
# touching the bundle's executable. Overwriting/re-signing the binary in
# place while a live process still has it mapped trips the kernel's code
# integrity check on the next page-in — SIGKILL "Code Signature Invalid" —
# which looks like a random crash, not a build issue. Escalate to SIGKILL
# ourselves if a hung main run loop ignores SIGTERM.
if pkill -x FastTab 2>/dev/null; then
  echo "==> Stopping running instance before install"
  for _ in $(seq 1 20); do          # up to ~5s for a graceful exit
    pgrep -x FastTab >/dev/null || break
    sleep 0.25
  done
  if pgrep -x FastTab >/dev/null; then
    echo "==> Old instance ignored SIGTERM; force-killing"
    pkill -9 -x FastTab 2>/dev/null || true
    sleep 0.5
  fi
fi

echo "==> Installing binary into bundle"
cp "${BIN}" "${APP}/Contents/MacOS/FastTab"

# Second executable: the native-messaging host relay. The deep re-sign below
# covers it, so copying it before the sign step is all that's required here.
HOST_BIN="$(swift build -c release --show-bin-path)/FastTabNativeHost"
if [[ -f "${HOST_BIN}" ]]; then
  echo "==> Installing native host binary into bundle"
  cp "${HOST_BIN}" "${APP}/Contents/MacOS/FastTabNativeHost"
else
  echo "build-app: FastTabNativeHost binary not found (skipping host install)" >&2
fi

# SwiftPM does not add the bundle's Frameworks dir to the rpath, so the embedded
# Sparkle.framework can't be found at runtime. Add it (idempotent).
if ! otool -l "${APP}/Contents/MacOS/FastTab" | grep -q "@executable_path/../Frameworks"; then
  echo "==> Adding @executable_path/../Frameworks rpath"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "${APP}/Contents/MacOS/FastTab"
fi

# Embed provisioning profile for CloudKit / restricted entitlements if available
PROFILE="${FASTTAB_PROVISION_PROFILE:-dist/embedded.provisionprofile}"
if [[ -f "${PROFILE}" ]]; then
  echo "==> Embedding provisioning profile from ${PROFILE}"
  cp "${PROFILE}" "${APP}/Contents/embedded.provisionprofile"
elif [[ -f "${HOME}/Downloads/FastTab_Mac_Development.provisionprofile" ]]; then
  echo "==> Embedding provisioning profile from Downloads"
  cp "${HOME}/Downloads/FastTab_Mac_Development.provisionprofile" "${APP}/Contents/embedded.provisionprofile"
fi

echo "==> Re-signing (deep)"
codesign --force --deep --options runtime \
  --sign "${SIGN_IDENTITY}" \
  "${APP}/Contents/Frameworks/Sparkle.framework" 2>/dev/null || true
codesign --force --deep --options runtime \
  --entitlements "${ENTITLEMENTS}" \
  --sign "${SIGN_IDENTITY}" \
  "${APP}"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "${APP}"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP}/Contents/Info.plist")"
echo "==> Done. ${APP} refreshed (v${version})"

if [[ "${1:-}" == "--open" ]]; then
  echo "==> Relaunching app"
  open "${APP}"
fi
