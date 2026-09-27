#!/usr/bin/env python3
"""Direct-run tests for the PermissionRequest hook bridge:
hook_permission_summary.py (views + decisions), hook_permissions.py (the
pending store), hook_permission_routes.py, the status-only row / needsYou
wiring, and hooks/agentbar-permission-hook.py against a real local server."""
import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

DASHBOARD = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(DASHBOARD, "server", "lib"))
HOOK = os.path.join(DASHBOARD, "hooks", "agentbar-permission-hook.py")

import hook_permission_summary as summary  # noqa: E402
import hook_permissions  # noqa: E402
import hook_permission_routes as routes  # noqa: E402
import chief_dashboard_views as views  # noqa: E402

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


class FakeClock:
    def __init__(self, now=1_790_000_000.0):
        self.now = now

    def __call__(self):
        return self.now


QUESTIONS_INPUT = {"questions": [
    {"question": "Which color?", "header": "Color", "multiSelect": False,
     "options": [{"label": "Red", "description": "warm"}, {"label": "Blue", "description": "cool"}]},
    {"question": "Which sizes?", "header": "Size", "multiSelect": True,
     "options": [{"label": "S", "description": ""}, {"label": "M", "description": ""}]},
]}
RULE_SUGGESTION = {"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": "python3 -c:*"}],
                   "behavior": "allow", "destination": "localSettings"}


def payload(session_id="sess-1", tool_name="Bash", tool_input=None, **extra):
    body = {"session_id": session_id, "tool_name": tool_name,
            "tool_input": tool_input if tool_input is not None else {"command": "python3 -c \"print(1)\""},
            "hook_event_name": "PermissionRequest", "claudePid": 4242, "hookPid": 4343}
    body.update(extra)
    return body


print("== summary: hookRequest views ==")
view = summary.build_hook_request_view("r1", "AskUserQuestion", QUESTIONS_INPUT, [], 100.0, 130.0)
check("question kind", view["kind"], "question")
check("sinceSec", view["sinceSec"], 30.0)
check("questions normalized", [q["question"] for q in view["questions"]], ["Which color?", "Which sizes?"])
check("multiSelect carried", view["questions"][1]["multiSelect"], True)
check("options carried", view["questions"][0]["options"][1], {"label": "Blue", "description": "cool"})
check("question view has no permission", "permission" in view, False)
view = summary.build_hook_request_view(
    "r2", "Bash", {"command": "ls", "description": "List files"}, [RULE_SUGGESTION], 100.0, 100.0)
check("permission kind", view["kind"], "permission")
check("bash title", view["permission"]["title"], "Run a shell command")
check("bash detail = command + description", view["permission"]["detail"], "ls\n\nList files")
check("suggestion label names the exact rule", view["permission"]["suggestions"],
      [{"index": 0, "label": "Always allow `Bash(python3 -c:*)` in this project"}])
check("plan detail", summary.build_hook_request_view(
    "r3", "ExitPlanMode", {"plan": "1. do x"}, [], 0, 0)["permission"]["detail"], "1. do x")
check("file detail", summary.build_hook_request_view(
    "r4", "Write", {"file_path": "/a/b.txt", "content": "x"}, [], 0, 0)["permission"]["detail"], "/a/b.txt")
check("detail capped", len(summary.build_hook_request_view(
    "r5", "Bash", {"command": "x" * 5000}, [], 0, 0)["permission"]["detail"]), summary.DETAIL_MAX_CHARS)
check("setMode label", summary.suggestion_label(
    {"type": "setMode", "mode": "acceptEdits", "destination": "session"}),
    "Switch to auto-accept edits mode for this session")
check("addDirectories label", summary.suggestion_label(
    {"type": "addDirectories", "directories": ["/tmp/x"], "destination": "session"}),
    "Always allow access to `/tmp/x` for this session")
check("needsYou detail question", summary.needs_you_detail({"kind": "question", "toolName": "AskUserQuestion"}), "Question")
check("needsYou detail permission", summary.needs_you_detail({"kind": "permission", "toolName": "Bash"}), "Permission: Bash")

print("== summary: decisions + validation ==")
answers = {"Which color?": "Red", "Which sizes?": "S, M"}
decision = summary.build_decision("AskUserQuestion", QUESTIONS_INPUT, [], {"behavior": "allow", "answers": answers})
check("question allow keeps tool_input + answers", decision,
      {"behavior": "allow", "updatedInput": {**QUESTIONS_INPUT, "answers": answers}})
