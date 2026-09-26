#!/usr/bin/env python3
"""`classifiers disagree 5m+: hook=working herdr=idle` must not fire on a worker that is working.

WHAT HAPPENED (2026-09-20 ~22:25, pane wB:p2Y `fb-injury`)
---------------------------------------------------------
Commit 93e1b66 made the disagree rule silent while the screen showed a LIVE
SPINNER. This alert fired anyway, 21 minutes after that commit was running, on a
pane that was plainly working. Its frame (REAL, redacted, fixtures/
disagree-frames.json): the worker's reply was being streamed while the visible
viewport sat scrolled back on an earlier plan render - so no spinner, an
idle-looking composer, footer `⏵⏵ auto mode on · ← 1 agent`. The classifier reads
that as UNKNOWN. The signals that DID show life were all on screen and all
ignored by the rule:

  * `N new messages (click) ↓` climbing 6 -> 11 -> 20 between sweeps;
  * the status line's `+1/-0` -> `+5/-0` (files the worker was creating) and the
    context % climbing 20 -> 22 -> 24 -> 26;
  * the hook's own `working` (every tool call refreshes it);
  * a sub-agent running (`◯ Explore ...` panel, earlier in the same turn).

The rule was `hook says working, herdr says idle, screen is not ACTIVE => alarm`.
93e1b66's own test even pinned it: "hook working, herdr idle, screen UNKNOWN ->
alarm (nothing corroborates the hook)". That premise was false - the rule simply
never LOOKED for corroboration beyond one spinner shape.

Bar: never fire against evidence of live work; keep firing on a genuinely dead
turn (hook `working` gone stale, screen frozen, no sub-agent) and never let
"a sub-agent is running" vouch forever (bounded ceiling, flagged with evidence).
"""
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "server", "lib"))

import chief_dashboard_feeds as feeds  # noqa: E402
import chief_dashboard_views as views  # noqa: E402
import classify_pane  # noqa: E402
import pane_screen_signals as signals  # noqa: E402

# Ported from AptusFit scripts/tests/test_disagree_live_work.py (P0 move).
# Dropped: section 7 ("the alert text carries its evidence"), which exercised
# chief_wake_fingerprint.attention_keys — that module lives in the
# agent-skills delivery-ops plugin and is NOT-CARRIED by this move (it wakes
# a human via the AptusFit chief flow, not part of the generic dashboard
# core). Sections 0-6 below (classify_pane / chief_dashboard_feeds /
# chief_dashboard_views / pane_screen_signals) are all in the MOVE set and
# are ported unchanged.

FRAMES = json.load(open(os.path.join(HERE, "fixtures", "disagree-frames.json")))
fails = []
PANE = "wB:p2Y"


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def frame(name):
    return FRAMES[name]["text"]


def build_row(hook_state="working", herdr_status="idle", *, screen_state, hook_age=400,
              unchanged_sec=None, subagents=0, turn_reported=True):
    """One agents-view row built from the REAL feed shapes, so the rule is
    exercised where the dashboard actually calls it. `unchanged_sec=None` = the
    dashboard has no history for the pane yet (first look)."""
    now = time.time()
    empty = lambda: {"broken": False, "warming": False, "error": None, "lastSuccessTs": 1.0,
                     "ageSec": 0, "lastDurationSec": 0, "data": None}
    snap = {n: empty() for n in ("hookCache", "herdr", "paneTick", "gitHealth", "board",
                                 "paneScreen", "workItems")}
    sid = feeds.sanitize_pane_id(PANE)
    snap["hookCache"]["data"] = {sid: {"seq": now - hook_age, "state": hook_state, "reason": None}}
    agent = {"pane_id": PANE, "tab_id": "wB:t2X", "agent_status": herdr_status}
    if turn_reported:
        agent["last_completed_turn"] = {"turn": 11, "completed_unix_ms": 1}
    snap["herdr"]["data"] = {"agents": [agent], "tabs": [{"tab_id": "wB:t2X", "label": "fb-injury"}]}
    entry = {"state": screen_state, "signal": "x", "digest": "d1",
             "changedAt": now - (unchanged_sec or 0), "motionKnown": unchanged_sec is not None,
             "subagents": subagents}
    snap["paneScreen"]["data"] = {sid: entry}
    return [r for r in views.build_agents_view(snap) if r["paneId"] == PANE][0]


