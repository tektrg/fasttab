#!/usr/bin/env python3
"""Direct-run tests for the Codex PermissionRequest hold: codex_hold_store.py
(pending store), the routes that share the Claude bridge's endpoints, and the
real hook `integrations/codex/agentbar-codex-permission.py` run as a
subprocess with a FAKE Codex payload against a local test server.
Never a real Codex session. Hostile text uses the inert sentinel only."""
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
HOOK = os.path.join(DASHBOARD, "integrations", "codex", "agentbar-codex-permission.py")

import codex_hold_store  # noqa: E402
import hook_permission_routes as routes  # noqa: E402
import hook_permissions  # noqa: E402
import tui_status_events  # noqa: E402

SENTINEL = "$(echo INJECTED)"
fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


class Presence:
    connected = True

    def is_connected(self):
        return self.connected

    def is_gone(self):
        return not self.connected


PRESENCE = Presence()
MOVED = {"on": False}
STORE = codex_hold_store.CodexHoldStore(presence=PRESENCE, moved_on=lambda request: MOVED["on"])
PAYLOAD = {"session_id": "cx-sess-1", "turn_id": "t1", "cwd": "/scratch/work", "hook_event_name": "PermissionRequest",
           "model": "gpt-x", "permission_mode": "default", "tool_name": "Bash", "transcript_path": None,
           "tool_input": {"command": f"touch scratch.txt {SENTINEL}", "description": "make a marker"}}

print("store")
reg = STORE.register({**PAYLOAD, "hookPid": os.getpid(), "claudePid": os.getpid()})
request_id = reg.get("requestId", "")
check("registered with the codex id prefix", request_id.startswith("tuicx"), True)
view = STORE.exposed_by_session()["cx-sess-1"]
check("view: permission, tool codex, command + description, no suggestions",
      (view["kind"], view["tool"], view["permission"]["title"], view["permission"]["detail"], view["permission"]["suggestions"]),
      ("permission", "codex", "Run a shell command", f"touch scratch.txt {SENTINEL}\n\nmake a marker", []))
STORE.wait(request_id, 0)  # a polling hook
check("allow with an 'always' suggestion is refused (Codex would fail closed)",
      STORE.answer(request_id, {"behavior": "allow", "suggestionIndex": 0})[1], 400)
res, status = STORE.answer(request_id, {"behavior": "allow"})
check("allow -> answered", (status, res["state"]), (200, "answered"))
check("wait returns the decision Codex reads", STORE.wait(request_id, 0)[0], {"state": "answered", "decision": {"behavior": "allow"}})
res, status = STORE.answer(request_id, {"behavior": "deny"})
check("second answer refused: first answer wins", (status, "Codex" in res["error"] or "AgentBar" in res["error"]), (409, True))

reg = STORE.register({**PAYLOAD, "session_id": "cx-sess-2", "hookPid": os.getpid(), "claudePid": os.getpid()})
STORE.wait(reg["requestId"], 0)
MOVED["on"] = True
STORE.sweep([])
res, status = STORE.answer(reg["requestId"], {"behavior": "allow"})
check("session moved on -> 'answered in Codex' 409", (status, "already answered in Codex" in res["error"]), (409, True))
MOVED["on"] = False

reg = STORE.register({**PAYLOAD, "session_id": "cx-sess-3", "hookPid": 2 ** 22 + 7, "claudePid": os.getpid()})
STORE.wait(reg["requestId"], 0)
STORE.sweep([])
res, status = STORE.answer(reg["requestId"], {"behavior": "deny"})
check("our hook process gone (another app's hook decided) -> 409, never handed on", status, 409)

PRESENCE.connected = False
check("AgentBar not connected -> ignored (fail open)",
      STORE.register({**PAYLOAD, "session_id": "cx-sess-4", "claudePid": os.getpid()})["state"], "ignored")
PRESENCE.connected = True
check("missing agent pid -> ignored", STORE.register({**PAYLOAD, "session_id": "cx-sess-5"})["state"], "ignored")
check("a question tool is not answered through Codex's hook",
      STORE.register({**PAYLOAD, "tool_name": "AskUserQuestion", "claudePid": os.getpid()})["state"], "ignored")
check("invalid payload -> ignored", STORE.register({"session_id": "x"})["state"], "ignored")

print("moved-on oracle reads the status store")
status_store = tui_status_events.TuiStatusStore(pid_alive=lambda p: True)
status_store.ingest({"tool": "codex", "event": "PermissionRequest", "sessionId": "cx-sess-9", "pid": 1})


class Req:
    session_id, created_at = "cx-sess-9", time.time() - 10


