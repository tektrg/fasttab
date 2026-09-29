#!/usr/bin/env python3
"""OpenCode plugin + Codex hook senders and their installer
(dashboard/integrations/): merge/uninstall keeps other vendors' entries,
idempotent, backups; the Codex hook and the OpenCode plugin fail open fast
(listener down) and deliver to a fake listener.

SAFETY: temp CODEX_HOME / OPENCODE_CONFIG_DIR only (never the real ones);
listeners are throwaway fakes on free ports; no real Codex/OpenCode runs.
Injection-style text is only the inert sentinel $(echo INJECTED).
"""
import copy
import glob
import http.server
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
INTEGRATIONS = os.path.join(os.path.dirname(HERE), "integrations")
_tmp = tempfile.mkdtemp(prefix="tui-integrations-test-")
os.environ["CODEX_HOME"] = os.path.join(_tmp, "codex")
os.environ["OPENCODE_CONFIG_DIR"] = os.path.join(_tmp, "opencode")
sys.path.insert(0, INTEGRATIONS)
import install  # noqa: E402

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


FOREIGN = {
    "hooks": {
        "PermissionRequest": [
            {"hooks": [{"type": "command", "command": "'/x/AgentPeekBridge' --bridge-hook-event codex", "timeout": 600}]},
            {"hooks": [{"type": "command", "command": "'/x/vibe-island-bridge' --source codex", "timeout": 7200}]},
        ],
        "PostCompact": [{"hooks": [{"type": "command", "command": "'/x/vibe-island-bridge'", "timeout": 5}],
                         "matcher": "manual|auto"}],
    },
    "otherTopLevelKey": {"keep": True},
}

print("== Codex hooks.json merge ==")
os.makedirs(os.environ["CODEX_HOME"])
hooks_path = os.path.join(os.environ["CODEX_HOME"], "hooks.json")
with open(hooks_path, "w") as f:
    json.dump(FOREIGN, f)
report = install.run("install", ["codex"])
data = json.load(open(hooks_path))
check("install ok + changed", (report["ok"], report["tools"]["codex"]["changed"]), (True, True))
check("every event has our entry",
      all(install._event_has_ours(data["hooks"].get(e, [])) for e in install.CODEX_EVENTS), True)
pr_commands = [h["command"] for g in data["hooks"]["PermissionRequest"] for h in g["hooks"]]
check("PermissionRequest also gets the answering hook (long timeout), once",
      [c for c in pr_commands if "agentbar-codex-permission.py" in c].__len__(), 1)
check("answering hook timeout leaves room for the hold limit",
      [h["timeout"] for g in data["hooks"]["PermissionRequest"] for h in g["hooks"]
       if "agentbar-codex-permission.py" in h["command"]], [install.CODEX_PERMISSION_TIMEOUT_SEC])
check("no other event gets the answering hook",
      sorted(e for e, gs in data["hooks"].items() if any("agentbar-codex-permission.py" in h.get("command", "")
                                                          for g in gs for h in g["hooks"])), ["PermissionRequest"])
check("vendor PermissionRequest entries kept, in order",
      data["hooks"]["PermissionRequest"][:2], FOREIGN["hooks"]["PermissionRequest"])
check("vendor matcher group kept", data["hooks"]["PostCompact"][0], FOREIGN["hooks"]["PostCompact"][0])
check("unrelated top-level key kept", data["otherTopLevelKey"], {"keep": True})
check("one backup made", len(glob.glob(hooks_path + ".bak-agentbar-*")), 1)
check("backup = original", json.load(open(glob.glob(hooks_path + ".bak-agentbar-*")[0])), FOREIGN)
check("status: installed", install.run("status", ["codex"])["tools"]["codex"]["installed"], True)
before = open(hooks_path).read()
check("second install: no change", install.run("install", ["codex"])["tools"]["codex"]["changed"], False)
check("second install: file byte-identical", open(hooks_path).read(), before)
check("second install: no extra backup", len(glob.glob(hooks_path + ".bak-agentbar-*")), 1)
mixed = copy.deepcopy(json.load(open(hooks_path)))
mixed["hooks"]["Stop"][-1]["hooks"].insert(0, {"type": "command", "command": "/x/other-in-same-group"})
with open(hooks_path, "w") as f:
    json.dump(mixed, f)
