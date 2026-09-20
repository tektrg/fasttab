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
APPS="${APPS:-FastTab AgentBar}"
run() { echo "+ $*"; [[ "${DRY_RUN:-0}" == 1 ]] || "$@"; }

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
  run ssh "${PRO}" "cd '${PRO_REPO}' && scripts/build-ios.sh"
fi
echo "==> prod-push done"
