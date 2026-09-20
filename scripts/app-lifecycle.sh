#!/usr/bin/env bash
# Stop or start prebuilt apps from this checkout's dist/. Used by prod-push.sh /
# prod-pull.sh around an rsync of a finished bundle.
#
# Stop MUST finish before the bundle is overwritten: replacing a signed binary
# under a live process trips the kernel code-integrity check (SIGKILL "Code
# Signature Invalid"). Escalates to SIGKILL if SIGTERM is ignored.
#
# Usage: scripts/app-lifecycle.sh stop|start <App> [<App>...]   (e.g. FastTab AgentBar)
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

action="${1:?usage: app-lifecycle.sh stop|start <App>...}"; shift
for app in "$@"; do
  case "${action}" in
    stop)
      pkill -x "${app}" 2>/dev/null || continue
      for _ in $(seq 1 20); do pgrep -x "${app}" >/dev/null || break; sleep 0.25; done
      pgrep -x "${app}" >/dev/null && { pkill -9 -x "${app}" 2>/dev/null || true; sleep 0.5; }
      echo "stopped ${app}"
      ;;
    start)
      [[ -d "dist/${app}.app" ]] || { echo "app-lifecycle: dist/${app}.app missing" >&2; exit 1; }
      open "dist/${app}.app"
      echo "started ${app}"
      ;;
    *) echo "app-lifecycle: unknown action ${action}" >&2; exit 1 ;;
  esac
done
