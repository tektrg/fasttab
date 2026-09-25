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
# scripts/lib/herdr_pane_lookup.py — pane ids go stale on every herdr reset.
# Override with --pane or $CHIEF_DASHBOARD_PANE.
#
# The wait polls until no feed reads `warming` (up to --wait seconds) instead of
# sleeping blind; the report is scripts/lib/dashboard_state_summary.py, which
# never crashes on an /api/state shape it has not seen.
#
# NOTE: the dashboard is offline for a few seconds while it restarts — other
# sessions polling it will blip.
#
# Usage: scripts/chief-dashboard-restart.sh [--pane wB:p1P] [--wait 55] [--dry-run]
set -uo pipefail

DASHBOARD_TAB_LABEL="chief-dashboard-server"
PANE="${CHIEF_DASHBOARD_PANE:-}"
WAIT_SEC=55
POLL_SEC=5
PORT="${CHIEF_DASHBOARD_PORT:-4711}"
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --pane) PANE="$2"; shift 2 ;;
    --wait) WAIT_SEC="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

SUMMARY_PY="$REPO_ROOT/scripts/lib/dashboard_state_summary.py"
if [ -z "$PANE" ]; then
  PANE="$(python3 "$REPO_ROOT/scripts/lib/herdr_pane_lookup.py" "$DASHBOARD_TAB_LABEL")" \
    || { echo "no herdr tab labelled '$DASHBOARD_TAB_LABEL' — create it (herdr tab create --cwd $REPO_ROOT --label $DASHBOARD_TAB_LABEL --no-focus) or pass --pane" >&2; exit 1; }
fi
if [ "$DRY_RUN" = 1 ]; then
  echo "[dry-run] would pkill chief-dashboard-server.py, run it in pane $PANE, poll :$PORT up to ${WAIT_SEC}s until no feed is warming"
  exit 0
fi

pkill -f 'chief-dashboard-server.py' 2>/dev/null
sleep 2
herdr pane run "$PANE" "python3 scripts/chief-dashboard-server.py" >/dev/null 2>&1 \
  || { echo "could not reach herdr pane $PANE — is the dashboard tab still open?" >&2; exit 1; }
# `pane run` already executes the command in this SHELL pane — no extra
# `send-keys enter` needed (a stray blind enter risks a `^M^M` double, or
# executing a leftover unsubmitted line, for no benefit). Verified 2026-09-09.

echo "restarted in $PANE; waiting up to ${WAIT_SEC}s for every feed to warm…"
fetch_state() { curl -s --max-time 5 "http://127.0.0.1:$PORT/api/state"; }
waited=0
while [ "$waited" -lt "$WAIT_SEC" ]; do
  sleep "$POLL_SEC"; waited=$((waited + POLL_SEC))
  fetch_state | python3 "$SUMMARY_PY" --is-warm && break
done

STATE_JSON="$(fetch_state)"
if [ -z "$STATE_JSON" ]; then
  echo "no answer from the server — read the pane, it did not start" >&2
  exit 1
fi
printf '%s' "$STATE_JSON" | python3 "$SUMMARY_PY"
printf '%s' "$STATE_JSON" | python3 "$SUMMARY_PY" --is-warm || echo "(still warming after ${WAIT_SEC}s — counts above may be short)"
exit 0
