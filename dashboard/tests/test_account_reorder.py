#!/usr/bin/env python3
"""POST /api/accounts/reorder (server/lib/account_edit.reorder) on port 4737.

SAFETY: accounts.json lives in a temp dir; no Keychain, no herdr.
"""
import http.client
import importlib.util
import json
import os
import sys
import tempfile
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
DASHBOARD_DIR = os.path.dirname(HERE)
_tmp = tempfile.mkdtemp(prefix="account-reorder-test-")
CONFIG_HOME = os.path.join(_tmp, "config")
os.makedirs(CONFIG_HOME)
ACCOUNTS_FILE = os.path.join(CONFIG_HOME, "accounts.json")
os.environ.update({
    "CHIEF_DASHBOARD_CONFIG_HOME": CONFIG_HOME,
    "CHIEF_DASHBOARD_STATE_HOME": os.path.join(_tmp, "state"),
    "CHIEF_DASHBOARD_MACHINES": "{}", "CHIEF_HERDR_BIN": os.path.join(_tmp, "no-such-herdr"),
    "AGENTBAR_PERSONAS_FILE": os.path.join(_tmp, "no-personas.json"),
    "CLAUDE_ROUTER_PORT": "1", "CLAUDE_ROUTER_ACCOUNTS": ACCOUNTS_FILE,
})
sys.path.insert(0, os.path.join(DASHBOARD_DIR, "server", "lib"))
import account_edit as edit  # noqa: E402

fails = []


def check(label, got, want):
    if got != want:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if got == want else 'FAIL'}  {label}")


def seed():
    with open(ACCOUNTS_FILE, "w") as f:
        json.dump({"autoResume": False, "accounts": [
            {"id": "a", "kind": "login", "configDir": "~/x"},
            {"id": "b", "kind": "apikey", "needsApproval": True, "extra": 1},
            {"id": "c", "kind": "proxy"}]}, f)


def ids():
    with open(ACCOUNTS_FILE) as f:
        return [r["id"] for r in json.load(f)["accounts"]]


print("== reorder() ==")
seed()
check("reorder ok", edit.reorder({"ids": ["c", "b", "a"]})["ok"], True)
check("new order", ids(), ["c", "b", "a"])
doc = json.load(open(ACCOUNTS_FILE))
check("other keys kept", (doc["autoResume"], doc["accounts"][1]["extra"]), (False, 1))
check("login below needsApproval allowed", edit.reorder({"ids": ["b", "a", "c"]})["ok"], True)
for label, bad in (("missing id", ["a", "b"]), ("unknown id", ["a", "b", "z"]),
                   ("duplicate", ["a", "a", "b"]), ("not list", "a,b,c"), ("non-string", [1, 2, 3])):
    check(f"refused: {label}", edit.reorder({"ids": bad})["ok"], False)
check("file unchanged after refusals", ids(), ["b", "a", "c"])
check("no ids", edit.reorder({})["ok"], False)

print("\n== HTTP route on port 4737 ==")
_spec = importlib.util.spec_from_file_location(
    "chief_dashboard_server_reorder_test", os.path.join(DASHBOARD_DIR, "server", "chief-dashboard-server.py"))
_srv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_srv)
PORT = 4737
servers = []
for remote in (False, True):
    s = _srv.QuietThreadingHTTPServer(("127.0.0.1", PORT + (1 if remote else 0)), _srv.Handler)
    s.remote_listener = remote
    threading.Thread(target=s.serve_forever, daemon=True).start()
    servers.append(s)


def request(body, port=PORT):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    data = json.dumps(body).encode()
    conn.request("POST", "/api/accounts/reorder", body=data,
                 headers={"Content-Type": "application/json", "Content-Length": str(len(data))})
    resp = conn.getresponse()
    raw = resp.read()
    conn.close()
    return resp.status, raw.decode()


status, raw = request({"ids": ["a", "b", "c"]})
check("route ok", (status, json.loads(raw)["ok"]), (200, True))
check("route wrote order", ids(), ["a", "b", "c"])
status, _ = request({"ids": ["c", "b", "a"]}, port=PORT + 1)
check("remote listener refuses", status in (401, 403), True)
check("remote did not write", ids(), ["a", "b", "c"])

for s in servers:
    s.shutdown()
if fails:
    print("\n".join(["FAILURES:"] + fails))
    sys.exit(1)