report = install.run("uninstall", ["codex"])
data = json.load(open(hooks_path))
check("uninstall ok + changed", (report["ok"], report["tools"]["codex"]["changed"]), (True, True))
check("uninstall: only ours removed (vendor file restored)",
      {k: v for k, v in data["hooks"].items() if k != "Stop"}, FOREIGN["hooks"])
check("uninstall: foreign hook sharing our group kept",
      data["hooks"]["Stop"], [{"hooks": [{"type": "command", "command": "/x/other-in-same-group"}]}])
check("uninstall again: no change", install.run("uninstall", ["codex"])["tools"]["codex"]["changed"], False)
with open(hooks_path, "w") as f:
    f.write("{ not json")
report = install.run("install", ["codex"])
check("unreadable hooks.json: refused, left untouched",
      (report["ok"], open(hooks_path).read()), (False, "{ not json"))
os.remove(hooks_path)
check("no hooks.json yet: created", (install.run("install", ["codex"])["ok"], os.path.exists(hooks_path)), (True, True))

print("\n== OpenCode plugin file ==")
plugins = os.path.join(os.environ["OPENCODE_CONFIG_DIR"], "plugins")
os.makedirs(plugins)
with open(os.path.join(plugins, "vibe-island.js"), "w") as f:
    f.write("// theirs\n")
report = install.run("install", ["opencode"])
target = os.path.join(plugins, install.OPENCODE_PLUGIN_NAME)
check("install ok + changed", (report["ok"], report["tools"]["opencode"]["changed"]), (True, True))
check("plugin copied", open(target).read(), open(install.OPENCODE_PLUGIN_SRC).read())
check("vendor plugin untouched", open(os.path.join(plugins, "vibe-island.js")).read(), "// theirs\n")
check("second install: no change", install.run("install", ["opencode"])["tools"]["opencode"]["changed"], False)
check("uninstall removes ours", (install.run("uninstall", ["opencode"])["ok"], os.path.exists(target)), (True, False))
check("uninstall keeps theirs", os.path.exists(os.path.join(plugins, "vibe-island.js")), True)
with open(target, "w") as f:
    f.write("// someone else's file with our name\n")
check("same-named foreign file: refused", install.run("install", ["opencode"])["ok"], False)
check("same-named foreign file: never removed",
      (install.run("uninstall", ["opencode"]), os.path.exists(target))[1], True)
os.remove(target)
out = subprocess.run([sys.executable, os.path.join(INTEGRATIONS, "install.py"), "status", "--json"],
                     capture_output=True, text=True, timeout=10, env=os.environ.copy())
check("CLI --json: one parseable object", sorted(json.loads(out.stdout)["tools"]), ["codex", "opencode"])


# ── fake listener ─────────────────────────────────────────────────────────
received = []


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        received.append((self.path, json.loads(self.rfile.read(int(self.headers["Content-Length"])))))
        body = b'{"ok": true}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
live_url = f"http://127.0.0.1:{server.server_address[1]}"
dead_url = f"http://127.0.0.1:{free_port()}"

print("\n== Codex hook: delivers, never decides, fails open ==")
hook = os.path.join(INTEGRATIONS, "codex", "agentbar-codex-hook.py")
payload = json.dumps({"hook_event_name": "PermissionRequest", "session_id": "cx-1", "cwd": "/tmp/p",
                      "tool_name": "Bash", "tool_input": {"command": "echo $(echo INJECTED)"},
                      "last_assistant_message": "$(echo INJECTED)"})


def run_hook(url, stdin):
    env = dict(os.environ, AGENTBAR_DASHBOARD_URL=url, HERDR_PANE_ID="w9:p9")
    t0 = time.monotonic()
    proc = subprocess.run([sys.executable, hook], input=stdin, capture_output=True,
                          text=True, timeout=10, env=env)
    return proc, time.monotonic() - t0


