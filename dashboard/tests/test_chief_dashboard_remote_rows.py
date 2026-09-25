#!/usr/bin/env python3
"""Direct-run tests for remote-row construction (slice 2): build_agents_view
emitting a row per configured machine from that machine's OWN herdr +
paneScreen feeds (R1/R4/R7), duplicate-agentSession surfacing (R6), and
chief_dashboard_store's screen-only derived:state for a remote row (R4)."""
import os
import sys

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib"))

import chief_dashboard_feeds as feeds  # noqa: E402
import chief_dashboard_views as views  # noqa: E402
import chief_dashboard_store as store  # noqa: E402
import chief_dashboard_herdr as herdr_transport  # noqa: E402

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def empty_feed(name):
    return {"broken": False, "warming": False, "error": None,
            "lastSuccessTs": 1.0, "ageSec": 0, "lastDurationSec": 0,
            "data": None}


def base_snap():
    snap = {name: empty_feed(name) for name in
            ("hookCache", "herdr", "paneTick", "gitHealth", "board",
             "paneScreen", "workItems")}
    snap["hookCache"]["data"] = {}
    snap["herdr"]["data"] = {"agents": [], "tabs": []}
    snap["paneScreen"]["data"] = {}
    return snap


# Patch MACHINES for the duration of this file only (module-level dict both
# chief_dashboard_feeds and chief_dashboard_views import by reference).
_ORIG_MACHINES = dict(feeds.MACHINES)
feeds.MACHINES.clear()
feeds.MACHINES["air-m1"] = {
    "sshAlias": "trungs-air", "herdrPath": "/x/herdr",
    "label": "Air", "maxParallel": 4}
views.MACHINES = feeds.MACHINES

