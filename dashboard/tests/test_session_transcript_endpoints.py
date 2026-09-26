#!/usr/bin/env python3
"""Direct-run tests for GET /api/session/latest and GET /api/session/plan
(dashboard/server/lib/session_transcript.py + the two thin handlers in
chief-dashboard-server.py), phase 1b of the agentbar-mobile-web plan
(docs/plans/2026-09-26-agentbar-mobile-web.md).

Same techniques as the rest of this test suite:
  - chief-dashboard-server.py is loaded via importlib.util (hyphenated
    filename, same trick as test_answer_pane_permission.py).
  - `_srv.get_full_state` is monkeypatched to a fake returning a scripted
    `computed.agents` list — never the real herdr/board state.
  - `_srv._pane_run_raw` is monkeypatched (same seam
    test_answer_pane_permission.py uses for `_read_pane_now`) for the plan
    endpoint's live pane read.
  - `_srv.herdr_transport.remote_shell_text` is monkeypatched for the
    "remote machine" cases — this is chief_dashboard_herdr's one ssh door,
    never a real ssh/subprocess call.
  - Local-disk cases point `_srv._CLAUDE_PROJECTS_ROOT` at a tempdir (never
    the real ~/.claude/projects) and, for the plan file, temporarily
    override $HOME (session_transcript.read_local_plan_file resolves `~`
    against $HOME at call time) — restored in a `finally`.

HARD SAFETY: never a real subprocess, never the live :4711 dashboard, never
a write under the real $HOME. All session ids/paths here are synthetic.
"""
import base64
import importlib.util
import json
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib"))

_spec = importlib.util.spec_from_file_location(
    "chief_dashboard_server",
    os.path.join(os.path.dirname(__file__), "..", "server", "chief-dashboard-server.py"))
_srv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_srv)

import session_transcript as st  # noqa: E402

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


TMP = tempfile.mkdtemp(prefix="session-transcript-test-")
PROJECTS_ROOT = os.path.join(TMP, "claude-projects")
os.makedirs(PROJECTS_ROOT, exist_ok=True)
_srv._CLAUDE_PROJECTS_ROOT = PROJECTS_ROOT


def write_transcript(session_id, lines, project="proj-a"):
    project_dir = os.path.join(PROJECTS_ROOT, project)
    os.makedirs(project_dir, exist_ok=True)
    path = os.path.join(project_dir, f"{session_id}.jsonl")
    with open(path, "w") as fh:
        fh.write("\n".join(json.dumps(l) for l in lines) + "\n")
    return path


def assistant_line(text, isSidechain=False):
    return {"type": "assistant", "isSidechain": isSidechain,
            "message": {"model": "claude-x", "content": [{"type": "text", "text": text}]}}


def ask_user_question_line(tool_use_id, questions):
    return {"type": "assistant", "isSidechain": False,
            "message": {"model": "claude-x", "content": [
                {"type": "tool_use", "id": tool_use_id, "name": "AskUserQuestion",
                 "input": {"questions": questions}},
            ]}}


def tool_result_line(tool_use_id):
    return {"type": "user", "message": {"content": [
        {"type": "tool_result", "tool_use_id": tool_use_id, "content": "answered"},
    ]}}


def agent(row_session="sess-1", machine="local", pane_id=None):
    return {"agentSession": row_session, "machine": machine, "paneId": pane_id}


def with_agents(agents):
    _srv.get_full_state = lambda: {"computed": {"agents": agents}}


ONE_QUESTION = [{"question": "Pick one", "options": [{"label": "A"}, {"label": "B"}]}]

print("== /api/session/latest: local, plain latest message ==")
write_transcript("sess-1", [assistant_line("hello there"),
                            assistant_line("the real latest message")])
with_agents([agent("sess-1")])
payload, status = _srv.handle_session_latest({"rowId": ["sess-1"]})
check("status", status, 200)
check("ok", payload["ok"], True)
check("machine", payload["machine"], "local")
check("latestMessage", payload["latestMessage"], "the real latest message")
check("no pending question", payload["pendingQuestion"], None)

