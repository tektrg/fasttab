#!/usr/bin/env bash

# Full distribution pipeline: build → sign → notarize → DMG → appcast → deploy.
# Run after scripts/release.sh has tagged and pushed the git release.
#
# Usage:
#   scripts/distribute.sh VERSION "Release notes text" [--skip-notarize] [--dry-run]
#
# Prerequisites:
#   .env file with credentials (see README), or set env vars:
#     FASTTAB_APPLE_ID, FASTTAB_APPLE_TEAM_ID, FASTTAB_APPLE_APP_PASSWORD
#     FASTTAB_POLAR_* production values (see .env for keys)
#   Developer ID Application certificate in Keychain
#   Sparkle sign_update tool (run: swift package resolve)
#   theindieapp_website repo at ../theindieapp_website with wrangler configured

set -euo pipefail

# ─── Helpers ─────────────────────────────────────────────────────────────────

die()  { echo "distribute: error: $*" >&2; exit 1; }
info() { echo "==> $*"; }
run()  {
  echo "+ $*"
  if [[ "${DRY_RUN}" == "false" ]]; then "$@"; fi
}

# ─── Args ────────────────────────────────────────────────────────────────────

VERSION=""
RELEASE_NOTES=""
SKIP_NOTARIZE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-notarize) SKIP_NOTARIZE=true; shift ;;
    --dry-run)       DRY_RUN=true;       shift ;;
    -h|--help)
      sed -n '3,9p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    -*)  die "unknown option: $1" ;;
    *)
      if [[ -z "${VERSION}" ]]; then
        VERSION="$1"
      elif [[ -z "${RELEASE_NOTES}" ]]; then
        RELEASE_NOTES="$1"
      else
        die "unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

[[ -n "${VERSION}" ]]       || die "VERSION is required  (e.g. 1.6.0)"
[[ -n "${RELEASE_NOTES}" ]] || die "RELEASE_NOTES is required  (e.g. \"Bug fixes and performance improvements\")"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be semver (e.g. 1.6.0)"

# ─── Paths ───────────────────────────────────────────────────────────────────

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "${REPO_ROOT}"

APP="dist/FastTab.app"
ENTITLEMENTS="dist/FastTab.entitlements"
INFO_PLIST="${APP}/Contents/Info.plist"
FRAMEWORKS="${APP}/Contents/Frameworks/Sparkle.framework"
RELEASE_DIR="dist/release"
DMG_PATH="${RELEASE_DIR}/FastTab-${VERSION}.dmg"
ZIP_PATH="${RELEASE_DIR}/FastTab-${VERSION}.zip"
APPCAST_ITEM_PATH="${RELEASE_DIR}/appcast-item-${VERSION}.xml"

SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"

WEBSITE_DIR="../theindieapp_website"
WEBSITE_APPCAST="${WEBSITE_DIR}/public/fasttab/appcast.xml"
WEBSITE_VERSION_JSON="${WEBSITE_DIR}/public/fasttab/version.json"
WEBSITE_DMG_DIR="${WEBSITE_DIR}/public/fasttab"

MIN_SYSTEM_VERSION="14.0"
APP_BASE_URL="https://fasttab.theindie.app/fasttab"

# ─── Load .env ───────────────────────────────────────────────────────────────

