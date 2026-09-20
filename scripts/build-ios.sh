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

# Resolve script location even if invoked via symlink
source_file="${BASH_SOURCE[0]}"
while [[ -L "${source_file}" ]]; do
  link_dir="$(cd -P "$(dirname "${source_file}")" && pwd)"
  source_file="$(readlink "${source_file}")"
  [[ "${source_file}" != /* ]] && source_file="${link_dir}/${source_file}"
done
script_dir="$(cd -P "$(dirname "${source_file}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
cd "${repo_root}/ios"

CONFIG="Debug"
CLEAN_BUILD=false
DEVICE_OVERRIDE="${FASTTAB_IOS_DEVICE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)
      CONFIG="Release"
      shift
      ;;
    --clean)
      CLEAN_BUILD=true
      shift
      ;;
    --device)
      DEVICE_OVERRIDE="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--release] [--clean] [--device <identifier>]"
      echo ""
      echo "Options:"
      echo "  --release   Build with Release configuration (default: Debug)"
      echo "  --clean     Wipe build artifacts before building"
      echo "  --device    Specific device identifier/name to target"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

SCHEME="FastTabMobile"
BUNDLE_ID="app.theindie.FastTabMobile"
DERIVED_DATA="build"

if [[ "${CLEAN_BUILD}" == true ]] && [[ -d "${DERIVED_DATA}" ]]; then
  echo "==> Cleaning ${DERIVED_DATA} directory"
  rm -rf "${DERIVED_DATA}"
fi

echo "==> xcodegen generate"
xcodegen generate

echo "==> Locating paired iPhone"
if [[ -n "${DEVICE_OVERRIDE}" ]]; then
  DEVICE_ID="${DEVICE_OVERRIDE}"
else
  devices_json="$(mktemp)"
  xcrun devicectl list devices --json-output "${devices_json}" >/dev/null
  device_info="$(python3 - "${devices_json}" <<'PY'
import json, sys

with open(sys.argv[1]) as f:
    data = json.load(f)

devices = [
    d for d in data.get("result", {}).get("devices", [])
    if d.get("hardwareProperties", {}).get("platform") == "iOS"
    and d.get("connectionProperties", {}).get("pairingState") == "paired"
]

if not devices:
    sys.exit(
        "Error: No paired iOS device found.\n"
        "Checklist:\n"
        "  1. Ensure your iPhone is unlocked and on the same Wi-Fi network.\n"
        "  2. In Xcode > Window > Devices and Simulators, verify 'Connect via network' is enabled."
    )

if len(devices) > 1:
    names = ", ".join(f"{d.get('deviceProperties', {}).get('name', 'Unknown')} ({d['identifier']})" for d in devices)
    sys.exit(f"Multiple paired iOS devices found: {names}.\nSet FASTTAB_IOS_DEVICE or use --device <id> to pick one.")

dev = devices[0]
name = dev.get("deviceProperties", {}).get("name", "iPhone")
model = dev.get("hardwareProperties", {}).get("marketingName") or dev.get("hardwareProperties", {}).get("productType", "")
ident = dev["identifier"]
print(f"{ident}\t{name}\t{model}")
PY
)"
  rm -f "${devices_json}"

  DEVICE_ID="$(echo "${device_info}" | cut -f1)"
  DEVICE_NAME="$(echo "${device_info}" | cut -f2)"
  DEVICE_MODEL="$(echo "${device_info}" | cut -f3)"
  echo "    target: ${DEVICE_NAME} (${DEVICE_MODEL})"
  echo "    device: ${DEVICE_ID}"
fi

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
