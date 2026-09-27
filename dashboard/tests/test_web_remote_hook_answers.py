#!/usr/bin/env python3
"""The phone's web remote as a hook-prompt answer surface (2026-09-27):
real `http.client` requests against a REAL remote listener (and main
listener) on throwaway loopback ports, proving:

  1. On the remote listener only `POST /api/hook/permission/<id>/answer`
     exists; register and wait stay 404 (the hook runs on this Mac).
  2. That answer is authenticated, CSRF-checked and audited like every other
     remote write, and reaches the same pending store AgentBar answers.
  3. The web UI's SSE stream (`/api/events?answerSurface=web`) counts as an
     answer surface on either listener — so a prompt is held while ONLY the
     phone is open; the same stream without the parameter never counts.

SAFETY: 127.0.0.1 only, OS-assigned ports (never 4711/4712), throwaway
CONFIG/STATE homes, no machines (no ssh/herdr), no real Claude session: the
"Claude pid" and "hook pid" are this test process.
"""
import http.client
import importlib.util
import json
import os
import socket
import sys
import tempfile
import threading
import time

DASHBOARD_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(DASHBOARD_DIR, "server", "lib"))

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


_tmp = tempfile.TemporaryDirectory()
CONFIG_HOME = os.path.join(_tmp.name, "config")
STATE_HOME = os.path.join(_tmp.name, "state")
os.makedirs(CONFIG_HOME)
os.makedirs(STATE_HOME)
MAIN_PORT, REMOTE_PORT = free_port(), free_port()
REMOTE_HOST = "web-remote-test.tailnet.ts.net"
TOKEN = "web-remote-test-token"
os.environ.update({
    "CHIEF_DASHBOARD_CONFIG_HOME": CONFIG_HOME,
    "CHIEF_DASHBOARD_STATE_HOME": STATE_HOME,
    "CHIEF_DASHBOARD_MACHINES": "{}",
    "CHIEF_DASHBOARD_HOST": "127.0.0.1",
    "CHIEF_DASHBOARD_PORT": str(MAIN_PORT),
    "AGENTBAR_PERSONAS_FILE": os.path.join(_tmp.name, "no-personas.json"),
})
with open(os.path.join(CONFIG_HOME, "config.json"), "w") as f:
    json.dump({"remote": {"enabled": True, "hosts": [REMOTE_HOST], "port": REMOTE_PORT}}, f)
with open(os.path.join(CONFIG_HOME, "remote-token"), "w") as f:
    f.write(TOKEN + "\n")
os.chmod(os.path.join(CONFIG_HOME, "remote-token"), 0o600)

_spec = importlib.util.spec_from_file_location(
    "chief_dashboard_server_web_remote_hook_test",
    os.path.join(DASHBOARD_DIR, "server", "chief-dashboard-server.py"))
_srv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_srv)

import agentbar_presence  # noqa: E402
import hook_permissions  # noqa: E402
import remote_access  # noqa: E402

AUTH = {"Authorization": f"Bearer {TOKEN}"}
SAME_ORIGIN = {"Origin": f"https://{REMOTE_HOST}"}


def request(port, method, path, body=None, headers=None):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    data = json.dumps(body).encode() if body is not None else b""
    hdrs = dict(headers or {}, Host="127.0.0.1")
    hdrs.update({"Content-Type": "application/json", "Content-Length": str(len(data))})
    try:
        conn.request(method, path, body=data, headers=hdrs)
        resp = conn.getresponse()
        raw = resp.read()
        try:
            return resp.status, json.loads(raw or b"{}")
        except ValueError:
            return resp.status, raw
    finally:
        conn.close()


def sse_client(port, query, headers):
    """Open /api/events and read one push in the background."""
    def run():
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        try:
            conn.request("GET", "/api/events" + query, headers=dict(headers, Host="127.0.0.1"))
            resp = conn.getresponse()
            for _ in range(1):
                while resp.fp.readline() not in (b"\n", b""):
                    pass
        except Exception:
            pass
        finally:
            conn.close()
    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    return thread


def hook_payload(session_id):
    return {"session_id": session_id, "tool_name": "AskUserQuestion",
            "tool_input": {"questions": [{"question": "Ship it?", "header": "Ship",
                                          "options": [{"label": "Yes"}, {"label": "No"}]}]},
            "claudePid": os.getpid(), "hookPid": os.getpid()}


def desktop_entry(session_id):
    return {"sessionId": session_id, "entrypoint": "claude-desktop", "status": "waiting"}


def audit_lines():
    try:
        with open(remote_access.AUDIT_LOG_PATH) as f:
            return [json.loads(line) for line in f if line.strip()]
    except OSError:
        return []


# The server's feeds are never started here: stub the state builder so SSE
# pushes are cheap and deterministic.
_srv.get_state_with_board = lambda: {"computed": {"agents": [], "needsYou": []}}

