#!/usr/bin/env python3
"""Direct-run tests for the remote (Air) activity clock, `screenActivitySec`.

WHY: Jev routing ranks sessions by "most recently active", and that clock was
the Pro-only hook cache (`hookSinceSec`). Air rows never have it, so they sorted
last and fell off AgentBar's 12-candidate cap. The remote paneScreen sweep
(~15s, already over ssh) now stamps "last screen change" per pane; remote rows
expose it as `screenActivitySec`, and ranking reads one accessor
(`personas.row_activity_sec`, mirrored by Swift `AgentSnapshot.activitySeconds`).

Bar: the clock moves only when the screen content changes; an unchanged poll or
a dropped read keeps it; a pane never seen changing (first look, or idle since a
dashboard restart) is None = oldest; it never makes a row look hook-backed.
"""
import os
import sys
import time

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib"))

os.environ.setdefault("CHIEF_DASHBOARD_MACHINES", "{}")

import chief_dashboard_feeds as feeds  # noqa: E402
import chief_dashboard_views as views  # noqa: E402
import chief_dashboard_herdr as herdr_transport  # noqa: E402
import pane_screen_signals as signals  # noqa: E402
import personas  # noqa: E402

fails = []
T0 = 1_800_000_000.0


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


print("== the sweep stamps a change only when the content changes ==")
history = {}
first = {"k": {"digest": "aaa"}}
signals.stamp_sweep_motion(first, history, T0, live_keys={"k"})
check("first look: no change observed yet", first["k"]["changeObserved"], False)
check("first look: activity unknown (None), not 'active at startup'",
      signals.screen_activity_sec(first["k"], T0 + 5), None)

same = {"k": {"digest": "aaa"}}
signals.stamp_sweep_motion(same, history, T0 + 15, live_keys={"k"})
check("unchanged poll after first look: still unknown (restart-safe)",
      signals.screen_activity_sec(same["k"], T0 + 15), None)

changed = {"k": {"digest": "bbb"}}
signals.stamp_sweep_motion(changed, history, T0 + 30, live_keys={"k"})
check("content changed: change observed", changed["k"]["changeObserved"], True)
check("content changed: activity measured from that sweep",
      signals.screen_activity_sec(changed["k"], T0 + 30), 0.0)

signals.stamp_sweep_motion({}, history, T0 + 45, live_keys={"k"})  # read failed
later = {"k": {"digest": "bbb"}}
signals.stamp_sweep_motion(later, history, T0 + 60, live_keys={"k"})
check("unchanged polls (and a dropped read) keep the change time",
      signals.screen_activity_sec(later["k"], T0 + 90), 60.0)

again = {"k": {"digest": "ccc"}}
signals.stamp_sweep_motion(again, history, T0 + 75, live_keys={"k"})
check("a newer change resets the clock",
      signals.screen_activity_sec(again["k"], T0 + 80), 5.0)
check("an entry with no stamp at all reads None",
      signals.screen_activity_sec({"state": "ACTIVE"}, T0), None)


print("== remote rows expose it; local rows and hook fields are untouched ==")


def empty_feed():
    return {"broken": False, "warming": False, "error": None,
            "lastSuccessTs": 1.0, "ageSec": 0, "lastDurationSec": 0, "data": None}


snap = {name: empty_feed() for name in
        ("hookCache", "herdr", "paneTick", "gitHealth", "board", "paneScreen", "workItems")}
snap["hookCache"]["data"] = {}
snap["herdr"]["data"] = {
    "agents": [{"pane_id": "w1:p1", "tab_id": "w1:t1", "agent": "claude"}],
    "tabs": [{"tab_id": "w1:t1", "label": "local-worker"}]}
snap["paneScreen"]["data"] = {feeds.sanitize_pane_id("w1:p1"): {
    "state": "WAITING", "digest": "x", "motionKnown": True,
    "changedAt": T0, "changeObserved": True}}
snap["herdr:air-m1"] = empty_feed()
snap["herdr:air-m1"]["data"] = {
    "agents": [{"pane_id": "w2:p1", "tab_id": "w2:t1", "agent": "claude"},
               {"pane_id": "w2:p2", "tab_id": "w2:t2", "agent": "claude"}],
    "tabs": []}
snap["paneScreen:air-m1"] = empty_feed()
busy_sid = feeds.sanitize_pane_id(herdr_transport.make_pane_key("air-m1", "w2:p1"))
idle_sid = feeds.sanitize_pane_id(herdr_transport.make_pane_key("air-m1", "w2:p2"))
recent_change = time.time() - 30
snap["paneScreen:air-m1"]["data"] = {
    busy_sid: {"state": "ACTIVE", "digest": "d1", "motionKnown": True,
               "changedAt": recent_change, "changeObserved": True},
    idle_sid: {"state": "WAITING", "digest": "d2", "motionKnown": True,
               "changedAt": recent_change, "changeObserved": False},
}

_ORIG_MACHINES = dict(feeds.MACHINES)
feeds.MACHINES.clear()
feeds.MACHINES["air-m1"] = {"sshAlias": "x", "herdrPath": "/x/herdr", "label": "Air", "maxParallel": 4}
views.MACHINES = feeds.MACHINES
try:
    rows = {r["paneId"]: r for r in views.build_agents_view(snap)}
finally:
    feeds.MACHINES.clear()
    feeds.MACHINES.update(_ORIG_MACHINES)
    views.MACHINES = feeds.MACHINES

busy, idle, local = rows["air-m1:w2:p1"], rows["air-m1:w2:p2"], rows["w1:p1"]
check("Air row with an observed change carries screenActivitySec ~30s",
      busy["screenActivitySec"] is not None and 29 <= busy["screenActivitySec"] <= 40, True)
check("Air row never seen changing: screenActivitySec None", idle["screenActivitySec"], None)
check("Air row still has no hook data", (busy["hasHookData"], busy["hookSinceSec"], busy["hookState"]),
      (False, None, None))
check("local row: screenActivitySec None (it has the hook clock)", local["screenActivitySec"], None)


print("== ranking reads hook clock first, then the screen clock ==")
check("hook clock wins", personas.row_activity_sec({"hookSinceSec": 500, "screenActivitySec": 1}), 500)
check("screen clock stands in", personas.row_activity_sec({"hookSinceSec": None, "screenActivitySec": 20}), 20)
check("neither -> None", personas.row_activity_sec({}), None)

persona = {"address": "air-m1:/w/aptus", "machine": "air-m1", "folder": "/w/aptus",
           "resolvedFolder": "/w/aptus"}
air_rows = [
    {"agentSession": "air-idle", "paneId": "air-m1:w2:p2", "machine": "air-m1",
     "cwd": "/w/aptus", "hookSinceSec": None, "screenActivitySec": None},
    {"agentSession": "air-busy", "paneId": "air-m1:w2:p1", "machine": "air-m1",
     "cwd": "/w/aptus", "hookSinceSec": None, "screenActivitySec": 25},
]
check("persona main session on the Air: the recently drawing pane wins",
      personas.main_session_for_persona(persona, air_rows, chief_id=None), "air-busy")

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("All screen-activity checks passed.")
