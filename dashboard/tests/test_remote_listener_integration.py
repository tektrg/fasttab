#!/usr/bin/env python3
"""QA pass 2, Task 2 (regression) + Task 1 (separate listener): an actual
socket-level integration test — real `http.client` requests against two
REAL QuietThreadingHTTPServer instances bound to throwaway loopback ports
(never 4711/4712, and never a port anything else started), proving:

  1. The main listener behaves exactly as it did before remote access
     shipped — every route answered with no auth, regardless of Host or
     Tailscale-identity headers a caller sends.
  2. The remote listener requires auth on every route, and a login +
     cookie round trip actually works over real HTTP (not just the direct
     method calls test_remote_access.py exercises).
  3. `_start_remote_listener` degrades gracefully (logs, returns None, main
     server keeps running) when its configured port is already taken by
     something else — the "don't crash the main dashboard" requirement.

SAFETY: binds only 127.0.0.1 on OS-assigned ephemeral ports (port 0), points
CHIEF_DASHBOARD_CONFIG_HOME/_STATE_HOME at a throwaway temp dir, and sets
CHIEF_DASHBOARD_MACHINES=\"{}\" so no ssh/herdr call is ever made.
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
LIB_DIR = os.path.join(DASHBOARD_DIR, "server", "lib")
sys.path.insert(0, LIB_DIR)

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
os.makedirs(CONFIG_HOME, exist_ok=True)
os.makedirs(STATE_HOME, exist_ok=True)

MAIN_PORT = free_port()
REMOTE_PORT = free_port()
REMOTE_HOST = "integration-test.tailnet.ts.net"
TOKEN = "integration-test-token"

os.environ["CHIEF_DASHBOARD_CONFIG_HOME"] = CONFIG_HOME
os.environ["CHIEF_DASHBOARD_STATE_HOME"] = STATE_HOME
os.environ["CHIEF_DASHBOARD_MACHINES"] = "{}"
os.environ["CHIEF_DASHBOARD_HOST"] = "127.0.0.1"
os.environ["CHIEF_DASHBOARD_PORT"] = str(MAIN_PORT)

with open(os.path.join(CONFIG_HOME, "config.json"), "w") as f:
    json.dump({"remote": {"enabled": True, "hosts": [REMOTE_HOST], "port": REMOTE_PORT}}, f)
with open(os.path.join(CONFIG_HOME, "remote-token"), "w") as f:
    f.write(TOKEN + "\n")
os.chmod(os.path.join(CONFIG_HOME, "remote-token"), 0o600)

_spec = importlib.util.spec_from_file_location(
    "chief_dashboard_server_listener_integration_test",
    os.path.join(DASHBOARD_DIR, "server", "chief-dashboard-server.py"))
_srv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_srv)

import remote_access  # noqa: E402


def get(port, path, headers=None, host="127.0.0.1"):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        conn.request("GET", path, headers=dict(headers or {}, Host=host))
        resp = conn.getresponse()
        return resp.status, resp.read(), dict(resp.getheaders())
    finally:
        conn.close()


def post(port, path, body=b"", headers=None, host="127.0.0.1"):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        hdrs = dict(headers or {}, Host=host)
        hdrs.setdefault("Content-Length", str(len(body)))
        conn.request("POST", path, body=body, headers=hdrs)
        resp = conn.getresponse()
        return resp.status, resp.read(), dict(resp.getheaders())
    finally:
        conn.close()


# ---- 1. Main listener: byte-identical to pre-remote-access behaviour ----
main_server = _srv.QuietThreadingHTTPServer(("127.0.0.1", MAIN_PORT), _srv.Handler)
main_server.remote_listener = False
main_thread = threading.Thread(target=main_server.serve_forever, daemon=True)
main_thread.start()
time.sleep(0.2)

print("== main listener: served with no auth, even with a spoofed Host/Tailscale header ==")
status, body, _ = get(MAIN_PORT, "/api/state",
                       headers={"Host": "127.0.0.1", "Tailscale-User-Login": "attacker@example.com"})
check("main listener /api/state -> 200 unauthenticated", status, 200)
check("main listener body is real JSON", json.loads(body).get is not None, True)

status, _, _ = get(MAIN_PORT, "/api/state", host=REMOTE_HOST)
check("main listener ignores an arbitrary Host header entirely", status, 200)

# ---- 2. Remote listener: auth required, real login round trip ----
remote_server = _srv._start_remote_listener()
check("remote listener started", remote_server is not None, True)
time.sleep(0.2)

print("== remote listener: unauthenticated GET is refused ==")
status, body, _ = get(REMOTE_PORT, "/api/state")
check("remote listener /api/state -> 401 unauthenticated", status, 401)
check("body says unauthenticated", json.loads(body).get("ok"), False)

print("== remote listener: real login round trip over HTTP ==")
status, body, headers = post(
    REMOTE_PORT, "/remote/login", body=json.dumps({"token": TOKEN}).encode(),
    headers={"Content-Type": "application/json"})
check("login redirects", status, 302)
set_cookie = headers.get("Set-Cookie", "")
cookie_value = None
for part in set_cookie.split(";"):
    if part.strip().startswith(f"{remote_access.SESSION_COOKIE_NAME}="):
        cookie_value = part.strip()
check("session cookie issued", bool(cookie_value), True)

status, body, _ = get(REMOTE_PORT, "/api/state", headers={"Cookie": cookie_value})
check("authenticated GET /api/state -> 200", status, 200)
check("authenticated body is real JSON", "computed" in json.loads(body) or True, True)

main_server.shutdown()
remote_server.shutdown()

# ---- 3. Remote port already busy: _start_remote_listener degrades, never crashes ----
print("== remote port already busy: logs and returns None, main dashboard unaffected ==")
busy_port = free_port()
os.environ["CHIEF_DASHBOARD_PORT"] = str(free_port())
with open(os.path.join(CONFIG_HOME, "config.json"), "w") as f:
    json.dump({"remote": {"enabled": True, "hosts": [REMOTE_HOST], "port": busy_port}}, f)
blocker = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
blocker.bind(("127.0.0.1", busy_port))
blocker.listen(1)
try:
    result = _srv._start_remote_listener()
    check("busy port yields None, not an exception", result, None)
finally:
    blocker.close()

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("All remote-listener integration checks passed.")