try:
    print("== a remote agent becomes a namespaced, screen-only row ==")
    snap = base_snap()
    snap["herdr:air-m1"] = empty_feed("herdr:air-m1")
    snap["herdr:air-m1"]["data"] = {
        "agents": [{
            "pane_id": "w2:p1", "tab_id": "w2:t1", "workspace_id": "w2",
            "terminal_title": "claude-aptus", "cwd": "/home/wifey/aptus",
            "agent_status": "idle",  # deliberately WRONG vs the screen below
            "agent_session": {"value": "sess-remote-1"},
        }],
        "tabs": [{"tab_id": "w2:t1", "label": "air-worker-1"}],
    }
    snap["paneScreen:air-m1"] = empty_feed("paneScreen:air-m1")
    remote_pane_key = herdr_transport.make_pane_key("air-m1", "w2:p1")
    sid = feeds.sanitize_pane_id(remote_pane_key)
    snap["paneScreen:air-m1"]["data"] = {
        sid: {"state": "ACTIVE", "signal": "still working"},
    }

    rows = views.build_agents_view(snap)
    remote_rows = [r for r in rows if r.get("machine") == "air-m1"]
    check("exactly one remote row built", len(remote_rows), 1)
    r = remote_rows[0]
    check("paneId is namespaced <machine>:<rawId>", r["paneId"], "air-m1:w2:p1")
    check("label comes from the tab", r["label"], "air-worker-1")
    check("cwd carried through", r["cwd"], "/home/wifey/aptus")
    check("no hook data — never invented for a remote row",
          r["hasHookData"], False)
    check("hookState is None, not borrowed from anywhere", r["hookState"], None)
    check("the Air's own status claim is kept but renamed, unverified",
          r["herdrStatusUnverified"], "idle")
    check("herdrStatus (the trusted field) is None for remote",
          r["herdrStatus"], None)
    check("disagree never fires for remote (no hook to disagree with)",
          r["disagree"], False)
    check("screenState comes from THIS machine's own paneScreen feed",
          r["screenState"], "ACTIVE")
    check("memoryBytes degrades to null on a remote row (R16)",
          r["memoryBytes"], None)

    print("== derived:state for that row reads off the SCREEN, never hookState ==")
    check("ACTIVE screen -> 'working', even though the Air claimed 'idle'",
          store.derived_values_for_agent(r)["derived:state"], "working")
    check("derived:machine carries the row's machine",
          store.derived_values_for_agent(r)["derived:machine"], "air-m1")

    print("== an unclassifiable remote screen reads 'unknown', never 'no data' ==")
    r2 = dict(r)
    r2["screenState"] = None
    check("no screen reading -> 'unknown' (a screen WAS attempted)",
          store.derived_values_for_agent(r2)["derived:state"], "unknown")

    print("== local rows are unaffected: still hookState-driven, machine='local' ==")
    snap2 = base_snap()
    snap2["hookCache"]["data"] = {
        feeds.sanitize_pane_id("w1:p1"):
            {"seq": 100, "state": "working", "reason": None}}
    snap2["herdr"]["data"] = {
        "agents": [{"pane_id": "w1:p1", "tab_id": "w1:t1",
                    "agent_status": "working",
                    "agent_session": {"value": "sess-local-1"}}],
        "tabs": [{"tab_id": "w1:t1", "label": "local-worker"}],
    }
    local_rows = views.build_agents_view(snap2)
    check("exactly one local row", len(local_rows), 1)
    check("local row's machine is 'local'", local_rows[0]["machine"], "local")
    check("local derived:state still reads the hook, unchanged",
          store.derived_values_for_agent(local_rows[0])["derived:state"],
          "working")
    check("local derived:machine reads 'local'",
          store.derived_values_for_agent(local_rows[0])["derived:machine"],
          "local")

    print("== the SAME agentSession on two machines: both rows stay, one is flagged ==")
    snap3 = base_snap()
    snap3["hookCache"]["data"] = {}
    snap3["herdr"]["data"] = {
        "agents": [{"pane_id": "w1:p1", "tab_id": "w1:t1",
                    "agent_status": "working",
                    "agent_session": {"value": "shared-uuid"}}],
        "tabs": [{"tab_id": "w1:t1", "label": "local-copy"}],
    }
    snap3["herdr:air-m1"] = empty_feed("herdr:air-m1")
    snap3["herdr:air-m1"]["data"] = {
        "agents": [{"pane_id": "w9:p9", "tab_id": "w9:t9",
                    "agent_status": "idle",
                    "agent_session": {"value": "shared-uuid"}}],
        "tabs": [{"tab_id": "w9:t9", "label": "air-copy"}],
    }
    snap3["paneScreen:air-m1"] = empty_feed("paneScreen:air-m1")
    snap3["paneScreen:air-m1"]["data"] = {}
    rows3 = views.build_agents_view(snap3)
    check("both copies survive — never merged/hidden", len(rows3), 2)
    local_copy = next(r for r in rows3 if r["machine"] == "local")
    air_copy = next(r for r in rows3 if r["machine"] == "air-m1")
    check("first-seen (local) keeps the real session id",
          local_copy["agentSession"], "shared-uuid")
    check("second-seen (remote) has its session id cleared, not shared",
          air_copy["agentSession"], None)
    check("second-seen is flagged with what it duplicates",
          air_copy.get("duplicateOfSession"), "shared-uuid")
    check("second-seen's row identity falls back to its OWN namespaced pane"
          " — never collides with the primary's row id",
          store.resolve_agent_row_id(air_copy) ==
          store.resolve_agent_row_id(local_copy), False)

    print("== get_full_state()'s feeds['machines'] summary never breaks "
          "build_needs_you (regression: it walks feeds_snap.items() assuming "
          "Feed shape; machines_status()'s {name: {status,...}} entry is NOT "
          "that shape and KeyErrored on 'broken' — every live /api/state "
          "request 500'd the instant .claude/dashboard-machines.json existed. "
          "P0 dashboard move: the same regression's build_chief_pass half is "
          "dropped here — build_chief_pass / GET /api/deliver/pass are "
          "RETIRED, no MOVE-set caller (see p0-dependency-audit.md)) ==")
    snap_with_machines = dict(base_snap())
    snap_with_machines["machines"] = {
        "air-m1": {"status": "ok", "error": None, "ageSec": 1, "agentCount": 0}}
    try:
        needs_you = views.build_needs_you(snap_with_machines, [])
        check("build_needs_you tolerates a 'machines' entry in feeds_snap",
              isinstance(needs_you, list), True)
    except KeyError as e:
        fails.append(f"build_needs_you raised KeyError on 'machines' entry: {e}")
        print("  FAIL  build_needs_you tolerates a 'machines' entry in feeds_snap")

    print("== bug fix: an ENDED row's liveness check must query its OWN "
          "machine's pane list, never default to local (a still-alive Air "
          "pane used to read as 'pane already gone' because the stub never "
          "carried a machine and the cache only ever checked local ids) ==")
    import importlib.util as _ilu

    def _load_server_module(name):
        spec = _ilu.spec_from_file_location(
            name, os.path.join(os.path.dirname(__file__), "..",
                                "chief-dashboard-server.py"))
        mod = _ilu.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    try:
        _srv = _load_server_module("chief_dashboard_server_remote_rows_test")
    except Exception as _e:
        print(f"  (skipped: server module not importable here — {type(_e).__name__})")
    else:
        import chief_dashboard_actions as act

        _orig_live_panes = act._live_panes

        def _ended_air_board(pane_id):
            return {"rows": [{
                "rowId": "sess-ended-air",
                "status": "ended",
                "derived": {"paneId": pane_id, "label": "air-ended-worker"},
            }]}

        act._live_panes = lambda machine=herdr_transport.LOCAL_MACHINE: (
            [{"pane_id": "w2:p1"}] if machine == "air-m1" else [])
        try:
            _srv._PANE_FEED_CACHE.clear()
            board_alive = _ended_air_board("air-m1:w2:p1")
            _srv._annotate_ended_rows(board_alive)
            row_alive = board_alive["rows"][0]
            check("still-alive Air pane's machine resolves to air-m1, not local",
                  row_alive["actions"]["close"]["enabled"], True)
            check("close reason no longer claims the pane is gone",
                  "already gone" in row_alive["actions"]["close"]["reason"], False)
            check("stop stays force-refused on a remote row regardless of liveness",
                  row_alive["actions"]["stop"]["enabled"], False)
        finally:
            act._live_panes = _orig_live_panes

        act._live_panes = lambda machine=herdr_transport.LOCAL_MACHINE: []
        try:
            _srv._PANE_FEED_CACHE.clear()
            board_dead = _ended_air_board("air-m1:w9:p9")
            _srv._annotate_ended_rows(board_dead)
            row_dead = board_dead["rows"][0]
            check("a TRULY gone Air pane still reads close-disabled",
                  row_dead["actions"]["close"]["enabled"], False)
            check("its reason still says gone (the negative case still works)",
                  "already gone" in row_dead["actions"]["close"]["reason"], True)
        finally:
            act._live_panes = _orig_live_panes

        print("== an unresolvable machine prefix reads 'unknown', never a "
              "false-certain 'gone' (machine removed from config since) ==")
        _srv._PANE_FEED_CACHE.clear()
        board_unknown = _ended_air_board("ghost-machine:w1:p1")
        _srv._annotate_ended_rows(board_unknown)
        row_unknown = board_unknown["rows"][0]
        check("unresolvable machine disables every ladder action",
              all(not a["enabled"] for a in row_unknown["actions"].values()), True)
        check("its reason names liveness as unknown, never 'gone'",
              "liveness unknown" in row_unknown["actions"]["close"]["reason"], True)

finally:
    feeds.MACHINES.clear()
    feeds.MACHINES.update(_ORIG_MACHINES)
    views.MACHINES = feeds.MACHINES

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("All remote-row checks passed.")