check("answer text cleaned (control chars, newlines)", summary.build_decision(
    "AskUserQuestion", QUESTIONS_INPUT, [],
    {"behavior": "allow", "answers": {"Which color?": " a\nb\x07c ", "Which sizes?": "S"}}
)["updatedInput"]["answers"]["Which color?"], "a b c")
check("answer capped at 500", len(summary.clean_answer_text("y" * 900)), 500)
check("permission allow once", summary.build_decision("Bash", {}, [RULE_SUGGESTION], {"behavior": "allow"}),
      {"behavior": "allow"})
check("permission allow always", summary.build_decision(
    "Bash", {}, [RULE_SUGGESTION], {"behavior": "allow", "suggestionIndex": 0}),
    {"behavior": "allow", "updatedPermissions": [RULE_SUGGESTION]})
check("deny with message", summary.build_decision("Bash", {}, [], {"behavior": "deny", "message": "no\nthanks"}),
      {"behavior": "deny", "message": "no thanks"})
check("deny default message", summary.build_decision("Bash", {}, [], {"behavior": "deny"})["message"],
      summary.DEFAULT_DENY_MESSAGE)
for label, tool, body in [
        ("bad behavior", "Bash", {"behavior": "maybe"}),
        ("suggestion index out of range", "Bash", {"behavior": "allow", "suggestionIndex": 3}),
        ("suggestion index bool", "Bash", {"behavior": "allow", "suggestionIndex": True}),
        ("answers missing a question", "AskUserQuestion", {"behavior": "allow", "answers": {"Which color?": "Red"}}),
        ("answers extra key", "AskUserQuestion", {"behavior": "allow", "answers": {**answers, "x": "y"}}),
        ("answers empty text", "AskUserQuestion", {"behavior": "allow", "answers": {**answers, "Which color?": "  "}}),
        ("answers not strings", "AskUserQuestion", {"behavior": "allow", "answers": {**answers, "Which color?": 3}}),
        ("body not object", "Bash", ["allow"])]:
    try:
        summary.build_decision(tool, QUESTIONS_INPUT, [RULE_SUGGESTION], body)
        check(f"rejects {label}", "accepted", "AnswerRejected")
    except summary.AnswerRejected:
        check(f"rejects {label}", "AnswerRejected", "AnswerRejected")

print("== store: register / answer / first decision wins ==")
clock = FakeClock()
store = hook_permissions.HookPermissionStore(clock=clock, pid_alive=lambda pid: True)
check("invalid payload ignored", store.register({"tool_name": "Bash"}), {"state": "ignored"})
check("herdr session ignored", store.register(payload("herdr-sess"), {"herdr-sess"}), {"state": "ignored"})
rid = store.register(payload())["requestId"]
check("request id issued", rid.startswith("hp"), True)
check("unknown request answer -> 404", store.answer("nope", {"behavior": "allow"})[1], 404)
check("bad answer -> 400, still pending", store.answer(rid, {"behavior": "x"})[1], 400)
check("wait(0) on pending", store.wait(rid, 0), ({"state": "pending"}, 200))
check("answer ok", store.answer(rid, {"behavior": "allow"}), ({"ok": True, "state": "answered"}, 200))
check("second answer -> 409", store.answer(rid, {"behavior": "deny"})[1], 409)
check("wait returns the decision", store.wait(rid, 5),
      ({"state": "answered", "decision": {"behavior": "allow"}}, 200))
check("unknown wait -> 404", store.wait("nope", 0)[1], 404)

print("== store: long-poll wakes on answer (real clock) ==")
live_store = hook_permissions.HookPermissionStore(pid_alive=lambda pid: True)
rid = live_store.register(payload())["requestId"]
threading.Timer(0.3, lambda: live_store.answer(rid, {"behavior": "deny"})).start()
t0 = time.time()
result, status = live_store.wait(rid, 10)
check("woken by answer, not by timeout", (result["state"], time.time() - t0 < 2), ("answered", True))

print("== store: resolution elsewhere ==")
clock = FakeClock()
store = hook_permissions.HookPermissionStore(clock=clock, pid_alive=lambda pid: pid != 999)
rid_tui = store.register(payload("s-tui"))["requestId"]
rid_dead = store.register(payload("s-dead", claudePid=999))["requestId"]
rid_silent = store.register(payload("s-silent"))["requestId"]
created_ms = int(clock.now * 1000)
sessions = [{"sessionId": "s-tui", "status": "waiting", "statusUpdatedAt": created_ms + 500}]
store.sweep(sessions)
check("session still waiting -> pending", store.wait(rid_tui, 0)[0]["state"], "pending")
check("claude pid dead -> resolved", store.wait(rid_dead, 0)[0],
      {"state": "resolved", "reason": "claude exited"})
