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
refused=""
run() { echo "+ $*"; [[ "${DRY_RUN:-0}" == 1 ]] || "$@"; }

run git push air "$(git rev-parse --abbrev-ref HEAD)"
# The Air builds ITS checkout: it must be exactly this commit, with no uncommitted Mac edits,
# or the guard below would approve one commit and deploy another.
head_sha="$(git rev-parse HEAD)"
air_head="$(ssh "${AIR}" "git -C '${AIR_REPO}' rev-parse HEAD")" || { echo "prod-pull: cannot reach the Air (${AIR})" >&2; exit 1; }
air_dirty="$(ssh "${AIR}" "git -C '${AIR_REPO}' status --porcelain -- Sources Package.swift Package.resolved")" \
  || { echo "prod-pull: cannot reach the Air (${AIR})" >&2; exit 1; }
if [[ "${DRY_RUN:-0}" != 1 ]]; then
  [[ "${air_head}" == "${head_sha}" ]] || { echo "prod-pull: STOP — the Air's checkout is at ${air_head:0:7}, not ${head_sha:0:7}; it would build other code" >&2; exit 1; }
  [[ -z "${air_dirty}" ]] || { echo "prod-pull: STOP — the Air's checkout has uncommitted Mac source edits; it would build them too" >&2; exit 1; }
fi

for app in ${APPS}; do
  case "${app}" in
    FastTab)  script="fasttab-build-mac-app.sh --no-open" ;;
    AgentBar) script="build-agentbar-app.sh --no-open" ;;
    *) echo "prod-pull: unknown app ${app}" >&2; exit 1 ;;
  esac
  # Deploy guard (see prod-push.sh guard 3): never replace code the incoming build lacks.
  rc=0; verdict="$(scripts/deploy-stamp.sh verdict "$(cat "dist/${app}.app.commit" 2>/dev/null || true)" "${head_sha}")" || rc=$?
  if (( rc == 3 )) && [[ " ${FORCE_REPLACE:-} " != *" ${app} "* && "${FORCE_REPLACE:-}" != all ]]; then
    echo "prod-pull: STOP ${app} — ${verdict}" >&2; refused+=" ${app}"; continue
  fi
  (( rc == 0 || rc == 3 )) || { echo "prod-pull: deploy stamp check failed for ${app}" >&2; exit 1; }
  (( rc == 3 )) && echo "!! FORCE_REPLACE: replacing ${app} anyway — ${verdict}" || echo "==> ${app}: ${verdict}"
  run ssh "${AIR}" "cd '${AIR_REPO}' && scripts/${script}"
  run scripts/app-lifecycle.sh stop "${app}"
  run rsync -aE --delete "${AIR}:${AIR_REPO}/dist/${app}.app/" "dist/${app}.app/"
  [[ "${DRY_RUN:-0}" == 1 ]] || ssh "${AIR}" "cat '${AIR_REPO}/dist/${app}.app.commit'" > "dist/${app}.app.commit"
  run scripts/app-lifecycle.sh start "${app}"
done

[[ "${IOS:-0}" == 1 ]] && run scripts/build-ios.sh
[[ -z "${refused}" ]] || { echo "prod-pull: not replaced (running code this build lacks):${refused}" >&2; exit 1; }
echo "==> prod-pull done"