if [[ -f ".env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source ".env"
  set +a
fi

# Resolve credentials with fallbacks
APPLE_ID="${FASTTAB_APPLE_ID:-${APPLE_ID:-}}"
APPLE_TEAM_ID="${FASTTAB_APPLE_TEAM_ID:-${APPLE_TEAM_ID:-}}"
APPLE_APP_PASSWORD="${FASTTAB_APPLE_APP_PASSWORD:-${APPLE_APP_PASSWORD:-}}"

# ─── 1. Prerequisites ────────────────────────────────────────────────────────

info "[1/9] Checking prerequisites..."

[[ -d "${APP}" ]]           || die "${APP} not found"
[[ -f "${ENTITLEMENTS}" ]]  || die "${ENTITLEMENTS} not found"
[[ -d "${WEBSITE_DIR}" ]]   || die "website repo not found at ${WEBSITE_DIR}"
[[ -f "${SIGN_UPDATE}" ]]   || die "sign_update not found at ${SIGN_UPDATE} — run: swift package resolve"

SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | awk -F '"' '{print $2}')"
[[ -n "${SIGN_IDENTITY}" ]] || die "no 'Developer ID Application' certificate found in Keychain"
echo "  Signing identity: ${SIGN_IDENTITY}"

if [[ "${SKIP_NOTARIZE}" == "false" ]]; then
  if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    echo "  Notary auth: keychain profile '${NOTARY_KEYCHAIN_PROFILE}'"
  elif [[ -n "${APPLE_ID}" && -n "${APPLE_TEAM_ID}" && -n "${APPLE_APP_PASSWORD}" ]]; then
    echo "  Notary auth: Apple ID (${APPLE_ID})"
  else
    die "notary credentials not found — set FASTTAB_APPLE_ID, FASTTAB_APPLE_TEAM_ID, FASTTAB_APPLE_APP_PASSWORD in .env"
  fi
fi

# Warn if Polar sandbox URLs are still in .env
POLAR_API_BASE="${FASTTAB_POLAR_API_BASE_URL:-}"
if [[ "${POLAR_API_BASE}" == *"sandbox"* ]]; then
  echo ""
  echo "  WARNING: .env still has FASTTAB_POLAR_API_BASE_URL pointing to sandbox."
  echo "  Update .env with production Polar values before a real release."
  echo "  Continuing in 5 seconds... (Ctrl+C to abort)"
  [[ "${DRY_RUN}" == "false" ]] && sleep 5
fi

mkdir -p "${RELEASE_DIR}"

# ─── 2. Bump version in Info.plist + inject Polar config ─────────────────────

info "[2/9] Updating Info.plist (version + Polar config)..."

plist_set() {
  /usr/libexec/PlistBuddy -c "Set :$1 $2" "${INFO_PLIST}"
}

run /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${INFO_PLIST}"
run /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}"             "${INFO_PLIST}"

# Inject Polar values from env if present
inject_plist_str() {
  local key="$1" val="$2"
  [[ -z "${val}" ]] && return
  # Add key if missing, otherwise Set
  if /usr/libexec/PlistBuddy -c "Print :${key}" "${INFO_PLIST}" &>/dev/null; then
    run /usr/libexec/PlistBuddy -c "Set :${key} ${val}" "${INFO_PLIST}"
  else
    run /usr/libexec/PlistBuddy -c "Add :${key} string ${val}" "${INFO_PLIST}"
  fi
}

inject_plist_str "FastTabPolarAPIBaseURL"          "${FASTTAB_POLAR_API_BASE_URL:-}"
inject_plist_str "FastTabPolarOrganizationID"      "${FASTTAB_POLAR_ORGANIZATION_ID:-}"
inject_plist_str "FastTabPolarPersonalBenefitID"   "${FASTTAB_POLAR_PERSONAL_BENEFIT_ID:-}"
inject_plist_str "FastTabPolarLifetimeBenefitID"   "${FASTTAB_POLAR_LIFETIME_BENEFIT_ID:-}"
inject_plist_str "FastTabPolarTeamBenefitID"       "${FASTTAB_POLAR_TEAM_BENEFIT_ID:-}"
inject_plist_str "FastTabPolarPersonalCheckoutURL" "${FASTTAB_POLAR_PERSONAL_CHECKOUT_URL:-}"
inject_plist_str "FastTabPolarLifetimeCheckoutURL" "${FASTTAB_POLAR_LIFETIME_CHECKOUT_URL:-}"
inject_plist_str "FastTabPolarTeamCheckoutURL"     "${FASTTAB_POLAR_TEAM_CHECKOUT_URL:-}"
inject_plist_str "FastTabPolarManageLicenseURL"    "${FASTTAB_POLAR_MANAGE_LICENSE_URL:-}"

