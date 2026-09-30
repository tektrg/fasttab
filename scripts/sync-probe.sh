#!/usr/bin/env bash
# Live end-to-end probe ("Layer 2") for FastTab's core sync promise:
#   a tab closed on the Mac disappears from the iPhone.
# Uses the REAL running FastTab and the REAL iCloud private database.
#
# Usage: scripts/sync-probe.sh [--browser NAME] [--appear-timeout S] [--disappear-timeout S] [-h|--help]
#
#   --browser NAME          Safari (default, AppleScript path), "Google Chrome" or
#                           "Microsoft Edge" (companion-extension path when the
#                           extension is installed there).
#   --appear-timeout S      Max seconds for the probe tab to reach the server (default 90).
#   --disappear-timeout S   Max seconds for it to leave the server after close (default 90).
#
# What it does:
#   1. Preflight: FastTab running, iCloud sync healthy (asks the app). For the
#      first ~2-4 min after FastTab launches (and once a day, when it rebuilds)
#      the app's server mirror walks the whole change feed and the first
#      answer waits for it; otherwise runs start in about a second.
#   2. Opens a NEW window of the probe browser with its own marker URL
#      (https://example.com/?fasttab-sync-probe=<uuid>). Existing tabs and
#      windows are never touched.
#   3. Polls the SERVER until a SyncedTab record with the marker exists.
#   4. Closes only the probe window (by id, after checking it holds only the
#      marker tab) WITHOUT opening the command bar - the idle-close case.
#   5. Polls the server until the record is gone; reports latency.
#   Cleanup (trap) always closes the probe window if still open.
#
# Server read: posts the distributed notification
# com.trungluong.FastTab.syncProbe.request; FastTab catches up its own
# read-only change feed of the CloudKit state zone (own token, not the sync
# engine's) and writes the records of THIS Mac whose URL contains the marker to
#   ~/Library/Application Support/com.trungluong.FastTab/sync-probe/server-tabs.json (0600)
# See Sources/FastTab/SyncServerProbe.swift.
#
# Needs macOS Automation permission for the calling app (Terminal, tmux host,
# Claude...) to control the probe browser: System Settings > Privacy & Security
# > Automation. Without it the run fails at "could not open probe window".
#
# Exit: 0 pass, 1 fail, 2 preflight/usage error. Last line is a one-line summary.
set -euo pipefail

browser="Safari"
appear_timeout_s=90
disappear_timeout_s=90
poll_interval_s=3
answer_wait_s=20
# The app's shared state-zone mirror walks the zone's whole change feed after
# launch and once a day (observed ~220 pages, ~2-4 min); otherwise requests
# are incremental (<1s).
warmup_wait_s=300

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --browser) browser="${2:?--browser needs a name}"; shift 2 ;;
    --appear-timeout) appear_timeout_s="${2:?}"; shift 2 ;;
    --disappear-timeout) disappear_timeout_s="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "sync-probe: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "${browser}" in
  "Safari"|"Google Chrome"|"Microsoft Edge") ;;
  *) echo "sync-probe: unsupported browser '${browser}' (Safari, Google Chrome, Microsoft Edge)" >&2; exit 2 ;;
esac
[[ "${appear_timeout_s}" =~ ^[0-9]+$ && "${disappear_timeout_s}" =~ ^[0-9]+$ ]] \
  || { echo "sync-probe: timeouts must be whole seconds" >&2; exit 2; }

answer_file="${HOME}/Library/Application Support/com.trungluong.FastTab/sync-probe/server-tabs.json"
marker="fasttab-sync-probe=$(uuidgen | tr '[:upper:]' '[:lower:]')"
probe_url="https://example.com/?${marker}"
probe_window_id=""
browser_was_running=1
pgrep -xq "${browser}" || browser_was_running=0

log() { echo "[sync-probe $(date +%H:%M:%S)] $*" >&2; }
summary() { echo "sync-probe $1 browser=\"${browser}\" $2"; }

# --- Server query (via the running FastTab) -----------------------------------

answer_field() { plutil -extract "$1" raw -o - "${answer_file}" 2>/dev/null || true; }

# Sets server_outcome, server_health, server_match_count, server_device_tab_count.
# $1 = seconds to wait for the answer (default answer_wait_s).
# Returns 1 when FastTab did not answer in time.
ask_server() {
  local wait_s="${1:-${answer_wait_s}}" request_id deadline
  request_id="$(uuidgen)"
  osascript -l JavaScript - "${request_id}" "${marker}" >/dev/null <<'JXA' || { log "could not post the probe request"; return 1; }
ObjC.import('Foundation');
function run(argv) {
  var userInfo = $.NSDictionary.dictionaryWithObjectsForKeys(
    $([argv[0], argv[1]]), $(['requestID', 'urlMarker']));
  $.NSDistributedNotificationCenter.defaultCenter
    .postNotificationNameObjectUserInfoDeliverImmediately(
      'com.trungluong.FastTab.syncProbe.request', 'sync-probe', userInfo, true);
}
JXA
  deadline=$(( $(date +%s) + wait_s ))
  while (( $(date +%s) < deadline )); do
    if [[ -f "${answer_file}" && "$(answer_field requestID)" == "${request_id}" ]]; then
      server_outcome="$(answer_field outcome)"
      server_health="$(answer_field syncHealth)"
      server_match_count="$(answer_field matchingTabs)"
      server_device_tab_count="$(answer_field thisDeviceTabRecordCount)"
      [[ "${server_outcome}" == "ok" ]] || log "server read outcome=${server_outcome} $(answer_field errorMessage)"
      return 0
    fi
    sleep 0.5
  done
  return 1
}

