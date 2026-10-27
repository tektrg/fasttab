#!/usr/bin/env python3
"""Account add/remove (server/lib/account_edit.py) + its HTTP routes on port 4735.

SAFETY: Keychain and herdr are fakes (never the real Keychain, never a real
pane); accounts.json and config dirs live in a temp dir.
"""
import contextlib
import http.client
import importlib.util
import io
import json
import os
import sys
import tempfile
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
DASHBOARD_DIR = os.path.dirname(HERE)
_tmp = tempfile.mkdtemp(prefix="account-edit-test-")
CONFIG_HOME = os.path.join(_tmp, "config")
os.makedirs(CONFIG_HOME)
ACCOUNTS_FILE = os.path.join(CONFIG_HOME, "accounts.json")
INSTANCES = os.path.join(_tmp, "instances")
os.environ.update({
    "CHIEF_DASHBOARD_CONFIG_HOME": CONFIG_HOME,
    "CHIEF_DASHBOARD_STATE_HOME": os.path.join(_tmp, "state"),
    "CHIEF_DASHBOARD_MACHINES": "{}", "CHIEF_HERDR_BIN": os.path.join(_tmp, "no-such-herdr"),
    "AGENTBAR_PERSONAS_FILE": os.path.join(_tmp, "no-personas.json"),
    "CLAUDE_ROUTER_PORT": "1", "CLAUDE_ROUTER_ACCOUNTS": ACCOUNTS_FILE,
    "ACCOUNT_LOGIN_CLAUDE_BIN": "/opt/claude",
})
sys.path.insert(0, os.path.join(DASHBOARD_DIR, "server", "lib"))
import account_edit as edit  # noqa: E402

SECRET = "sk-SENTINEL-TOKEN-0042"
fails = []


def check(label, got, want):
    if got != want:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if got == want else 'FAIL'}  {label}")


class FakeKeychain:
    def __init__(self, ok=True):
        self.ok, self.items, self.deleted = ok, {}, []

    def store(self, service, token):
        if self.ok:
            self.items[service] = token
        return self.ok

    def delete(self, service):
        self.deleted.append(service)
        return self.items.pop(service, None) is not None


class FakeOps:
    def __init__(self):
        self.calls = []

    def find_tab(self, label):
        self.calls.append(("find", label))

    def create_tab(self, label):
        self.calls.append(("create", label))
        return "t7", "w1:p7"

    def wait_ready(self, pane_id):
        self.calls.append(("wait", pane_id))

    def busy(self, pane_id):
        return False

    def run(self, pane_id, command):
        self.calls.append(("run", pane_id, command))


def file_text():
    with open(ACCOUNTS_FILE) as f:
        return f.read()


with open(ACCOUNTS_FILE, "w") as f:
    json.dump({"autoResume": False, "extra": {"k": 1}, "accounts": [
        {"id": "aptus", "kind": "proxy", "baseUrl": "http://x", "custom": "keep"}]}, f)

print("\n== slug ==")
check("slug", edit.slug_id("Work Max!", set()), "work-max")
check("unique", edit.slug_id("Work Max", {"work-max", "work-max-2"}), "work-max-3")
check("empty -> account", edit.slug_id("!!!", set()), "account")

print("\n== add-subscription ==")
ops = FakeOps()
reply = edit.add_subscription({"label": "Work Max"}, ops=ops, instances_dir=INSTANCES)
check("ok + tab", (reply["ok"], reply["tab"]), (True, "t7"))
check("row", reply["account"], {"id": "work-max", "label": "Work Max", "kind": "login",
                                "tier": "claude", "configDir": os.path.join(INSTANCES, "work-max")})
check("dir created", os.path.isdir(os.path.join(INSTANCES, "work-max")), True)
check("login tab label", ops.calls[1], ("create", "claude-login-work-max"))
reply = edit.add_subscription({"label": "Work Max"}, ops=FakeOps(), instances_dir=INSTANCES)
check("second gets unique id", reply["account"]["id"], "work-max-2")
check("missing label", edit.add_subscription({}, ops=FakeOps())["ok"], False)
doc = json.loads(file_text())
check("other keys kept", (doc["autoResume"], doc["extra"]), (False, {"k": 1}))
check("order + unknown keys kept", [(r["id"], r.get("custom")) for r in doc["accounts"]],
      [("aptus", "keep"), ("work-max", None), ("work-max-2", None)])

print("\n== add-api ==")
kc = FakeKeychain()
good = {"label": "DeepSeek", "baseUrl": "https://api.deepseek.com/anthropic/", "token": SECRET,
        "model": "deepseek-chat", "tier": "fallback", "authHeader": "x-api-key"}
out = io.StringIO()
with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
    reply = edit.add_api(good, keychain=kc)
