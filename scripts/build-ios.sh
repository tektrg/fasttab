#!/usr/bin/env bash

set -euo pipefail

# Builds ios/FastTabMobile and installs it on a paired iPhone over the
# network (no cable required) using `xcrun devicectl`, which talks to any
# device already paired for wireless debugging (Xcode > Window > Devices
# and Simulators > check "Connect via network" once, with the phone
# plugged in).
#
# Usage:
#   scripts/build-ios.sh [--release]
#
# Env overrides:
#   FASTTAB_IOS_DEVICE   Device UUID/name/dns_name to target, skips
#                        auto-detection (needed if more than one iOS
#                        device is paired).

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}/ios"

CONFIG="Debug"
if [[ "${1:-}" == "--release" ]]; then
  CONFIG="Release"
fi

SCHEME="FastTabMobile"
BUNDLE_ID="app.theindie.FastTabMobile"
DERIVED_DATA="build"

echo "==> xcodegen generate"
xcodegen generate

echo "==> Locating paired iPhone"
if [[ -n "${FASTTAB_IOS_DEVICE:-}" ]]; then
  DEVICE_ID="${FASTTAB_IOS_DEVICE}"
else
  devices_json="$(mktemp)"
  xcrun devicectl list devices --json-output "${devices_json}" >/dev/null
  DEVICE_ID="$(python3 - "${devices_json}" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
devices = [
    d for d in data["result"]["devices"]
    if d.get("hardwareProperties", {}).get("platform") == "iOS"
    and d.get("connectionProperties", {}).get("pairingState") == "paired"
]
if not devices:
    sys.exit("no paired iOS device found")
if len(devices) > 1:
    names = ", ".join(d["deviceProperties"]["name"] for d in devices)
    sys.exit(f"multiple paired iOS devices ({names}); set FASTTAB_IOS_DEVICE to the one to use")
print(devices[0]["identifier"])
PY
)"
  rm -f "${devices_json}"
fi
echo "    device: ${DEVICE_ID}"

echo "==> xcodebuild (${CONFIG})"
xcodebuild_args=(
  build
  -project FastTabMobile.xcodeproj
  -scheme "${SCHEME}"
  -configuration "${CONFIG}"
  -destination "generic/platform=iOS"
  -derivedDataPath "${DERIVED_DATA}"
  -allowProvisioningUpdates
)
if command -v xcbeautify >/dev/null 2>&1; then
  xcodebuild "${xcodebuild_args[@]}" | xcbeautify
else
  xcodebuild "${xcodebuild_args[@]}"
fi

APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIG}-iphoneos/FastTabMobile.app"
[[ -d "${APP_PATH}" ]] || { echo "build-ios: ${APP_PATH} not found" >&2; exit 1; }

echo "==> Installing on device"
xcrun devicectl device install app --device "${DEVICE_ID}" "${APP_PATH}"

echo "==> Launching"
xcrun devicectl device process launch --device "${DEVICE_ID}" --terminate-existing "${BUNDLE_ID}"

echo "==> Done"