def disagrees(**kw):
    return build_row(**kw)["disagree"]


# ── 0. the input: what the classifier makes of the REAL alert frames ─────────
print("== 0: the real frames the alert fired on ==")
for name in ("p2y_scrolled_back_streaming_a", "p2y_scrolled_back_streaming_b",
             "p2y_scrolled_back_streaming_c", "p2y_scrolled_back_streaming_alert_frame"):
    check(f"{name}: classified UNKNOWN (no spinner, idle-looking composer)",
          classify_pane.classify(frame(name))[0], "UNKNOWN")
alert_state = classify_pane.classify(frame("p2y_scrolled_back_streaming_alert_frame"))[0]

# ── 1. wB:p2Y itself, the exact state that fired ─────────────────────────────
print("== 1: the real p2Y alert state does not fire ==")
check("hook working (fresh, 40s) + herdr idle + the real alert frame -> no alarm",
      disagrees(screen_state=alert_state, hook_age=40), False)
check("hook working last event 6m ago + screen changed 30s ago (the counters climb) -> no alarm",
      disagrees(screen_state=alert_state, hook_age=360, unchanged_sec=30), False)
check("same, and herdr reports no completed turn at all (a default, not a measurement) -> no alarm",
      disagrees(screen_state=alert_state, hook_age=360, unchanged_sec=30, turn_reported=False), False)

# ── 2. a running sub-agent is live work ──────────────────────────────────────
print("== 2: sub-agent running ==")
check("stale hook, idle-looking composer, 2 sub-agent lines on screen (first look) -> no alarm",
      disagrees(screen_state="UNKNOWN", hook_age=600, subagents=2), False)
check("parked on background agents, hook quiet 20m -> no alarm (waiting on purpose)",
      disagrees(screen_state="WAITING_ON_BACKGROUND", hook_age=1200), False)

# ── 3. genuinely dead: must STILL fire ───────────────────────────────────────
print("== 3: a dead turn still alarms ==")
check("hook working 30m stale, screen frozen 30m, no sub-agent -> ALARM",
      disagrees(screen_state="UNKNOWN", hook_age=1800, unchanged_sec=1800), True)
check("...with a WAITING (finished-looking) screen -> ALARM",
      disagrees(screen_state="WAITING", hook_age=1800, unchanged_sec=1800), True)
check("a sub-agent line on a FROZEN screen does not vouch (its timer would tick) -> ALARM",
      disagrees(screen_state="UNKNOWN", hook_age=1800, unchanged_sec=1800, subagents=1), True)
check("a spinner glyph on a FROZEN screen does not vouch -> ALARM",
      disagrees(screen_state="ACTIVE", hook_age=1800, unchanged_sec=1800), True)
check("a crash banner is never vouched for, even with a fresh hook -> ALARM",
      disagrees(screen_state="CRASHED", hook_age=10, unchanged_sec=5), True)
check("an open prompt is never vouched for by movement -> ALARM",
      disagrees(screen_state="NEEDS_HUMAN", hook_age=400, unchanged_sec=5), True)

# ── 4. bounded ceiling: no new blind spot ────────────────────────────────────
print("== 4: even a plausible-looking pane is flagged past the ceiling ==")
THREE_HOURS = 3 * 3600
check("screen still moving but the hook has been silent 3h -> ALARM (with evidence)",
      disagrees(screen_state="UNKNOWN", hook_age=THREE_HOURS, unchanged_sec=20), True)
check("sub-agent 'running' but hook silent 3h -> ALARM",
      disagrees(screen_state="UNKNOWN", hook_age=THREE_HOURS, subagents=1), True)
check("a spinner glyph with UNKNOWN motion and a hook silent 5h -> ALARM (a glyph is not a ticking spinner)",
      disagrees(screen_state="ACTIVE", hook_age=5 * 3600), True)
check("a spinner that is provably ticking is trusted past the ceiling (a 3h tool call)",
      disagrees(screen_state="ACTIVE", hook_age=THREE_HOURS, unchanged_sec=3), False)
check("parked on a background agent for 3h -> ALARM (the 2h parked ceiling)",
      disagrees(screen_state="WAITING_ON_BACKGROUND", hook_age=THREE_HOURS), True)