main_server = _srv.QuietThreadingHTTPServer(("127.0.0.1", MAIN_PORT), _srv.Handler)
main_server.remote_listener = False
threading.Thread(target=main_server.serve_forever, daemon=True).start()
remote_server = _srv._start_remote_listener()
check("remote listener started", remote_server is not None, True)
time.sleep(0.2)
store = hook_permissions.STORE

print("== presence: only the answering web UI's stream counts ==")
agentbar_presence.PRESENCE = agentbar_presence.AgentBarPresence()
store._presence = agentbar_presence.PRESENCE
sse_client(REMOTE_PORT, "", AUTH).join()
check("remote SSE without answerSurface (old PWA build) -> not a surface",
      agentbar_presence.PRESENCE.seconds_since_seen(), None)
sse_client(REMOTE_PORT, "?answerSurface=web", {}).join()
check("unauthenticated remote SSE with the param -> not a surface",
      agentbar_presence.PRESENCE.seconds_since_seen(), None)
sse_client(REMOTE_PORT, "?answerSurface=web", AUTH).join()
check("authenticated phone SSE ?answerSurface=web -> connected",
      agentbar_presence.PRESENCE.is_connected(), True)
agentbar_presence.PRESENCE = agentbar_presence.AgentBarPresence()
store._presence = agentbar_presence.PRESENCE
sse_client(MAIN_PORT, "?answerSurface=web", {}).join()
check("local browser tab of the web UI -> connected too",
      agentbar_presence.PRESENCE.is_connected(), True)

print("== a prompt is held with ONLY the phone connected ==")
agentbar_presence.PRESENCE = agentbar_presence.AgentBarPresence()
store._presence = agentbar_presence.PRESENCE
held = store.register(hook_payload("sess-phone"), (), desktop_entry("sess-phone"))
check("no surface at all -> ignored, retryable (hook re-sends)",
      (held.get("state"), held.get("retryable")), ("ignored", True))
phone_stream = sse_client(REMOTE_PORT, "?answerSurface=web", AUTH)
phone_stream.join()
held = store.register(hook_payload("sess-phone"), (), desktop_entry("sess-phone"))
request_id = held.get("requestId")
check("phone connected -> held", bool(request_id), True)

print("== remote listener: register / wait stay local-only ==")
status, body = request(REMOTE_PORT, "POST", "/api/hook/permission", hook_payload("x"), AUTH)
check("remote register -> 404 route", (status, body), (404, {"error": "not found"}))
status, body = request(REMOTE_PORT, "GET", f"/api/hook/permission/{request_id}/wait?timeout=0",
                       headers=AUTH)
check("remote wait -> 404 route", (status, body), (404, {"error": "not found"}))

print("== remote listener: answer = authenticated, CSRF-checked, audited ==")
answer_path = f"/api/hook/permission/{request_id}/answer"
answer_body = {"behavior": "allow", "answers": {"Ship it?": "Yes"}}
status, _ = request(REMOTE_PORT, "POST", answer_path, answer_body)
check("unauthenticated -> 401", status, 401)
status, _ = request(REMOTE_PORT, "POST", answer_path, answer_body,
                    dict(AUTH, Origin="https://evil.example"))
check("foreign Origin -> 403", status, 403)
check("still pending after the refusals", store._requests[request_id].state, "pending")
status, body = request(REMOTE_PORT, "POST", answer_path, {"behavior": "allow", "answers": {}},
                       dict(AUTH, **SAME_ORIGIN))
check("bad answer -> 400 with the reason", (status, "exactly these questions" in body.get("error", "")),
      (400, True))
status, body = request(REMOTE_PORT, "POST", answer_path, answer_body, dict(AUTH, **SAME_ORIGIN))
check("phone answer -> 200 answered", (status, body), (200, {"ok": True, "state": "answered"}))
check("the hook's decision is the phone's answer",
      store._requests[request_id].decision["updatedInput"]["answers"], {"Ship it?": "Yes"})
status, body = request(REMOTE_PORT, "POST", answer_path, answer_body, dict(AUTH, **SAME_ORIGIN))
check("second answer -> 409 first decision wins", status, 409)
status, body = request(REMOTE_PORT, "POST", "/api/hook/permission/hp-none/answer",
                       answer_body, dict(AUTH, **SAME_ORIGIN))
check("unknown request -> store 404 (not the route 404)", (status, body.get("error")),
      (404, "unknown request"))
entries = [e for e in audit_lines() if e["route"] == answer_path]
check("every remote answer attempt audited (401, 403, 400, 200, 409)",
      [e["status"] for e in entries], [401, 403, 400, 200, 409])
check("audit row names the request id", entries[-1]["rowId"], request_id)

main_server.shutdown()
if remote_server is not None:
    remote_server.shutdown()

print()
if fails:
    print(f"FAIL: {len(fails)} failure(s)")
    for f in fails:
        print("  - " + f)
    sys.exit(1)
print("PASS: all web-remote hook answer checks")
