#!/usr/bin/env bash
# Quick start: Fast Tab (menu bar).
#   scripts/start-app-fasttab.sh            # launch dist/FastTab.app, build it if the bundle is missing
#   scripts/start-app-fasttab.sh --build    # always rebuild (release) then relaunch
# Naming: every Mac app in the portfolio has scripts/start-app-<slug>.sh; `macapp fasttab` calls this.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"
APP="dist/FastTab.app"
BIN="${APP}/Contents/MacOS/FastTab"   # test the executable: a failed build can leave a hollow bundle

# fasttab-build-mac-app.sh only REFRESHES an existing bundle (it keeps Info.plist, icon, Sparkle,
# URL scheme from it); nothing in the repo can create dist/FastTab.app from scratch. dist/ is
# gitignored, so if it is wiped the bundle is gone: say so plainly instead of the build's cryptic error.
if [[ ! -x "${BIN}" ]]; then
  echo "start-app-fasttab: ${APP} is missing (dist/ is gitignored and was probably wiped)." >&2
  echo "  Recreate it, then build:  scripts/fasttab-restore-dist.sh && scripts/fasttab-build-mac-app.sh" >&2
  exit 1
fi
if [[ "${1:-}" == "--build" ]]; then
  exec scripts/fasttab-build-mac-app.sh   # builds, re-signs and relaunches
fi
if pgrep -f "${APP}/Contents/MacOS/FastTab" >/dev/null; then
  echo "==> Fast Tab already running"
else
  echo "==> Launching ${APP}"
  open "${APP}"
fi
