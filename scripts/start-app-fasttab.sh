#!/usr/bin/env bash
# Quick start: Fast Tab (menu bar).
#   scripts/start-app-fasttab.sh            # launch dist/FastTab.app, build it if the bundle is missing
#   scripts/start-app-fasttab.sh --build    # always rebuild (release) then relaunch
# Naming: every Mac app in the portfolio has scripts/start-app-<slug>.sh; `macapp fasttab` calls this.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"
APP="dist/FastTab.app"

if [[ "${1:-}" == "--build" || ! -d "${APP}" ]]; then
  exec scripts/fasttab-build-mac-app.sh   # builds, re-signs and relaunches
fi
if pgrep -f "${APP}/Contents/MacOS/FastTab" >/dev/null; then
  echo "==> Fast Tab already running"
else
  echo "==> Launching ${APP}"
  open "${APP}"
fi
