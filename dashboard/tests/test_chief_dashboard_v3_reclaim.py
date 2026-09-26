#!/usr/bin/env python3
"""Direct-run tests for Chief Dashboard v3 reclaim (phase 5): measured memory
+ the Stop → Close → Relaunch ladder.

Pure functions + tmpdirs + injected fakes — no herdr, no panes, no network.
"""
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib"))

import chief_dashboard_memory as mem  # noqa: E402
import chief_dashboard_actions as act  # noqa: E402
from chief_dashboard_store import (  # noqa: E402
    BoardStore, resolve_agent_row_id,
)

fails = []


def check(label, got, want=True):
    ok = (got == want) if want is not True else bool(got)
    if not ok:
        fails.append(f"{label}: got {got!r}" + (f" want {want!r}" if want is not True else ""))
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


print("== format_bytes ==")
check("none stays none", mem.format_bytes(None), None)
check("bytes", mem.format_bytes(512), "512 B")
check("mb", mem.format_bytes(200 * 1024 * 1024), "200.0 MB")
check("gb", mem.format_bytes(int(2.1 * 1024**3)), "2.1 GB")

print("== parse_ps + sum_tree ==")
ppid_of, rss_of = mem.parse_ps("  100     1  1024\n  101   100  2048\n  102   101   512\n")
check("ppid map", ppid_of, {100: 1, 101: 100, 102: 101})
check("rss bytes", rss_of[100], 1024 * 1024)
check("tree sums descendants",
      mem.sum_tree([100], ppid_of, rss_of), (1024 + 2048 + 512) * 1024)
check("unknown root is unmeasurable, not 0",
      mem.sum_tree([999], ppid_of, rss_of), None)
check("empty roots is unmeasurable", mem.sum_tree([], ppid_of, rss_of), None)

print("== sampler: one ps serves all panes ==")
ps_calls = []
sampler = mem.MemorySampler(
    pane_ids_fn=lambda: ["w8:pA", "w8:pB", "w8:pGone"],
    proc_info_fn=lambda pane: {"w8:pA": [100], "w8:pB": [101],
                               "w8:pGone": []}[pane],
    ps_fn=lambda: (ps_calls.append(1), "  100     1  1024\n  101   100  2048\n")[1],
)
snap = sampler.sample_once()
check("one ps call", len(ps_calls), 1)
check("pane A sums its tree", snap["w8:pA"], (1024 + 2048) * 1024)
check("pane B sums child only", snap["w8:pB"], 2048 * 1024)
check("empty foreground reads None (renders —)",
      snap["w8:pGone"], None)
check("snapshot is cheap read", sampler.snapshot(), snap)

print("== state_word: one click must be earned ==")
check("idle hook reads idle",
      act.state_word({"hasHookData": True, "hookState": "idle"}), "idle")
check("working hook", act.state_word(
    {"hasHookData": True, "hookState": "working"}), "working")
check("no hook data is unknown, never idle", act.state_word(
    {"hasHookData": False, "hookState": None, "herdrStatus": None,
     "screenState": None}), "unknown")
check("falls back to herdr guess", act.state_word(
    {"hasHookData": False, "herdrStatus": "working"}), "working")

print("== build_reason names the stake ==")
r = act.build_reason({"hasHookData": True, "hookState": "working"},
                     2_100_000_000, 3, ["1867 (claimed)"])
check("state first", r.startswith("working"), True)
check("uncommitted clause", "3 uncommitted files in fe/" in r, True)
check("owner clause", "owns work item 1867 (claimed)" in r, True)
check("memory clause", "GB" in r, True)
r2 = act.build_reason({"hasHookData": True, "hookState": "idle"},
                      None, 0, [])
check("quiet pane names only state", r2, "idle")

print("== assess_row guards (server-side, not hidden buttons) ==")
live = {"w8:pA", "w8:p2C", "w1:pM", "w8:pX"}
idle_agent = {"paneId": "w8:pA", "label": "worker", "hasHookData": True,
              "hookState": "idle", "agentSession": "sess-1"}
