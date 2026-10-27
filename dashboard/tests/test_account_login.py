#!/usr/bin/env python3
"""Account login (server/lib/account_login.py): the login command, the
loggedIn detection, start_login with fake herdr ops, and the
POST /api/accounts/login + GET /api/accounts routes on port 4734.

SAFETY: no herdr, no real pane, no real login. `security` is stubbed for the
detection checks; config dirs live in a temp dir.
"""
import http.client
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
DASHBOARD_DIR = os.path.dirname(HERE)
_tmp = tempfile.mkdtemp(prefix="account-login-test-")
CONFIG_HOME = os.path.join(_tmp, "config")
os.makedirs(CONFIG_HOME)
os.environ.update({
    "CHIEF_DASHBOARD_CONFIG_HOME": CONFIG_HOME,
    "CHIEF_DASHBOARD_STATE_HOME": os.path.join(_tmp, "state"),
    "CHIEF_DASHBOARD_MACHINES": "{}", "CHIEF_HERDR_BIN": os.path.join(_tmp, "no-such-herdr"),
    "AGENTBAR_PERSONAS_FILE": os.path.join(_tmp, "no-personas.json"),
    "CLAUDE_ROUTER_PORT": "1",  # nothing listens: router down
    "ACCOUNT_LOGIN_CLAUDE_BIN": "/opt/claude bin/claude",
})
sys.path.insert(0, os.path.join(DASHBOARD_DIR, "server", "lib"))
import account_login as login  # noqa: E402

fails = []


def check(label, got, want):
    if got != want:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if got == want else 'FAIL'}  {label}")


SUB_DIR = os.path.join(_tmp, "sub dir")
os.makedirs(SUB_DIR)
ACCOUNTS_FILE = os.path.join(CONFIG_HOME, "accounts.json")
with open(ACCOUNTS_FILE, "w") as f:
    json.dump({"accounts": [
        {"id": "aptus", "kind": "proxy", "baseUrl": "http://x"},
        {"id": "sub", "label": "Sub", "kind": "login", "configDir": SUB_DIR},
    ]}, f)
os.environ["CLAUDE_ROUTER_ACCOUNTS"] = ACCOUNTS_FILE

print("\n== login command ==")
check("command shape", login.login_command("/d x"),
      "env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_MODEL "
      "CLAUDE_CONFIG_DIR='/d x' '/opt/claude bin/claude' /login")
check("injection stays quoted", "'$(echo INJECTED)'" in login.login_command("$(echo INJECTED)"), True)

print("\n== loggedIn detection ==")
check("default dir service", login.keychain_service("~/.claude"), "Claude Code-credentials")
check("hashed service", login.keychain_service("/Users/a/.claude-instances/x"),
      "Claude Code-credentials-" + __import__("hashlib").sha256(
          b"/Users/a/.claude-instances/x").hexdigest()[:8])
seen = []


def fake_security(code):
    def run(argv, **kw):
        seen.append(argv)
        return subprocess.CompletedProcess(argv, code)
    return run


check("keychain hit -> True", login.logged_in(SUB_DIR, run=fake_security(0)), True)
check("never asks for the secret", any(a in ("-w", "-g") for a in seen[-1]), False)
check("not found (44) -> False", login.logged_in(SUB_DIR, run=fake_security(44)), False)
check("other error -> None", login.logged_in(SUB_DIR, run=fake_security(1)), None)


def broken(*a, **kw):
    raise OSError("no security")


check("no security tool -> None", login.logged_in(SUB_DIR, run=broken), None)
open(os.path.join(SUB_DIR, ".credentials.json"), "w").close()
check(".credentials.json -> True", login.logged_in(SUB_DIR, run=broken), True)
os.remove(os.path.join(SUB_DIR, ".credentials.json"))


class FakeOps:
    def __init__(self, existing=None, busy=False):
        self.existing, self.is_busy, self.calls = existing, busy, []

    def find_tab(self, label):
        self.calls.append(("find", label))
        return self.existing

    def create_tab(self, label):
        self.calls.append(("create", label))
        return "t9", "w1:p9"

    def wait_ready(self, pane_id):
        self.calls.append(("wait", pane_id))

    def busy(self, pane_id):
        return self.is_busy

    def run(self, pane_id, command):
        self.calls.append(("run", pane_id, command))


