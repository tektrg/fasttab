#!/usr/bin/env bash
# Restart the chief dashboard server and report what it sees.
#
# WHY THIS EXISTS
# ---------------
# Verifying a dashboard change is a multi-step dance done by hand: kill the
# server, retype the command into its herdr pane (a SHELL pane — `pane run`
# executes it there by itself, verified 2026-09-09; see scripts/nudge-pane.sh
# for the separate, unreliable case of typing into an already-booted Claude
# Code TUI, which this is not), wait long enough for the SLOWEST feed to warm
# — the screen reader is on a 45s cycle — and only then read /api/state.
# Skipping the wait is the trap: every feed reads `warming` on a cold start,
# NEEDS YOU comes back short, and the change looks broken when it is merely
# early (cost two false verdicts on 2026-09-04).
#
# The pane is discovered by its herdr TAB LABEL (`chief-dashboard-server`) via
# server/lib/herdr_pane_lookup.py — pane ids go stale on every herdr reset.
# Override with --pane or $CHIEF_DASHBOARD_PANE.
#
# --detached (no herdr pane needed): launches the server as a plain background
# process instead, logging to dashboard/.claude/restart-detached-<port>.log.
# This is the P0-move testing path — a second instance on :4712 has no herdr
# tab of its own and must never touch the real :4711 pane. Production (:4711,
# the PO's own pane) keeps using the herdr-pane path below.
#
# The wait polls until no feed reads `warming` (up to --wait seconds) instead of
# sleeping blind; the report is server/lib/dashboard_state_summary.py, which
# never crashes on an /api/state shape it has not seen.
#
# NOTE: the dashboard is offline for a few seconds while it restarts — other
# sessions polling it will blip.
#
# Usage: scripts/restart.sh [--pane wB:p1P] [--port 4712] [--detached] [--wait 55] [--dry-run]
set -uo pipefail

DASHBOARD_TAB_LABEL="chief-dashboard-server"
PANE="${CHIEF_DASHBOARD_PANE:-}"
WAIT_SEC=55
POLL_SEC=5
PORT="${CHIEF_DASHBOARD_PORT:-4711}"
DETACHED=0
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --pane) PANE="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --detached) DETACHED=1; shift ;;
    --wait) WAIT_SEC="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

DASHBOARD_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DASHBOARD_HOME" || exit 1

SERVER_RELPATH="server/chief-dashboard-server.py"
SERVER_BASENAME="chief-dashboard-server.py"
SUMMARY_PY="$DASHBOARD_HOME/server/lib/dashboard_state_summary.py"
DETACHED_LOG="$DASHBOARD_HOME/.claude/restart-detached-$PORT.log"

if [ "$DETACHED" = 0 ] && [ -z "$PANE" ]; then
  PANE="$(python3 "$DASHBOARD_HOME/server/lib/herdr_pane_lookup.py" "$DASHBOARD_TAB_LABEL")" \
    || { echo "no herdr tab labelled '$DASHBOARD_TAB_LABEL' — create it (herdr tab create --cwd $DASHBOARD_HOME --label $DASHBOARD_TAB_LABEL --no-focus), pass --pane, or pass --detached to skip herdr" >&2; exit 1; }
fi

if [ "$DRY_RUN" = 1 ]; then
  if [ "$DETACHED" = 1 ]; then
    echo "[dry-run] would kill whatever owns :$PORT (only if it looks like $SERVER_BASENAME), launch it detached with CHIEF_DASHBOARD_PORT=$PORT, poll :$PORT up to ${WAIT_SEC}s until no feed is warming"
  else
    echo "[dry-run] would kill whatever owns :$PORT (only if it looks like $SERVER_BASENAME), run it in pane $PANE, poll :$PORT up to ${WAIT_SEC}s until no feed is warming"
  fi
  exit 0
fi

# ---- restart/kill by PORT OWNER, never `pkill -f <name>` (design call #3) --
# A name-based pkill kills every same-named process regardless of which port
# it holds — the real :4711 board, a :4712 test instance, and any other
# worktree's copy, all in one shot. That is exactly why the brief forbids it:
# ask the port who owns it, confirm the owner's argv looks like this server,
# and only signal THAT pid. Same shape as chief-dashboard-watchdog.py's
# kill_stale_server(), which this mirrors in bash.
kill_port_owner() {
  local port="$1" pids pid cmd killed_any=0
  pids="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null)"
  [ -z "$pids" ] && return 0
  for pid in $pids; do
    cmd="$(ps -o command= -p "$pid" 2>/dev/null)"
    case "$cmd" in
      *"$SERVER_BASENAME"*)
        kill "$pid" 2>/dev/null && killed_any=1
        echo "killed pid $pid (was holding :$port, argv matched $SERVER_BASENAME)"
        ;;
      *)
        echo "port $port is held by pid $pid that does not look like $SERVER_BASENAME (argv: ${cmd:-<unreadable>}) — refusing to kill it" >&2
        ;;
    esac
  done
  [ "$killed_any" = 1 ] || return 0
  local deadline=$((SECONDS + 10))
  while [ $SECONDS -lt "$deadline" ]; do
    lsof -nP -iTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1 || return 0
    sleep 0.5
  done
  echo "port $port still held 10s after signalling — relaunching anyway" >&2
}

kill_port_owner "$PORT"

if [ "$DETACHED" = 1 ]; then
  mkdir -p "$(dirname "$DETACHED_LOG")"
  CHIEF_DASHBOARD_PORT="$PORT" nohup python3 "$SERVER_RELPATH" >>"$DETACHED_LOG" 2>&1 &
  disown
  echo "restarted detached (pid $!, log $DETACHED_LOG); waiting up to ${WAIT_SEC}s for every feed to warm…"
else
  herdr pane run "$PANE" "CHIEF_DASHBOARD_PORT=$PORT python3 $SERVER_RELPATH" >/dev/null 2>&1 \
    || { echo "could not reach herdr pane $PANE — is the dashboard tab still open?" >&2; exit 1; }
  # `pane run` already executes the command in this SHELL pane — no extra
  # `send-keys enter` needed (a stray blind enter risks a `^M^M` double, or
  # executing a leftover unsubmitted line, for no benefit). Verified 2026-09-09.
  echo "restarted in $PANE; waiting up to ${WAIT_SEC}s for every feed to warm…"
fi

fetch_state() { curl -s --max-time 5 "http://127.0.0.1:$PORT/api/state"; }
waited=0
while [ "$waited" -lt "$WAIT_SEC" ]; do
  sleep "$POLL_SEC"; waited=$((waited + POLL_SEC))
  fetch_state | python3 "$SUMMARY_PY" --is-warm && break
done

STATE_JSON="$(fetch_state)"
if [ -z "$STATE_JSON" ]; then
  echo "no answer from the server — read the pane/log, it did not start" >&2
  exit 1
fi
printf '%s' "$STATE_JSON" | python3 "$SUMMARY_PY"
printf '%s' "$STATE_JSON" | python3 "$SUMMARY_PY" --is-warm || echo "(still warming after ${WAIT_SEC}s — counts above may be short)"
exit 0
