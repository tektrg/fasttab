#!/usr/bin/env bash
# Stop or start prebuilt apps from this checkout's dist/. Used by prod-push.sh /
# prod-pull.sh around an rsync of a finished bundle.
#
# Stop MUST finish before the bundle is overwritten: replacing a signed binary
# under a live process trips the kernel code-integrity check (SIGKILL "Code
# Signature Invalid"). Escalates to SIGKILL if SIGTERM is ignored.
# Stop also writes a deploy marker (<state>/<App>.deploying) so the keep-alive
# (scripts/agentbar-keepalive.sh) doesn't relaunch the app mid-rsync; start removes it.
#
# Start is verified: within START_TIMEOUT (20s) exactly ONE process must run from
# dist/<App>.app (extras are killed, oldest kept); otherwise "STOP" on stderr, exit 1.
# `open` returning 0 is not proof the app is up.
#
# Every action appends one line to <state>/lifecycle.log.
# Env: LIFECYCLE_STATE_DIR (~/.local/state/app-lifecycle)  START_TIMEOUT (20)
# Usage: scripts/app-lifecycle.sh stop|start|status <App> [<App>...]   (e.g. FastTab AgentBar)
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")/.." && pwd)"   # :-. = streamed via `bash -s` from scripts/ (prod-push)
cd "${repo_root}"
state="${LIFECYCLE_STATE_DIR:-${HOME}/.local/state/app-lifecycle}"
mkdir -p "${state}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "${state}/lifecycle.log"; }
exe_of() { echo "${repo_root}/dist/$1.app/Contents/MacOS/$1"; }
# PIDs running this checkout's bundle, lowest (≈ oldest) first.
pids_of() { pgrep -f "^$(exe_of "$1")( .*)?$" 2>/dev/null | sort -n || true; }

action="${1:?usage: app-lifecycle.sh stop|start|status <App>...}"; shift
rc=0
for app in "$@"; do
  case "${action}" in
    stop)
      date +%s > "${state}/${app}.deploying"
      # Only this checkout's bundle: another checkout's instance isn't being replaced.
      own="^$(exe_of "${app}")( .*)?$"
      if pkill -f "${own}" 2>/dev/null; then
        for _ in $(seq 1 20); do pgrep -f "${own}" >/dev/null || break; sleep 0.25; done
        pgrep -f "${own}" >/dev/null && { pkill -9 -f "${own}" 2>/dev/null || true; sleep 0.5; }
      fi
      log "stop ${app} (deploy marker set) by ${SSH_CONNECTION:+ssh }pid $$ ppid ${PPID}"
      echo "stopped ${app}"
      ;;
    start)
      [[ -d "dist/${app}.app" ]] || { echo "app-lifecycle: STOP — dist/${app}.app missing, ${app} NOT running" >&2; log "start ${app} FAILED: bundle missing"; rc=1; continue; }
      [[ -n "$(pids_of "${app}")" ]] || open "dist/${app}.app" || true
      n=0; pids=""
      for _ in $(seq 1 $(( ${START_TIMEOUT:-20} * 4 ))); do
        pids="$(pids_of "${app}")"; n=$(echo "${pids}" | grep -c . || true)
        (( n >= 1 )) && break; sleep 0.25
      done
      if (( n == 0 )); then
        echo "app-lifecycle: STOP — ${app} did not start within ${START_TIMEOUT:-20}s (open dist/${app}.app); it is NOT running" >&2
        log "start ${app} FAILED: no process after ${START_TIMEOUT:-20}s"; rc=1; continue
      fi
      if (( n > 1 )); then
        extra="$(echo "${pids}" | tail -n +2 | tr '\n' ' ')"
        env kill ${extra} 2>/dev/null || true
        echo "!! ${n} ${app} processes — killed the newer: ${extra}"
        log "start ${app}: killed extras ${extra}"
      fi
      rm -f "${state}/${app}.deploying"
      log "start ${app} ok pid $(echo "${pids}" | head -1)"
      echo "started ${app} (pid $(echo "${pids}" | head -1), exactly one)"
      ;;
    status) echo "${app}: $(pids_of "${app}" | tr '\n' ' ')" ;;
    *) echo "app-lifecycle: unknown action ${action}" >&2; exit 1 ;;
  esac
done
exit "${rc}"
