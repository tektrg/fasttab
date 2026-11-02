#!/usr/bin/env bash
# Archive FastTab Reader (ios/) in Release, export an App Store IPA, check its entitlements,
# upload it to TestFlight with the asc CLI and set the "What to Test" notes.
#
# Run ON THE PRO inside its GUI-session tmux (codesign needs the unlocked login keychain):
#   scripts/fasttab-ios-testflight.sh marketing/appstore/testflight-notes-<version>-<build>.txt
# The build number is whatever ios/project.yml says (bump + commit it first).
# Env: ASC_PROFILE (CraftAgentApstoreConnect), ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
notes_file="$(cd "${repo_root}" && realpath "${1:?usage: $0 <notes.txt>}")"

APP_ID=6828689539 # FastTab Reader (app.theindie.FastTabMobile)
TEAM_ID=56S46Y7CKN
export ASC_PROFILE="${ASC_PROFILE:-CraftAgentApstoreConnect}"
ASC_KEY_ID="${ASC_KEY_ID:-U9RVTQA9CK}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-61b86e20-5703-42b1-afc4-ecf9714f6013}"
ASC_KEY_PATH="${ASC_KEY_PATH:-${HOME}/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"

cd "${repo_root}/ios"
[[ -z "$(git status --porcelain)" ]] || { echo "ios/ checkout is dirty; commit first" >&2; exit 1; }
build="$(grep -m1 -E '^[[:space:]]*CURRENT_PROJECT_VERSION:' project.yml | grep -oE '[0-9]+')"
version="$(grep -m1 -E '^[[:space:]]*MARKETING_VERSION:' project.yml | grep -oE '[0-9.]+')"
[[ -s "${notes_file}" ]] || { echo "notes file empty: ${notes_file}" >&2; exit 1; }
(( $(wc -c < "${notes_file}") <= 4000 )) || { echo "notes over 4000 chars" >&2; exit 1; }
echo "==> FastTab Reader ${version} (${build}) from $(git rev-parse --abbrev-ref HEAD)@$(git rev-parse --short HEAD)"

out="${repo_root}/.build/testflight/${build}"
rm -rf "${out}"; mkdir -p "${out}"
auth=(-allowProvisioningUpdates -authenticationKeyPath "${ASC_KEY_PATH}"
      -authenticationKeyID "${ASC_KEY_ID}" -authenticationKeyIssuerID "${ASC_ISSUER_ID}")

xcodegen generate -q
echo "==> archive"
xcodebuild -project FastTabMobile.xcodeproj -scheme FastTabMobile -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "${out}/FastTab.xcarchive" "${auth[@]}" \
  archive -quiet

cat > "${out}/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>${TEAM_ID}</string>
</dict></plist>
EOF
echo "==> export"
xcodebuild -exportArchive -archivePath "${out}/FastTab.xcarchive" -exportPath "${out}/export" \
  -exportOptionsPlist "${out}/ExportOptions.plist" "${auth[@]}" -quiet
ipa="$(ls "${out}"/export/*.ipa)"
scripts/check-ipa-entitlements.sh "${ipa}"

echo "==> upload ${ipa##*/}"
asc builds upload --app "${APP_ID}" --ipa "${ipa}"
asc builds wait --app "${APP_ID}" --build-number "${build}" --platform IOS
asc builds update --app "${APP_ID}" --build-number "${build}" --platform IOS --uses-non-exempt-encryption=false || true
notes="$(cat "${notes_file}")"
asc builds test-notes update --app "${APP_ID}" --build-number "${build}" --platform IOS --locale en-US --whats-new "${notes}" \
  || asc builds test-notes create --app "${APP_ID}" --build-number "${build}" --platform IOS --locale en-US --whats-new "${notes}"
asc builds test-notes view --app "${APP_ID}" --build-number "${build}" --platform IOS --locale en-US
echo "==> TestFlight build ${build} uploaded"
