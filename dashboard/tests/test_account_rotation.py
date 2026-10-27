#!/usr/bin/env python3
"""Account rotation (server/lib/account_rotation.py + classify_pane.limit_wall):
limit-wall detection, next-account choice, transcript copy, the resume
command, guards, and the /api/accounts routes on a throwaway port.

SAFETY: no herdr, no real pane, no real API. Pane ops are recorders; the
router is a fake on an OS-assigned loopback port; config/state/config dirs
live in a temp dir.
"""
import http.client
import http.server
import importlib.util
import json
import os
import socket
import sys
import tempfile
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
DASHBOARD_DIR = os.path.dirname(HERE)
FIXTURES = os.path.join(HERE, "fixtures", "limit-walls")
_tmp = tempfile.mkdtemp(prefix="account-rotation-test-")
CONFIG_HOME = os.path.join(_tmp, "config")
STATE_HOME = os.path.join(_tmp, "state")
os.makedirs(CONFIG_HOME)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


ROUTER_PORT = free_port()
os.environ.update({
    "CHIEF_DASHBOARD_CONFIG_HOME": CONFIG_HOME, "CHIEF_DASHBOARD_STATE_HOME": STATE_HOME,
    "CHIEF_DASHBOARD_MACHINES": "{}", "CHIEF_HERDR_BIN": os.path.join(_tmp, "no-such-herdr"),
    "AGENTBAR_PERSONAS_FILE": os.path.join(_tmp, "no-personas.json"),
    "CLAUDE_ROUTER_PORT": str(ROUTER_PORT),
})
sys.path.insert(0, os.path.join(DASHBOARD_DIR, "server", "lib"))
import account_rotation as rot  # noqa: E402
import classify_pane  # noqa: E402

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def fixture(name):
    with open(os.path.join(FIXTURES, name)) as f:
        return f.read()


print("== limit wall detection ==")
for name, state, wall in [("usage_limit.txt", "CRASHED", True),
                          ("router_approval.txt", "CRASHED", True),
                          ("api_error_500.txt", "CRASHED", False),
                          ("wall_then_active.txt", "ACTIVE", False)]:
    text = fixture(name)
    check(f"{name}: state unchanged ({state})", classify_pane.classify(text)[0], state)
    check(f"{name}: limitWall={wall}", classify_pane.limit_wall(text), wall)
check("prose about limits: no wall",
      classify_pane.limit_wall("⏺ Note: you've hit your limit of retries.\n✻ Cooked for 5m 3s · done 3:13 PM\n"),
      False)

print("\n== next login account ==")
DEFAULT_DIR = os.path.join(_tmp, "dot-claude")
SUB_DIR = os.path.join(_tmp, "sub-code")
SUB2_DIR = os.path.join(_tmp, "sub2-code")
ACCOUNTS = [
    {"id": "aptus", "kind": "proxy", "tier": "claude", "baseUrl": "https://example.invalid",
     "tokenKeychain": "secret-service-name"},
    {"id": "ssvsub", "kind": "login", "tier": "claude", "configDir": SUB_DIR},
    {"id": "sub2", "kind": "login", "tier": "claude", "configDir": SUB2_DIR},
    {"id": "deepseek", "kind": "apikey", "tier": "fallback", "needsApproval": True,
     "baseUrl": "https://example.invalid"},
    {"id": "late-login", "kind": "login", "configDir": os.path.join(_tmp, "late")},
]
pick, _ = rot.next_login_account(ACCOUNTS, "default", {}, 100)
check("from default -> first login row", pick["id"], "ssvsub")
pick, _ = rot.next_login_account(ACCOUNTS, "ssvsub", {}, 100)
check("skips current", pick["id"], "sub2")
pick, why = rot.next_login_account(ACCOUNTS, "default", {"ssvsub": 200, "sub2": 200}, 100)
check("limited rows skipped; stops at needsApproval (never reaches late login)", pick, None)
check("reason names the approval tier", "needs approval" in why, True)
pick, _ = rot.next_login_account(ACCOUNTS, "default", {"ssvsub": 50}, 100)
check("expired limit is usable again", pick["id"], "ssvsub")

print("\n== current account + transcript copy ==")
SID = "11111111-2222-3333-4444-555555555555"
src_slug = os.path.join(DEFAULT_DIR, "projects", "-Users-x-proj")
os.makedirs(os.path.join(src_slug, SID, "subagents"))
with open(os.path.join(src_slug, SID + ".jsonl"), "w") as f:
    f.write('{"type":"user"}\n')
