#!/usr/bin/env python3
"""Direct-run tests for the hook answer bridge's RE-SEND path: a prompt the
dashboard lost (restart -> /wait 404, dashboard down) or could not show yet
(AgentBar not connected) is sent again by the hook, deduped by the store, and
held only while the session file still shows that prompt.
(test_hook_permissions.py covers the single-send bridge.)"""
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

DASHBOARD = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(DASHBOARD, "server", "lib"))
HOOK = os.path.join(DASHBOARD, "hooks", "agentbar-permission-hook.py")

import hook_permissions  # noqa: E402
import hook_permission_routes as routes  # noqa: E402
import session_prompt_state as prompt_state  # noqa: E402

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


class SwitchablePresence:
    def __init__(self, connected=True):
        self.connected = connected

    def is_connected(self):
        return self.connected

    def is_gone(self):
        return not self.connected


class FakeClock:
    def __init__(self, now=1_790_000_000.0):
        self.now = now

    def __call__(self):
        return self.now


QUESTION_INPUT = {"questions": [{"question": "Ship it?", "header": "Ship", "multiSelect": False,
                                 "options": [{"label": "Yes", "description": ""},
                                             {"label": "No", "description": ""}]}]}


def payload(session_id="s1", **extra):
    body = {"session_id": session_id, "tool_name": "AskUserQuestion", "tool_input": QUESTION_INPUT,
            "hook_event_name": "PermissionRequest", "claudePid": 4242, "hookPid": 4343}
    body.update(extra)
    return body


def session_file(session_id="s1", status="waiting", status_at=None, entrypoint="claude-desktop", pid=4242):
    entry = {"pid": pid, "sessionId": session_id, "kind": "interactive", "entrypoint": entrypoint,
             "status": status}
    if status_at is not None:
        entry["statusUpdatedAt"] = int(status_at * 1000)
    return entry


print("== session_prompt_state ==")
check("waiting written with the prompt = still waiting",
      prompt_state.prompt_still_waiting(session_file(status_at=100.3), 100.0), True)
check("busy after the prompt = moved on", prompt_state.session_moved_on(session_file("s1", "busy", 101), 100.0), True)
check("waiting again 5s later = the NEXT prompt",
      prompt_state.prompt_still_waiting(session_file(status_at=105), 100.0), False)
check("busy from before the prompt = not waiting yet, not moved on",
      (prompt_state.session_moved_on(session_file("s1", "busy", 99), 100.0),
       prompt_state.prompt_still_waiting(session_file("s1", "busy", 99), 100.0)), (False, False))
check("Desktop / CLI show their own prompt",
      [prompt_state.shows_own_prompt(session_file(entrypoint=e), "s1") for e in ("claude-desktop", "cli", "sdk-cli")],
      [True, True, False])
check("another session's file never counts", prompt_state.shows_own_prompt(session_file("other"), "s1"), False)

print("== store: dedupe + re-send guard ==")
clock = FakeClock()
store = hook_permissions.HookPermissionStore(clock=clock, ticks=clock, pid_alive=lambda pid: True,
                                             presence=SwitchablePresence())
started = clock.now - 30
first = store.register(payload(promptStartedAt=started), (), session_file())
again = store.register(payload(promptStartedAt=started, hookPid=5555), (), session_file())
check("same prompt twice -> one request", again["requestId"], first["requestId"])
check("the re-send's hook is the one listening now", store._requests[first["requestId"]].hook_pid, 5555)
check("timer counts from the prompt, not the re-send",
      store.exposed_by_session([])["s1"]["sinceSec"], 30.0)
other = store.register(payload(tool_input={"questions": [{**QUESTION_INPUT["questions"][0], "question": "Other?"}]}),
                       (), session_file())
check("a different prompt -> its own request", other["requestId"] != first["requestId"], True)
by_id_a = store.register(payload("s2", tool_use_id="toolu_1"), (), session_file("s2"))
by_id_b = store.register(payload("s2", tool_use_id="toolu_1", tool_input={"questions": []}), (), session_file("s2"))
check("tool_use_id wins over the input hash", by_id_a["requestId"], by_id_b["requestId"])

store = hook_permissions.HookPermissionStore(clock=clock, ticks=clock, pid_alive=lambda pid: True,
                                             presence=SwitchablePresence())
resend = payload(promptStartedAt=started, reregister=True)
reply = store.register(resend, (), session_file("s1", "busy", started + 5))
check("re-send after it was answered in Claude -> ignored for good",
      (reply["state"], reply["reason"], reply["retryable"]),
      ("ignored", hook_permissions.REASON_PROMPT_GONE, False))
reply = store.register(resend, (), session_file(status_at=started + 20))
check("re-send while the NEXT prompt is up -> ignored", reply.get("reason"), hook_permissions.REASON_PROMPT_GONE)
reply = store.register(resend, (), session_file(status_at=started + 0.2))
check("re-send while still waiting -> held", "requestId" in reply, True)
check("held re-send keeps the prompt's start time",
      store._requests[reply["requestId"]].created_at, started)
check("a first send needs no `waiting` yet (the status lands a moment later)",
      "requestId" in store.register(payload("s3"), (), session_file("s3", "busy", started - 60)), True)
check("promptStartedAt in the future -> now",
      hook_permissions.prompt_started_at({"promptStartedAt": clock.now + 60}, clock.now), clock.now)
check("promptStartedAt not a number -> now",
      hook_permissions.prompt_started_at({"promptStartedAt": True}, clock.now), clock.now)

store = hook_permissions.HookPermissionStore(clock=clock, ticks=clock, pid_alive=lambda pid: True,
                                             presence=SwitchablePresence(connected=False))
