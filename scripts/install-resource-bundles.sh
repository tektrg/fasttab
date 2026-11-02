#!/usr/bin/env bash
# Usage: install-resource-bundles.sh <swiftpm-bin-path> <App.app>
#
# SwiftPM keeps a dependency's resources in `<Package>_<Target>.bundle` beside the built binary.
# The app build scripts copy only the executable, so without this step the shipped app has no
# resources: the generated `Bundle.module` finds nothing in `Contents/Resources` and traps
# (Settings > Highlights crashed this way — IndieTable's `table-core.js`). It only appeared to work
# on the Mac that built the app, where SwiftPM's lookup falls back to the build folder.
#
# Copies ONLY the allow-listed bundles into `Contents/Resources` (where the `Bundle.module`
# lookup lands). The build folder also holds test-fixture bundles (`*Tests.bundle`) that must
# never ship, so there is deliberately no glob. A new runtime dependency with resources must be
# added to REQUIRED (crashes without it) or OPTIONAL (nice to have) below.
# Run it BEFORE the final codesign of the app so the seal covers the bundles.
# A REQUIRED bundle the build did not produce is an error, not a skip.
set -euo pipefail

BIN_DIR="${1:?usage: install-resource-bundles.sh <swiftpm-bin-path> <App.app>}"
APP="${2:?usage: install-resource-bundles.sh <swiftpm-bin-path> <App.app>}"
DEST="${APP}/Contents/Resources"

# Resource bundles the app cannot run without (crash on first use if absent).
REQUIRED=(IndieLibKit_IndieTable.bundle)
# Shipped when present: GRDB's privacy manifest (no runtime lookup).
OPTIONAL=(GRDB_GRDB.bundle)

[[ -d "${DEST}" ]] || { echo "install-resource-bundles: ${DEST} not found" >&2; exit 1; }

for name in "${REQUIRED[@]}"; do
  [[ -d "${BIN_DIR}/${name}" ]] || {
    echo "install-resource-bundles: required ${name} not found in ${BIN_DIR}" >&2
    exit 1
  }
done

# The app is refreshed in place, so drop bundles an older build shipped that are no longer wanted.
ALLOWED=" ${REQUIRED[*]} ${OPTIONAL[*]} "
shopt -s nullglob
for existing in "${DEST}"/*.bundle; do
  name="$(basename "${existing}")"
  if [[ "${ALLOWED}" != *" ${name} "* ]]; then
    rm -rf "${existing}"
    echo "==> Removed stale resource bundle ${name}"
  fi
done

for name in "${REQUIRED[@]}" "${OPTIONAL[@]}"; do
  [[ -d "${BIN_DIR}/${name}" ]] || continue
  rm -rf "${DEST:?}/${name}"
  cp -R "${BIN_DIR}/${name}" "${DEST}/${name}"
  echo "==> Installed resource bundle ${name}"
done
