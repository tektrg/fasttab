#!/usr/bin/env python3
"""Direct-run tests for P4 (Claude sessions outside herdr as status-only rows,
claude_sessions.py + its wiring in build_agents_view / build_needs_you /
assess_row) and P5 (herdr agent_status fallback for non-Claude panes)."""
import json
import os
import subprocess
import sys
import tempfile

LIB = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "server", "lib")
sys.path.insert(0, LIB)

import claude_sessions  # noqa: E402
import chief_dashboard_views as views  # noqa: E402
import chief_dashboard_store as store  # noqa: E402
import chief_dashboard_actions as actions  # noqa: E402
import pane_screen_signals as signals  # noqa: E402

fails = []
NOW = 1_790_433_800.0
HOST_ID = "local_8711df12-aaaa-bbbb-cccc-0123456789ab"


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def session(pid, sid, **extra):
    entry = {"pid": pid, "sessionId": sid, "cwd": "/Users/x/01_Project/demo",
             "kind": "interactive", "entrypoint": "claude-desktop",
             "name": f"name-{sid}", "status": "busy",
             "statusUpdatedAt": int((NOW - 30) * 1000)}
    entry.update(extra)
    return entry


def feed(data):
    return {"broken": False, "warming": False, "error": None,
            "lastSuccessTs": 1.0, "ageSec": 0, "lastDurationSec": 0, "data": data}


def snap_with(herdr_agents, sessions, screens=None):
    snap = {n: feed(None) for n in ("hookCache", "paneTick", "board")}
    snap["hookCache"]["data"] = {}
    snap["herdr"] = feed({"agents": herdr_agents, "tabs": []})
    snap["paneScreen"] = feed(screens or {})
    snap["claudeSessions"] = feed(sessions)
    return snap


print("== read_live_sessions: per-file decoding, liveness, pid reuse ==")
with tempfile.TemporaryDirectory() as tmp:
    def write(name, content):
        with open(os.path.join(tmp, name), "w") as f:
            f.write(content if isinstance(content, str) else json.dumps(content))

    write("101.json", session(101, "live-a", procStart="Sat Sep  6 11:34:21 2026",
                              statusUpdatedAt=1000))
    write("102.json", session(102, "dead-b"))
    write("103.json", "{not json")
    write("104.json", session(104, "oneshot-c", kind="print"))
    write("105.json", session(105, "recycled-d", procStart="Fri Sep 25 09:00:00 2026"))
    write("106.json", session(106, "live-e", statusUpdatedAt=5000))
    write("107.json", ["a", "list"])
    write("notes.txt", "ignored")
    alive = {101, 104, 105, 106}
    got = claude_sessions.read_live_sessions(
        tmp, pid_alive=lambda pid: pid in alive,
        proc_start_by_pid=lambda pids: {101: "Sat Sep 6 11:34:21 2026",
                                        105: "Sat Sep 26 10:00:00 2026"})
    check("only live, interactive, same-process sessions; newest status first",
          [e["sessionId"] for e in got], ["live-e", "live-a"])
    got = claude_sessions.read_live_sessions(
        tmp, pid_alive=lambda pid: pid in alive, proc_start_by_pid=lambda pids: {})
    check("ps unavailable -> liveness alone decides",
          sorted(e["sessionId"] for e in got), ["live-a", "live-e", "recycled-d"])
_t = 1_790_422_461
_fmt = "%a %b %d %H:%M:%S %Y"
import time  # noqa: E402
check("procStart in UTC matches ps's local-time lstart",
      claude_sessions._same_process_start(time.strftime(_fmt, time.gmtime(_t)),
                                          time.strftime(_fmt, time.localtime(_t))), True)
check("procStart a day off is a different process",
      claude_sessions._same_process_start(time.strftime(_fmt, time.gmtime(_t + 3600 * 30)),
                                          time.strftime(_fmt, time.localtime(_t))), False)
check("unparseable procStart -> liveness decides",
      claude_sessions._same_process_start("garbage", "also garbage"), True)
check("recorded_process_start reads procStart as UTC",
      claude_sessions.recorded_process_start({"procStart": time.strftime(_fmt, time.gmtime(_t))}), _t)