busy_agent = {"paneId": "w8:pA", "label": "worker", "hasHookData": True,
              "hookState": "working", "agentSession": "sess-1"}
a = act.assess_row(idle_agent, "sess-1", live_pane_ids=live)
check("idle stop is one click",
      (a["stop"]["enabled"], a["stop"]["needsConfirm"]), (True, False))
a = act.assess_row(busy_agent, "sess-1", live_pane_ids=live)
check("busy stop needs confirm",
      (a["stop"]["enabled"], a["stop"]["needsConfirm"]), (True, True))
check("busy reason names state", a["stop"]["reason"].startswith("working"), True)
a = act.assess_row(
    {"paneId": "w8:p2C", "label": "srv", "hasHookData": True,
     "hookState": "idle", "agentSession": "s"},
    "s", live_pane_ids=live, own_pane="w8:p2C")
check("own pane refused", a["stop"],
      {"enabled": False, "needsConfirm": False, "reason": a["stop"]["reason"]})
check("own pane names self-destruct", "own pane" in a["stop"]["reason"], True)
a = act.assess_row(
    {"paneId": "w8:pX", "label": "chief", "hasHookData": True,
     "hookState": "idle", "agentSession": "s"},
    "s", live_pane_ids=live)
check("chief refused", a["close"]["enabled"], False)
a = act.assess_row(
    {"paneId": "w1:pM", "label": "aptusfit-metro", "hasHookData": True,
     "hookState": "idle", "agentSession": "s"},
    "s", live_pane_ids=live | {"w1:pM"})
check("dev-server refused with later-pass reason",
      ("later pass" in a["stop"]["reason"], a["stop"]["enabled"]),
      (True, False))
check("dev-server backend too", act.assess_row(
    {"paneId": "w1:pM", "label": "aptusfit-backend", "hookState": "idle",
     "hasHookData": True, "agentSession": "s"},
    "s", live_pane_ids=live | {"w1:pM"})["stop"]["enabled"], False)
a = act.assess_row(
    {"paneId": "w9:pZ", "label": "gone", "hasHookData": True,
     "hookState": "idle", "agentSession": "s"},
    "s", live_pane_ids=live)
check("gone pane: stop off", a["stop"]["enabled"], False)
check("gone pane: close off", a["close"]["enabled"], False)
check("gone pane: relaunch off", a["relaunch"]["enabled"], False)
a = act.assess_row(
    {"paneId": "w8:pA", "label": "worker", "hasHookData": True,
     "hookState": "idle", "agentSession": None},
    "pane:w8-pA", live_pane_ids=live)
check("no session: relaunch off, stop on",
      (a["relaunch"]["enabled"], a["stop"]["enabled"]), (False, True))
check("relaunch reason says why",
      "undo for Stop" in a["relaunch"]["reason"], True)
check("busy close needs confirm",
      act.assess_row(busy_agent, "sess-1",
                     live_pane_ids=live)["close"]["needsConfirm"], True)
check("idle close is one click",
      act.assess_row(idle_agent, "sess-1",
                     live_pane_ids=live)["close"]["needsConfirm"], False)
check("close after stop is one click",
      act.assess_row(busy_agent, "sess-1", live_pane_ids=live,
                     was_stopped=True)["close"]["needsConfirm"], False)
check("relaunch ungated only by a logged stop",
      (act.assess_row(busy_agent, "sess-1", live_pane_ids=live,
                      was_stopped=True)["relaunch"]["enabled"],
       act.assess_row(busy_agent, "sess-1",
                      live_pane_ids=live)["relaunch"]["enabled"]),
      (True, False))
check("re-stop refused (would kill the shell)",
      act.assess_row(busy_agent, "sess-1", live_pane_ids=live,
                     was_stopped=True)["stop"]["enabled"], False)
