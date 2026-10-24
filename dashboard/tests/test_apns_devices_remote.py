#!/usr/bin/env python3
"""APNs device registry on the REMOTE listener (iOS app registers its token):
real requests against a REAL remote listener on a throwaway loopback port:
unauthenticated register/unregister -> 401 and nothing stored; with the
Bearer token -> stored (0600) and removed.

SAFETY: 127.0.0.1 only, OS-assigned ports, throwaway CONFIG/STATE homes.
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
REMOTE_HOST = "apns-remote-test.tailnet.ts.net"
TOKEN = "apns-remote-test-token"
os.environ.update({
    "CHIEF_DASHBOARD_CONFIG_HOME": CONFIG_HOME,
    "CHIEF_DASHBOARD_STATE_HOME": STATE_HOME,
    "CHIEF_DASHBOARD_MACHINES": "{}",
    "CHIEF_DASHBOARD_HOST": "127.0.0.1",
    "CHIEF_DASHBOARD_PORT": str(MAIN_PORT),
    "AGENTBAR_APNS_DEVICES_FILE": os.path.join(CONFIG_HOME, "apns-devices.json"),
    "AGENTBAR_PERSONAS_FILE": os.path.join(_tmp.name, "no-personas.json"),
})
with open(os.path.join(CONFIG_HOME, "config.json"), "w") as f:
    json.dump({"remote": {"enabled": True, "hosts": [REMOTE_HOST], "port": REMOTE_PORT}}, f)
with open(os.path.join(CONFIG_HOME, "remote-token"), "w") as f:
    f.write(TOKEN + "\n")
os.chmod(os.path.join(CONFIG_HOME, "remote-token"), 0o600)

_spec = importlib.util.spec_from_file_location(
    "chief_dashboard_server_apns_remote_test",
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


DEVICE = "c" * 64
DEVICES_FILE = os.path.join(CONFIG_HOME, "apns-devices.json")
_srv.get_state_with_board = lambda: {"computed": {"agents": [], "needsYou": []}}
remote_server = _srv._start_remote_listener()
check("remote listener started", remote_server is not None, True)
time.sleep(0.2)

print("== unauthenticated ==")
status, _ = request(REMOTE_PORT, "POST", "/api/apns/devices", {"deviceToken": DEVICE})
check("register without auth -> 401", status, 401)
check("nothing stored", os.path.exists(DEVICES_FILE), False)
status, _ = request(REMOTE_PORT, "DELETE", "/api/apns/devices", {"deviceToken": DEVICE})
check("unregister without auth -> 401", status, 401)

print("== authenticated ==")
status, body = request(REMOTE_PORT, "POST", "/api/apns/devices", {"deviceToken": DEVICE, "label": "iPhone"}, AUTH)
check("register with token -> 200", (status, body), (200, {"ok": True}))
with open(DEVICES_FILE) as f:
    check("stored", list(json.load(f)), [DEVICE])
check("file mode 0600", os.stat(DEVICES_FILE).st_mode & 0o777, 0o600)
status, _ = request(REMOTE_PORT, "POST", "/api/apns/devices", {"deviceToken": DEVICE}, dict(AUTH, Origin="https://evil.example"))
check("foreign Origin -> 403", status, 403)
status, body = request(REMOTE_PORT, "DELETE", "/api/apns/devices", {"deviceToken": DEVICE}, AUTH)
check("unregister -> removed", (status, body), (200, {"ok": True, "removed": True}))

remote_server.shutdown()
if fails:
    print("\n".join(["FAILURES:"] + fails))
    sys.exit(1)
print("ALL PASS")
