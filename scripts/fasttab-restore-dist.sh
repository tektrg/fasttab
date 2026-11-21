#!/usr/bin/env bash
# Re-creates dist/FastTab.app (+ its entitlements file and signing profile) when dist/ was wiped.
#
#   scripts/fasttab-restore-dist.sh            # refuses if dist/FastTab.app already exists
#   scripts/fasttab-restore-dist.sh --force    # replace it
#   then: scripts/fasttab-build-mac-app.sh     # swaps in the current source build and re-signs
#
# Why this exists: fasttab-build-mac-app.sh only REFRESHES a bundle. The bundle itself (Info.plist,
# icon, URL scheme, Sparkle) was assembled by hand once and dist/ is gitignored, so a wiped dist/
# (2026-11-20) left nothing in the repo able to recreate it. The shell comes from the newest shipped
# release DMG in the website repo; the executables inside are replaced by the build script.
#
# What is RECONSTRUCTED, not recovered (the original dist/FastTab.entitlements was never in git):
#   the entitlement list below = apple-events (what the shipped app carries) + the keys
#   distribute.sh names + the Development profile's grants. Check it against the profile if the app
#   is ever SIGKILLed at launch (AMFI): an entitlement the profile does not grant does exactly that.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

FORCE=0; [[ "${1:-}" == "--force" ]] && FORCE=1
if [[ -e dist/FastTab.app && "${FORCE}" == 0 ]]; then
  echo "restore-dist: dist/FastTab.app exists; pass --force to replace it" >&2; exit 1
fi

DMG="$(ls ../theindieapp_website/public/fasttab/FastTab-*.dmg 2>/dev/null | sort -V | tail -1)"
[[ -n "${DMG}" ]] || { echo "restore-dist: no FastTab-*.dmg in ../theindieapp_website/public/fasttab" >&2; exit 1; }
PROFILE="${FASTTAB_PROVISION_PROFILE:-$(ls -t "${HOME}"/Downloads/FastTab_Mac_Development*.provisionprofile 2>/dev/null | head -1)}"
[[ -f "${PROFILE}" ]] || { echo "restore-dist: no FastTab_Mac_Development*.provisionprofile in ~/Downloads (set FASTTAB_PROVISION_PROFILE)" >&2; exit 1; }

mnt="$(mktemp -d)"; trap 'hdiutil detach "${mnt}" -quiet 2>/dev/null || true; rmdir "${mnt}" 2>/dev/null || true' EXIT
echo "==> Shell from ${DMG}"
hdiutil attach "${DMG}" -nobrowse -readonly -quiet -mountpoint "${mnt}"
mkdir -p dist
rm -rf dist/FastTab.app
ditto "${mnt}/FastTab.app" dist/FastTab.app

echo "==> Profile ${PROFILE}"
cp "${PROFILE}" dist/embedded.provisionprofile

echo "==> Entitlements (reconstructed, see header)"
cat > dist/FastTab.entitlements <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.automation.apple-events</key><true/>
  <key>com.apple.security.get-task-allow</key><true/>
  <key>com.apple.application-identifier</key><string>56S46Y7CKN.app.theindie.FastTab</string>
  <key>com.apple.developer.team-identifier</key><string>56S46Y7CKN</string>
  <key>com.apple.developer.applesignin</key><array><string>Default</string></array>
  <key>com.apple.developer.aps-environment</key><string>development</string>
  <key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array>
  <key>com.apple.developer.icloud-container-identifiers</key><array><string>iCloud.app.theindie.FastTab</string></array>
  <key>com.apple.developer.icloud-container-development-container-identifiers</key><array><string>iCloud.app.theindie.FastTab</string></array>
  <key>com.apple.developer.icloud-container-environment</key><string>Development</string>
</dict>
</plist>
PLIST
plutil -lint dist/FastTab.entitlements >/dev/null
echo "==> Restored. Now run scripts/fasttab-build-mac-app.sh"
