#!/usr/bin/env python3
"""Direct-run tests for the hook bridge's safety guard: a Claude prompt is
held only while AgentBar is connected (agentbar_presence.py), and released
once AgentBar has been gone 15s — so no hook ever waits on nobody."""
import importlib.util
import os
import sys
import types

DASHBOARD = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(DASHBOARD, "server", "lib"))

import agentbar_presence  # noqa: E402
import hook_permissions  # noqa: E402

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


class FakeClock:
    def __init__(self, now=1_790_000_000.0):
        self.now = now

    def __call__(self):
        return self.now


def payload(session_id="sess-1"):
    return {"session_id": session_id, "tool_name": "Bash", "tool_input": {"command": "ls"},
            "claudePid": 4242, "hookPid": 4343}


def cli_entry(session_id="sess-1"):
    return {"sessionId": session_id, "entrypoint": "cli"}


print("== presence: connected / gone windows ==")
clock = FakeClock()
presence = agentbar_presence.AgentBarPresence(clock=clock)
check("never seen -> not connected", presence.is_connected(), False)
check("never seen -> gone", presence.is_gone(), True)
presence.note_seen()
check("just seen -> connected", (presence.is_connected(), presence.is_gone()), (True, False))
clock.now += agentbar_presence.CONNECTED_WITHIN_SEC + 1
check("11s silent -> not connected, not yet gone (reconnect grace)",
      (presence.is_connected(), presence.is_gone()), (False, False))
clock.now += agentbar_presence.GONE_AFTER_SEC - agentbar_presence.CONNECTED_WITHIN_SEC
check("16s silent -> gone", presence.is_gone(), True)

print("== which requests are AgentBar ==")
is_agentbar = agentbar_presence.is_agentbar_request
check("header on local listener", is_agentbar({"X-AgentBar": "1"}, False), True)
check("header on the remote (phone) listener", is_agentbar({"X-AgentBar": "1"}, True), False)
check("no header (browser tab, curl)", is_agentbar({"User-Agent": "Mozilla"}, False), False)
check("other value", is_agentbar({"X-AgentBar": "0"}, False), False)
check("no headers object", is_agentbar(None, False), False)
is_web = agentbar_presence.is_web_answer_stream
check("web UI stream ?answerSurface=web", is_web({"answerSurface": ["web"]}), True)
check("stream without it (old cached build, curl)", is_web({}), False)
check("other value", is_web({"answerSurface": ["mac"]}), False)
check("no query", is_web(None), False)

print("== store: hold only while AgentBar is connected ==")
clock = FakeClock()
presence = agentbar_presence.AgentBarPresence(clock=clock)
store = hook_permissions.HookPermissionStore(clock=clock, ticks=clock, pid_alive=lambda pid: True, presence=presence)
reply = store.register(payload(), (), cli_entry())
check("no AgentBar -> ignored at once", reply.get("state"), "ignored")
check("ignored reason says why", "not connected" in reply.get("reason", ""), True)
check("not connected is retryable (the hook re-sends once AgentBar is back)", reply.get("retryable"), True)
check("nothing held", store._requests, {})
presence.note_seen()
rid = store.register(payload(), (), cli_entry()).get("requestId")
check("AgentBar connected -> held", bool(rid), True)
store.wait(rid, 0)  # the hook polls at once
check("other ignore reasons still win (herdr)", store.register(
    payload("h"), {"h"}, cli_entry("h"))["reason"], "herdr pane (answered from its screen)")

print("== store: AgentBar drops -> pending released within 15s ==")
clock.now += agentbar_presence.CONNECTED_WITHIN_SEC + 2
check("12s without AgentBar -> still pending (may be reconnecting)",
      store.wait(rid, 0)[0]["state"], "pending")
check("new prompt meanwhile is not held", store.register(payload("s2"), (), cli_entry("s2"))["state"], "ignored")
clock.now += agentbar_presence.GONE_AFTER_SEC
check("gone 15s+ -> resolved, the hook's /wait returns", store.wait(rid, 0)[0],
      {"state": "resolved", "reason": hook_permissions.REASON_AGENTBAR_GONE, "retryable": True})