print("== /api/session/latest: pending AskUserQuestion form ==")
write_transcript("sess-2", [
    assistant_line("earlier turn"),
    ask_user_question_line("toolu_1", ONE_QUESTION),
])
with_agents([agent("sess-2")])
payload, status = _srv.handle_session_latest({"rowId": ["sess-2"]})
check("ok", payload["ok"], True)
check("pending form toolUseId", payload["pendingQuestion"]["toolUseId"], "toolu_1")
check("pending form question text",
      payload["pendingQuestion"]["questions"][0]["question"], "Pick one")
check("pending form options",
      [o["label"] for o in payload["pendingQuestion"]["questions"][0]["options"]],
      ["A", "B"])

print("== /api/session/latest: answered AskUserQuestion -> no pending question ==")
write_transcript("sess-3", [
    ask_user_question_line("toolu_2", ONE_QUESTION),
    tool_result_line("toolu_2"),
    assistant_line("thanks, proceeding"),
])
with_agents([agent("sess-3")])
payload, status = _srv.handle_session_latest({"rowId": ["sess-3"]})
check("ok", payload["ok"], True)
check("settled question is not pending", payload["pendingQuestion"], None)
check("latest message still read", payload["latestMessage"], "thanks, proceeding")

print("== /api/session/latest: missing rowId -> 400 ==")
payload, status = _srv.handle_session_latest({})
check("status", status, 400)
check("ok", payload["ok"], False)

print("== /api/session/latest: row not live -> ok:false, not a 400 ==")
with_agents([])
payload, status = _srv.handle_session_latest({"rowId": ["sess-nope"]})
check("status", status, 200)
check("ok", payload["ok"], False)
check("reason mentions not live", "not live" in payload["error"], True)

print("== /api/session/latest: no Claude session on the row ==")
row_id_for_no_session = _srv.resolve_agent_row_id(
    {"agentSession": None, "machine": "local", "paneId": "w1:p1"})
with_agents([{"agentSession": None, "machine": "local", "paneId": "w1:p1"}])
payload, status = _srv.handle_session_latest({"rowId": [row_id_for_no_session]})
check("status", status, 200)
check("ok", payload["ok"], False)
check("reason mentions no session", "no Claude session" in payload["error"], True)

print("== /api/session/latest: unsafe session id (path traversal) refused ==")
with_agents([agent("../../etc/passwd")])
payload, status = _srv.handle_session_latest({"rowId": ["../../etc/passwd"]})
check("status", status, 400)
check("ok", payload["ok"], False)

print("== /api/session/latest: window grows past 256KB to find the message ==")
FILLER_LINE = {"type": "user", "message": {"content": "a" * 1000}}
big_lines = [assistant_line("early message, past the first window")]
# ~300KB of filler AFTER the message, well past TAIL_WINDOW_BYTES[0] (256KB)
# but comfortably under TAIL_WINDOW_BYTES[1] (1MB) — proves the loop widens
# the window instead of giving up after the first (too-small) one.
big_lines += [FILLER_LINE] * 300
write_transcript("sess-big", big_lines)
with_agents([agent("sess-big")])
file_size = os.path.getsize(os.path.join(PROJECTS_ROOT, "proj-a", "sess-big.jsonl"))
check("fixture file is bigger than the first tail window", file_size > st.TAIL_WINDOW_BYTES[0], True)
check("fixture file is still under the second tail window", file_size < st.TAIL_WINDOW_BYTES[1], True)
payload, status = _srv.handle_session_latest({"rowId": ["sess-big"]})
check("ok", payload["ok"], True)
check("message found only after widening the window",
      payload["latestMessage"], "early message, past the first window")

print("== /api/session/latest: remote machine, ssh round trip ==")
write_transcript("sess-remote", [assistant_line("from the air")], project="proj-remote")
# Simulate what the REAL remote host's inline python3 script would print,
# by running session_transcript's own script-builder against the local
# fixture file directly (proves the wiring end to end without a real ssh).
remote_path = os.path.join(PROJECTS_ROOT, "proj-remote", "sess-remote.jsonl")
with open(remote_path, "rb") as fh:
    remote_bytes = fh.read()
