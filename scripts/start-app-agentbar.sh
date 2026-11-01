#!/usr/bin/env bash
# Starts everything AgentBar needs: the chief dashboard (port 4711), then the app.
#
# Usage:
#   scripts/start-app-agentbar.sh             # start dashboard if down, launch app
#   scripts/start-app-agentbar.sh --build     # also rebuild AgentBar first (build-agentbar-app.sh)
#   scripts/start-app-agentbar.sh --restart   # restart the dashboard even if it is up
#
# Dashboard start: inside the herdr tab "chief-dashboard-server" when herdr is
# running and has that tab, else a plain background process (--detached).
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

PORT="${CHIEF_DASHBOARD_PORT:-4711}"
APP="dist/AgentBar.app"
BUILD=0
RESTART=0
for arg in "$@"; do
  case "${arg}" in
    --build) BUILD=1 ;;
    --restart) RESTART=1 ;;
    *) echo "unknown flag: ${arg}" >&2; exit 2 ;;
  esac
done

dashboard_up() {
  [[ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://localhost:${PORT}/api/state")" == "200" ]]
}

if dashboard_up && [[ "${RESTART}" == 0 ]]; then
  echo "==> Dashboard already up on :${PORT}"
else
  mode=(--detached)
  if herdr tab list >/dev/null 2>&1 \
     && python3 dashboard/server/lib/herdr_pane_lookup.py chief-dashboard-server >/dev/null 2>&1; then
    mode=()
  fi
  echo "==> Starting dashboard on :${PORT} (${mode[*]:-herdr tab})"
  dashboard/scripts/restart.sh "${mode[@]}" || { echo "start-app-agentbar: dashboard failed to start" >&2; exit 1; }
fi

if [[ "${BUILD}" == 1 ]]; then
  scripts/build-agentbar-app.sh   # builds and relaunches
  exit $?
fi

if [[ ! -d "${APP}" ]]; then
  echo "==> ${APP} missing, building"
  scripts/build-agentbar-app.sh
  exit $?
fi

if pgrep -x AgentBar >/dev/null; then
  echo "==> AgentBar already running"
else
  echo "==> Launching ${APP}"
  open "${APP}"
fi