check("a late answer says why in plain words", store.answer(rid, {"behavior": "allow"})[0]["error"],
      "AgentBar and the web remote lost their dashboard connection; if Claude "
      "is still waiting this prompt shows again in a few seconds, else answer it in Claude.")
presence.note_seen()
rid2 = store.register(payload("s3"), (), cli_entry("s3")).get("requestId")
check("AgentBar back -> holds again", bool(rid2), True)
check("and answers work", store.answer(rid2, {"behavior": "deny"})[1], 200)

print("== store default = the server's one PRESENCE ==")
check("default presence", hook_permissions.HookPermissionStore()._presence is agentbar_presence.PRESENCE, True)
check("server STORE uses it", hook_permissions.STORE._presence is agentbar_presence.PRESENCE, True)

print("== server: who marks AgentBar seen ==")
_spec = importlib.util.spec_from_file_location(
    "chief_dashboard_server", os.path.join(DASHBOARD, "server", "chief-dashboard-server.py"))
_srv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_srv)


class FakeWfile:
    """Delivers `ok_writes` pushes, then the client is gone (broken pipe)."""

    def __init__(self, ok_writes, on_write):
        self.ok_writes, self.on_write = ok_writes, on_write

    def write(self, chunk):
        if self.ok_writes <= 0:
            raise BrokenPipeError()
        self.ok_writes -= 1
        self.on_write()

    def flush(self):
        pass


class FakeHandler(_srv.Handler):
    def __init__(self, headers, remote=False):  # noqa: no socket behind it
        self.headers = headers
        self.server = types.SimpleNamespace(remote_listener=remote)

    def send_response(self, *a):
        pass

    def send_header(self, *a):
        pass

    def end_headers(self):
        pass


def fresh_presence():
    clock = FakeClock()
    agentbar_presence.PRESENCE = agentbar_presence.AgentBarPresence(clock=clock)
    return clock


real_presence = agentbar_presence.PRESENCE
fresh_presence()
check("AgentBar request marks seen", (FakeHandler({"X-AgentBar": "1"})._note_agentbar_seen(),
                                      agentbar_presence.PRESENCE.is_connected()), (True, True))
fresh_presence()
FakeHandler({})._note_agentbar_seen()
check("browser/curl request does not", agentbar_presence.PRESENCE.is_connected(), False)
FakeHandler({"X-AgentBar": "1"}, remote=True)._note_agentbar_seen()
check("remote listener request does not", agentbar_presence.PRESENCE.is_connected(), False)

_srv.get_state_with_board = lambda: {}
_srv.time = types.SimpleNamespace(sleep=lambda s: None, time=lambda: 0)


def run_sse(headers, ok_writes):
    """Seen-times recorded around each delivered push of one SSE client."""
    clock = fresh_presence()
    seen_after_write = []
    handler = FakeHandler(headers)

    def on_write():
        clock.now += 2  # the server pushes every ~2s
        seen_after_write.append(clock.now)

    handler.wfile = FakeWfile(ok_writes, on_write)
    handler._serve_sse()
    return clock, seen_after_write


clock, writes = run_sse({"X-AgentBar": "1"}, ok_writes=3)
check("AgentBar SSE: seen after every delivered push",
      agentbar_presence.PRESENCE.seconds_since_seen(), 0.0)
clock.now += agentbar_presence.GONE_AFTER_SEC + 1
check("AgentBar SSE dropped (broken pipe) -> gone 15s later", agentbar_presence.PRESENCE.is_gone(), True)
run_sse({"Accept": "text/event-stream"}, ok_writes=3)
check("browser SSE never counts", agentbar_presence.PRESENCE.seconds_since_seen(), None)
agentbar_presence.PRESENCE = real_presence

print()
if fails:
    print(f"FAIL: {len(fails)} failure(s)")
    for f in fails:
        print("  - " + f)
    sys.exit(1)
print("PASS: all AgentBar presence checks")
