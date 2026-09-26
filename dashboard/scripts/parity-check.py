#!/usr/bin/env python3
"""P0 dashboard-move parity check: does the moved server (default :4712)
produce the same AGENT ROWS as AptusFit's live server (default :4711)?

GET ONLY. This never writes to either port — see the brief's hard rule
("never POST to 4711, restart it, or kill it"). Run it with the moved
server already up on its port (e.g. `scripts/restart.sh --port 4712
--detached`, or the tmux session `dash-4712`) and AptusFit's real instance
already up on 4711 (it always is — do not start or stop it).

WHAT COUNTS AS PARITY
----------------------
Same set of pane ids in `computed.agents`, and for each pane id: same
`machine` and the same STATUS CLASS. Not byte-identical rows — `screenState`
free text, `contextPct`, `memoryBytes` etc. are read live and can tick
between the two curl calls (timing noise, not a regression). "Status class"
buckets `screenState` the same coarse way the UI's own severity grouping
does (needs-you / working / idle-ish / unknown), so a benign flip inside one
bucket (e.g. WAITING -> WAITING_LONG) does not fail the check, but a hop
between buckets (e.g. WAITING -> UNKNOWN) does — that would mean the two
servers disagree about the one thing the whole board exists to answer.

Usage:
  scripts/parity-check.py [--old http://127.0.0.1:4711] [--new http://127.0.0.1:4712]
  scripts/parity-check.py --retries 3 --retry-wait 2   # tolerate one-off timing blips
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request

#: Coarse status buckets — must stay in sync with however the UI's own
#: severity grouping reads `screenState` (see dashboard/ui's status badge).
#: Kept intentionally small and conservative: anything not recognized falls
#: into its own literal bucket, so an unrecognized state is compared for
#: exact equality rather than silently waved through.
_STATUS_BUCKETS = {
    "NEEDS_YOU": {"NEEDS_YOU", "PERMISSION", "QUESTION"},
    "WORKING": {"WORKING", "ACTIVE"},
    "WAITING": {"WAITING", "WAITING_LONG", "IDLE"},
    "UNKNOWN": {"UNKNOWN"},
}


def status_bucket(screen_state) -> str:
    s = str(screen_state or "").upper()
    for bucket, members in _STATUS_BUCKETS.items():
        if s in members:
            return bucket
    return f"OTHER:{s}"  # unrecognized — compared literally, not waved through


def fetch_state(base_url: str, timeout: float = 8.0) -> dict:
    url = base_url.rstrip("/") + "/api/state"
    req = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read().decode("utf-8", "replace")
    return json.loads(body)


def agent_rows(state: dict) -> dict:
    """paneId -> {machine, statusBucket, screenState} for every row in
    computed.agents. paneId is the natural join key — it is what both
    AgentBar and the UI already key rows on."""
    rows = {}
    for agent in (state.get("computed") or {}).get("agents") or []:
        pane_id = agent.get("paneId")
        if not pane_id:
            continue
        rows[pane_id] = {
            "machine": agent.get("machine"),
            "statusBucket": status_bucket(agent.get("screenState")),
            "screenState": agent.get("screenState"),
        }
    return rows


def diff_rows(old_rows: dict, new_rows: dict) -> list:
    """Human-readable mismatch lines, or [] when parity holds."""
    problems = []
    old_ids, new_ids = set(old_rows), set(new_rows)
    only_old = sorted(old_ids - new_ids)
    only_new = sorted(new_ids - old_ids)
    if only_old:
        problems.append(f"{len(only_old)} pane(s) on the OLD server missing from "
                         f"the new one: {only_old}")
    if only_new:
        problems.append(f"{len(only_new)} pane(s) on the NEW server not present "
                         f"on the old one: {only_new}")
    for pane_id in sorted(old_ids & new_ids):
        old, new = old_rows[pane_id], new_rows[pane_id]
        if old["machine"] != new["machine"]:
            problems.append(f"{pane_id}: machine differs — old={old['machine']!r} "
                             f"new={new['machine']!r}")
        if old["statusBucket"] != new["statusBucket"]:
            problems.append(
                f"{pane_id}: status bucket differs — "
                f"old={old['statusBucket']!r} ({old['screenState']!r}) "
                f"new={new['statusBucket']!r} ({new['screenState']!r})")
    return problems


def run_once(old_url: str, new_url: str) -> tuple[bool, list, int, int]:
    """-> (ok, problems, old_count, new_count)."""
    try:
        old_state = fetch_state(old_url)
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as exc:
        return False, [f"could not read {old_url}/api/state: {exc}"], 0, 0
    try:
        new_state = fetch_state(new_url)
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as exc:
        return False, [f"could not read {new_url}/api/state: {exc}"], 0, 0
    old_rows = agent_rows(old_state)
    new_rows = agent_rows(new_state)
    problems = diff_rows(old_rows, new_rows)
    return not problems, problems, len(old_rows), len(new_rows)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--old", default="http://127.0.0.1:4711",
                     help="AptusFit's live server (read-only, GET only). Default :4711.")
    ap.add_argument("--new", default="http://127.0.0.1:4712",
                     help="The moved server under test. Default :4712.")
    ap.add_argument("--retries", type=int, default=1,
                     help="Attempts before reporting failure (each fetches both "
                          "servers again) — absorbs one-off timing noise between "
                          "the two curl calls. Default 1 (no retry).")
    ap.add_argument("--retry-wait", type=float, default=2.0,
                     help="Seconds between retries. Default 2.0.")
    args = ap.parse_args()

    last_problems, last_old_n, last_new_n = [], 0, 0
    for attempt in range(1, args.retries + 1):
        ok, problems, old_n, new_n = run_once(args.old, args.new)
        if ok:
            print(f"PARITY OK — {old_n} agent row(s) on {args.old}, "
                  f"{new_n} on {args.new}, all pane ids/machine/status match "
                  f"(attempt {attempt}/{args.retries})")
            return 0
        last_problems, last_old_n, last_new_n = problems, old_n, new_n
        if attempt < args.retries:
            print(f"attempt {attempt}/{args.retries}: {len(problems)} mismatch(es) "
                  f"— retrying in {args.retry_wait}s (may be timing noise)")
            time.sleep(args.retry_wait)

    print(f"PARITY FAILED — {last_old_n} agent row(s) on {args.old}, "
          f"{last_new_n} on {args.new}, after {args.retries} attempt(s):")
    for p in last_problems:
        print(f"  - {p}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
