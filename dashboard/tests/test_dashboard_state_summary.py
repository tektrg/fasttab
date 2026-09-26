#!/usr/bin/env python3
"""Direct-run tests for dashboard/server/lib/dashboard_state_summary.py and
dashboard/server/lib/herdr_pane_lookup.py (pure parsing; no dashboard, no herdr).

Ported from AptusFit scripts/tests/test_dashboard_state_summary.py (P0 move).
Dropped: the `sweep_status`/`jev_sweep_probe` section — jev-shadow is an
AptusFit-only producer script, out of scope for this move (NOT-CARRIED)."""
import os
import sys

DASHBOARD_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(DASHBOARD_DIR, "server", "lib"))

from dashboard_state_summary import classify_feed, format_summary, is_warm, summarize_state  # noqa: E402
from herdr_pane_lookup import pane_rows_for_label  # noqa: E402

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


print("classify_feed")
check("warming dict", classify_feed({"warming": True, "broken": True}), "warming")
check("broken dict", classify_feed({"warming": False, "broken": True}), "broken")
check("ok dict", classify_feed({"warming": False, "broken": False, "data": {}}), "ok")
check("null feed = warming", classify_feed(None), "warming")
check("unrecognised dict", classify_feed({"foo": 1}), "unknown")
check("unrecognised scalar", classify_feed("x"), "unknown")

print("summarize_state: live shape with machines + machinesConfigError")
state = {
    "feeds": {
        "herdr": {"warming": False, "broken": False},
        "paneScreen": {"warming": True, "broken": True},
        "board": {"warming": False, "broken": True},
        "herdr:air-m1": {"warming": False, "broken": False},
        "machines": {"air-m1": {"status": "ok"}, "air-m2": {"status": "warming"}},
        "machinesConfigError": None,
    },
    "computed": {"agents": [{"screenState": "ACTIVE"}, {"screenState": "ACTIVE"}, {"screenState": "IDLE"}, {}],
                 "needsYou": [{"kind": "blocked", "label": "w", "detail": "d", "sinceSec": None}]},
}
summary = summarize_state(state)
check("warming feeds + warming machine", summary["warming"], ["paneScreen", "machine:air-m2"])
check("broken feeds", summary["broken"], ["board"])
check("no unknowns (machines keys are not feeds)", summary["unknown"], [])
check("agent count", summary["agentCount"], 4)
check("screen states", summary["screenStates"], {"ACTIVE": 2, "IDLE": 1, "unknown": 1})
check("needsYou count", summary["needsYouCount"], 1)
check("not warm", is_warm(summary), False)
check("null machinesConfigError is not a signal", summarize_state(
    {"feeds": {"machinesConfigError": None}, "computed": {}})["warming"], [])
check("truthy machinesConfigError surfaces", "machines config error: bad" in format_summary(
    summarize_state({"feeds": {"machinesConfigError": "bad"}, "computed": {}})), True)
check("all warm", is_warm(summarize_state({"feeds": {"herdr": {"warming": False, "broken": False}}})), True)

print("summarize_state never raises on unknown shapes")
for label, odd in (("empty", {}), ("list", []), ("feeds list", {"feeds": []}),
                   ("computed str", {"feeds": {}, "computed": "x"}), ("None", None)):
    try:
        text = format_summary(summarize_state(odd))
        check(f"{label}: prints", isinstance(text, str), True)
    except Exception as error:  # noqa: BLE001
        check(f"{label}: prints", repr(error), "no exception")
check("missing computed reads unknown", "agents unknown" in format_summary(summarize_state({})), True)

print("pane_rows_for_label")
tab_list = {"result": {"tabs": [{"label": "a", "tab_id": "w1:t1"}, {"label": "chief-dashboard-server", "tab_id": "wB:t1N"},
                                {"label": "chief-dashboard-server", "tab_id": "wB:t9"}]}}
pane_list = {"result": {"panes": [{"pane_id": "w1:p1", "tab_id": "w1:t1"}, {"pane_id": "wB:p1P", "tab_id": "wB:t1N"},
                                  {"pane_id": "wB:p99", "tab_id": "wB:t9"}]}}
rows = pane_rows_for_label(tab_list, pane_list, "chief-dashboard-server")
check("first match by tab order", [row["pane_id"] for row in rows], ["wB:p1P", "wB:p99"])
check("no such label", pane_rows_for_label(tab_list, pane_list, "nope"), [])
check("reshaped payload", pane_rows_for_label({"error": 1}, pane_list, "a"), [])

if fails:
    print("\nFAILED:\n  " + "\n  ".join(fails))
    sys.exit(1)
print("\nall passed")
