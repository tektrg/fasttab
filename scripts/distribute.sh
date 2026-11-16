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
#     (or NOTARY_KEYCHAIN_PROFILE, a notarytool keychain profile: preferred)
#     FASTTAB_POLAR_* production values (see .env for keys)
#   Developer ID Application certificate in Keychain
#   Sparkle sign_update tool (run: swift package resolve) + EdDSA key (keychain account ed25519)
#   ../IndieLibKit (scripts/indie-mac-release.sh) and ../theindieapp_website (wrangler configured)
#
# Fast Tab-only steps live here (release checks, Info.plist values, release build, the files
# copied into the app, release entitlements, website). Signing, notarizing, the DMG, the Sparkle
# signature and the appcast item are IndieLibKit's shared scripts/indie-mac-release.sh.
# dist/FastTab.app is never modified: a throwaway copy is prepared and the signed, notarized
# app lands in dist/release/FastTab.app next to the DMG.

set -euo pipefail

# ─── Helpers ─────────────────────────────────────────────────────────────────

die()  { echo "distribute: error: $*" >&2; exit 1; }
info() { echo "==> $*"; }
run()  {
  echo "+ $*"
  if [[ "${DRY_RUN}" == "false" ]]; then "$@"; fi
}

# A release blocker: a real run stops before building; a dry run lists them all and exits 3.
BLOCKERS=()
blocker() { BLOCKERS+=("$*"); echo "  BLOCKER: $*" >&2; }

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
RELEASE_DIR="dist/release"
DMG_PATH="${RELEASE_DIR}/FastTab-${VERSION}.dmg"
APPCAST_ITEM_PATH="${RELEASE_DIR}/appcast-item-${VERSION}.xml"

SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"
SHARED_RELEASE="../IndieLibKit/scripts/indie-mac-release.sh"

WEBSITE_DIR="../theindieapp_website"
WEBSITE_APPCAST="${WEBSITE_DIR}/public/fasttab/appcast.xml"
WEBSITE_VERSION_JSON="${WEBSITE_DIR}/public/fasttab/version.json"
WEBSITE_DMG_DIR="${WEBSITE_DIR}/public/fasttab"

APP_BASE_URL="https://fasttab.theindie.app/fasttab"

# What every installed copy (1.3.0–1.6.1) has. An update that differs breaks it for users.
RELEASE_BUNDLE_ID="com.trungluong.FastTab"
RELEASE_FEED_URL="${APP_BASE_URL}/appcast.xml"

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

# ─── 1. Prerequisites + release checks ───────────────────────────────────────

info "[1/7] Checking prerequisites..."

[[ -d "${APP}" ]]            || die "${APP} not found"
[[ -f "${ENTITLEMENTS}" ]]   || die "${ENTITLEMENTS} not found"
[[ -d "${WEBSITE_DIR}" ]]    || die "website repo not found at ${WEBSITE_DIR}"
[[ -x "${SHARED_RELEASE}" ]] || die "shared release script not found at ${SHARED_RELEASE} (IndieLibKit checkout next to this repo)"
[[ -f "${SIGN_UPDATE}" ]]    || die "sign_update not found at ${SIGN_UPDATE} — run: swift package resolve"

SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | awk -F '"' '{print $2}')"
if [[ -z "${SIGN_IDENTITY}" ]]; then
  [[ "${DRY_RUN}" == "true" ]] || die "no 'Developer ID Application' certificate found in Keychain"
  echo "  Signing identity: none found (dry run continues)"
else
  echo "  Signing identity: ${SIGN_IDENTITY}"
fi

# Notary credentials → the shared script: a keychain profile by name, or the Apple ID trio as
# NOTARY_* environment variables (never on this script's command lines).
NOTARY_FLAGS=()
if [[ "${SKIP_NOTARIZE}" == "true" ]]; then
  NOTARY_FLAGS=(--skip-notarize)
