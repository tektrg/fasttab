#!/usr/bin/env python3
"""Message a Claude Desktop / CLI row (session_inbox.py) over real HTTP:
the phone's remote listener applies the same login + same-origin + audit
rules as every other remote write, and AgentBar's local listener works too.

SAFETY: 127.0.0.1 only, OS-assigned ports (never 4711/4712), throwaway
CONFIG/STATE homes, a temp sessions dir and a FAKE inbox socket; the "live
Claude pid" is this test process. No real session is ever reached.
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
SESSIONS = os.path.join(_tmp.name, "sessions")
for d in (CONFIG_HOME, STATE_HOME, SESSIONS):
    os.makedirs(d)
SOCKET_PATH = os.path.join(_tmp.name, "s.sock")
MAIN_PORT, REMOTE_PORT = free_port(), free_port()
REMOTE_HOST = "inbox-remote-test.tailnet.ts.net"
REMOTE_TOKEN = "inbox-remote-test-token"
PEER_TOKEN = "peer-token-SENTINEL-remote"
SESSION_ID = "sess-remote-inbox"
os.environ.update({
    "CHIEF_DASHBOARD_CONFIG_HOME": CONFIG_HOME,
    "CHIEF_DASHBOARD_STATE_HOME": STATE_HOME,
    "CHIEF_DASHBOARD_MACHINES": "{}",
    "CHIEF_DASHBOARD_HOST": "127.0.0.1",
    "CHIEF_DASHBOARD_PORT": str(MAIN_PORT),
    "CLAUDE_SESSIONS_DIR": SESSIONS,
    "AGENTBAR_PERSONAS_FILE": os.path.join(_tmp.name, "no-personas.json"),
})
with open(os.path.join(CONFIG_HOME, "config.json"), "w") as f:
    json.dump({"remote": {"enabled": True, "hosts": [REMOTE_HOST], "port": REMOTE_PORT}}, f)
with open(os.path.join(CONFIG_HOME, "remote-token"), "w") as f:
    f.write(REMOTE_TOKEN + "\n")
os.chmod(os.path.join(CONFIG_HOME, "remote-token"), 0o600)
with open(os.path.join(SESSIONS, f"{os.getpid()}.json"), "w") as f:
    json.dump({"pid": os.getpid(), "sessionId": SESSION_ID, "kind": "interactive",
               "entrypoint": "cli", "status": "idle", "peerProtocol": 1,
               "messagingSocketPath": SOCKET_PATH}, f)
key_path = os.path.join(SESSIONS, f"{os.getpid()}.{'ab' * 32}.key")
with open(key_path, "w") as f:
    json.dump({"peerToken": PEER_TOKEN}, f)
os.chmod(key_path, 0o600)

_spec = importlib.util.spec_from_file_location(
    "chief_dashboard_server_remote_inbox_test",
    os.path.join(DASHBOARD_DIR, "server", "chief-dashboard-server.py"))
_srv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_srv)

import claude_sessions  # noqa: E402
import remote_access  # noqa: E402

check("sessions dir is the temp one", claude_sessions.SESSIONS_DIR, SESSIONS)

received = []
listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
listener.bind(SOCKET_PATH)
listener.listen(8)


def serve_inbox():
    while True:
        try:
            conn, _ = listener.accept()
        except OSError:
            return
        buf = b""
        conn.settimeout(2)
        try:
            while buf.count(b"\n") < 2:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                buf += chunk
            while conn.recv(4096):
                pass  # a real session stays connected after accepting
        except OSError:
            pass
        conn.close()
        received.append([json.loads(line) for line in buf.decode().splitlines() if line])


threading.Thread(target=serve_inbox, daemon=True).start()

AGENT = {"paneId": None, "label": "cli-run", "cwd": "/x", "source": "claude-cli",
         "agentSession": SESSION_ID, "messageVia": "inbox", "sessionStatus": "idle",
         "hookState": "idle", "hasHookData": True}
_srv.get_full_state = lambda: {"computed": {"agents": [AGENT]}, "feeds": {}}
_srv.get_state_with_board = lambda: {"computed": {"agents": [AGENT], "needsYou": []}}
_srv._own_pane_cached = lambda ids: None
_srv._pane_run_raw = lambda *a, **k: (_ for _ in ()).throw(AssertionError("herdr touched"))

main_server = _srv.QuietThreadingHTTPServer(("127.0.0.1", MAIN_PORT), _srv.Handler)
main_server.remote_listener = False
threading.Thread(target=main_server.serve_forever, daemon=True).start()
remote_server = _srv._start_remote_listener()
check("remote listener started", remote_server is not None, True)
time.sleep(0.2)

AUTH = {"Authorization": f"Bearer {REMOTE_TOKEN}"}
SAME_ORIGIN = {"Origin": f"https://{REMOTE_HOST}"}
PATH = "/api/session/message"


def post(port, body, headers=None):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    data = json.dumps(body).encode()
    hdrs = dict(headers or {}, Host="127.0.0.1")
    hdrs.update({"Content-Type": "application/json", "Content-Length": str(len(data))})
    try:
        conn.request("POST", PATH, body=data, headers=hdrs)
        resp = conn.getresponse()
        raw = resp.read()
        return resp.status, json.loads(raw or b"{}"), raw
    finally:
        conn.close()


def wait_received(count):
    deadline = time.monotonic() + 3
    while len(received) < count and time.monotonic() < deadline:
        time.sleep(0.02)


def audit_lines():
    try:
        with open(remote_access.AUDIT_LOG_PATH) as f:
            return [json.loads(line) for line in f if line.strip()]
    except OSError:
        return []


BODY = {"rowId": SESSION_ID, "actor": "po", "text": "from the phone"}
print("== remote listener: auth, CSRF, audit ==")
status, _body, _raw = post(REMOTE_PORT, BODY)
check("unauthenticated -> 401", status, 401)
status, _body, _raw = post(REMOTE_PORT, BODY, dict(AUTH, Origin="https://evil.example"))
check("foreign Origin -> 403", status, 403)
time.sleep(0.3)
check("nothing reached the inbox after the refusals", received, [])
status, body, raw = post(REMOTE_PORT, BODY, dict(AUTH, **SAME_ORIGIN))
wait_received(1)
check("authenticated same-origin -> sent", (status, body.get("ok"), body.get("state")),
      (200, True, "message sent"))
check("the fake inbox got exactly auth + message",
      received, [[{"type": "auth", "token": PEER_TOKEN},
                  {"type": "user", "message": {"role": "user", "content": "from the phone"}}]])
check("peer token not in the HTTP response", PEER_TOKEN.encode() in raw, False)
deadline = time.monotonic() + 3  # the audit line is written just after the reply
while len([e for e in audit_lines() if e["route"] == PATH]) < 3 and time.monotonic() < deadline:
    time.sleep(0.02)
entries = [e for e in audit_lines() if e["route"] == PATH]
check("every remote attempt audited (401, 403, 200)", [e["status"] for e in entries], [401, 403, 200])
check("audit row names the session row", entries[-1].get("rowId"), SESSION_ID)
check("audit row records the reply's ok (sent)", entries[-1].get("ok"), True)
check("a 401/403 gate refusal carries no reply ok", [e.get("ok") for e in entries[:2]], [None, None])
check("peer token not in the audit log", PEER_TOKEN in json.dumps(audit_lines()), False)

print("== local listener (AgentBar) ==")
status, body, _raw = post(MAIN_PORT, dict(BODY, text="from AgentBar"), {"X-AgentBar": "1"})
wait_received(2)
check("local send -> sent", (status, body.get("ok")), (200, True))
check("second message arrived", received[-1][1]["message"]["content"], "from AgentBar")
status, body, _raw = post(MAIN_PORT, dict(BODY, text="/compact"), {"X-AgentBar": "1"})
check("slash command refused, nothing more sent", (body.get("ok"), len(received)), (False, 2))

main_server.shutdown()
if remote_server is not None:
    remote_server.shutdown()
listener.close()

print()
if fails:
    print(f"FAIL: {len(fails)} failure(s)")
    for f in fails:
        print("  - " + f)
    sys.exit(1)
print("PASS: all remote inbox message checks")
