#!/usr/bin/env bash
# Keep-alive for AgentBar on the Pro: run every 60s by launchd (scripts/com.trungluong.agentbar-keepalive.plist).
# Relaunches AgentBar only after a crash / kill / missed deploy relaunch — never after a clean quit:
#   running                                            -> nothing
#   ~/Library/Application Support/AgentBar/clean-quit  -> nothing (AgentBar writes it on a normal
#                                                         quit, deletes it on launch; CleanQuitMarker.swift)
#   <state>/AgentBar.deploying younger than 10 min     -> nothing (app-lifecycle.sh stop/start)
#   otherwise                                          -> `open` it + one line in <state>/keepalive.log
# Install on the Pro (one-liner, from the main checkout): scripts/agentbar-keepalive.sh --install
#   copies this script to ~/.local/bin (so the checkout may sit on any branch) and loads the plist,
#   which points AGENTBAR_APP at this checkout's dist/AgentBar.app. Re-run after changing either.
# Env (tests): AGENTBAR_APP  AGENTBAR_SUPPORT_DIR  LIFECYCLE_STATE_DIR  DEPLOY_STALE_SECS (600)  NOW
set -uo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${AGENTBAR_APP:-${repo_root}/dist/AgentBar.app}"
support="${AGENTBAR_SUPPORT_DIR:-${HOME}/Library/Application Support/AgentBar}"
clean_quit="${support}/clean-quit"   # = "Library/Application Support/AgentBar/clean-quit"
state="${LIFECYCLE_STATE_DIR:-${HOME}/.local/state/app-lifecycle}"
label="com.trungluong.agentbar-keepalive"

if [[ "${1:-}" == --install ]]; then
  plist="${HOME}/Library/LaunchAgents/${label}.plist"
  mkdir -p "${HOME}/.local/bin" "${state}"
  cp "${repo_root}/scripts/agentbar-keepalive.sh" "${HOME}/.local/bin/agentbar-keepalive.sh"
  sed "s#__REPO__#${repo_root}#g; s#__HOME__#${HOME}#g" "${repo_root}/scripts/${label}.plist" > "${plist}"
  launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "${plist}" && echo "installed ${plist} (every 60s; log ${state}/keepalive.log)"
  exit
fi

mkdir -p "${state}"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "${state}/keepalive.log"; }

pgrep -f "^${app}/Contents/MacOS/AgentBar( .*)?$" >/dev/null && exit 0
[[ -f "${clean_quit}" ]] && exit 0
if [[ -f "${state}/AgentBar.deploying" ]]; then
  since="$(cat "${state}/AgentBar.deploying" 2>/dev/null)"; [[ "${since}" =~ ^[0-9]+$ ]] || since=0
  (( ${NOW:-$(date +%s)} - since < ${DEPLOY_STALE_SECS:-600} )) && exit 0
  reason="not running, no clean-quit marker, deploy marker stale ($(( ${NOW:-$(date +%s)} - since ))s)"
else
  reason="not running, no clean-quit marker"
fi
[[ -d "${app}" ]] || { log "cannot relaunch: ${app} missing (${reason})"; exit 1; }
if open "${app}"; then log "relaunched AgentBar: ${reason}"; else log "open FAILED: ${reason}"; exit 1; fi
