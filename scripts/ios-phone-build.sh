#!/usr/bin/env bash
# Runs on the PRO (where the iPhone is paired). Builds + installs the iPhone app from a
# temporary clean copy of exact commits, then removes the copy. Never checks out, resets or
# edits the real checkouts: other sessions' branches and uncommitted work stay as they are.
# Called by `PHONE_ONLY=1 scripts/prod-push.sh` (streamed over ssh, so the Pro's own copy of
# this file may be older); can also be run by hand on the Pro.
#
# Usage: ios-phone-build.sh --app-repo <dir> --lib-repo <dir> --app-sha <commit> --lib-sha <commit> [--device <id>]
#   Temp layout <root>/wt-phone-XXXX/{command-bar-macos,IndieLibKit}: the iOS project finds
#   IndieLibKit as a sibling (../IndieLibKit), same as the real checkouts.
# Env: PHONE_TMP_ROOT (dir holding the temp copy; default: parent of --app-repo)
#      PHONE_SEED_DIR (SwiftPM packages copied into the temp build, APFS clone = no disk cost;
#                      default <app-repo>/ios/build/SourcePackages; skipped if missing)
#      PHONE_BUILD_CMD (default scripts/build-ios-in-gui-session.sh, run inside the temp copy)
#
# Keeps the temp copy (and says so) while an iPhone build is still running in it (tmux session
# fasttab-ios-push alive: build timed out, or the ssh link dropped) — removing it would break it.
set -euo pipefail

main() {
  export PATH="${PATH}:/opt/homebrew/bin:/usr/local/bin"   # bare ssh PATH lacks Homebrew (tmux, xcodegen)
  local app_repo="" lib_repo="" app_sha="" lib_sha="" device=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --app-repo) app_repo="$2"; shift 2 ;;
      --lib-repo) lib_repo="$2"; shift 2 ;;
      --app-sha) app_sha="$2"; shift 2 ;;
      --lib-sha) lib_sha="$2"; shift 2 ;;
      --device) device="$2"; shift 2 ;;
      *) echo "ios-phone-build: unknown option $1" >&2; return 2 ;;
    esac
  done
  [[ -n "${app_repo}" && -n "${lib_repo}" && -n "${app_sha}" && -n "${lib_sha}" ]] \
    || { echo "ios-phone-build: --app-repo, --lib-repo, --app-sha and --lib-sha are required" >&2; return 2; }
  git -C "${app_repo}" cat-file -e "${app_sha}^{commit}" 2>/dev/null \
    || { echo "ios-phone-build: commit ${app_sha} not found in ${app_repo}" >&2; return 1; }
  git -C "${lib_repo}" cat-file -e "${lib_sha}^{commit}" 2>/dev/null \
    || { echo "ios-phone-build: commit ${lib_sha} not found in ${lib_repo}" >&2; return 1; }

  local root="${PHONE_TMP_ROOT:-$(dirname "${app_repo}")}"
  local seed="${PHONE_SEED_DIR:-${app_repo}/ios/build/SourcePackages}"
  local build_cmd="${PHONE_BUILD_CMD:-scripts/build-ios-in-gui-session.sh}"
  TMP="$(mktemp -d "${root}/wt-phone-XXXXXX")"
  APP_REPO="${app_repo}"; LIB_REPO="${lib_repo}"
  trap cleanup EXIT

  echo "==> temp clean copy: ${TMP} (app ${app_sha:0:7}, IndieLibKit ${lib_sha:0:7})"
  git -C "${app_repo}" worktree add -q --detach "${TMP}/command-bar-macos" "${app_sha}" </dev/null
  git -C "${lib_repo}" worktree add -q --detach "${TMP}/IndieLibKit" "${lib_sha}" </dev/null
  if [[ -d "${seed}" ]]; then
    mkdir -p "${TMP}/command-bar-macos/ios/build"
    cp -cR "${seed}" "${TMP}/command-bar-macos/ios/build/" 2>/dev/null \
      || echo "!! could not clone the package cache (${seed}); the build downloads packages"
  fi

  local args=(); [[ -n "${device}" ]] && args=(--device "${device}")
  (cd "${TMP}/command-bar-macos" && "${build_cmd}" "${args[@]+"${args[@]}"}" </dev/null)
  echo "==> iPhone build installed: app $(git -C "${TMP}/command-bar-macos" log --oneline -1), IndieLibKit ${lib_sha:0:7}"
}

cleanup() {
  [[ -n "${TMP:-}" && -d "${TMP}" ]] || return 0
  if tmux has-session -t fasttab-ios-push 2>/dev/null; then
    echo "!! an iPhone build is still running in ${TMP} (tmux session fasttab-ios-push) — kept; remove later with:" >&2
    echo "   git -C '${APP_REPO}' worktree remove --force '${TMP}/command-bar-macos'; git -C '${LIB_REPO}' worktree remove --force '${TMP}/IndieLibKit'; rmdir '${TMP}'" >&2
    return 0
  fi
  [[ -d "${TMP}/command-bar-macos" ]] && git -C "${APP_REPO}" worktree remove --force "${TMP}/command-bar-macos" </dev/null || true
  [[ -d "${TMP}/IndieLibKit" ]] && git -C "${LIB_REPO}" worktree remove --force "${TMP}/IndieLibKit" </dev/null || true
  rmdir "${TMP}" 2>/dev/null || echo "!! could not remove ${TMP} (not empty?)" >&2
  echo "==> temp copy removed"
}

# Everything runs from main (read fully before it starts), so streaming this file over
# `ssh ... bash -s` can't have a child command swallow the rest of the script from stdin.
main "$@"