echo "  Version set to ${VERSION}"

# ─── 3. Build release binary ─────────────────────────────────────────────────

info "[3/9] Building release binary..."

run swift build -c release

BIN="$(swift build -c release --show-bin-path)/FastTab"
[[ "${DRY_RUN}" == "true" ]] || [[ -f "${BIN}" ]] || die "built binary not found at ${BIN}"
run cp "${BIN}" "${APP}/Contents/MacOS/FastTab"

# Ensure Sparkle rpath is set (idempotent)
if ! otool -l "${APP}/Contents/MacOS/FastTab" | grep -q "@executable_path/../Frameworks"; then
  run install_name_tool -add_rpath "@executable_path/../Frameworks" "${APP}/Contents/MacOS/FastTab"
fi

# ─── 4. Sign with Developer ID ───────────────────────────────────────────────

info "[4/9] Signing with Developer ID..."

# Sign Sparkle XPC services individually first
SPARKLE_VER_DIR="$(ls -d "${FRAMEWORKS}/Versions/"*/ 2>/dev/null | grep -v Current | head -1 | sed 's:/$::')"
if [[ -n "${SPARKLE_VER_DIR}" ]]; then
  for xpc in "${SPARKLE_VER_DIR}/XPCServices/"*.xpc; do
    [[ -e "${xpc}" ]] || continue
    run codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${xpc}"
  done
  [[ -e "${SPARKLE_VER_DIR}/Updater.app" ]]  && \
    run codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${SPARKLE_VER_DIR}/Updater.app"
  [[ -e "${SPARKLE_VER_DIR}/Autoupdate" ]]   && \
    run codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${SPARKLE_VER_DIR}/Autoupdate"
fi

run codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${FRAMEWORKS}"

run codesign \
  --force \
  --options runtime \
  --entitlements "${ENTITLEMENTS}" \
  --sign "${SIGN_IDENTITY}" \
  --timestamp \
  "${APP}"

run codesign --verify --deep --strict --verbose=1 "${APP}"
echo "  Signed."

# ─── 5. Notarize ─────────────────────────────────────────────────────────────

if [[ "${SKIP_NOTARIZE}" == "false" ]]; then
  info "[5/9] Notarizing..."

  run ditto -c -k --keepParent "${APP}" "${ZIP_PATH}"

  NOTARY_ARGS=("--wait" "--no-progress")
  if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    NOTARY_ARGS+=("--keychain-profile" "${NOTARY_KEYCHAIN_PROFILE}")
  else
    NOTARY_ARGS+=("--apple-id" "${APPLE_ID}" "--team-id" "${APPLE_TEAM_ID}" "--password" "${APPLE_APP_PASSWORD}")
  fi

  run xcrun notarytool submit "${ZIP_PATH}" "${NOTARY_ARGS[@]}"
  run xcrun stapler staple "${APP}"
  run xcrun stapler validate "${APP}"
  run rm -f "${ZIP_PATH}"
  echo "  Notarized and stapled."
else
  info "[5/9] Notarization skipped."
fi

# ─── 6. Create DMG ───────────────────────────────────────────────────────────

info "[6/9] Creating DMG..."

TMP_DMG_STAGING="${RELEASE_DIR}/dmg-staging"
run rm -rf "${TMP_DMG_STAGING}"
run mkdir -p "${TMP_DMG_STAGING}"
run cp -R "${APP}" "${TMP_DMG_STAGING}/"
run ln -sf /Applications "${TMP_DMG_STAGING}/Applications"

run hdiutil create \
  -volname "FastTab" \
  -srcfolder "${TMP_DMG_STAGING}" \
  -fs HFS+ \
  -format UDZO \
  -o "${DMG_PATH}" \
  >/dev/null