proc, _ = run_hook(live_url, payload)
check("live: exit 0", proc.returncode, 0)
check("live: NO stdout (never a decision)", proc.stdout, "")
path, event = received[-1] if received else (None, {})
check("live: posted to /api/hook/tui-event", path, "/api/hook/tui-event")
check("live: event fields", (event.get("tool"), event.get("event"), event.get("sessionId"), event.get("paneId")),
      ("codex", "PermissionRequest", "cx-1", "w9:p9"))
check("live: sentinel forwarded as inert text", event.get("title"), "Bash: echo $(echo INJECTED)")
check("live: full command forwarded as detail (PermissionRequest only)", event.get("detail"), "echo $(echo INJECTED)")
check("live: pid reported", isinstance(event.get("pid"), int), True)
proc, took = run_hook(dead_url, payload)
check("listener down: exit 0", proc.returncode, 0)
check("listener down: no stdout, no stderr", (proc.stdout, proc.stderr), ("", ""))
check(f"listener down: fast ({took:.2f}s < 2s)", took < 2, True)
proc, _ = run_hook(live_url, "not json")
check("garbage stdin: exit 0, silent", (proc.returncode, proc.stdout, proc.stderr), (0, "", ""))
check("no output anywhere contains INJECTED executed", "INJECTED" not in (proc.stdout + proc.stderr), True)

print("\n== OpenCode plugin (node): delivers, fails open ==")
node = shutil.which("node")
if not node:
    print("  SKIP  node not installed")
else:
    driver = os.path.join(_tmp, "drive-plugin.mjs")
    with open(driver, "w") as f:
        f.write("""
const mod = await import(process.argv[2]);
const hooks = await mod.default.server({ serverUrl: new URL("http://127.0.0.1:1"), directory: "/tmp/oc" });
const t0 = Date.now();
await hooks.event({ event: { type: "permission.asked", properties: { id: "per_1", sessionID: "ses_1", permission: "bash", patterns: ["ls *"], always: ["ls *"], metadata: { command: "$(echo INJECTED)" }, title: "$(echo INJECTED)" } } });
await hooks.event({ event: { type: "session.status", properties: { sessionID: "ses_1", status: { type: "busy" } } } });
await hooks.event({ event: { type: "message.part.delta", properties: { sessionID: "ses_1" } } });
console.log(JSON.stringify({ handlerMs: Date.now() - t0 }));
await new Promise((r) => setTimeout(r, 1200));
""")

    def run_plugin(url):
        env = dict(os.environ, AGENTBAR_DASHBOARD_URL=url, HERDR_PANE_ID="w1:p2")
        t0 = time.monotonic()
        proc = subprocess.run([node, driver, os.path.join(INTEGRATIONS, "opencode", "agentbar-status.js")],
                              capture_output=True, text=True, timeout=20, env=env)
        return proc, time.monotonic() - t0

    received.clear()
    proc, _ = run_plugin(live_url)
    check("live: node exit 0", (proc.returncode, proc.stderr), (0, ""))
    events = sorted((b for p, b in received), key=lambda e: e["event"])  # posts race; order is not the contract
    check("live: two forwarded, delta skipped", [e["event"] for e in events], ["permission.asked", "session.status"])
    check("live: fields", events and (events[0]["tool"], events[0]["sessionId"], events[0]["paneId"],
                                      events[0]["cwd"], events[0]["serverUrl"]),
          ("opencode", "ses_1", "w1:p2", "/tmp/oc", "http://127.0.0.1:1"))
    check("live: statusType", events[1:] and events[1].get("statusType"), "busy")
    check("live: pending permission reported for answering",
          events and events[0].get("request"),
          {"id": "per_1", "kind": "permission", "permission": "bash", "patterns": ["ls *"], "always": ["ls *"],
           "detail": "$(echo INJECTED)"})
    proc, took = run_plugin(dead_url)
    check("listener down: node exit 0, no error output", (proc.returncode, proc.stderr), (0, ""))
    handler_ms = json.loads(proc.stdout.strip().splitlines()[0])["handlerMs"]
    check(f"listener down: event handler never waits on the network ({handler_ms}ms < 200)", handler_ms < 200, True)

server.shutdown()
print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("ALL PASS")
