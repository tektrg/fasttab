#!/usr/bin/env python3
"""Direct-run tests for Chief Dashboard v3 phase 6: archive + kanban/bulk
surfaces' backend. Pure functions + tmpdirs — no herdr, no panes, no network.
"""
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib"))

import chief_dashboard_actions as act  # noqa: E402
from chief_dashboard_store import BoardStore  # noqa: E402

fails = []


def check(label, got, want=True):
    ok = (got == want) if want is not True else bool(got)
    if not ok:
        fails.append(f"{label}: got {got!r}" + (f" want {want!r}" if want is not True else ""))
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


print("== archive flag roundtrip ==")
tmp = tempfile.mkdtemp()
store = BoardStore(db_path=os.path.join(tmp, "b.db"),
                   schema_path=os.path.join(tmp, "s.json"))
m = store.archived_map("session", ["s1"])
check("missing reads False", m["s1"]["archived"], False)
store.set_archived("session", "s1", True, "po")
m = store.archived_map("session", ["s1", "s2"])
check("set reads True", m["s1"]["archived"], True)
check("other row untouched", m["s2"]["archived"], False)
store.set_archived("session", "s1", False, "chief")
check("clear reads False",
      store.archived_map("session", ["s1"])["s1"]["archived"], False)

print("== action log: archive is audited, ladder gates ignore it ==")
check("archive allowed", store.log_session_action(
    "s1", "archive", "chief", "board-only")["action"], "archive")
check("unarchive allowed", store.log_session_action(
    "s1", "unarchive", "chief", "")["action"], "unarchive")
try:
    store.log_session_action("s1", "nuke", "po")
    check("bad action rejected", False, True)
except ValueError:
    check("bad action rejected", True, True)
check("archive note names who", store.ended_annotation(
    {"action": "archive", "actor": "chief"}), "archived by chief")
check("archive by po reads you", store.ended_annotation(
    {"action": "archive", "actor": "po"}), "archived by you")
check("unarchive is not an ending",
      store.ended_annotation({"action": "unarchive", "actor": "po"}), None)
store2dir = tempfile.mkdtemp()
store2 = BoardStore(db_path=os.path.join(store2dir, "b.db"),
                    schema_path=os.path.join(store2dir, "s.json"))
store2.log_session_action("s9", "stop", "po", "idle")
store2.log_session_action("s9", "archive", "po", "tidy")
check("stop survives a later archive",
      store2.last_ladder_action(["s9"])["s9"], "stop")
check("archive alone is no ladder state",
      store2.last_ladder_action(["s9", "zz"])["zz"], None)

print("== board: archived attaches + hides by default ==")
t0 = time.time()
a1 = {"paneId": "w8:pA", "paneIdSanitized": "w8-pA", "label": "live-one",
      "agentSession": "sess-live", "hasHookData": True, "hookState": "idle"}
a2 = {"paneId": "w8:pB", "paneIdSanitized": "w8-pB", "label": "live-two",
      "agentSession": "sess-arch", "hasHookData": True, "hookState": "idle"}
store.build_session_board([a1, a2], now_ts=t0)
store.set_archived("session", "sess-arch", True, "po")
board = store.build_session_board([a1, a2], now_ts=t0 + 5)
check("no-view (default) board hides archived",
      sorted(r["rowId"] for r in board["rows"]), ["sess-live"])
by_id = {r["rowId"]: r for r in
         store.build_session_board([a1, a2], now_ts=t0 + 5,
                                   view_id="view_archived")["rows"]}
check("live row carries flag", by_id["sess-arch"]["archived"], True)
check("flag in values (filterable)", by_id["sess-arch"]["values"]["archived"], True)
check("other row clean",
      store.archived_map("session", ["sess-live"])["sess-live"]["archived"],
      False)
check("archived property listed",
      "archived" in [p["id"] for p in board["properties"]], True)
arch_view = store.get_view("view_archived")
check("Archived view seeded", arch_view["name"], "Archived")
shown = store.build_session_board([a1, a2], now_ts=t0 + 5,
                                  view_id="view_archived")
check("Archived view shows only archived",
      [r["rowId"] for r in shown["rows"]], ["sess-arch"])
plain = store.build_session_board([a1, a2], now_ts=t0 + 5,
                                    view_id="view_all_sessions")
check("default view hides archived",
      [r["rowId"] for r in plain["rows"]], ["sess-live"])

print("== actors: chief may tidy, never destroy ==")
check("chief archives", act.check_actor(
    "chief", allowed=act.ARCHIVE_ACTORS), (True, ""))
check("po archives", act.check_actor(
    "po", allowed=act.ARCHIVE_ACTORS), (True, ""))
ok, why = act.check_actor("chief")
check("chief stopped on ladder", (ok, "'po'" in why), (False, True))
ok, _ = act.check_actor("intruder", allowed=act.ARCHIVE_ACTORS)
check("stranger refused archive", ok, False)

print("== assess: archive entries ride along, guards keep them ==")
live = {"w8:pA"}
ag = {"paneId": "w8:pA", "label": "worker", "hasHookData": True,
      "hookState": "idle", "agentSession": "s1"}
a = act.assess_row(ag, "s1", live_pane_ids=live)
check("archive offered, one click",
      (a["archive"]["enabled"], a["archive"]["needsConfirm"]), (True, False))
check("unarchive off when live", a["unarchive"]["enabled"], False)
a = act.assess_row(ag, "s1", live_pane_ids=live, is_archived=True)
check("archived flips the pair",
      (a["archive"]["enabled"], a["unarchive"]["enabled"]), (False, True))
a = act.assess_row(
    {"paneId": "w8:pX", "label": "chief", "hasHookData": True,
     "hookState": "idle", "agentSession": "s"},
    "s", live_pane_ids=live | {"w8:pX"})
check("chief keeps archive (tidying, not destruction)",
      a["archive"]["enabled"], True)
check("chief still cannot stop", a["stop"]["enabled"], False)

print()
if fails:
    print(f"{len(fails)} FAILURES")
    sys.exit(1)
print("all v3-phase-6 checks pass")