with open(os.path.join(src_slug, SID, "subagents", "a.jsonl"), "w") as f:
    f.write("{}\n")
cur = rot.current_account(SID, ACCOUNTS, DEFAULT_DIR)
check("session found under the default dir", cur[0], "default")
check("unknown session -> None", rot.current_account("nope", ACCOUNTS, DEFAULT_DIR), None)
check("path-ish session id refused", rot.find_transcript("../x", DEFAULT_DIR), None)

print("\n== resume command ==")
cmd = rot.resume_command("/Users/x/.claude-instances/ssv code", SID)
check("command", cmd,
      "env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_MODEL "
      "CLAUDE_CONFIG_DIR='/Users/x/.claude-instances/ssv code' claude --resume "
      f"{SID} --dangerously-skip-permissions")
check("hostile session id is quoted, not executed",
      "'$(echo INJECTED)'" in rot.resume_command("/d", "$(echo INJECTED)"), True)

print("\n== Rotator with recorded pane ops ==")
ACCOUNTS_FILE = os.path.join(CONFIG_HOME, "accounts.json")
with open(ACCOUNTS_FILE, "w") as f:
    json.dump({"accounts": ACCOUNTS}, f)
calls = []
busy = {"w1:p1": [123]}


def fake_stop(pane_id):
    calls.append(("stop", pane_id))
    busy[pane_id] = []


ops = {"stop": fake_stop, "busy": lambda p: busy.get(p, []),
       "type": lambda p, c: calls.append(("type", p, c))}
clock = [1000.0]
rotator = rot.Rotator(pane_ops=ops, default_dir=DEFAULT_DIR, accounts_file=ACCOUNTS_FILE,
                      state_path=os.path.join(STATE_HOME, "rot"), clock=lambda: clock[0])
ROW = {"paneId": "w1:p1", "agentSession": SID, "source": "herdr", "agentKind": "claude",
       "machine": "local", "limitWall": True}

done = rotator.on_screens([ROW])
check("auto: one resume", len(done), 1)
check("auto: to ssvsub", done[0]["toAccount"], "ssvsub")
check("stopped then typed", [c[0] for c in calls], ["stop", "type"])
check("typed the resume command into the pane", calls[-1][2], rot.resume_command(SUB_DIR, SID))
copied = os.path.join(SUB_DIR, "projects", "-Users-x-proj", SID + ".jsonl")
check("transcript copied into target dir", os.path.isfile(copied), True)
check("sibling dir copied", os.path.isfile(os.path.join(SUB_DIR, "projects", "-Users-x-proj", SID,
                                                        "subagents", "a.jsonl")), True)
check("source kept (copy, not move)", os.path.isfile(os.path.join(src_slug, SID + ".jsonl")), True)
check("default remembered limited", "default" in rotator.limits_view(), True)
check("limited memory persisted",
      os.path.isfile(os.path.join(STATE_HOME, "rot", "limited-until.json")), True)
with open(os.path.join(STATE_HOME, "rot", "log.jsonl")) as f:
    check("log line written", json.loads(f.readline())["event"], "resumed")

calls.clear()
check("same episode: no second auto resume", rotator.on_screens([ROW]), [])
check("no pane ops", calls, [])
rotator.on_screens([dict(ROW, limitWall=False)])
check("cleared wall ends the episode", rotator.open_episodes, set())
try:
    rotator.resume(ROW)
    check("cooldown refuses a quick manual resume", "no error", "error")
except RuntimeError as e:
    check("cooldown refuses a quick manual resume", "just resumed" in str(e), True)

clock[0] += rot.PANE_COOLDOWN_SEC + 1
os.utime(copied, (os.path.getmtime(copied) + 100,) * 2)  # the new account now writes newer
busy["w1:p1"] = [456]
done = rotator.on_screens([ROW])
check("second wall moves ssvsub -> sub2", done and done[0]["toAccount"], "sub2")

