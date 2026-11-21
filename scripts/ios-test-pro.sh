#!/usr/bin/env bash
# Run the iPhone app's unit tests (FastTabMobileTests) on the Pro's shared simulator.
#
# Usage (on the Pro):  scripts/ios-test-pro.sh [checkout-dir]     (default: this repo)
#   checkout-dir: a checkout with ../IndieLibKit next to it (a worktree at
#   ~/01_Project/wt-<slug>/command-bar-macos works).
# From the Air:  ssh mbp-m4 '~/01_Project/<wt>/command-bar-macos/scripts/ios-test-pro.sh'
#
# Why a script: the tests must run SIGNED. `CODE_SIGNING_ALLOWED=NO` strips the iCloud
# entitlement, SyncConsumer builds a CKContainer at launch and the test host traps before
# any test runs ("Early unexpected exit ... signal trap"). Holds the one shared simulator
# via mac-sim. Output: /tmp/ios-test-pro.log; exit code = xcodebuild's.
set -uo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export MAC_SIM_OWNER="${MAC_SIM_OWNER:-claude-ios-test-$$}"

root="$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd)"
log=/tmp/ios-test-pro.log
dd="${IOS_TEST_DD:-${root}/build/DerivedData-ios}"

[[ "$(hostname -s)" != *Air* ]] || { echo "run this on the Pro (the Air has no iOS simulator)" >&2; exit 2; }
command -v mac-sim >/dev/null || { echo "mac-sim not on PATH" >&2; exit 2; }
[[ -d "${root}/../IndieLibKit" ]] || { echo "missing ${root}/../IndieLibKit (ios/project.yml needs it)" >&2; exit 2; }

free_gb=$(( $(df -k / | awk 'NR==2{print $4}') / 1048576 ))
(( free_gb >= 2 )) || { echo "only ${free_gb} GB free; a test build needs ~2 GB (clear stale build files first)" >&2; exit 2; }

# Optional speed-up: a fresh derived-data dir downloads every package (~1 GB). If the Pro's main
# checkout still has a package cache, clone it (APFS clone, ~free). Without one the build just
# downloads (override the seed: IOS_TEST_PACKAGE_SEED).
seed="${IOS_TEST_PACKAGE_SEED:-$HOME/01_Project/command-bar-macos/ios/build/SourcePackages}"
if [[ ! -d "${dd}/SourcePackages" && -d "${seed}" ]]; then
  mkdir -p "${dd}" && cp -c -R "${seed}" "${dd}/SourcePackages" || exit 1
fi

cd "${root}/ios" && xcodegen generate -q || exit 1

mac-sim run --label "fasttab: iOS unit tests" -- bash -c \
  "arch -arm64 xcodebuild -project FastTabMobile.xcodeproj -scheme FastTabMobile \
     -destination \"id=\$SIM_UDID\" -derivedDataPath '${dd}' test" > "${log}" 2>&1
rc=$?

echo "ios tests rc=${rc} (log: ${log})"
grep -A30 '^Failing tests:' "${log}" | sed '/^$/q'
grep -m3 -E 'error:|BUILD FAILED|signal trap' "${log}"
grep -E 'Executed [0-9]+ tests, with' "${log}" | tail -1
exit "${rc}"