store.sweep([{"sessionId": "s-tui", "status": "busy", "statusUpdatedAt": created_ms - 5000}])
check("older status update does not resolve", store.wait(rid_tui, 0)[0]["state"], "pending")
store.sweep([{"sessionId": "s-tui", "status": "busy", "statusUpdatedAt": created_ms + 2000}])
check("session moved on -> resolved", store.wait(rid_tui, 0)[0],
      {"state": "resolved", "reason": "answered elsewhere"})
check("answer after resolve -> 409", store.answer(rid_tui, {"behavior": "allow"})[1], 409)
clock.now += hook_permissions.HOOK_SILENT_RESOLVE_SEC + 1
store.sweep([])
check("hook silent 90s -> resolved", store._requests[rid_silent].state, "resolved")
rid_old = store.register(payload("s-old"))["requestId"]
store._requests[rid_old].created_at -= hook_permissions.MAX_AGE_SEC + 1
store.sweep([])
check("older than 24h -> expired", store._requests[rid_old].state, "expired")
clock.now += hook_permissions.FINISHED_KEEP_SEC + 1
store.sweep([])
check("finished requests pruned later", rid_tui in store._requests, False)

print("== store: exposure (oldest pending per session) ==")
clock = FakeClock()
store = hook_permissions.HookPermissionStore(clock=clock, pid_alive=lambda pid: True)
first = store.register(payload("s-a"))["requestId"]
clock.now += 1
store.register(payload("s-a", tool_name="AskUserQuestion", tool_input=QUESTIONS_INPUT))
store.register(payload("s-b", tool_name="AskUserQuestion", tool_input=QUESTIONS_INPUT))
exposed = store.exposed_by_session([])
check("one per session", sorted(exposed), ["s-a", "s-b"])
check("oldest one exposed", exposed["s-a"]["requestId"], first)
store.answer(first, {"behavior": "allow"})
check("next one exposed after answer", store.exposed_by_session([])["s-a"]["kind"], "question")

print("== routes ==")
store = hook_permissions.HookPermissionStore(pid_alive=lambda pid: True)
check("is_hook_path", [routes.is_hook_path(p) for p in
      ("/api/hook/permission", "/api/hook/permission/x/wait", "/api/hook/permissionx")], [True, True, False])
check("remote listener GET -> 404", routes.handle_get("/api/hook/permission/x/wait", {}, True, store)[1], 404)
check("remote listener POST -> 404", routes.handle_post(
    "/api/hook/permission", lambda: payload(), True, store)[1], 404)
reg, status = routes.handle_post("/api/hook/permission", lambda: payload(), False, store)
check("register route", (status, "requestId" in reg), (200, True))
check("bad JSON -> 400", routes.handle_post(
    "/api/hook/permission", lambda: json.loads("{"), False, store)[1], 400)
check("unknown action -> 404", routes.handle_post(
    f"/api/hook/permission/{reg['requestId']}/zap", dict, False, store)[1], 404)
check("answer route", routes.handle_post(
    f"/api/hook/permission/{reg['requestId']}/answer", lambda: {"behavior": "allow"}, False, store)[1], 200)
check("wait route (timeout clamped, answered)", routes.handle_get(
    f"/api/hook/permission/{reg['requestId']}/wait", {"timeout": ["999"]}, False, store)[0]["state"], "answered")

print("== views: status-only row + needsYou carry hookRequest ==")


def feed(data):
    return {"broken": False, "warming": False, "error": None,
            "lastSuccessTs": 1.0, "ageSec": 0, "lastDurationSec": 0, "data": data}