elif [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  echo "  Notary auth: keychain profile '${NOTARY_KEYCHAIN_PROFILE}'"
  NOTARY_FLAGS=(--notary-profile "${NOTARY_KEYCHAIN_PROFILE}")
elif [[ -n "${APPLE_ID}" && -n "${APPLE_TEAM_ID}" && -n "${APPLE_APP_PASSWORD}" ]]; then
  echo "  Notary auth: Apple ID (${APPLE_ID})"
  export NOTARY_APPLE_ID="${APPLE_ID}" NOTARY_TEAM_ID="${APPLE_TEAM_ID}" NOTARY_PASSWORD="${APPLE_APP_PASSWORD}"
else
  die "notary credentials not found — set FASTTAB_APPLE_ID, FASTTAB_APPLE_TEAM_ID, FASTTAB_APPLE_APP_PASSWORD in .env"
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

plist_read() { /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null || true; }

# The update must look like the app users already have, or Sparkle/macOS treat it as another app.
INFO_PLIST_SRC="${APP}/Contents/Info.plist"
bundle_id="$(plist_read CFBundleIdentifier "${INFO_PLIST_SRC}")"
[[ "${bundle_id}" == "${RELEASE_BUNDLE_ID}" ]] || blocker "${INFO_PLIST_SRC} has CFBundleIdentifier '${bundle_id}', every shipped release is '${RELEASE_BUNDLE_ID}' (a new id loses users' settings, permissions and license, and needs its own iCloud setup)"
feed_url="$(plist_read SUFeedURL "${INFO_PLIST_SRC}")"
[[ "${feed_url}" == "${RELEASE_FEED_URL}" ]] || blocker "SUFeedURL is '${feed_url}', expected ${RELEASE_FEED_URL}"
plutil -extract CFBundleURLTypes xml1 -o - "${INFO_PLIST_SRC}" 2>/dev/null | grep -q "<string>fasttab</string>" \
  || blocker "Info.plist does not register the fasttab:// URL scheme (CFBundleURLTypes); license activation links would not open the app"
ed_key_plist="$(plist_read SUPublicEDKey "${INFO_PLIST_SRC}")"
ed_key_env="${SPARKLE_PUBLIC_ED_KEY:-}"
if [[ -z "${ed_key_plist}" && -z "${ed_key_env}" ]]; then
  blocker "no SUPublicEDKey in Info.plist and no SPARKLE_PUBLIC_ED_KEY in .env; this release could never update itself"
elif [[ -n "${ed_key_plist}" && -n "${ed_key_env}" && "${ed_key_plist}" != "${ed_key_env}" ]]; then
  blocker "Info.plist SUPublicEDKey differs from .env SPARKLE_PUBLIC_ED_KEY"
fi

# Sparkle compares sparkle:version (= CFBundleVersion = VERSION); a published DMG is never replaced.
FEED_OK=true
if [[ -f "${WEBSITE_APPCAST}" ]]; then
  if ! xmllint --noout "${WEBSITE_APPCAST}" 2>/dev/null; then
    FEED_OK=false
    blocker "${WEBSITE_APPCAST} is not valid XML ($(xmllint --noout "${WEBSITE_APPCAST}" 2>&1 | head -1)). Sparkle cannot parse it either, so no installed copy sees any update until it is repaired"
  elif grep -q "<sparkle:version>${VERSION}</sparkle:version>" "${WEBSITE_APPCAST}"; then
    blocker "appcast already has version ${VERSION}"
  fi
fi
[[ ! -e "${WEBSITE_DMG_DIR}/FastTab-${VERSION}.dmg" ]] || blocker "${WEBSITE_DMG_DIR}/FastTab-${VERSION}.dmg already exists (bump the version)"

# The embedded Sparkle.framework (kept in dist/FastTab.app, not rebuilt) must be the version the
# binary is linked against (IndieLibKit pins it exactly).
sparkle_resolved_plist="$(find .build/artifacts/sparkle -path '*macos*/Sparkle.framework/Versions/*/Resources/Info.plist' 2>/dev/null | head -1)"
sparkle_resolved=""
[[ -z "${sparkle_resolved_plist}" ]] || sparkle_resolved="$(plist_read CFBundleShortVersionString "${sparkle_resolved_plist}")"
sparkle_embedded="$(plist_read CFBundleShortVersionString "${APP}/Contents/Frameworks/Sparkle.framework/Resources/Info.plist")"
echo "  Sparkle: embedded ${sparkle_embedded:-none}, linked ${sparkle_resolved:-unknown}"
[[ -n "${sparkle_embedded}" && "${sparkle_embedded}" == "${sparkle_resolved}" ]] \
  || blocker "embedded Sparkle.framework (${sparkle_embedded:-missing}) is not the linked Sparkle (${sparkle_resolved:-unknown}); copy it from .build/artifacts/sparkle into ${APP}/Contents/Frameworks"

mkdir -p "${RELEASE_DIR}"

# ─── 2. Release copy: Info.plist values + entitlements ───────────────────────

info "[2/7] Preparing the release copy (version, Polar config, entitlements)..."

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fasttab-release.XXXXXX")"
trap 'rm -rf "${STAGE_DIR}"' EXIT
STAGE_APP="${STAGE_DIR}/FastTab.app"
# APFS clone: instant, no extra disk. Falls back to a real copy.
cp -cR "${APP}" "${STAGE_APP}" 2>/dev/null || { rm -rf "${STAGE_APP}"; ditto "${APP}" "${STAGE_APP}"; }
INFO_PLIST="${STAGE_APP}/Contents/Info.plist"
echo "  Release copy: ${STAGE_APP} (dist/FastTab.app stays as it is)"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}"             "${INFO_PLIST}"

