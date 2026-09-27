#!/usr/bin/env bash
# Runs on the PRO (fallback when driving from the Pro). Pushes source to the Air,
# builds the Mac apps there, pulls the bundles back into this checkout's dist/,
# and restarts them. The iPhone build stays local (Xcode is here).
#
# Env: AIR_SSH (trungs-air)  AIR_REPO  APPS ("FastTab AgentBar")  IOS (0)  DRY_RUN (0)
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

AIR="${AIR_SSH:-trungs-air}"
AIR_REPO="${AIR_REPO:-/Users/wifey/01_Project/command-bar-macos}"
APPS="${APPS:-FastTab AgentBar}"
run() { echo "+ $*"; [[ "${DRY_RUN:-0}" == 1 ]] || "$@"; }

run git push air "$(git rev-parse --abbrev-ref HEAD)"

for app in ${APPS}; do
  case "${app}" in
    FastTab)  script="fasttab-build-mac-app.sh --no-open" ;;
    AgentBar) script=build-agentbar-app.sh ;;
    *) echo "prod-pull: unknown app ${app}" >&2; exit 1 ;;
  esac
  run ssh "${AIR}" "cd '${AIR_REPO}' && scripts/${script}"
  run scripts/app-lifecycle.sh stop "${app}"
  run rsync -aE --delete "${AIR}:${AIR_REPO}/dist/${app}.app/" "dist/${app}.app/"
  run scripts/app-lifecycle.sh start "${app}"
done

[[ "${IOS:-0}" == 1 ]] && run scripts/build-ios.sh
echo "==> prod-pull done"
