#!/usr/bin/env bash
# Runs the pure profile-name tests (Tests/FastTabTests/ProfileNamesTests.swift) without a Mac:
# a throwaway package compiles Sources/FastTab/ProfileNames.swift alone under the module name
# FastTab, so `@testable import FastTab` works. Needs a Swift toolchain (swiftly on the Linux VM).
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/FastTab" "$work/Tests/FastTabTests"
cp "$repo/Sources/FastTab/ProfileNames.swift" "$work/Sources/FastTab/"
cp "$repo/Tests/FastTabTests/ProfileNamesTests.swift" "$work/Tests/FastTabTests/"
cat > "$work/Package.swift" <<'PKG'
// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "ProfileNamesHarness", targets: [
    .target(name: "FastTab", swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "FastTabTests", dependencies: ["FastTab"], swiftSettings: [.swiftLanguageMode(.v5)]),
])
PKG
[ -f "$HOME/.local/share/swiftly/env.sh" ] && source "$HOME/.local/share/swiftly/env.sh"
cd "$work" && swift test 2>&1 | grep -E '✘|✔ Test run|error:' 