check("still in the permission state -> not moved on", codex_hold_store.status_store_moved_on(Req, status_store), False)
status_store.ingest({"tool": "codex", "event": "PostToolUse", "sessionId": "cx-sess-9", "pid": 1})
check("PostToolUse after the prompt -> moved on", codex_hold_store.status_store_moved_on(Req, status_store), True)
check("unknown session -> not moved on", codex_hold_store.status_store_moved_on(
    type("R", (), {"session_id": "nope", "created_at": 0}), status_store), False)

print("hook subprocess through the shared routes")


class Handler(BaseHTTPRequestHandler):
    store = codex_hold_store.CodexHoldStore(presence=PRESENCE, moved_on=lambda request: MOVED["on"])

    def log_message(self, *a):
        pass

    def _send(self, payload, status=200):
        raw = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        parsed = urlparse(self.path)
        self._send(*routes.handle_get(parsed.path, parse_qs(parsed.query), False, self.store))

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        self._send(*routes.handle_post(urlparse(self.path).path, lambda: json.loads(self.rfile.read(length) or b"{}"),
                                       False, self.store))


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
URL = f"http://127.0.0.1:{server.server_address[1]}"
DEAD_PROXY = "http://127.0.0.1:9"


def run_hook(payload, answer=None, url=URL, hold_sec="30", timeout=20):
    proc = subprocess.Popen([sys.executable, HOOK], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, env=dict(os.environ, AGENTBAR_DASHBOARD_URL=url, AGENTBAR_CODEX_HOLD_SEC=hold_sec,
                                                HTTP_PROXY=DEAD_PROXY, http_proxy=DEAD_PROXY, NO_PROXY=""))
    proc.stdin.write(json.dumps(payload))
    proc.stdin.close()
    started = time.time()
    if answer is not None:
        deadline = time.time() + 8
        while time.time() < deadline:
            pending = Handler.store.exposed_by_session()
            if payload["session_id"] in pending:
                time.sleep(0.3)  # let the hook's first /wait land
                res, status = routes.handle_post(
                    f"/api/hook/permission/{pending[payload['session_id']]['requestId']}/answer", lambda: answer, False, Handler.store)
                break
            time.sleep(0.05)
    out = proc.stdout.read()
    proc.wait(timeout=timeout)
    return proc.returncode, out, time.time() - started


code, out, _ = run_hook(PAYLOAD, {"behavior": "allow"})
check("allow: exit 0, exactly Codex's decision on stdout", (code, json.loads(out)), (0, {
    "hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}}))
code, out, _ = run_hook({**PAYLOAD, "session_id": "cx-h2"}, {"behavior": "deny", "message": f"no {SENTINEL}"})
check("deny carries the message as plain data", json.loads(out)["hookSpecificOutput"]["decision"],
      {"behavior": "deny", "message": f"no {SENTINEL}"})
registered = {r.claude_pid for r in Handler.store._requests.values()}
check("hook reports Codex's pid (its parent) and it is a bare-string pid", registered, {os.getpid()})
check("sentinel was never executed (no marker in output)", "INJECTED" not in out.replace(SENTINEL, ""), True)

code, out, elapsed = run_hook({**PAYLOAD, "session_id": "cx-h3"}, None, url="http://127.0.0.1:9")
check("dashboard down: silent exit 0, fast", (code, out, elapsed < 12), (0, "", True))
PRESENCE.connected = False
code, out, elapsed = run_hook({**PAYLOAD, "session_id": "cx-h4"}, None)
check("AgentBar not connected: ignored -> silent, fast (Codex draws its own prompt)", (code, out, elapsed < 12), (0, "", True))
PRESENCE.connected = True
code, out, elapsed = run_hook({**PAYLOAD, "session_id": "cx-h5"}, None, hold_sec="2")
check("hold limit reached: silent exit near the limit", (code, out, 1.5 < elapsed < 20), (0, "", True))
code, out, elapsed = run_hook({**PAYLOAD, "session_id": "cx-h6"}, None, hold_sec="0")
check("hold limit 0 = never hold", (code, out, elapsed < 12), (0, "", True))
code, out, _ = run_hook({**PAYLOAD, "session_id": "cx-h7", "agent_id": "sub-1"}, None)
check("subagent prompt is not held", (code, out), (0, ""))
proc = subprocess.run([sys.executable, HOOK], input="not json", capture_output=True, text=True, timeout=10,
                      env=dict(os.environ, AGENTBAR_DASHBOARD_URL=URL))
check("garbage stdin: fails open", (proc.returncode, proc.stdout), (0, ""))

MOVED["on"] = True
code, out, _ = run_hook({**PAYLOAD, "session_id": "cx-h8"}, None, hold_sec="10")
MOVED["on"] = False
check("answered elsewhere while held: hook stops silently", (code, out), (0, ""))

server.shutdown()
if fails:
    print(f"\nFAIL: {len(fails)} failure(s)")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("\nPASS: all Codex hold checks")
