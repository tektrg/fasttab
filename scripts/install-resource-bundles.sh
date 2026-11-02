#!/usr/bin/env bash
# Usage: install-resource-bundles.sh <swiftpm-bin-path> <App.app>
#
# SwiftPM keeps a dependency's resources in `<Package>_<Target>.bundle` beside the built binary.
# The app build scripts copy only the executable, so without this step the shipped app has no
# resources: the generated `Bundle.module` finds nothing in `Contents/Resources` and traps
# (Settings > Highlights crashed this way — IndieTable's `table-core.js`). It only appeared to work
# on the Mac that built the app, where SwiftPM's lookup falls back to the build folder.
#
# Copies every `*.bundle` into `Contents/Resources` (where `Bundle.main.resourceURL` lookup lands).
# Run it BEFORE the final codesign of the app so the seal covers the bundles.
# A bundle listed in REQUIRED that the build did not produce is an error, not a skip.
set -euo pipefail

BIN_DIR="${1:?usage: install-resource-bundles.sh <swiftpm-bin-path> <App.app>}"
APP="${2:?usage: install-resource-bundles.sh <swiftpm-bin-path> <App.app>}"
DEST="${APP}/Contents/Resources"

# Resource bundles the app cannot run without (crash on first use if absent).
REQUIRED=(IndieLibKit_IndieTable.bundle)

[[ -d "${DEST}" ]] || { echo "install-resource-bundles: ${DEST} not found" >&2; exit 1; }

for name in "${REQUIRED[@]}"; do
  [[ -d "${BIN_DIR}/${name}" ]] || {
    echo "install-resource-bundles: required ${name} not found in ${BIN_DIR}" >&2
    exit 1
  }
done

shopt -s nullglob
for bundle in "${BIN_DIR}"/*.bundle; do
  name="$(basename "${bundle}")"
  rm -rf "${DEST:?}/${name}"
  cp -R "${bundle}" "${DEST}/${name}"
  echo "==> Installed resource bundle ${name}"
done