# Inject values from env if present (add the key if missing, otherwise Set)
inject_plist_str() {
  local key="$1" val="$2"
  [[ -z "${val}" ]] && return
  if /usr/libexec/PlistBuddy -c "Print :${key}" "${INFO_PLIST}" &>/dev/null; then
    /usr/libexec/PlistBuddy -c "Set :${key} ${val}" "${INFO_PLIST}"
  else
    /usr/libexec/PlistBuddy -c "Add :${key} string ${val}" "${INFO_PLIST}"
  fi
  echo "  ${key} set"
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
# Shipped in 1.6.1's Info.plist (PaymentConfiguration reads them); kept in .env.
inject_plist_str "FastTabSupportURL"                   "${FASTTAB_SUPPORT_URL:-}"
inject_plist_str "FastTabPricingURL"                   "${FASTTAB_PRICING_URL:-}"
inject_plist_str "FastTabPersonalLicensedMajorVersion" "${FASTTAB_PERSONAL_LICENSED_MAJOR_VERSION:-}"
[[ -n "${ed_key_plist}" ]] || inject_plist_str "SUPublicEDKey" "${ed_key_env}"

echo "  Version set to ${VERSION}"

# A Development provisioning profile cannot back a Developer ID app: 1.6.1 shipped none. Keep an
# embedded profile only when it is a Developer ID one (ProvisionsAllDevices).
PROFILE_PLIST="${STAGE_DIR}/profile.plist"
STAGE_PROFILE="${STAGE_APP}/Contents/embedded.provisionprofile"
: > "${PROFILE_PLIST}"
if [[ -f "${STAGE_PROFILE}" ]]; then
  security cms -D -i "${STAGE_PROFILE}" > "${PROFILE_PLIST}" 2>/dev/null || : > "${PROFILE_PLIST}"
  if [[ "$(plutil -extract ProvisionsAllDevices raw -o - "${PROFILE_PLIST}" 2>/dev/null)" == "true" ]]; then
    echo "  Embedded profile: Developer ID ($(plutil -extract Name raw -o - "${PROFILE_PLIST}" 2>/dev/null)), kept"
  else
    echo "  Embedded profile: '$(plutil -extract Name raw -o - "${PROFILE_PLIST}" 2>/dev/null)' is not Developer ID; left out of the release"
    rm -f "${STAGE_PROFILE}"
    : > "${PROFILE_PLIST}"
  fi
fi

# Release entitlements from dist/FastTab.entitlements (the development set):
# - get-task-allow and the development-only iCloud container key never ship (notarization
#   rejects get-task-allow);
# - profile-restricted keys (application-identifier, com.apple.developer.*, keychain groups)
#   ship only when the embedded Developer ID profile grants them, else macOS kills the app at
#   launch (the old aps-environment rule, for every such key); iCloud/push flip to production.
# With no Developer ID profile this is exactly 1.6.1's set: apple-events only.
RELEASE_ENTITLEMENTS="${STAGE_DIR}/FastTab.release.entitlements"
python3 -I - "${ENTITLEMENTS}" "${PROFILE_PLIST}" "${RELEASE_ENTITLEMENTS}" <<'PYEOF'
import os, plistlib, sys
src, profile_path, out = sys.argv[1:4]
with open(src, "rb") as f:
    ent = plistlib.load(f)
granted = {}
if os.path.getsize(profile_path) > 0:
    with open(profile_path, "rb") as f:
        granted = plistlib.load(f).get("Entitlements", {})
dropped = []
for key in ("com.apple.security.get-task-allow",
            "com.apple.developer.icloud-container-development-container-identifiers"):
    if key in ent:
        ent.pop(key); dropped.append(f"{key} (development only)")
def restricted(key):
    return (key == "com.apple.application-identifier" or key == "keychain-access-groups"
            or key.startswith("com.apple.developer."))
for key in list(ent):
    if restricted(key) and key not in granted:
        ent.pop(key); dropped.append(f"{key} (no Developer ID profile grants it)")
if "com.apple.developer.icloud-container-environment" in ent:
    ent["com.apple.developer.icloud-container-environment"] = "Production"
if "com.apple.developer.aps-environment" in ent:
    ent["com.apple.developer.aps-environment"] = "production"
with open(out, "wb") as f:
    plistlib.dump(ent, f)
for d in dropped:
    print(f"  entitlement dropped: {d}")
for k in sorted(ent):
    print(f"  entitlement shipped: {k}")
PYEOF

# Fast Tab opens its CloudKit container at launch (SyncService); without the iCloud entitlement
# that traps on start for every user.
/usr/libexec/PlistBuddy -c "Print :com.apple.developer.icloud-services" "${RELEASE_ENTITLEMENTS}" &>/dev/null \
  || blocker "release entitlements have no iCloud (no Developer ID provisioning profile with iCloud embedded); this build opens its CloudKit container at launch and would crash on start. Embed a Developer ID profile with the iCloud capability (dist/embedded.provisionprofile) first"

if [[ ${#BLOCKERS[@]} -gt 0 && "${DRY_RUN}" == "false" ]]; then
  die "${#BLOCKERS[@]} release blocker(s) above; nothing was built or signed"
fi

# ─── 3. Build release binaries into the copy ─────────────────────────────────

info "[3/7] Building release binary..."

run swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

# Three executables: the app, the native-messaging host relay Chrome launches (without this copy
# a release shipped whatever stale host an earlier local build left), and the reader comment MCP
# helper agent clients launch by path.
install_bin() {  # <built name> <name in Contents/MacOS>
  if [[ "${DRY_RUN}" == "true" ]] || [[ -f "${BIN_DIR}/$1" ]]; then
    run cp "${BIN_DIR}/$1" "${STAGE_APP}/Contents/MacOS/$2"
  else
    die "$1 binary not found at ${BIN_DIR}/$1"
  fi
}
install_bin FastTab FastTab
install_bin FastTabNativeHost FastTabNativeHost
install_bin FastTabMCP fasttab-mcp

# Reader window resources, shared with the iPhone app (single copy under ios/).
for res in Readability.js reader_template.html; do
  run cp "ios/FastTabMobile/Resources/${res}" "${STAGE_APP}/Contents/Resources/${res}"
done

# SwiftPM resource bundles (IndieTable's table-core.js for Settings > Highlights, ...). Without
# them the app traps on first use. Must precede signing.
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "  [dry-run] scripts/install-resource-bundles.sh ${BIN_DIR} ${STAGE_APP}"
else
  scripts/install-resource-bundles.sh "${BIN_DIR}" "${STAGE_APP}"
fi

# Ensure Sparkle rpath is set (idempotent)
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "  [dry-run] add @executable_path/../Frameworks rpath to FastTab if missing"
elif ! otool -l "${STAGE_APP}/Contents/MacOS/FastTab" | grep -q "@executable_path/../Frameworks"; then
  run install_name_tool -add_rpath "@executable_path/../Frameworks" "${STAGE_APP}/Contents/MacOS/FastTab"
fi

# ─── 4. Sign → notarize → DMG → Sparkle signature → appcast (shared) ─────────

info "[4/7] Sign, notarize, DMG, Sparkle signature, appcast item (indie-mac-release.sh)..."

# The two helpers are launched outside the app (Chrome; agent clients), so they are signed with
# NO entitlements: the profile does not cover them and AMFI would kill them on exec.
SHARED_ARGS=(
  --app "${STAGE_APP}"
  --name FastTab
  --entitlements "${RELEASE_ENTITLEMENTS}"
  --helper Contents/MacOS/FastTabNativeHost
  --helper Contents/MacOS/fasttab-mcp
  --sign-update "${SIGN_UPDATE}"
  --ed-key-account ed25519
  --download-url-base "${APP_BASE_URL}"
  --notes "${RELEASE_NOTES}"
  --out "${RELEASE_DIR}"
)
[[ -z "${SIGN_IDENTITY}" ]] || SHARED_ARGS+=(--identity "${SIGN_IDENTITY}")
if [[ "${FEED_OK}" == "true" ]]; then
  SHARED_ARGS+=(--appcast "${WEBSITE_APPCAST}")
else
  echo "  (appcast left out of the shared run: it is not valid XML, see blockers)"
fi
[[ "${DRY_RUN}" == "false" ]] || SHARED_ARGS+=(--dry-run)

echo "+ ${SHARED_RELEASE} ${SHARED_ARGS[*]} ${NOTARY_FLAGS[*]+${NOTARY_FLAGS[*]}}"
"${SHARED_RELEASE}" "${SHARED_ARGS[@]}" ${NOTARY_FLAGS[@]+"${NOTARY_FLAGS[@]}"}

# ─── 5. Copy DMG + version.json into the website ─────────────────────────────

info "[5/7] Updating website..."

if [[ "${DRY_RUN}" == "false" ]]; then
  cp "${DMG_PATH}" "${WEBSITE_DMG_DIR}/"
  echo "  Copied DMG to ${WEBSITE_DMG_DIR}/ (appcast item inserted in step 4)"

  # version.json — one-line summary of release notes (JSON-escaped)
  python3 -I - "${WEBSITE_VERSION_JSON}" "${VERSION}" "${APP_BASE_URL}/FastTab-${VERSION}.dmg" "${RELEASE_NOTES}" <<'PYEOF'
import json, sys
path, version, url, notes = sys.argv[1:5]
with open(path, "w") as f:
    f.write("{\n")
    f.write(f'  "version": {json.dumps(version)},\n')
    f.write(f'  "download_url": {json.dumps(url)},\n')
    f.write(f'  "release_notes": {json.dumps(notes)},\n')
    f.write('  "mandatory": false\n}\n')
PYEOF
  echo "  Updated version.json"
else
  echo "+ cp ${DMG_PATH} ${WEBSITE_DMG_DIR}/"
  echo "+ write ${WEBSITE_VERSION_JSON} (${VERSION})"
fi

# ─── 6. Deploy website ───────────────────────────────────────────────────────

info "[6/7] Deploying website..."

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

# ─── 7. Summary ──────────────────────────────────────────────────────────────

info "[7/7] Done."
echo ""
echo "============================================"
echo "Distribution complete: FastTab ${VERSION}"
echo "============================================"
echo "  App:       ${RELEASE_DIR}/FastTab.app (signed release copy)"
echo "  DMG:       ${DMG_PATH}"
echo "  Appcast:   ${APPCAST_ITEM_PATH}"
[[ "${SKIP_NOTARIZE}" == "true" ]]  && echo "  Notarize:  SKIPPED"
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "  NOTE: dry run — no files were modified"
  if [[ ${#BLOCKERS[@]} -gt 0 ]]; then
    echo ""
    echo "  ${#BLOCKERS[@]} RELEASE BLOCKER(S) — a real run would stop at step 1:"
    for b in "${BLOCKERS[@]}"; do echo "   - ${b}"; done
    exit 3
  fi
fi
echo ""
echo "Users will receive the update via Sparkle on next check."
echo "Git tag + GitHub Release: run scripts/release.sh ${VERSION} (if not done yet)"