run rm -rf "${TMP_DMG_STAGING}"
echo "  DMG: ${DMG_PATH}"

# ─── 7. Sign DMG + generate appcast item ─────────────────────────────────────

info "[7/9] Signing DMG with Sparkle EdDSA key..."

if [[ "${DRY_RUN}" == "false" ]]; then
  SPARKLE_SIG_LINE="$("${SIGN_UPDATE}" "${DMG_PATH}" 2>/dev/null)"
  [[ -n "${SPARKLE_SIG_LINE}" ]] || die "sign_update produced no output — check Sparkle key in Keychain"

  DMG_SIZE="$(stat -f%z "${DMG_PATH}")"
  PUB_DATE="$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S +0000")"

  # Escape release notes for CDATA (no escaping needed — CDATA wrapper handles it)
  cat > "${APPCAST_ITEM_PATH}" <<APPCAST_XML
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_SYSTEM_VERSION}</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>${RELEASE_NOTES}</p>]]></description>
      <enclosure
        url="${APP_BASE_URL}/FastTab-${VERSION}.dmg"
        ${SPARKLE_SIG_LINE}
        length="${DMG_SIZE}"
        type="application/octet-stream" />
    </item>
APPCAST_XML

  echo "  Appcast item: ${APPCAST_ITEM_PATH}"
else
  echo "  Dry run: skipping sign_update and appcast-item generation."
fi

# ─── 8. Update website ───────────────────────────────────────────────────────

info "[8/9] Updating website..."

if [[ "${DRY_RUN}" == "false" ]]; then
  # Copy DMG
  cp "${DMG_PATH}" "${WEBSITE_DMG_DIR}/"
  echo "  Copied DMG to ${WEBSITE_DMG_DIR}/"

  # Prepend new <item> into appcast.xml before the first existing <item>
  APPCAST_ITEM_CONTENT="$(cat "${APPCAST_ITEM_PATH}")"
  python3 - "${WEBSITE_APPCAST}" "${APPCAST_ITEM_CONTENT}" <<'PYEOF'
import sys, re

path = sys.argv[1]
new_item = sys.argv[2]

with open(path, 'r') as f:
    content = f.read()

# Insert after <language>...</language> line (just before first <item>)
content = re.sub(
    r'(<language>[^<]*</language>)',
    r'\1\n' + new_item,
    content,
    count=1
)

with open(path, 'w') as f:
    f.write(content)

print(f"  Updated {path}")
PYEOF

  # Update version.json — one-line summary of release notes
  NOTES_SUMMARY="${RELEASE_NOTES}"
  cat > "${WEBSITE_VERSION_JSON}" <<VERSION_JSON
{
  "version": "${VERSION}",
  "download_url": "${APP_BASE_URL}/FastTab-${VERSION}.dmg",
  "release_notes": "${NOTES_SUMMARY}",
  "mandatory": false
}
VERSION_JSON
  echo "  Updated version.json"
else
  echo "  Dry run: skipping website file updates."
fi

# ─── 9. Deploy website ───────────────────────────────────────────────────────

info "[9/9] Deploying website..."

if [[ "${DRY_RUN}" == "false" ]]; then
  (
    cd "${WEBSITE_DIR}"
    npm run build
    npx wrangler pages deploy dist
  )
  echo "  Website deployed."
else
  echo "  Dry run: skipping npm build and wrangler deploy."
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "============================================"
echo "Distribution complete: FastTab ${VERSION}"
echo "============================================"
echo "  DMG:       ${DMG_PATH}"
echo "  Appcast:   ${APPCAST_ITEM_PATH}"
[[ "${SKIP_NOTARIZE}" == "true" ]]  && echo "  Notarize:  SKIPPED"
[[ "${DRY_RUN}" == "true" ]]        && echo "  NOTE: dry run — no files were modified"
echo ""
echo "Users will receive the update via Sparkle on next check."
echo "Git tag + GitHub Release: run scripts/release.sh ${VERSION} (if not done yet)"
