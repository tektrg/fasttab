#!/usr/bin/env bash

set -euo pipefail

# Builds a fresh release binary and CREATES dist/AgentBar.app from scratch.
# Unlike fasttab-build-mac-app.sh (which refreshes a hand-prepared FastTab bundle), AgentBar
# has nothing to preserve: no Sparkle, no entitlements, no provisioning profile.
#
# Usage:
#   scripts/build-agentbar-app.sh [--open]

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

APP="dist/AgentBar.app"
BUNDLE_ID="com.trungluong.AgentBar"
SIGN_IDENTITY="${FASTTAB_SIGN_IDENTITY:-SELAV8N2B9}"

# This checkout is often shared by multiple concurrent Claude Code sessions.
# Two overlapping runs of this script raced once and left dist/AgentBar.app
# holding a stale binary while still printing success — serialize instead.
# `mkdir` is atomic on a POSIX filesystem, unlike `flock` this needs no tool
# macOS doesn't ship by default. Self-heals if a prior run crashed/was killed
# without cleaning up (stale lock whose owning PID is no longer alive).
LOCK_DIR=".build/.agentbar-build.lock.d"
mkdir -p .build
waited=0
announced=0
while ! mkdir "${LOCK_DIR}" 2>/dev/null; do
  owner_pid="$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
  if [[ -n "${owner_pid}" ]] && ! kill -0 "${owner_pid}" 2>/dev/null; then
    echo "==> Removing stale build lock (owning process ${owner_pid} is gone)"
    rm -rf "${LOCK_DIR}"
    continue
  fi
  if [[ "${announced}" == 0 ]]; then
    echo "==> Another build-agentbar-app.sh is running; waiting for it to finish..."
    announced=1
  fi
  sleep 1
  waited=$((waited + 1))
  if (( waited > 300 )); then
    echo "build-agentbar-app: waited 5 minutes for the build lock; giving up" >&2
    exit 1
  fi
done
echo $$ > "${LOCK_DIR}/pid"
trap 'rm -rf "${LOCK_DIR}"' EXIT

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
BIN_HASH="$(shasum -a 256 "${BIN}" | awk '{print $1}')"
cp "${BIN}" "${APP}/Contents/MacOS/AgentBar"

# Belt-and-suspenders for the race above: confirm the bytes that landed in
# dist/ are exactly the ones just compiled, before we sign/launch them.
INSTALLED_HASH="$(shasum -a 256 "${APP}/Contents/MacOS/AgentBar" | awk '{print $1}')"
if [[ "${BIN_HASH}" != "${INSTALLED_HASH}" ]]; then
  echo "build-agentbar-app: installed binary doesn't match the one just built (hash mismatch) — aborting before signing/launching a stale app" >&2
  exit 1
fi

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
