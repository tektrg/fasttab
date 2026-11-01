#!/bin/bash
# Raw FastTab Reader captures for the App Store set, on the demo library (AppStoreDemo.swift, Debug only).
# usage: capture.sh            → marketing/appstore/tools/raw/en/<shot>.png (git-ignored)
# Builds, takes the shared simulator (mac-sim), backs up the app's data + App Group, launches
# once per screen with -FastTabAppStoreDemo, screenshots, then restores the backup.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"; TOOLS="$ROOT/marketing/appstore/tools"
DD="$ROOT/ios/build/AppStoreDD"
cd "$ROOT/ios"
lockf -k /tmp/fasttab-ios-xcodebuild.lock xcodebuild -project FastTabMobile.xcodeproj -scheme FastTabMobile \
  -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD" build -quiet 2>&1 | grep -E "error:" || true
export APP="$DD/Build/Products/Debug-iphonesimulator/FastTabMobile.app" OUT="$TOOLS/raw/en"
[ -d "$APP" ] || { echo "build failed: $APP missing" >&2; exit 1; }
mac-sim run --label "command-bar-macos: FastTab Reader appstore screenshots" -- bash -c '
  set -e
  BID=app.theindie.FastTabMobile; BK=/tmp/fasttab-appstore-backup; rm -rf "$BK"; mkdir -p "$BK" "$OUT"
  DATA=$(xcrun simctl get_app_container "$SIM_UDID" $BID data 2>/dev/null || true)
  GROUP=$(xcrun simctl get_app_container "$SIM_UDID" $BID group.app.theindie.FastTab 2>/dev/null || true)
  [ -n "$DATA" ] && cp -R "$DATA" "$BK/data"; [ -n "$GROUP" ] && cp -R "$GROUP" "$BK/group"
  restore() {
    xcrun simctl terminate "$SIM_UDID" $BID 2>/dev/null || true
    xcrun simctl status_bar "$SIM_UDID" clear || true
    if [ -d "$BK/data" ]; then D=$(xcrun simctl get_app_container "$SIM_UDID" $BID data); rsync -a --delete "$BK/data/" "$D/"; fi
    if [ -d "$BK/group" ]; then G=$(xcrun simctl get_app_container "$SIM_UDID" $BID group.app.theindie.FastTab); rsync -a --delete "$BK/group/" "$G/"; fi
    if [ -z "$DATA" ]; then xcrun simctl uninstall "$SIM_UDID" $BID || true; fi
    echo "restored simulator app data"
  }
  trap restore EXIT
  # Fresh containers: the demo library only, nothing left from earlier simulator use.
  xcrun simctl uninstall "$SIM_UDID" $BID 2>/dev/null || true
  xcrun simctl install "$SIM_UDID" "$APP"
  xcrun simctl status_bar "$SIM_UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
  xcrun simctl ui "$SIM_UDID" appearance light
  for S in 1-tabs:tabs 2-youtube:transcript 3-listen:listen 4-shuffle:swipe 5-reader:reader 6-bookmarks:bookmarks 7-highlights:highlights 8-read:read 9-stats:more; do
    NAME=${S%%:*}; SCREEN=${S#*:}
    xcrun simctl terminate "$SIM_UDID" $BID 2>/dev/null || true
    xcrun simctl launch "$SIM_UDID" $BID -FastTabAppStoreDemo YES -FastTabDemoScreen $SCREEN \
      -FastTabAppMode mac -FastTabStatsDemo YES -onboarding.v1.completed YES -AppleLanguages "(en)" -AppleLocale en_US >/dev/null
    if [ $SCREEN = listen ]; then sleep 12; else sleep 7; fi
    xcrun simctl io "$SIM_UDID" screenshot "$OUT/$NAME.png" >/dev/null 2>&1
    echo "captured $NAME"
  done
'
ls "$OUT"
