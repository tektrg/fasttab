#!/usr/bin/env bash

set -euo pipefail

# Builds ios/FastTabMobile and installs it on a paired iPhone over the
# network (no cable required) using `xcrun devicectl`, which talks to any
# device already paired for wireless debugging (Xcode > Window > Devices
# and Simulators > check "Connect via network" once, with the phone
# plugged in).
#
# Usage:
#   scripts/build-ios.sh [--release] [--clean] [--wait] [--device <id>]
#
# Checks the phone is reachable (unlocked, tunnel up) before building.
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
WAIT_FOR_DEVICE=false
WAIT_SECONDS=120

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
    --wait)
      WAIT_FOR_DEVICE=true
      shift
      ;;
    --device)
      DEVICE_OVERRIDE="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--release] [--clean] [--wait] [--device <identifier>]"
      echo ""
      echo "Options:"
      echo "  --release   Build with Release configuration (default: Debug)"
      echo "  --clean     Wipe build artifacts before building"
      echo "  --wait      If the iPhone isn't reachable, poll up to 2 min before giving up"
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

# Preflight: find the paired iPhone and make sure it is reachable right now
# (tunnel up), so an asleep/locked/off-Wi-Fi phone fails in seconds instead
# of after a ~3 min build. Prints "<id>\t<name>\t<model>" or exits non-zero
# (2 = paired but not reachable).
find_reachable_device() {
  local devices_json
  devices_json="$(mktemp)"
  xcrun devicectl list devices --json-output "${devices_json}" >/dev/null 2>&1 || true
  python3 - "${devices_json}" "${DEVICE_OVERRIDE}" <<'PY2'
import json, sys

try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except (OSError, ValueError):
    sys.exit("Error: could not read `xcrun devicectl list devices` output.")
wanted = sys.argv[2]

def matches(d):
    if not wanted:
        return True
    conn = d.get("connectionProperties", {})
    names = {d.get("identifier"), d.get("deviceProperties", {}).get("name"),
             d.get("hardwareProperties", {}).get("udid")} | set(conn.get("potentialHostnames", []))
    return wanted in names

devices = [
    d for d in data.get("result", {}).get("devices", [])
    if d.get("hardwareProperties", {}).get("platform") == "iOS"
    and d.get("connectionProperties", {}).get("pairingState") == "paired"
    and matches(d)
]

if not devices:
    sys.exit(
        f"Error: No paired iOS device found{' matching ' + wanted if wanted else ''}.\n"
        "In Xcode > Window > Devices and Simulators, verify 'Connect via network' is enabled."
    )

if len(devices) > 1:
    names = ", ".join(f"{d.get('deviceProperties', {}).get('name', 'Unknown')} ({d['identifier']})" for d in devices)
    sys.exit(f"Multiple paired iOS devices found: {names}.\nSet FASTTAB_IOS_DEVICE or use --device <id> to pick one.")

dev = devices[0]
if dev.get("connectionProperties", {}).get("tunnelState") != "connected":
    sys.exit(2)
name = dev.get("deviceProperties", {}).get("name", "iPhone")
model = dev.get("hardwareProperties", {}).get("marketingName") or dev.get("hardwareProperties", {}).get("productType", "")
print(f"{dev['identifier']}\t{name}\t{model}")
PY2
  local status=$?
  rm -f "${devices_json}"
  return "${status}"
}

UNREACHABLE_MSG="iPhone not reachable: unlock it and keep it on the same Wi-Fi as this Mac (or plug in a cable), then rerun"

echo "==> Checking the iPhone is reachable"
wait_deadline=$(( SECONDS + WAIT_SECONDS ))
while true; do
  status=0
  device_info="$(find_reachable_device)" || status=$?
  [[ "${status}" -eq 0 ]] && break
  [[ "${status}" -ne 2 ]] && exit 1
  if [[ "${WAIT_FOR_DEVICE}" != true ]] || (( SECONDS >= wait_deadline )); then
    echo "${UNREACHABLE_MSG}" >&2
    [[ "${WAIT_FOR_DEVICE}" != true ]] && echo "    (or rerun with --wait to poll for up to $(( WAIT_SECONDS / 60 )) min)" >&2
    exit 1
  fi
  echo "    not reachable yet, retrying in 5s (unlock the phone)"
  sleep 5
done

DEVICE_ID="$(echo "${device_info}" | cut -f1)"
DEVICE_NAME="$(echo "${device_info}" | cut -f2)"
DEVICE_MODEL="$(echo "${device_info}" | cut -f3)"
echo "    target: ${DEVICE_NAME} (${DEVICE_MODEL})"
echo "    device: ${DEVICE_ID}"

echo "==> xcodegen generate"
xcodegen generate

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
# Phones sometimes drop right after a long build; retry once after a pause.
if ! xcrun devicectl device install app --device "${DEVICE_ID}" "${APP_PATH}"; then
  echo "    install failed, retrying in 10s (keep the phone unlocked)"
  sleep 10
  xcrun devicectl device install app --device "${DEVICE_ID}" "${APP_PATH}" \
    || { echo "${UNREACHABLE_MSG}" >&2; exit 1; }
fi

echo "==> Launching"
xcrun devicectl device process launch --device "${DEVICE_ID}" --terminate-existing "${BUNDLE_ID}"

echo "==> Done"