for label, row, want in [
    ("non-Claude pane refused", dict(ROW, paneId="w1:p9", agentKind="opencode"), "only Claude"),
    ("remote pane refused", dict(ROW, paneId="w1:p8", machine="air"), "this Mac only"),
    ("status-only row refused", dict(ROW, paneId="w1:p7", source="claude-desktop"), "herdr pane"),
]:
    calls.clear()
    try:
        rotator.resume(row)
        check(label, "no error", want)
    except RuntimeError as e:
        check(label, want in str(e), True)
    check(f"{label}: no pane ops", calls, [])

with open(ACCOUNTS_FILE, "w") as f:
    json.dump({"autoResume": False, "accounts": ACCOUNTS}, f)
check("autoResume false: auto path does nothing",
      rotator.on_screens([dict(ROW, paneId="w1:p5")]), [])

print("\n== HTTP routes on a throwaway port ==")


class FakeRouter(http.server.BaseHTTPRequestHandler):
    approved = []

    def log_message(self, *a):
        pass

    def _json(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._json(200, {"active": "aptus", "lastSwitch": None, "approvedFallback": None,
                         "pendingApproval": {"id": "deepseek", "label": "DeepSeek"},
                         "accounts": [{"id": "aptus", "cooldownUntil": 5.0, "cooldownSecondsLeft": 60}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        if body.get("id") != "deepseek":
            return self._json(400, {"error": "unknown fallback account"})
        FakeRouter.approved.append(body["id"])
        self._json(200, {"approved": body["id"]})


_spec = importlib.util.spec_from_file_location(
    "chief_dashboard_server_account_test", os.path.join(DASHBOARD_DIR, "server", "chief-dashboard-server.py"))
_srv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_srv)
_srv.ROTATOR = rotator
_srv._live_agent_rows = lambda: [dict(ROW, paneId="w1:p3", limitWall=False)]
busy["w1:p3"] = []
os.environ["CLAUDE_ROUTER_ACCOUNTS"] = ACCOUNTS_FILE
DASH_PORT = 4733
dash = _srv.QuietThreadingHTTPServer(("127.0.0.1", DASH_PORT), _srv.Handler)
dash.remote_listener = False
threading.Thread(target=dash.serve_forever, daemon=True).start()


def request(method, path, body=None):
    conn = http.client.HTTPConnection("127.0.0.1", DASH_PORT, timeout=5)
    data = json.dumps(body).encode() if body is not None else b""
    conn.request(method, path, body=data, headers={"Content-Type": "application/json",
                                                     "Content-Length": str(len(data))})
    resp = conn.getresponse()
    out = resp.status, json.loads(resp.read() or b"{}")
    conn.close()
    return out


status, view = request("GET", "/api/accounts")
check("router down -> 200, routerReachable false", (status, view["routerReachable"]), (200, False))
check("rows listed in order", [a["id"] for a in view["accounts"]], [a["id"] for a in ACCOUNTS])
check("no token fields", any("tokenKeychain" in a for a in view["accounts"]), False)
status, reply = request("POST", "/api/accounts/approve-fallback", {"id": "deepseek"})
check("approve with router down -> clear error", reply, {"ok": False, "error": "claude-router is not running"})

router = http.server.ThreadingHTTPServer(("127.0.0.1", ROUTER_PORT), FakeRouter)
threading.Thread(target=router.serve_forever, daemon=True).start()
status, view = request("GET", "/api/accounts")
check("router up -> reachable", view["routerReachable"], True)
check("pendingApproval passed through", view["pendingApproval"]["id"], "deepseek")
check("cooldown merged", view["accounts"][0]["cooldownSecondsLeft"], 60)
status, reply = request("POST", "/api/accounts/approve-fallback", {"id": "deepseek"})
check("approve proxied", (reply, FakeRouter.approved), ({"ok": True, "approved": "deepseek"}, ["deepseek"]))
status, reply = request("POST", "/api/accounts/approve-fallback", {"id": "bogus"})
check("router refusal surfaced", (reply["ok"], "unknown" in reply["error"]), (False, True))
calls.clear()
status, reply = request("POST", "/api/accounts/resume", {"paneId": "w1:p3"})
check("manual resume ok", reply.get("ok"), True)
check("manual resume typed once", [c[0] for c in calls], ["type"])
status, reply = request("POST", "/api/accounts/resume", {"paneId": "w1:nope"})
check("unknown pane refused", reply["ok"], False)

dash.shutdown()
router.shutdown()
if fails:
    print("\n".join(["FAILURES:"] + fails))
    sys.exit(1)
print("ALL PASS")