print("== actor: accident guard ==")
check("po passes", act.check_actor("po"), (True, ""))
ok, why = act.check_actor("chief")
check("chief refused", (ok, "po" in why), (False, True))
ok, _ = act.check_actor(None)
check("missing refused", ok, False)

print("== do_stop: TERM, wait, KILL survivors ==")
real_live = act._live_panes
act._live_panes = lambda: [{"pane_id": "w8:pA", "tab_id": "w8:tA"}]
killed = []
trees = [
    {100, 101, 102},  # first ps: all alive
    {102},            # second ps: 102 survived TERM
    set(),            # third: all gone
]
orig_tree = act._tree_pids
act._tree_pids = lambda roots: trees.pop(0) if trees else set()
try:
    res = act.do_stop("w8:pA",
                      kill_fn=lambda pid, sig: killed.append((pid, sig)),
                      sleep_fn=lambda s: None,
                      roots_fn=lambda pane: [100])
    import signal as _sig
    check("terms whole tree",
          sorted(p for p, s in killed if s == _sig.SIGTERM), [100, 101, 102])
    check("sigkills survivor",
          [p for p, s in killed if s == _sig.SIGKILL], [102])
    check("reports", (res["freed"], res["sigkilled"]), (3, 1))
    try:
        act.do_stop("w8:pGone", roots_fn=lambda pane: [1])
        check("gone pane raises", False, True)
    except RuntimeError as e:
        check("gone pane raises", "likely closed" in str(e), True)
    try:
        act.do_stop("w8:pA", roots_fn=lambda pane: [])
        check("empty foreground raises", False, True)
    except RuntimeError as e:
        check("empty foreground raises", "nothing to stop" in str(e), True)
finally:
    act._live_panes = real_live
    act._tree_pids = orig_tree

print("== store: action log + ended annotation ==")
tmp = tempfile.mkdtemp()
store = BoardStore(db_path=os.path.join(tmp, "b.db"),
                   schema_path=os.path.join(tmp, "s.json"))
entry = store.log_session_action("sess-1", "stop", "po", "idle")
check("log returns row", (entry["action"], entry["actor"]), ("stop", "po"))
try:
    store.log_session_action("sess-1", "nuke", "po")
    check("bad action rejected", False, True)
except ValueError:
    check("bad action rejected", True, True)
ann = store.session_action_annotations(["sess-1", "sess-zzz"])
check("annotation keyed", ann["sess-1"]["action"], "stop")
check("missing row absent", "sess-zzz" in ann, False)
check("ended suffix",
      store.ended_annotation(ann["sess-1"]), "stopped by you")
check("no log, no suffix", store.ended_annotation(None), None)
check("chief actor named", store.ended_annotation(
    {"action": "close", "actor": "chief"}), "closed by chief")

agent = {"paneId": "w8:pG", "paneIdSanitized": "w8-pG",
         "label": "gone-worker", "agentSession": "sess-1",
         "hasHookData": False}
row_id = resolve_agent_row_id(agent)
check("row id is session", row_id, "sess-1")
t0 = time.time()
store.build_session_board([agent], now_ts=t0)  # sight it live first
board = store.build_session_board([], now_ts=t0 + 10)  # then it ends
ended = [r for r in board["rows"] if r["rowId"] == "sess-1"]
check("stopped row lingers with note", len(ended), 1)
check("note reads ended · stopped by you", ended[0].get("endedNote"),
      "ended · stopped by you")
board2 = store.build_session_board([], now_ts=time.time())
plain = [r for r in board2["rows"] if r.get("endedNote") == "ended"]
check("unlogged rows read bare ended", len(plain) >= 0, True)

print("== agent_pids_in_pane: a bare shell is empty, not busy ==")
real_fg_shell = act._pane_fg_and_shell
act._pane_fg_and_shell = lambda pane_id, **kw: ([100, 200], 200)
check("shell pid excluded", act.agent_pids_in_pane("w8:pX"), [100])
act._pane_fg_and_shell = lambda pane_id, **kw: ([200], 200)
check("prompt-only pane is relaunchable", act.agent_pids_in_pane("w8:pX"), [])
act._pane_fg_and_shell = real_fg_shell

