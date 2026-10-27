#!/usr/bin/env python3
"""scripts/claude-launch.py: which account a new `claude` starts on.

Pure tests of choose()/launch_env(); nothing is exec'd, no router, no Keychain.
"""
import importlib.util
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DASHBOARD_DIR = os.path.dirname(HERE)
_tmp = tempfile.mkdtemp(prefix="claude-launch-test-")
os.environ.update({"CHIEF_DASHBOARD_CONFIG_HOME": _tmp, "CHIEF_DASHBOARD_STATE_HOME": _tmp})
_spec = importlib.util.spec_from_file_location(
    "claude_launch", os.path.join(DASHBOARD_DIR, "scripts", "claude-launch.py"))
L = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(L)

fails = []


def check(label, got, want):
    if got != want:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if got == want else 'FAIL'}  {label}")


NOW = 1000.0
SUB_A = {"id": "a", "kind": "login", "configDir": "/cfg/a", "label": "Personal"}
SUB_B = {"id": "b", "kind": "login", "configDir": "/cfg/b"}
APTUS = {"id": "aptus", "kind": "proxy", "baseUrl": "https://p"}
DEEP = {"id": "ds", "kind": "apikey", "baseUrl": "https://d", "needsApproval": True, "label": "DeepSeek"}
yes = lambda d: True  # noqa: E731


def pick(rows, status=None, logged=yes, limited=None):
    kind, row = L.choose(rows, NOW, status, logged, limited)
    return kind, row and row["id"]


check("top login wins", pick([SUB_A, APTUS]), ("login", "a"))
check("proxy on top -> router", pick([APTUS, SUB_A]), ("router", "aptus"))
check("disabled skipped", pick([dict(SUB_A, enabled=False), SUB_B]), ("login", "b"))
check("limited login skipped", pick([SUB_A, SUB_B], limited={"a": NOW + 60}), ("login", "b"))
check("expired limit ignored", pick([SUB_A], limited={"a": NOW - 1}), ("login", "a"))
check("not logged in skipped", pick([SUB_A, SUB_B], logged=lambda d: d != "/cfg/a"), ("login", "b"))
check("logged-in unknown = usable", pick([SUB_A], logged=lambda d: None), ("login", "a"))
cool = {"accounts": [{"id": "aptus", "cooldownUntil": NOW + 30}]}
check("cooling proxy skipped", pick([APTUS, SUB_A], status=cool), ("login", "a"))
check("router down = healthy", pick([APTUS, SUB_A], status=None), ("router", "aptus"))
check("stops at needsApproval", pick([dict(SUB_A, enabled=False), DEEP, SUB_B]), ("router", "ds"))
check("limited login then DeepSeek -> router", pick([SUB_A, DEEP], limited={"a": NOW + 1}), ("router", "ds"))
check("nothing usable -> default", pick([dict(SUB_A, enabled=False)]), ("default", None))
check("empty -> default", pick([]), ("default", None))

base = {"PATH": "/bin", "ANTHROPIC_BASE_URL": "x", "ANTHROPIC_AUTH_TOKEN": "t",
        "ANTHROPIC_MODEL": "m", "CLAUDE_CONFIG_DIR": "/old"}
env = L.launch_env("login", SUB_A, base, "4720")
check("login env", (env["CLAUDE_CONFIG_DIR"], [k for k in L.ANTHROPIC_VARS if k in env], env["PATH"]),
      ("/cfg/a", [], "/bin"))
env = L.launch_env("router", APTUS, base, "4799")
check("router env", (env["ANTHROPIC_BASE_URL"], env["ANTHROPIC_AUTH_TOKEN"], "ANTHROPIC_MODEL" in env,
                     "CLAUDE_CONFIG_DIR" in env), ("http://127.0.0.1:4799", "router", False, False))
env = L.launch_env("default", None, base, "4720")
check("default env drops ANTHROPIC_*", [k for k in L.ANTHROPIC_VARS if k in env], [])
check("labels", (L.label_of("login", SUB_A), L.label_of("router", DEEP), L.label_of("default", None)),
      ("Personal", "DeepSeek (via router, asks first)", "default (~/.claude)"))
check("CLAUDE_BIN wins", L.claude_binary({"CLAUDE_BIN": "/x/claude"}), "/x/claude")

# main(): exec is recorded, never run
import json  # noqa: E402
acc = os.path.join(_tmp, "accounts.json")
with open(acc, "w") as f:
    json.dump({"accounts": [SUB_A]}, f)
os.environ["CLAUDE_ROUTER_ACCOUNTS"] = acc
os.environ["CLAUDE_BIN"] = "/fake/claude"
calls = []
L.os.execvpe = lambda b, a, e: calls.append((b, a, e.get("CLAUDE_CONFIG_DIR")))
L.account_login.logged_in = yes
L.main(["--resume", "x"])
check("main execs with argv passthrough", calls, [("/fake/claude", ["/fake/claude", "--resume", "x"], "/cfg/a")])

if fails:
    print("\n".join(["FAILURES:"] + fails))
    sys.exit(1)