shared = hook_permissions.STORE
shared._requests.clear()
now_ms = int(time.time() * 1000)
session_entries = [
    {"pid": os.getpid(), "sessionId": "cli-hook", "cwd": "/x/demo", "kind": "interactive",
     "entrypoint": "cli", "name": "demo", "status": "busy", "statusUpdatedAt": now_ms - 10_000},
    {"pid": os.getpid(), "sessionId": "cli-plain", "cwd": "/x/plain", "kind": "interactive",
     "entrypoint": "cli", "name": "plain", "status": "busy", "statusUpdatedAt": now_ms - 10_000},
]
hook_rid = shared.register(payload("cli-hook", claudePid=os.getpid()))["requestId"]
snap = {n: feed(None) for n in ("hookCache", "paneTick", "board")}
snap["hookCache"]["data"] = {}
snap["herdr"] = feed({"agents": [], "tabs": []})
snap["paneScreen"] = feed({})
snap["claudeSessions"] = feed(session_entries)
agents = {a["agentSession"]: a for a in views.build_agents_view(snap)}
check("row carries hookRequest", agents["cli-hook"]["hookRequest"]["requestId"], hook_rid)
check("row reads blocked while hook pending", agents["cli-hook"]["hookState"], "blocked")
check("row reason names the tool", agents["cli-hook"]["hookReason"], "Permission: Bash")
check("other row unchanged", (agents["cli-plain"]["hookRequest"], agents["cli-plain"]["hookState"]),
      (None, "working"))
needs = [r for r in views.build_needs_you(snap, list(agents.values())) if r.get("agentSession") == "cli-hook"]
check("needsYou entry with hookRequest", (len(needs), needs[0]["hookRequest"]["requestId"]), (1, hook_rid))
check("needsYou detail", needs[0]["detail"], "Permission: Bash")
shared._requests.clear()

print("== hook script against a real local server ==")


class HookRouteHandler(BaseHTTPRequestHandler):
    store = None

    def log_message(self, *args):
        pass

    def _send(self, body, status):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parsed = urlparse(self.path)
        self._send(*routes.handle_get(parsed.path, parse_qs(parsed.query), False, self.store))

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        self._send(*routes.handle_post(
            urlparse(self.path).path, lambda: json.loads(self.rfile.read(length) or b"{}"),
            False, self.store))


HookRouteHandler.store = hook_permissions.HookPermissionStore()
server = ThreadingHTTPServer(("127.0.0.1", 0), HookRouteHandler)
threading.Thread(target=server.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{server.server_address[1]}"


def run_hook(stdin_payload, dashboard_url, answer_body=None, timeout=15):
    proc = subprocess.Popen([sys.executable, HOOK], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True,
                            env=dict(os.environ, AGENTBAR_DASHBOARD_URL=dashboard_url))
    proc.stdin.write(json.dumps(stdin_payload))
    proc.stdin.close()
    if answer_body is not None:
        deadline = time.time() + 5
        while time.time() < deadline:
            pending = HookRouteHandler.store.exposed_by_session([])
            if stdin_payload["session_id"] in pending:
                HookRouteHandler.store.answer(pending[stdin_payload["session_id"]]["requestId"], answer_body)
                break
            time.sleep(0.05)
    out = proc.stdout.read()
    proc.wait(timeout=timeout)
    return proc.returncode, out


hook_stdin = {"session_id": "hook-s1", "tool_name": "AskUserQuestion", "tool_input": QUESTIONS_INPUT,
              "hook_event_name": "PermissionRequest"}
code, out = run_hook(hook_stdin, url, {"behavior": "allow", "answers": answers})
check("hook exit 0", code, 0)
check("hook prints the decision", json.loads(out), {"hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {"behavior": "allow", "updatedInput": {**QUESTIONS_INPUT, "answers": answers}}}})
code, out = run_hook({**hook_stdin, "session_id": "hook-s2", "tool_name": "Bash",
                      "tool_input": {"command": "true"}}, url, {"behavior": "deny", "message": "nope"})
check("hook deny", json.loads(out)["hookSpecificOutput"]["decision"], {"behavior": "deny", "message": "nope"})
registered = {r.claude_pid for r in HookRouteHandler.store._requests.values()}
check("hook reports its Claude (parent) pid", registered, {os.getpid()})
t0 = time.time()
code, out = run_hook({"tool_name": "Bash"}, url)
check("ignored payload -> silent exit 0", (code, out), (0, ""))
code, out = run_hook(hook_stdin, "http://127.0.0.1:9")
check("dashboard down -> silent exit 0", (code, out), (0, ""))
check("fails open fast (<2s each)", time.time() - t0 < 4, True)
proc = subprocess.run([sys.executable, HOOK], input="not json", capture_output=True, text=True,
                      env=dict(os.environ, AGENTBAR_DASHBOARD_URL=url))
check("garbage stdin -> silent exit 0", (proc.returncode, proc.stdout, proc.stderr), (0, "", ""))
server.shutdown()

print()
if fails:
    print(f"FAIL: {len(fails)} failure(s)")
    for f in fails:
        print("  - " + f)
    sys.exit(1)
print("PASS: all hook permission checks")
