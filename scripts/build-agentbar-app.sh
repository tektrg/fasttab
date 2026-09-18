#!/usr/bin/env bash

set -euo pipefail

# Builds a fresh release binary and CREATES dist/AgentBar.app from scratch.
# Unlike build-app.sh (which refreshes a hand-prepared FastTab bundle), AgentBar
# has nothing to preserve: no Sparkle, no entitlements, no provisioning profile.
#
# Usage:
#   scripts/build-agentbar-app.sh [--open]

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

APP="dist/AgentBar.app"
BUNDLE_ID="com.trungluong.AgentBar"
SIGN_IDENTITY="${FASTTAB_SIGN_IDENTITY:-SELAV8N2B9}"

echo "==> swift build -c release --product AgentBar"
swift build -c release --product AgentBar

BIN="$(swift build -c release --show-bin-path)/AgentBar"
[[ -f "${BIN}" ]] || { echo "build-agentbar-app: built binary not found at ${BIN}" >&2; exit 1; }

# Terminate any running instance and WAIT for it to actually exit before
# replacing the executable. Overwriting/re-signing the binary while a live
# process still has it mapped trips the kernel's code integrity check on the
# next page-in — SIGKILL "Code Signature Invalid" — which looks like a random
# crash. Escalate to SIGKILL if a hung main run loop ignores SIGTERM.
if pkill -x AgentBar 2>/dev/null; then
  echo "==> Stopping running instance before install"
  for _ in $(seq 1 20); do          # up to ~5s for a graceful exit
    pgrep -x AgentBar >/dev/null || break
    sleep 0.25
  done
  if pgrep -x AgentBar >/dev/null; then
    echo "==> Old instance ignored SIGTERM; force-killing"
    pkill -9 -x AgentBar 2>/dev/null || true
    sleep 0.5
  fi
fi

echo "==> Assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS"
cp "${BIN}" "${APP}/Contents/MacOS/AgentBar"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>AgentBar</string>
  <key>CFBundleDisplayName</key><string>AgentBar</string>
  <key>CFBundleExecutable</key><string>AgentBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Developer ID / development identity if it is in the keychain, else ad-hoc.
if security find-identity -v -p codesigning | grep -q "${SIGN_IDENTITY}"; then
  echo "==> Signing with ${SIGN_IDENTITY}"
  codesign --force --options runtime --sign "${SIGN_IDENTITY}" "${APP}"
else
  echo "==> Identity ${SIGN_IDENTITY} not in keychain; signing ad-hoc"
  codesign --force --sign - "${APP}"
fi

echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "${APP}"
echo "==> Done. ${APP} created"

if [[ "${1:-}" == "--open" ]]; then
  echo "==> Launching app"
  open "${APP}"
fi