print("\n== start_login ==")
ops = FakeOps()
reply = login.start_login({"id": "sub"}, ops=ops)
check("new tab ok", reply, {"ok": True, "tab": "t9", "pane": "w1:p9", "reused": False})
check("new tab steps", [c[0] for c in ops.calls], ["find", "create", "wait", "run"])
check("tab label", ops.calls[1][1], "claude-login-sub")
check("typed login command", ops.calls[-1][2], login.login_command(SUB_DIR))
ops = FakeOps(existing=("t2", "w1:p2"))
reply = login.start_login({"id": "sub"}, ops=ops)
check("reuse idle tab", (reply["reused"], [c[0] for c in ops.calls]), (True, ["find", "run"]))
ops = FakeOps(existing=("t2", "w1:p2"), busy=True)
reply = login.start_login({"id": "sub"}, ops=ops)
check("busy tab not typed into", (reply["ok"], [c[0] for c in ops.calls]), (True, ["find"]))
check("proxy row refused", login.start_login({"id": "aptus"}, ops=FakeOps())["ok"], False)
check("unknown id refused", login.start_login({"id": "nope"}, ops=FakeOps())["error"],
      "unknown account 'nope'")
check("missing id refused", login.start_login({}, ops=FakeOps())["error"], "missing id")

print("\n== start_pool_login ==")
ops = FakeOps()
check("pool login ok", login.start_pool_login({}, ops=ops)["ok"], True)
check("pool tab + command", (ops.calls[1][1], ops.calls[-1][2]),
      ("cliproxy-login", login.POOL_LOGIN_COMMAND))


class FailingOps(FakeOps):
    def create_tab(self, label):
        raise RuntimeError("herdr down")


check("herdr failure -> error", login.start_login({"id": "sub"}, ops=FailingOps()),
      {"ok": False, "error": "herdr: herdr down"})

print("\n== HTTP routes on port 4734 ==")
_spec = importlib.util.spec_from_file_location(
    "chief_dashboard_server_login_test", os.path.join(DASHBOARD_DIR, "server", "chief-dashboard-server.py"))
_srv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_srv)
route_ops = FakeOps()
_srv.account_login.HerdrLoginOps = lambda: route_ops
PORT = 4734
dash = _srv.QuietThreadingHTTPServer(("127.0.0.1", PORT), _srv.Handler)
dash.remote_listener = False
threading.Thread(target=dash.serve_forever, daemon=True).start()


def request(method, path, body=None, content_type="application/json"):
    conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=5)
    data = json.dumps(body).encode() if body is not None else b""
    conn.request(method, path, body=data, headers={"Content-Type": content_type,
                                                     "Content-Length": str(len(data))})
    resp = conn.getresponse()
    out = resp.status, json.loads(resp.read() or b"{}")
    conn.close()
    return out


status, reply = request("POST", "/api/accounts/login", {"id": "sub"})
check("route ok", (status, reply.get("ok"), reply.get("tab")), (200, True, "t9"))
check("route typed once", [c[0] for c in route_ops.calls].count("run"), 1)
status, reply = request("POST", "/api/accounts/login", {"id": "aptus"})
check("route refuses proxy row", reply["ok"], False)
status, reply = request("POST", "/api/accounts/login", {"id": "sub"}, content_type="text/plain")
check("non-JSON content type refused", status, 400)
status, view = request("GET", "/api/accounts")
rows = {a["id"]: a for a in view["accounts"]}
check("login row has loggedIn bool/None", rows["sub"].get("loggedIn") in (True, False, None)
      and "loggedIn" in rows["sub"], True)
check("proxy row has no loggedIn", "loggedIn" in rows["aptus"], False)

dash.shutdown()
if fails:
    print("\n".join(["FAILURES:"] + fails))
    sys.exit(1)
print("ALL PASS")