# Polls until the marker record count satisfies $1 ("present" | "absent").
# Echoes elapsed seconds on success; returns 1 on timeout.
wait_for_server() {
  local want="$1" timeout_s="$2" started now
  started=$(date +%s)
  while :; do
    now=$(date +%s)
    if ask_server && [[ "${server_outcome}" == "ok" ]]; then
      if [[ "${want}" == "present" && "${server_match_count}" -ge 1 ]] \
        || [[ "${want}" == "absent" && "${server_match_count}" -eq 0 ]]; then
        echo $(( now - started )); return 0
      fi
    fi
    (( now - started >= timeout_s )) && return 1
    sleep "${poll_interval_s}"
  done
}

# --- Probe window (browser name is allowlisted above, safe to inline) --------

open_probe_window() {
  if ! pgrep -xq "${browser}"; then
    log "${browser} is not running; launching it in the background (quit again after the probe if it has no windows)"
    open -g -a "${browser}"
    for _ in $(seq 1 40); do pgrep -xq "${browser}" && break; sleep 0.25; done
    sleep 2
  fi
  if [[ "${browser}" == "Safari" ]]; then
    osascript - "${probe_url}" <<'OSA'
on run argv
  set probeURL to item 1 of argv
  tell application "Safari"
    make new document with properties {URL:probeURL}
    repeat 50 times
      repeat with w in windows
        try
          if URL of current tab of w is probeURL then return id of w
        end try
      end repeat
      delay 0.1
    end repeat
  end tell
  error "probe window not found"
end run
OSA
  else
    osascript - "${probe_url}" <<OSA
on run argv
  set probeURL to item 1 of argv
  tell application "${browser}"
    set probeWindow to make new window
    set URL of active tab of probeWindow to probeURL
    return id of probeWindow
  end tell
end run
OSA
  fi
}

# Closes the probe window only if it still holds exactly the marker tab.
close_probe_window() {
  [[ -n "${probe_window_id}" ]] || return 0
  local result
  result="$(osascript - "${probe_window_id}" "${marker}" <<OSA
on run argv
  set probeWindowID to (item 1 of argv) as integer
  set probeMarker to item 2 of argv
  tell application "${browser}"
    set matches to (every window whose id is probeWindowID)
    if (count of matches) is 0 then return "gone"
    set probeWindow to item 1 of matches
    if (count of tabs of probeWindow) is not 1 then return "refused: window has other tabs"
    if (URL of tab 1 of probeWindow) does not contain probeMarker then return "refused: tab is not the probe"
    close probeWindow
    return "closed"
  end tell
end run
OSA
)" || result="error"
  log "probe window ${probe_window_id}: ${result}"
  probe_window_id=""
  [[ "${result}" == "closed" || "${result}" == "gone" ]]
}

cleanup() {
  close_probe_window || true
  # Launched the browser just for the probe and nothing else is open: quit it.
  if (( browser_was_running == 0 )) \
    && [[ "$(osascript -e "tell application \"${browser}\" to count windows" 2>/dev/null || echo 1)" == "0" ]]; then
    osascript -e "tell application \"${browser}\" to quit" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap 'exit 1' INT TERM

# --- 1. Preflight --------------------------------------------------------------

pgrep -xq FastTab || { summary "PREFLIGHT-FAIL" "reason=\"FastTab is not running\""; exit 2; }
log "asking FastTab for the server's view (up to ~4 min right after a FastTab launch)"
if ! ask_server "${warmup_wait_s}"; then
  summary "PREFLIGHT-FAIL" "reason=\"FastTab did not answer the probe request within ${warmup_wait_s}s (build predates the probe hook, or sync not started)\""
  exit 2
fi
case "${server_outcome}" in
  ok) ;;
  zone-missing) summary "PREFLIGHT-FAIL" "reason=\"iCloud state zone does not exist yet - has this Mac ever synced?\""; exit 2 ;;
  *) summary "PREFLIGHT-FAIL" "reason=\"server read failed (outcome=${server_outcome}, health=${server_health})\""; exit 2 ;;
esac
case "${server_health}" in
  ok) ;;
  unknown) log "warning: sync health is 'unknown' (account status not determined yet); continuing" ;;
  *) summary "PREFLIGHT-FAIL" "reason=\"iCloud sync unhealthy: ${server_health}\""; exit 2 ;;
esac
log "preflight ok: health=${server_health}, this Mac has ${server_device_tab_count} tab records on the server"

# --- 2-3. Open probe tab, wait for it on the server ---------------------------

log "opening probe window in ${browser}: ${probe_url}"
probe_window_id="$(open_probe_window)" || { summary "FAIL" "reason=\"could not open probe window\""; exit 1; }
log "probe window id=${probe_window_id}; waiting for server record (timeout ${appear_timeout_s}s)"
if ! appear_s="$(wait_for_server present "${appear_timeout_s}")"; then
  summary "FAIL" "appears=FAIL(>${appear_timeout_s}s)"
  exit 1
fi
log "PASS appears: record on server after ${appear_s}s"

# --- 4-5. Close it idle, wait for it to leave the server ----------------------

close_probe_window || { summary "FAIL" "appears=${appear_s}s reason=\"probe window close refused\""; exit 1; }
log "probe window closed (command bar untouched); waiting for server delete (timeout ${disappear_timeout_s}s)"
if ! disappear_s="$(wait_for_server absent "${disappear_timeout_s}")"; then
  summary "FAIL" "appears=${appear_s}s disappears=FAIL(>${disappear_timeout_s}s)"
  exit 1
fi
log "PASS disappears: record gone from server after ${disappear_s}s"
summary "PASS" "appears=${appear_s}s disappears=${disappear_s}s"
