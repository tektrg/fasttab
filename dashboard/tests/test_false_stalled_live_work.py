#!/usr/bin/env python3
"""A worker that is visibly working is never mis-read as idle by the screen
classifier or the dashboard's row-level disagree check.

Ported from AptusFit scripts/tests/test_false_stalled_live_work.py (P0 move).
That file is a boundary test between dashboard-side code (classify_pane,
pane_screen_signals, chief_dashboard_views/feeds, pane_live_work — all in the
MOVE set) and producer-side "stalled worker" detection (pane_liveness,
pane_evidence, and the agent-skills delivery-ops plugin's `supervisor` —
NOT-CARRIED, they stay in AptusFit and run inside worker sessions, not the
dashboard server). This port keeps only the MOVE-set sections:

  1. classify: every live spinner shape reads ACTIVE (classify_pane)
  d. hook_vs_herdr_disagree (pane_screen_signals)
  d2. the dashboard row itself does not flag a live screen as disagreeing
      (chief_dashboard_views / chief_dashboard_feeds)
  q1/q2. spinner-shape + elapsed-time parsing regressions (classify_pane,
      pane_live_work)

Dropped entirely: the `Sweeper`-based sections (2, c, frozen-spinner,
ceiling, fresh-hook-rescue, e/e2/e3, "the desk wake line") and q3 — all
exercise `pane_liveness.observe`, `pane_evidence.annotate_stalled/
evidence_for/desk_message`, or `delivery_ops.supervisor.supervise`, none of
which the dashboard server imports.
"""
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "server", "lib"))

import classify_pane  # noqa: E402
import pane_screen_signals as signals  # noqa: E402

FRAMES = json.load(open(os.path.join(HERE, "fixtures", "live-work-frames.json")))
fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def frame(name):
    return FRAMES[name]["text"]


def state(text):
    return classify_pane.classify(text)[0]


def without_monitor_footer(text):
    """The same real frame with its `1 monitor` footer segment removed, so the
    parked-on-background rule cannot mask the spinner read under test."""
    return re.sub(r"· 1 shell, 1 monitor|· 1 monitor", "", text)


# ── 1. The live-work shapes the classifier missed ───────────────────────────
print("== classify: every live spinner shape reads ACTIVE ==")
for name in ("wrapped_detail_spinner_sock_hopping", "post_compaction_session_start_hooks",
             "bare_spinner_no_parenthetical", "code_search_doodling_8m",
             "compacting_conversation", "long_turn_doodling_10m"):
    check(f"{name} -> ACTIVE", state(without_monitor_footer(frame(name))), "ACTIVE")
    check(f"{name} (with its real monitor footer) -> ACTIVE", state(frame(name)), "ACTIVE")

print("== classify: a finished / dead frame is still NOT active ==")
check("turn ended, 1 shell claimed -> WAITING", state(frame("dead_shell_turn_ended")), "WAITING")
FINISHED = ("  Done.\n\n✻ Baked for 2m 49s · done 3:34 PM\n" + "─" * 76 + "\n❯\n" + "─" * 76 +
            "\n    [Opus 5 (1M context)] 25% context | git:main\n  ⏵⏵ auto mode on (shift+tab to cycle)\n")
check("finished spinner line -> WAITING", state(FINISHED), "WAITING")
PROSE = ("  Notes for next time:\n  · Loading… is what the page shows first\n\n" + "─" * 76 +
         "\n❯\n" + "─" * 76 + "\n  ⏵⏵ auto mode on (shift+tab to cycle)\n")
check("a prose bullet ending in an ellipsis is not a spinner", state(PROSE) == "ACTIVE", False)

# ── (d) hook=working vs herdr=done is not news while the screen shows work ───
print("== d: herdr's agent_status is untrusted; only a screen-uncorroborated split alarms ==")
D = signals.hook_vs_herdr_disagree
check("hook working, herdr done, screen ACTIVE -> no alarm", D("working", "done", "ACTIVE"), False)
check("hook idle == herdr done (same fact, two spellings) -> no alarm", D("idle", "done", "WAITING"), False)
check("hook idle, herdr working, screen WAITING -> no alarm (screen sides with hook)",
      D("idle", "working", "WAITING"), False)