remote_reply = json.dumps({
    "found": True, "size": len(remote_bytes),
    "chunkStartsAtFileStart": True,
    "tailB64": base64.b64encode(remote_bytes).decode("ascii"),
})


def fake_remote_shell_text(machine, script, **kwargs):
    check("remote call targets the configured machine", machine, "air-m1")
    return remote_reply


_srv.herdr_transport.remote_shell_text = fake_remote_shell_text
with_agents([agent("sess-remote", machine="air-m1")])
payload, status = _srv.handle_session_latest({"rowId": ["sess-remote"]})
check("ok", payload["ok"], True)
check("machine reported back", payload["machine"], "air-m1")
check("latest message read over the remote door", payload["latestMessage"], "from the air")

print("== /api/session/latest: remote ssh failure surfaces as ok:false ==")
_srv.herdr_transport.remote_shell_text = lambda machine, script, **kw: (
    (_ for _ in ()).throw(_srv.herdr_transport.SshUnreachable("ssh air unreachable")))
with_agents([agent("sess-remote", machine="air-m1")])
payload, status = _srv.handle_session_latest({"rowId": ["sess-remote"]})
check("status", status, 200)
check("ok", payload["ok"], False)
check("reason surfaces the ssh failure", "unreachable" in payload["error"], True)


# --------------------------------------------------------------------------
# /api/session/plan
# --------------------------------------------------------------------------

class FakePaneRead:
    def __init__(self, screen):
        self.screen = screen

    def pane_run_raw(self, args, machine="local", timeout=15):
        if args[:2] == ["pane", "read"]:
            return self.screen
        raise AssertionError(f"unexpected herdr call: {args}")


FOUND_PLAN_SCREEN = "\n".join([
    "Claude has written up a plan and is ready to execute. Would you like "
    "to proceed?",
    "",
    "❯ 1. Yes, and use auto mode",
    "  2. Yes, manually approve edits",
    "  3. Tell Claude what to change",
    "",
    "ctrl+g to edit in Vim · ~/plans/my-plan.md",
])
NO_PATH_PLAN_SCREEN = "\n".join([
    "Claude has written up a plan and is ready to execute. Would you like "
    "to proceed?",
    "",
    "❯ 1. Yes, and use auto mode",
    "  2. Yes, manually approve edits",
    "  3. Tell Claude what to change",
    "",
    "no plan file footer on this screen at all",
])
NOT_A_PLAN_SCREEN = "\n".join([
    "Do you want to proceed?",
    "",
    "❯ 1. Yes",
    "  2. No",
])

PLAN_HOME = os.path.join(TMP, "plan-home")
os.makedirs(os.path.join(PLAN_HOME, "plans"), exist_ok=True)
_ORIG_HOME = os.environ.get("HOME")


def with_plan_home(fn):
    os.environ["HOME"] = PLAN_HOME
    try:
        fn()
    finally:
        if _ORIG_HOME is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = _ORIG_HOME


print("== /api/session/plan: plan file found and read ==")
with open(os.path.join(PLAN_HOME, "plans", "my-plan.md"), "w") as fh:
    fh.write("# The Plan\n\nDo the thing.\n")
_srv._pane_run_raw = FakePaneRead(FOUND_PLAN_SCREEN).pane_run_raw
with_agents([agent("sess-plan", pane_id="w1:p1")])


def _run_found():
    payload, status = _srv.handle_session_plan({"rowId": ["sess-plan"]})
    check("status", status, 200)
    check("ok", payload["ok"], True)
    check("planPath echoed verbatim", payload["planPath"], "~/plans/my-plan.md")
    check("plan status", payload["plan"]["status"], "text")
    check("plan text", payload["plan"]["text"], "# The Plan\n\nDo the thing.\n")
    check("not truncated", payload["plan"]["truncated"], False)


with_plan_home(_run_found)

print("== /api/session/plan: plan box open, no file named -> noPath ==")
_srv._pane_run_raw = FakePaneRead(NO_PATH_PLAN_SCREEN).pane_run_raw
with_agents([agent("sess-plan-nopath", pane_id="w1:p1")])
payload, status = _srv.handle_session_plan({"rowId": ["sess-plan-nopath"]})
check("ok", payload["ok"], True)
check("planPath is None", payload["planPath"], None)
check("plan status noPath", payload["plan"]["status"], "noPath")