check("recorded_process_start: startedAt rules out a reading after it",
      claude_sessions.recorded_process_start({"procStart": time.strftime(_fmt, time.gmtime(_t)),
                                              "startedAt": (_t + 30) * 1000}), _t)
check("recorded_process_start: missing / garbage -> None",
      (claude_sessions.recorded_process_start({}), claude_sessions.recorded_process_start({"procStart": "x"})),
      (None, None))
check("missing folder -> empty list, not an error",
      claude_sessions.read_live_sessions("/nonexistent/claude-sessions"), [])
check("real ps: own pid is read back",
      os.getpid() in claude_sessions._proc_start_by_pid([os.getpid()]), True)

env = dict(os.environ, CLAUDE_SESSIONS_DIR="/tmp/override-sessions")
out = subprocess.run([sys.executable, "-c",
                      f"import sys; sys.path.insert(0, {LIB!r}); import claude_sessions;"
                      " print(claude_sessions.SESSIONS_DIR)"],
                     capture_output=True, text=True, env=env).stdout.strip()
check("CLAUDE_SESSIONS_DIR overrides the sessions folder", out, "/tmp/override-sessions")

print("== build_status_only_rows: status mapping, skip herdr, openUrl ==")
sessions = [
    session(1, "busy-1", hostSessionId=HOST_ID),
    session(2, "wait-2", status="waiting", waitingFor="input needed", name=None),
    session(3, "idle-3", status="idle", entrypoint="cli", tmux="s:@1.%1",
            hostSessionId=HOST_ID),
    session(4, "in-herdr", status="busy"),
    session(5, "odd-5", status="compacting", entrypoint="sdk-ts",
            hostSessionId="not-a-desktop-id"),
]
rows = {r["agentSession"]: r for r in claude_sessions.build_status_only_rows(
    sessions, {"in-herdr"}, NOW, machine="local")}
check("herdr's own session is skipped", sorted(rows), ["busy-1", "idle-3", "odd-5", "wait-2"])
check("busy -> working", rows["busy-1"]["hookState"], "working")
check("waiting -> blocked", rows["wait-2"]["hookState"], "blocked")
check("waiting reason from waitingFor", rows["wait-2"]["hookReason"], "Input needed")
check("idle -> idle", rows["idle-3"]["hookState"], "idle")
check("unknown status -> no hook state", rows["odd-5"]["hookState"], None)
check("unknown status -> hasHookData False", rows["odd-5"]["hasHookData"], False)
check("label = name", rows["busy-1"]["label"], "name-busy-1")
check("label falls back to folder name", rows["wait-2"]["label"], "demo")
check("secondsInStatus from statusUpdatedAt", rows["busy-1"]["secondsInStatus"], 30.0)
check("hookSinceSec mirrors it", rows["busy-1"]["hookSinceSec"], 30.0)
check("no pane", rows["busy-1"]["paneId"], None)
check("source desktop", rows["busy-1"]["source"], "claude-desktop")
check("source cli", rows["idle-3"]["source"], "claude-cli")
check("source for another entrypoint", rows["odd-5"]["source"], "claude-sdk-ts")
check("desktop openUrl", rows["busy-1"]["openUrl"],
      f"claude://code/continue?session={HOST_ID}")
check("cli row: no openUrl even with a host id", rows["idle-3"]["openUrl"], None)
check("invalid host id: no openUrl", rows["odd-5"]["openUrl"], None)
check("tmux target carried", rows["idle-3"]["tmuxTarget"], "s:@1.%1")
for odd_host_id in ("not-a-desktop-id", HOST_ID + "\n", HOST_ID + "&x=1", "local_a b"):
    desktop_row = claude_sessions.build_status_only_rows(
        [session(6, "desk-6", hostSessionId=odd_host_id)], set(), NOW, machine="local")[0]
    check(f"desktop row, malformed host id {odd_host_id!r}: no openUrl",
          desktop_row["openUrl"], None)

