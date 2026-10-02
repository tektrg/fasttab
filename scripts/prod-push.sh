#!/usr/bin/env bash
# Runs on the AIR (dev machine). Builds the Mac apps here, ships the finished
# bundles into the Pro's dist/, and restarts them there.
# IOS=1 additionally pushes the source to the Pro and installs the iPhone build
# from there (Xcode exists only on the Pro).
#
# Env: MAC_PRO_SSH (mbp-m4)  MAC_PRO_REPO  APPS ("FastTab AgentBar")  IOS (0)  DRY_RUN (0)
#      SKIP_MAIN_SYNC (0) — deploy a non-main checkout without syncing (loud; for branch testing)
#
# Guards (user-approved 2026-10-02):
#  1. Main sync first: this checkout must be on a clean `main`; the Pro's `main` is merged in
#     here, then fast-forwarded on the Pro. Anything that can't merge cleanly (conflict here,
#     or the Pro's uncommitted edits in the way) stops BEFORE any build or app restart.
#  2. Signed or nothing: an ad-hoc-signed bundle (signing identity missing from the keychain
#     search list) is refused before it replaces the Pro's copy — ad-hoc loses macOS
#     permissions (Accessibility for the hotkeys).
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

PRO="${MAC_PRO_SSH:-mbp-m4}"
PRO_REPO="${MAC_PRO_REPO:-/Users/trungluong/01_Project/command-bar-macos}"
APPS="${APPS-FastTab AgentBar}"   # APPS= (empty) skips the Mac apps
run() { echo "+ $*"; [[ "${DRY_RUN:-0}" == 1 ]] || "$@"; }
die() { echo "prod-push: STOP — $*" >&2; exit 1; }

sync_main_with_pro() {
  if [[ "${SKIP_MAIN_SYNC:-0}" == 1 ]]; then
    echo "!! SKIP_MAIN_SYNC=1: deploying $(git rev-parse --abbrev-ref HEAD) WITHOUT syncing main"
    return
  fi
  [[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] \
    || die "this checkout is on '$(git rev-parse --abbrev-ref HEAD)', not main (use a main worktree, or SKIP_MAIN_SYNC=1 for a branch test)"
  [[ -z "$(git status --porcelain --untracked-files=no)" ]] \
    || die "uncommitted changes here — commit them first"
  run git fetch pro main
  if ! git merge-base --is-ancestor pro/main HEAD; then
    echo "+ git merge pro/main"
    if [[ "${DRY_RUN:-0}" != 1 ]] && ! git merge --no-edit -m "Merge Pro's main (prod-push sync)" pro/main; then
      git merge --abort || true
      die "Air and Pro main don't merge cleanly — resolve by hand, nothing was deployed"
    fi
  fi
  # Fast-forward the Pro: a side branch, then --ff-only there (fails, leaving the Pro as it was,
  # if its checkout isn't on main or its own uncommitted edits touch incoming files).
  run git push pro "+HEAD:refs/heads/prod-push-sync"   # throwaway: a leftover never blocks
  run ssh "${PRO}" "cd '${PRO_REPO}' && [ \"\$(git rev-parse --abbrev-ref HEAD)\" = main ] && git merge --ff-only prod-push-sync; rc=\$?; git branch -D prod-push-sync >/dev/null; exit \$rc" \
    || die "the Pro's main can't fast-forward (not on main, moved meanwhile, or its uncommitted edits are in the way) — nothing was deployed"
  echo "==> main synced: Air and Pro at $(git rev-parse --short HEAD)"
}

require_signed() {
  local app_path="$1"
  [[ "${DRY_RUN:-0}" == 1 ]] && return
  if codesign -dv "${app_path}" 2>&1 | grep -q "Signature=adhoc"; then
    die "${app_path} is ad-hoc signed (identity not in the keychain search list? see CLAUDE.md 'Air signing') — not deployed"
  fi
}

sync_main_with_pro

# ssh sessions can't unlock the login keychain (codesign → errSecInternalComponent), so
# signing uses a dedicated keychain holding only the dev identity, unlocked from files
# under ~/.config (keychain password + identity hash). One-time setup: see CLAUDE.md.
sign_dir="${HOME}/.config"
if [[ -f "${sign_dir}/fasttab-signing.kcpw" ]]; then
  echo "+ unlock fasttab-signing keychain"
  [[ "${DRY_RUN:-0}" == 1 ]] || security unlock-keychain -p "$(cat "${sign_dir}/fasttab-signing.kcpw")" \
    "${HOME}/Library/Keychains/fasttab-signing.keychain-db"
  export FASTTAB_SIGN_IDENTITY="${FASTTAB_SIGN_IDENTITY:-$(cat "${sign_dir}/fasttab-signing.identity")}"
fi
# Fail fast, before a long build: the identity must be findable (the build scripts silently
# fall back to ad-hoc otherwise — how 2026-10-01's push went out unsigned).
if [[ -n "${APPS}" && "${DRY_RUN:-0}" != 1 ]]; then
  security find-identity -v -p codesigning | grep -q "${FASTTAB_SIGN_IDENTITY:-SELAV8N2B9}" \
    || die "signing identity ${FASTTAB_SIGN_IDENTITY:-SELAV8N2B9} not in the keychain search list (security list-keychains -d user; see CLAUDE.md 'Air signing')"
fi

for app in ${APPS}; do
  case "${app}" in
    FastTab)  run scripts/fasttab-build-mac-app.sh --no-open ;;
    AgentBar) run scripts/build-agentbar-app.sh ;;
    *) echo "prod-push: unknown app ${app}" >&2; exit 1 ;;
  esac
done

for app in ${APPS}; do require_signed "dist/${app}.app"; done

for app in ${APPS}; do
  run ssh "${PRO}" "cd '${PRO_REPO}' && scripts/app-lifecycle.sh stop ${app}"
  run rsync -aE --delete "dist/${app}.app/" "${PRO}:${PRO_REPO}/dist/${app}.app/"
  run ssh "${PRO}" "cd '${PRO_REPO}' && scripts/app-lifecycle.sh start ${app}"
done

if [[ "${IOS:-0}" == 1 ]]; then
  branch="$(git rev-parse --abbrev-ref HEAD)"
  run git push pro "${branch}"
  # Via a tmux session on the Pro so Xcode can sign (see build-ios-in-gui-session.sh).
  run ssh "${PRO}" "cd '${PRO_REPO}' && scripts/build-ios-in-gui-session.sh"
fi
echo "==> prod-push done"