check("AgentBar not connected -> retryable", store.register(payload(), (), session_file()).get("retryable"), True)
check("subagent prompt -> not retryable",
      store.register(payload(agent_id="a1"), (), session_file()).get("retryable"), False)

print("== hook script: re-sends against a real local server ==")
sessions_dir = tempfile.mkdtemp(prefix="hook-resend-sessions-")
MY_PID = os.getpid()  # the hook's parent = its "Claude" process


def write_my_session(status, status_at, session_id="hook-r1", entrypoint="claude-desktop"):
    with open(os.path.join(sessions_dir, f"{MY_PID}.json"), "w") as f:
        json.dump(session_file(session_id, status, status_at, entrypoint, pid=MY_PID), f)


def fresh_session_entry(body):
    try:
        with open(os.path.join(sessions_dir, f"{MY_PID}.json")) as f:
            entry = json.load(f)
    except OSError:
        return None
    return entry if entry.get("sessionId") == body.get("session_id") else None


class ResendHandler(BaseHTTPRequestHandler):
    store = None
    down = False  # simulates the dashboard restarting (every request 404s)

    def log_message(self, *args):
        pass

    def _send(self, body, status):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parsed = urlparse(self.path)
        self._send(*routes.handle_get(parsed.path, parse_qs(parsed.query), False, type(self).store))

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        self._send(*routes.handle_post(
            urlparse(self.path).path, lambda: json.loads(self.rfile.read(length) or b"{}"),
            False, type(self).store, session_entry=fresh_session_entry))


def new_store(connected=True):
    presence = SwitchablePresence(connected)
    return hook_permissions.HookPermissionStore(presence=presence), presence


server = ThreadingHTTPServer(("127.0.0.1", 0), ResendHandler)
threading.Thread(target=server.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{server.server_address[1]}"


def start_hook(session_id="hook-r1"):
    proc = subprocess.Popen([sys.executable, HOOK], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True,
                            env=dict(os.environ, AGENTBAR_DASHBOARD_URL=url, CLAUDE_SESSIONS_DIR=sessions_dir))
    proc.stdin.write(json.dumps({"session_id": session_id, "tool_name": "AskUserQuestion",
                                 "tool_input": QUESTION_INPUT, "hook_event_name": "PermissionRequest"}))
    proc.stdin.close()
    return proc


def wait_for_pending(store, session_id, timeout=8):
    deadline = time.time() + timeout
    while time.time() < deadline:
        pending = store.exposed_by_session([])
        if session_id in pending:
            return pending[session_id]["requestId"]
        time.sleep(0.05)
    return None


def finish(proc, timeout=10):
    try:
        out = proc.communicate(timeout=timeout)[0]
    except subprocess.TimeoutExpired:
        proc.kill()
        return "TIMEOUT"
    return out


answer = {"behavior": "allow", "answers": {"Ship it?": "Yes"}}
decision_out = {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {
    "behavior": "allow", "updatedInput": {**QUESTION_INPUT, "answers": {"Ship it?": "Yes"}}}}}

# 1. Dashboard restart: the held prompt vanishes (404), the hook re-sends it to the new instance.
write_my_session("waiting", time.time())
ResendHandler.store, _ = new_store()
proc = start_hook()
check("held by the first instance", wait_for_pending(ResendHandler.store, "hook-r1") is not None, True)
restarted_away = ResendHandler.store
ResendHandler.store, _ = new_store()  # restart: the new store knows nothing...
restarted_away._requests.clear()      # ...and the old one's long-poll now answers 404
rid = wait_for_pending(ResendHandler.store, "hook-r1")
check("re-sent to the restarted dashboard", rid is not None, True)
if rid:
    ResendHandler.store.answer(rid, answer)
out = finish(proc)
check("answer after the restart reaches Claude", json.loads(out) if out.startswith("{") else out, decision_out)

# 2. AgentBar not connected at first: re-sent once it connects.
write_my_session("waiting", time.time())
ResendHandler.store, presence = new_store(connected=False)
proc = start_hook()
time.sleep(1.5)
check("nothing held while AgentBar is away", ResendHandler.store.exposed_by_session([]), {})
presence.connected = True
rid = wait_for_pending(ResendHandler.store, "hook-r1")
check("held once AgentBar connects", rid is not None, True)
if rid:
    ResendHandler.store.answer(rid, answer)
out = finish(proc)
check("answered after AgentBar came back", json.loads(out) if out.startswith("{") else out, decision_out)

# 3. Answered in Claude while the hook was retrying: it stops, silently.
write_my_session("waiting", time.time())
ResendHandler.store, presence = new_store(connected=False)
proc = start_hook()
time.sleep(1.2)
write_my_session("busy", time.time())
t0 = time.time()
out = finish(proc, timeout=15)
check("prompt answered in Claude -> hook exits with no decision", out, "")
check("... within one backoff pause", time.time() - t0 < 11, True)

# 4. A session Claude hides prompts for (SDK run): never retried, exits at once.
write_my_session("waiting", time.time(), entrypoint="sdk-cli")
ResendHandler.store, _ = new_store(connected=False)
t0 = time.time()
out = finish(start_hook(), timeout=5)
check("sdk session: no retry, fast exit", (out, time.time() - t0 < 2), ("", True))

# 5. Dashboard down and no session file: fail open fast, as before.
os.remove(os.path.join(sessions_dir, f"{MY_PID}.json"))
server.shutdown()
server.server_close()
t0 = time.time()
out = finish(start_hook(), timeout=5)
check("dashboard down + unknown session: fast silent exit", (out, time.time() - t0 < 2), ("", True))

print()
if fails:
    print(f"FAIL: {len(fails)} failure(s)")
    for f in fails:
        print("  - " + f)
    sys.exit(1)
print("PASS: all hook re-send checks")