check("ok", reply["ok"], True)
check("row", reply["account"], {"id": "deepseek", "label": "DeepSeek", "kind": "apikey",
      "tier": "fallback", "needsApproval": True, "baseUrl": "https://api.deepseek.com/anthropic",
      "model": "deepseek-chat", "authHeader": "x-api-key", "tokenKeychain": "claude-router-deepseek"})
check("keychain got token", kc.items, {"claude-router-deepseek": SECRET})
check("token not in reply", SECRET in json.dumps(reply), False)
check("token not in file", SECRET in file_text(), False)
check("token not logged", SECRET in out.getvalue(), False)
check("claude tier no approval",
      edit.add_api(dict(good, label="Z", tier="claude"), keychain=kc)["account"]["needsApproval"], False)
for name, bad in [("http remote", {"baseUrl": "http://evil.com"}), ("no token", {"token": "  "}),
                  ("bad tier", {"tier": "x"}), ("bad header", {"authHeader": "basic"}),
                  ("no label", {"label": ""}), ("ftp", {"baseUrl": "ftp://a"})]:
    check(f"refused: {name}", edit.add_api(dict(good, **bad), keychain=FakeKeychain())["ok"], False)
check("http localhost ok", edit.add_api(dict(good, label="Local", baseUrl="http://127.0.0.1:9"),
                                        keychain=FakeKeychain())["ok"], True)
before = file_text()
reply = edit.add_api(dict(good, label="Fail"), keychain=FakeKeychain(ok=False))
check("keychain failure -> no row", (reply["ok"], file_text() == before), (False, True))

print("\n== remove ==")
reply = edit.remove({"id": "deepseek"}, keychain=kc)
check("removed + keychain deleted", (reply["ok"], reply.get("keychainDeleted")), (True, True))
check("gone from file", "deepseek\"" in file_text(), False)
reply = edit.remove({"id": "work-max"}, keychain=kc)
check("login row: folder kept + note", (os.path.isdir(os.path.join(INSTANCES, "work-max")),
                                        "left on disk" in reply.get("note", "")), (True, True))
check("login row: no keychain call", "keychainDeleted" in reply, False)
check("unknown id", edit.remove({"id": "nope"}, keychain=kc)["ok"], False)
check("missing id", edit.remove({}, keychain=kc)["ok"], False)

print("\n== HTTP routes on port 4735 ==")
_spec = importlib.util.spec_from_file_location(
    "chief_dashboard_server_edit_test", os.path.join(DASHBOARD_DIR, "server", "chief-dashboard-server.py"))
_srv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_srv)
route_kc, route_ops = FakeKeychain(), FakeOps()
_srv.account_edit.KeychainOps = lambda: route_kc
_srv.account_login.HerdrLoginOps = lambda: route_ops
_srv.account_edit.INSTANCES_DIR = INSTANCES
PORT = 4735
servers = []
for remote in (False, True):
    s = _srv.QuietThreadingHTTPServer(("127.0.0.1", PORT + (1 if remote else 0)), _srv.Handler)
    s.remote_listener = remote
    threading.Thread(target=s.serve_forever, daemon=True).start()
    servers.append(s)


def request(path, body, port=PORT, content_type="application/json"):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    data = json.dumps(body).encode()
    conn.request("POST", path, body=data, headers={"Content-Type": content_type,
                                                   "Content-Length": str(len(data))})
    resp = conn.getresponse()
    raw = resp.read()
    conn.close()
    return resp.status, raw.decode()


log = io.StringIO()
with contextlib.redirect_stderr(log), contextlib.redirect_stdout(log):
    status, raw = request("/api/accounts/add-api", dict(good, label="Route"))
    reply = json.loads(raw)
    check("route add-api ok", (status, reply["ok"], reply["account"]["id"]), (200, True, "route"))
    check("route reply has no token", SECRET in raw, False)
    status, raw = request("/api/accounts/add-subscription", {"label": "Personal"})
    check("route add-subscription", (json.loads(raw)["ok"], json.loads(raw)["tab"]), (True, "t7"))
    status, raw = request("/api/accounts/remove", {"id": "route"})
    check("route remove", json.loads(raw)["keychainDeleted"], True)
    status, _ = request("/api/accounts/add-api", good, content_type="text/plain")
    check("non-JSON refused", status, 400)
    for p in ("/api/accounts/add-api", "/api/accounts/add-subscription", "/api/accounts/remove"):
        status, raw = request(p, dict(good, id="aptus"), port=PORT + 1)
        check(f"remote listener refuses {p}", status in (401, 403), True)
check("token not in server log", SECRET in log.getvalue(), False)
check("token not in file (end)", SECRET in file_text(), False)
check("aptus survived", json.loads(file_text())["accounts"][0]["id"], "aptus")

for s in servers:
    s.shutdown()
if fails:
    print("\n".join(["FAILURES:"] + fails))
    sys.exit(1)
print("ALL PASS")