print("== /api/session/plan: named file missing on disk -> unreadable ==")
MISSING_PLAN_SCREEN = FOUND_PLAN_SCREEN.replace("my-plan.md", "no-such-plan.md")


def _run_missing():
    payload, status = _srv.handle_session_plan({"rowId": ["sess-plan-missing"]})
    check("ok", payload["ok"], True)
    check("plan status unreadable", payload["plan"]["status"], "unreadable")
    check("reason says not found", "not found" in payload["plan"]["reason"], True)


_srv._pane_run_raw = FakePaneRead(MISSING_PLAN_SCREEN).pane_run_raw
with_agents([agent("sess-plan-missing", pane_id="w1:p1")])
with_plan_home(_run_missing)

print("== /api/session/plan: pane not on a plan box right now ==")
_srv._pane_run_raw = FakePaneRead(NOT_A_PLAN_SCREEN).pane_run_raw
with_agents([agent("sess-plan-not-open", pane_id="w1:p1")])
payload, status = _srv.handle_session_plan({"rowId": ["sess-plan-not-open"]})
check("ok", payload["ok"], False)
check("reason says not a plan box", "not showing a plan approval" in payload["error"], True)

print("== /api/session/plan: row has no pane at all ==")
with_agents([agent("sess-plan-nopane", pane_id=None)])
payload, status = _srv.handle_session_plan({"rowId": ["sess-plan-nopane"]})
check("ok", payload["ok"], False)
check("reason says no pane", "no pane" in payload["error"], True)

print("== /api/session/plan: plan file over the 200KB cap is truncated ==")
big_plan_path = os.path.join(PLAN_HOME, "plans", "big-plan.md")
with open(big_plan_path, "w") as fh:
    fh.write("x" * (st.PLAN_FILE_MAX_BYTES + 5000))
BIG_PLAN_SCREEN = FOUND_PLAN_SCREEN.replace("my-plan.md", "big-plan.md")
_srv._pane_run_raw = FakePaneRead(BIG_PLAN_SCREEN).pane_run_raw
with_agents([agent("sess-plan-big", pane_id="w1:p1")])


def _run_big():
    payload, status = _srv.handle_session_plan({"rowId": ["sess-plan-big"]})
    check("ok", payload["ok"], True)
    check("plan status text", payload["plan"]["status"], "text")
    check("plan truncated", payload["plan"]["truncated"], True)
    check("plan text capped at the byte limit",
          len(payload["plan"]["text"]), st.PLAN_FILE_MAX_BYTES)


with_plan_home(_run_big)

print("== /api/session/plan: remote machine reads the file over ssh ==")
# split_pane_key (called on the namespaced paneId before the pane read)
# needs "air-m1" to actually be a configured machine, same as
# test_chief_dashboard_remote_rows.py — mutate the shared MACHINES dict in
# place (chief_dashboard_feeds/-views/-server all import the same object).
_srv.MACHINES["air-m1"] = {"sshAlias": "trungs-air", "herdrPath": "/x/herdr",
                           "label": "Air", "maxParallel": 4}


def fake_remote_plan_shell_text(machine, script, **kwargs):
    check("remote plan call targets the configured machine", machine, "air-m1")
    return json.dumps({"dataB64": base64.b64encode(b"# Remote plan\n").decode("ascii")})


_srv.herdr_transport.remote_shell_text = fake_remote_plan_shell_text
_srv._pane_run_raw = FakePaneRead(FOUND_PLAN_SCREEN).pane_run_raw
with_agents([agent("sess-plan-remote", machine="air-m1", pane_id="air-m1:w1:p1")])
payload, status = _srv.handle_session_plan({"rowId": ["sess-plan-remote"]})
check("ok", payload["ok"], True)
check("machine", payload["machine"], "air-m1")
check("plan text read over ssh", payload["plan"]["text"], "# Remote plan\n")

_srv.MACHINES.pop("air-m1", None)
shutil.rmtree(TMP, ignore_errors=True)

if fails:
    print(f"\n{len(fails)} FAILURE(S):")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("\nAll checks passed.")
