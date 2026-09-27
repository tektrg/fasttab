#!/usr/bin/env bash

set -euo pipefail

# Builds a fresh release binary and refreshes dist/FastTab.app in place.
# Preserves the existing bundle's Info.plist, Resources (icon) and embedded
# Sparkle.framework; replaces only the executable and re-signs.
#
# Usage:
#   scripts/fasttab-build-mac-app.sh
#
# Always relaunches the app after refreshing the bundle. Pass --no-open to
# skip that (e.g. for scripted builds where nothing should pop to front).

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

# Second executable: the native-messaging host relay. It is signed separately
# below (see the inside-out signing block) — never by a --deep sweep of the app.
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

# Inside-out signing: nested code first (each with only the entitlements it
# actually needs), then the outer bundle. Never use --deep to sign: --deep
# applies the SAME entitlements to every nested executable, which is what broke
# the Chrome extension — see the native-host note below.
echo "==> Re-signing nested code"
codesign --force --options runtime \
  --sign "${SIGN_IDENTITY}" \
  "${APP}/Contents/Frameworks/Sparkle.framework" 2>/dev/null || true

# The native-messaging host relay MUST be signed with NO entitlements.
# Chrome launches it directly by absolute path, so the app bundle's embedded
# provisioning profile does not apply to it, and its signing identifier
# (FastTabNativeHost) can never match the profile's app ID anyway. If it carries
# the app's profile-restricted entitlements (com.apple.application-identifier,
# com.apple.developer.icloud-*), AMFI SIGKILLs it the instant Chrome execs it —
# Chrome then reports "Native host has exited" and the extension never connects.
# The relay is a pure stdio<->Unix-socket byte pump: it needs no entitlements at
# all. Keep --options runtime though: hardened runtime is required to notarize.
if [[ -f "${APP}/Contents/MacOS/FastTabNativeHost" ]]; then
  echo "==> Re-signing native host (no entitlements — see comment above)"
  codesign --force --options runtime \
    --sign "${SIGN_IDENTITY}" \
    "${APP}/Contents/MacOS/FastTabNativeHost"
fi

# aps-environment (CloudKit push, i.e. realtime sync) is a *profile-restricted*
# entitlement: signing it into a bundle whose embedded profile does not grant it
# gets the app SIGKILLed by AMFI at launch — the same failure mode documented for
# the native host above, and it looks like a random crash, not a signing problem.
#
# So the entitlement follows the profile rather than the other way round. Until
# the App ID has the Push Notifications capability and the profile is
# regenerated, the app signs without it and sync falls back to its poll. Nothing
# to remember, nothing to undo: drop in a push-enabled profile and the next
# build picks the entitlement up.
SIGNING_ENTITLEMENTS="${ENTITLEMENTS}"
if [[ -f "${APP}/Contents/embedded.provisionprofile" ]] && \
   security cms -D -i "${APP}/Contents/embedded.provisionprofile" 2>/dev/null \
     | grep -q "aps-environment"; then
  echo "==> Profile grants push; signing with aps-environment (realtime sync enabled)"
else
  echo "==> Profile has no Push Notifications capability; signing without aps-environment"
  echo "    (sync still works on its poll — regenerate the profile to get realtime)"
  SIGNING_ENTITLEMENTS="$(mktemp -t FastTabEntitlements).plist"
  cp "${ENTITLEMENTS}" "${SIGNING_ENTITLEMENTS}"
  /usr/libexec/PlistBuddy -c "Delete :com.apple.developer.aps-environment" \
    "${SIGNING_ENTITLEMENTS}" >/dev/null 2>&1 || true
fi

echo "==> Re-signing app bundle"
codesign --force --options runtime \
  --entitlements "${SIGNING_ENTITLEMENTS}" \
  --sign "${SIGN_IDENTITY}" \
  "${APP}"

# --deep IS correct for verification (it walks nested code); it is only signing
# that must stay shallow.
echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "${APP}"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP}/Contents/Info.plist")"
echo "==> Done. ${APP} refreshed (v${version})"

if [[ "${1:-}" != "--no-open" ]]; then
  echo "==> Relaunching app"
  open "${APP}"
fi