print("== build_agents_view merges them, never duplicating a herdr row ==")
herdr_agents = [{"pane_id": "w1:p1", "tab_id": "w1:t1", "agent": "claude",
                 "agent_status": "idle", "agent_session": {"value": "in-herdr"},
                 "cwd": "/x"}]
agents = views.build_agents_view(snap_with(herdr_agents, sessions))
by_session = {a["agentSession"]: a for a in agents}
check("one row per session", sorted(by_session),
      ["busy-1", "idle-3", "in-herdr", "odd-5", "wait-2"])
check("herdr row keeps its pane", by_session["in-herdr"]["paneId"], "w1:p1")
check("herdr row tagged source herdr", by_session["in-herdr"]["source"], "herdr")
check("no claudeSessions feed in the snapshot -> herdr rows only",
      len(views.build_agents_view({k: v for k, v in snap_with(herdr_agents, sessions).items()
                                   if k != "claudeSessions"})), 1)
check("row id is the session id", store.resolve_agent_row_id(by_session["busy-1"]), "busy-1")
check("derived:state working", store.derived_values_for_agent(by_session["busy-1"])["derived:state"], "working")
check("derived:state idle", store.derived_values_for_agent(by_session["idle-3"])["derived:state"], "idle")

print("== build_needs_you: waiting session is one paneless blocked row ==")
snap = snap_with(herdr_agents, sessions)
needs = views.build_needs_you(snap, views.build_agents_view(snap))
check("only the waiting session", [(n["kind"], n["identity"]) for n in needs],
      [("blocked", "wait-2")])
check("its detail is the waiting reason", needs[0]["detail"], "Input needed")
check("no pane on it", needs[0]["paneId"], None)
check("source on it", needs[0]["source"], "claude-desktop")
check("no permission box", needs[0]["permission"], None)

print("== assess_row: nothing to stop / close / relaunch ==")
acts = actions.assess_row(by_session["busy-1"], "busy-1", live_pane_ids={"w1:p1"})
check("stop refused", acts["stop"]["enabled"], False)
check("close refused", acts["close"]["enabled"], False)
check("relaunch refused", acts["relaunch"]["enabled"], False)
check("reason names the source", "claude-desktop session" in acts["stop"]["reason"], True)
check("archive still allowed", acts["archive"]["enabled"], True)

print("== P5: herdr agent_status backs up an unclassifiable non-Claude screen ==")
fb = signals.screen_state_with_herdr_fallback
check("screen answer stands", fb("opencode", "WAITING", "working"), ("WAITING", "screen"))
check("opencode UNKNOWN + working", fb("opencode", "UNKNOWN", "working"), ("ACTIVE", "herdr"))
check("opencode no read + blocked", fb("opencode", None, "blocked"), ("NEEDS_HUMAN", "herdr"))
check("opencode done -> WAITING", fb("opencode", "UNKNOWN", "done"), ("WAITING", "herdr"))
check("herdr unknown -> no fallback", fb("opencode", "UNKNOWN", "unknown"), ("UNKNOWN", "screen"))
check("claude pane never falls back", fb("claude", "UNKNOWN", "working"), ("UNKNOWN", "screen"))
check("nothing at all", fb("opencode", None, None), (None, None))

oc_agents = [
    {"pane_id": "w3:p1", "tab_id": "w3:t1", "agent": "opencode", "agent_status": "working"},
    {"pane_id": "w3:p2", "tab_id": "w3:t1", "agent": "claude", "agent_status": "working"},
]
screens = {views.sanitize_pane_id("w3:p1"): {"state": "UNKNOWN"},
           views.sanitize_pane_id("w3:p2"): {"state": "UNKNOWN"}}
rows = {a["paneId"]: a for a in views.build_agents_view(snap_with(oc_agents, [], screens))}
check("opencode row reads ACTIVE", rows["w3:p1"]["screenState"], "ACTIVE")
check("provenance herdr", rows["w3:p1"]["screenStateSource"], "herdr")
check("derived:state working", store.derived_values_for_agent(rows["w3:p1"])["derived:state"], "working")
check("claude row untouched", rows["w3:p2"]["screenState"], "UNKNOWN")

print()
if fails:
    print(f"{len(fails)} FAIL")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("all PASS")