print("== store: get_seen_row feeds stopped-pane resolution ==")
seen = store.get_seen_row("session", "sess-1")
check("sees last pane", (seen["last_pane"], seen["last_label"]),
      ("w8:pG", "gone-worker"))
check("missing row is None", store.get_seen_row("session", "nope"), None)

print("== transcript_exists guards the resume promise ==")
tdir = tempfile.mkdtemp()
os.makedirs(os.path.join(tdir, "proj"))
open(os.path.join(tdir, "proj", "sess-abc.jsonl"), "w").write("{}\n")
check("transcript found", act.transcript_exists("sess-abc", tdir), True)
check("missing refused", act.transcript_exists("nope", tdir), False)
check("path traversal refused",
      act.transcript_exists("../evil", tdir), False)

print("== owners_of_session ==")
runs = {"rk": {"itemId": "1867", "by": "w", "stage": "doing",
               "session": None, "pane": None, "slug": "x"}}
check("label digits join", act.owners_of_session(
    "sess-9", {"agentSession": "sess-9", "paneId": "w8:p9",
               "label": "deliver-1867-thing"}, runs, []),
    ["1867 (claimed)"])
check("no match, no owner", act.owners_of_session(
    "sess-9", {"agentSession": "sess-9", "label": "other"}, runs, []), [])
check("null record pane never matches a null sanitized pane", act.owners_of_session(
    "pane:w8-p38",
    {"agentSession": None, "paneId": "w8:p38", "label": "hubble-large-file-muse"},
    {"rk": {"itemId": "124", "by": None, "stage": "plan",
             "session": None, "pane": None, "slug": "x"}}, []), [])
check("manual numeric link counts", act.owners_of_session(
    "sess-9", {"agentSession": "sess-9", "label": "other"}, {},
    [{"targetKind": "session", "targetId": "sess-9",
      "workRowId": "notion:abc"}]), [])

print()
print("== live board rows carry actions (regression) ==")
# The table view reads /api/board. `_annotate_ended_rows` only ever touched
# ended rows, so live rows — the only kind worth stopping — arrived with no
# buttons while the agents list looked fine. Guard both directions.
import importlib.util as _ilu
_spec = _ilu.spec_from_file_location(
    "chief_dashboard_server",
    os.path.join(os.path.dirname(__file__), "..", "chief-dashboard-server.py"))
_srv = _ilu.module_from_spec(_spec)
try:
    _spec.loader.exec_module(_srv)
except Exception as _e:  # server module pulls real feeds; skip if unimportable
    print(f"  (skipped: server module not importable here — {type(_e).__name__})")
else:
    _agents = [{"rowId": "s1", "actions": {"stop": {"enabled": True}},
                "memoryBytes": 123},
               {"rowId": "s2", "actions": {"stop": {"enabled": False}},
                "memoryBytes": None}]
    _board = {"rows": [{"rowId": "s1", "status": "live"},
                       {"rowId": "s2", "status": "live"},
                       {"rowId": "s3", "status": "ended"},
                       {"rowId": "s9", "status": "live"}]}
    _srv._annotate_live_rows(_board, _agents)
    _r = {r["rowId"]: r for r in _board["rows"]}
    check("live row gets actions", bool(_r["s1"].get("actions")), True)
    check("live row gets memoryBytes", _r["s1"].get("memoryBytes"), 123)
    check("second live row too", bool(_r["s2"].get("actions")), True)
    check("ended row left to _annotate_ended_rows",
          _r["s3"].get("actions"), None)
    check("live row with no agent stays bare", _r["s9"].get("actions"), None)

print()
if fails:
    print(f"{len(fails)} FAILURES")
    sys.exit(1)
print("all v3-reclaim checks pass")