check("hook working, herdr done, screen WAITING -> alarm (screen sides with herdr)",
      D("working", "done", "WAITING"), True)
check("hook working, herdr idle, screen UNKNOWN, NO evidence supplied -> alarm (see "
      "test_disagree_live_work.py for the evidence that silences it)",
      D("working", "idle", "UNKNOWN"), True)
check("no hook data -> never an alarm", D(None, "done", "ACTIVE"), False)

print("== d2: the dashboard row itself no longer flags hook=working herdr=done on a live screen ==")
import chief_dashboard_views as views  # noqa: E402
import chief_dashboard_feeds as feeds  # noqa: E402


def agents_view_row(hook_state, herdr_status, screen_state, hook_age_sec=0):
    empty = lambda: {"broken": False, "warming": False, "error": None, "lastSuccessTs": 1.0,
                     "ageSec": 0, "lastDurationSec": 0, "data": None}
    snap = {n: empty() for n in ("hookCache", "herdr", "paneTick", "gitHealth", "board",
                                 "paneScreen", "workItems")}
    sid = feeds.sanitize_pane_id("w6:p12")
    snap["hookCache"]["data"] = {sid: {"seq": time.time() - hook_age_sec, "state": hook_state,
                                 "reason": None}}
    snap["herdr"]["data"] = {"agents": [{"pane_id": "w6:p12", "tab_id": "w6:t12",
                                         "agent_status": herdr_status}], "tabs": []}
    snap["paneScreen"]["data"] = {sid: {"state": screen_state, "signal": "x"}}
    return [r for r in views.build_agents_view(snap) if r["paneId"] == "w6:p12"][0]


check("row: hook working / herdr done / spinner on screen -> disagree False",
      agents_view_row("working", "done", "ACTIVE")["disagree"], False)
check("row: hook working 10m stale / herdr done / finished screen -> disagree True (genuine split)",
      agents_view_row("working", "done", "WAITING", hook_age_sec=600)["disagree"], True)
check("row: a hook `working` from seconds ago outranks a finished-looking screen (as resolve_state does)",
      agents_view_row("working", "done", "WAITING", hook_age_sec=5)["disagree"], False)

# ── QA round 1 regressions ───────────────────────────────────────────────────
print("== q1: bullets in a FINISHED reply are not spinners ==")
import pane_live_work as live_work  # noqa: E402
BOX = "\n" + "─" * 60 + "\n❯\n" + "─" * 60 + "\n  ⏵⏵ auto mode on"
DONE = "\n✻ Baked for 2m 3s"
for label, body in (
        ("summary bullet", "⏺ Summary:\n  · Loading…\n  · Done\n"),
        ("indented tool output", "      ✳ Working now…\n"),
        ("finished bullet with a duration", "· Fixed it… (took 4s)\n"),
        ("retry note", "· Retrying… (attempt 2 in 5s)\n")):
    for tail_name, tail in (("with box", BOX), ("with done marker + box", DONE + BOX)):
        check(f"{label} ({tail_name}) is not ACTIVE",
              classify_pane.classify(body + tail)[0] != "ACTIVE", True)
check("a real bare spinner above the box is still ACTIVE",
      classify_pane.classify("⏺ Monitor event\n\n✽ Skedaddling…\n" + BOX)[0], "ACTIVE")

print("== q2: the timer is the LAST one in the parenthetical ==")
prog = live_work.progress(["✻ Running… (timeout 120s hook 1/3 · 9m 58s)", "─" * 60])
check("elapsed is 9m58s not the 120s timeout", prog and prog["elapsedSec"], 598)

prog = live_work.progress(["✽ Flummoxing… (22m 35s · ↓ 46.9k tokens · thought for 1s)", "─" * 60])
check("a trailing `thought for 1s` is not the running clock", prog and prog["elapsedSec"], 22 * 60 + 35)

if fails:
    print("\nFAILURES:")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("\nAll false-stalled checks passed.")