# ── 5. progress is measured between sweeps ───────────────────────────────────
print("== 5: rising counters between sweeps count as progress ==")
stamp = getattr(signals, "stamp_screen_motion", None)
digest = getattr(feeds, "screen_digest", None) or getattr(signals, "screen_digest", None)
check("the dashboard has a per-sweep motion stamp", callable(stamp), True)
if callable(stamp):
    t0 = 1_800_000_000.0
    seq = [("p2y_scrolled_back_streaming_a", t0), ("p2y_scrolled_back_streaming_b", t0 + 15),
           ("p2y_scrolled_back_streaming_c", t0 + 30), ("p2y_scrolled_back_streaming_alert_frame", t0 + 45)]
    prev = None
    for name, ts in seq:
        text = frame(name)
        cur = {"state": "UNKNOWN", "digest": signals.screen_digest(text)}
        stamp(cur, prev, ts)
        if prev is not None:
            check(f"{name}: screen counted as MOVING vs the previous sweep",
                  (cur["motionKnown"], cur["changedAt"]), (True, ts))
        else:
            check(f"{name}: first look is 'unknown', not 'moving'", cur["motionKnown"], False)
        prev = cur
    same = {"state": "UNKNOWN", "digest": prev["digest"]}
    stamp(same, prev, t0 + 900)
    check("an identical screen keeps its OLD changedAt (frozen clock keeps running)",
          (same["motionKnown"], same["changedAt"]), (True, t0 + 45))
    base = frame("p2y_scrolled_back_streaming_c")
    check("only the +N/-M status counter differs -> different fingerprint",
          signals.screen_digest(base) != signals.screen_digest(base.replace("+5/-0", "+6/-0")), True)
    check("a pure reflow (whitespace) is NOT movement",
          signals.screen_digest(base) == signals.screen_digest(base.replace("  ", "   ")), True)

print("== 5b: history survives a pane whose read fails for one sweep (QA1 #1) ==")
sweep = getattr(signals, "stamp_sweep_motion", None)
check("the dashboard keeps a per-pane motion history", callable(sweep), True)
if callable(sweep):
    hist, t0 = {}, 1_800_000_000.0
    sweep({"k": {"digest": "aaa"}}, hist, t0, live_keys={"k"})
    sweep({}, hist, t0 + 15, live_keys={"k"})                      # unreadable this sweep
    third = {"k": {"digest": "aaa"}}
    sweep(third, hist, t0 + 30, live_keys={"k"})
    check("a dropped read does not reset the frozen clock",
          (third["k"]["motionKnown"], third["k"]["changedAt"]), (True, t0))
    sweep({}, hist, t0 + 45, live_keys={"other"})
    check("a pane that is no longer live is forgotten", "k" in hist, False)

print("== 5c: a quiet feed does not turn a moving screen into a frozen one (QA2 #1) ==")
now = time.time()
entry = {"motionKnown": True, "changedAt": now - 920, "ts": now - 900}
check("20 s of motion before the last read, feed silent 15 min -> 20 s, not 920 s",
      round(signals.screen_unchanged_sec(entry, now)), 20)
check("a live feed (read just now) still measures to now",
      round(signals.screen_unchanged_sec({"motionKnown": True, "changedAt": now - 700, "ts": now}, now)), 700)

# ── 6. the feed reads sub-agent lines off the real panel frame ───────────────
print("== 6: read_one_pane_screen carries the fingerprint + sub-agent count ==")
_orig = feeds.herdr_transport.herdr_cmd_text
try:
    feeds.herdr_transport.herdr_cmd_text = lambda machine, argv, **kw: frame("p2y_subagents_running_panel")
    got = feeds.read_one_pane_screen(PANE)
    entry = got[1] if got else {}
    check("2 sub-agent status lines are counted", entry.get("subagents"), 2)
    check("a fingerprint is carried", bool(entry.get("digest")), True)
    feeds.herdr_transport.herdr_cmd_text = lambda machine, argv, **kw: frame("p2y_scrolled_back_streaming_c")
    entry = (feeds.read_one_pane_screen(PANE) or (None, {}))[1]
    check("an idle-looking streaming frame has no sub-agents", entry.get("subagents"), 0)
finally:
    feeds.herdr_transport.herdr_cmd_text = _orig

print()
if fails:
    print(f"{len(fails)} FAILED:")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("ALL PASS")
