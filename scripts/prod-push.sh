#!/usr/bin/env bash
# Runs on the AIR (dev machine). Builds the Mac apps here, ships the finished
# bundles into the Pro's dist/, and restarts them there.
# IOS=1 additionally pushes the source to the Pro and installs the iPhone build
# from there (Xcode exists only on the Pro).
#
# Env: MAC_PRO_SSH (mbp-m4)  MAC_PRO_REPO  APPS ("FastTab AgentBar")  IOS (0)  DRY_RUN (0)
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

PRO="${MAC_PRO_SSH:-mbp-m4}"
PRO_REPO="${MAC_PRO_REPO:-/Users/trungluong/01_Project/command-bar-macos}"
APPS="${APPS-FastTab AgentBar}"   # APPS= (empty) skips the Mac apps
run() { echo "+ $*"; [[ "${DRY_RUN:-0}" == 1 ]] || "$@"; }

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

for app in ${APPS}; do
  case "${app}" in
    FastTab)  run scripts/build-app.sh ;;
    AgentBar) run scripts/build-agentbar-app.sh ;;
    *) echo "prod-push: unknown app ${app}" >&2; exit 1 ;;
  esac
done

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
