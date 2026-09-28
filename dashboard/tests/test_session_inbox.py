#!/usr/bin/env python3
"""Direct-run tests for session_inbox.py (message a Claude Desktop / plain
CLI session through its peer-messaging socket) and its wiring:
`messageVia` on rows, `_handle_reach_action`'s inbox branch, the audit rows.

SAFETY: temp sessions dir + a FAKE Unix socket server only. The real
~/.claude/sessions is never read (every call passes `sessions_dir`, and the
server-level tests repoint claude_sessions.SESSIONS_DIR), no real session's
socket is ever touched, and the "live Claude pid" is this test process.
Hostile text uses the inert sentinel only.
"""
import contextlib
import importlib.util
import io
import json
import os
import socket
import sys
import tempfile
import threading

DASHBOARD_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_state_tmp = tempfile.TemporaryDirectory()
os.environ["CHIEF_DASHBOARD_STATE_HOME"] = _state_tmp.name  # never the live board db
os.environ["CHIEF_DASHBOARD_CONFIG_HOME"] = _state_tmp.name
os.environ["CHIEF_DASHBOARD_MACHINES"] = "{}"
sys.path.insert(0, os.path.join(DASHBOARD_DIR, "server", "lib"))

import claude_sessions  # noqa: E402
import session_inbox  # noqa: E402

fails = []
TOKEN = "peer-token-SENTINEL-7f3a"
SESSION_ID = "sess-inbox-1"
LIVE_PID = os.getpid()
DEAD_PID = 999_983  # far above macOS's pid range in practice
SENTINEL_TEXT = "please run $(echo INJECTED) and `echo INJECTED`"


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


class FakeInbox:
    """A Unix socket that records every line one client sends, optionally
    answering with `reply`. Stands in for a Claude session's inbox."""

    def __init__(self, path, reply=None, listen=True):
        self.path = path
        self.reply = reply
        self.lines = []
        if os.path.lexists(path):
            os.unlink(path)  # a previous fake's socket file (temp dir only)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(path)
        self.thread = None
        if listen:
            self.sock.listen(1)
            self.thread = threading.Thread(target=self._serve, daemon=True)
            self.thread.start()
        else:
            self.sock.close()  # leaves a dead socket file behind

    def _serve(self):
        self.sock.settimeout(5)
        try:
            conn, _ = self.sock.accept()
        except OSError:
            return
        buf = b""
        conn.settimeout(2)
        try:
            while buf.count(b"\n") < 2:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                buf += chunk
            if self.reply is not None:
                conn.sendall(self.reply)
        except OSError:
            pass
        finally:
            conn.close()
        self.lines = [json.loads(line) for line in buf.decode().splitlines() if line]

    def finish(self):
        if self.thread:
            self.thread.join(timeout=5)
        self.sock.close()
        return self.lines


class Sandbox:
    """A temp sessions dir with one session file + key + socket path."""

    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.sessions = os.path.join(self.tmp.name, "sessions")
        os.makedirs(self.sessions)
        self.socket_path = os.path.join(self.tmp.name, "s.sock")

    def write_session(self, pid, session_id=SESSION_ID, **extra):
        entry = {"pid": pid, "sessionId": session_id, "kind": "interactive",
                 "entrypoint": "claude-desktop", "status": "idle",
                 "peerProtocol": 1, "messagingSocketPath": self.socket_path,
                 "startedAt": 1_000_000_000_000, "statusUpdatedAt": 1}
        entry.update(extra)
        with open(os.path.join(self.sessions, f"{pid}.json"), "w") as f:
            json.dump(entry, f)
        return entry

    def write_key(self, pid, mode=0o600, token=TOKEN, name_hash="ab12" * 16):
        path = os.path.join(self.sessions, f"{pid}.{name_hash}.key")
        with open(path, "w") as f:
            json.dump({"peerToken": token}, f)
        os.chmod(path, mode)
        return path

    def send(self, text="hello there", session_id=SESSION_ID):
        return session_inbox.send_message(session_id, text, sessions_dir=self.sessions,
                                          timeout=2, reply_wait=0.3)

    def close(self):
        self.tmp.cleanup()


def expected_lines(text):
    return [{"type": "auth", "token": TOKEN},
            {"type": "user", "message": {"role": "user", "content": text}}]


captured_output = io.StringIO()
results_seen = []


def run_send(box, text="hello there", session_id=SESSION_ID):
    with contextlib.redirect_stdout(captured_output), contextlib.redirect_stderr(captured_output):
        result = box.send(text, session_id)
    results_seen.append(result)
    return result


print("== happy path: exactly the two protocol lines, token not echoed ==")
box = Sandbox()
box.write_session(LIVE_PID)
box.write_key(LIVE_PID)
inbox = FakeInbox(box.socket_path)
result = run_send(box, SENTINEL_TEXT)
lines = inbox.finish()
check("delivered", (result["delivered"], result["error"]), (True, None))
check("socket got auth then the user message, verbatim", lines, expected_lines(SENTINEL_TEXT))
check("sentinel never executed (stays literal)", "INJECTED" in lines[1]["message"]["content"], True)
box.close()

print("== pid changed (Desktop resumed the session): resolve by sessionId ==")
box = Sandbox()
old_socket = os.path.join(box.tmp.name, "old.sock")
box.write_session(DEAD_PID, messagingSocketPath=old_socket)
box.write_key(DEAD_PID)
box.write_session(LIVE_PID)
box.write_key(LIVE_PID, name_hash="cd34" * 16)
old_inbox = FakeInbox(old_socket)
inbox = FakeInbox(box.socket_path)
result = run_send(box)
check("delivered to the live process", result["delivered"], True)
check("new pid's socket got the message", inbox.finish(), expected_lines("hello there"))
old_inbox.sock.close()
check("old (dead) pid's socket got nothing", old_inbox.lines, [])
box.close()

print("== dead pid / unknown session: not running, nothing sent ==")
box = Sandbox()
box.write_session(DEAD_PID)
box.write_key(DEAD_PID)
result = run_send(box)
check("dead pid -> not running", (result["delivered"], result["maybeDelivered"], result["error"]),
      (False, False, session_inbox.NOT_RUNNING))
result = run_send(box, session_id="some-other-session")
check("unknown session -> not running", result["error"], session_inbox.NOT_RUNNING)
box.close()

print("== two live processes claim one session: refused ==")
box = Sandbox()
box.write_session(LIVE_PID)
box.write_session(os.getppid())
result = run_send(box)
check("ambiguous -> refused", (result["delivered"], "two running" in result["error"]), (False, True))
box.close()

print("== unsafe files: refused before connecting ==")


def unsafe_case(label, arrange):
    box = Sandbox()
    box.write_session(LIVE_PID)
    inbox = FakeInbox(box.socket_path)
    arrange(box)
    result = run_send(box)
    inbox.sock.close()  # unblocks accept(); nothing may have connected
    inbox.thread.join(timeout=5)
    check(label, (result["delivered"], result["maybeDelivered"], result["error"], inbox.lines),
          (False, False, session_inbox.UNSAFE_FILES, []))
    box.close()


unsafe_case("key readable by others (0644)", lambda b: b.write_key(LIVE_PID, mode=0o644))
unsafe_case("no key at all", lambda b: None)


def symlinked_key(b):
    real = os.path.join(b.tmp.name, "elsewhere.key")
    with open(real, "w") as f:
        json.dump({"peerToken": TOKEN}, f)
    os.chmod(real, 0o600)
    os.symlink(real, os.path.join(b.sessions, f"{LIVE_PID}.{'ef56' * 16}.key"))


unsafe_case("key is a symlink", symlinked_key)


def two_keys(b):
    b.write_key(LIVE_PID)
    b.write_key(LIVE_PID, name_hash="9999" * 16)


unsafe_case("two keys for one pid (ambiguous)", two_keys)


def stale_key(b):
    path = b.write_key(LIVE_PID)
    b.write_session(LIVE_PID, startedAt=int((os.path.getmtime(path) + 3600) * 1000))


unsafe_case("key older than the process (recycled pid leftover)", stale_key)


def key_without_token(b):
    b.write_key(LIVE_PID, token="")


unsafe_case("key with an empty token", key_without_token)

box = Sandbox()
box.write_session(LIVE_PID)
box.write_key(LIVE_PID)
with open(box.socket_path, "w") as f:
    f.write("not a socket")
result = run_send(box)
check("socket path is a regular file -> unsafe", result["error"], session_inbox.UNSAFE_FILES)
box.write_session(LIVE_PID, messagingSocketPath="relative.sock")
result = run_send(box)
check("relative socket path -> unsafe", result["error"], session_inbox.UNSAFE_FILES)
box.close()

print("== protocol / connection failures ==")
box = Sandbox()
box.write_session(LIVE_PID, peerProtocol=2)
box.write_key(LIVE_PID)
result = run_send(box)
check("unknown peerProtocol -> unsupported", result["error"], session_inbox.UNSUPPORTED)
box.write_session(LIVE_PID, entrypoint="sdk-cli")
check("non-interactive entrypoint -> unsupported", run_send(box)["error"], session_inbox.UNSUPPORTED)
box.write_session(LIVE_PID)
FakeInbox(box.socket_path, listen=False)
result = run_send(box)
check("stale socket (nobody listening) -> cannot connect, nothing sent",
      (result["error"], result["maybeDelivered"]), (session_inbox.CANNOT_CONNECT, False))
box.close()

box = Sandbox()
box.write_session(LIVE_PID)
box.write_key(LIVE_PID)
inbox = FakeInbox(box.socket_path, reply=b'{"type":"error","message":"bad token"}\n')
result = run_send(box)
inbox.finish()
check("session answers an error line -> refused", (result["delivered"], result["error"]),
      (False, session_inbox.REFUSED_BY_SESSION))
box.close()

box = Sandbox()
box.write_session(LIVE_PID)
box.write_key(LIVE_PID)
inbox = FakeInbox(box.socket_path, reply=b'{"type":"ack"}\n')
check("a non-error reply counts as delivered", run_send(box)["delivered"], True)
inbox.finish()
box.close()

print("== the token never leaks ==")
check("token in no result", any(TOKEN in json.dumps(r) for r in results_seen), False)
check("token in nothing printed/logged", TOKEN in captured_output.getvalue(), False)

print("== row rules (deliver_row_message) ==")
ROW = {"paneId": None, "source": "claude-desktop", "agentSession": SESSION_ID,
       "messageVia": "inbox", "sessionStatus": "idle", "hookState": "idle"}
sent = []


def fake_send(result):
    def send(session_id, text):
        sent.append((session_id, text))
        return result
    return send


OK = {"delivered": True, "maybeDelivered": True, "error": None}
for text in ("/compact", "/clear", "/help me"):
    sent.clear()
    got = session_inbox.deliver_row_message(ROW, text, True, send=fake_send(OK))
    check(f"{text!r} refused, typed:false, nothing sent",
          (got.get("ok"), got.get("typed"), got.get("error"), sent),
          (False, False, session_inbox.SLASH_REFUSED, []))
for label, extra in (("hookRequest pending", {"hookRequest": {"requestId": "hp-1"}}),
                     ("transcriptQuestion pending", {"transcriptQuestion": {"question": "?"}}),
                     ("session waiting", {"sessionStatus": "waiting"}),
                     ("hookState blocked", {"hookState": "blocked"})):
    sent.clear()
    got = session_inbox.deliver_row_message(dict(ROW, **extra), "hi", True, send=fake_send(OK))
    check(f"{label} -> refused, nothing sent",
          (got.get("error"), got.get("typed"), sent), (session_inbox.PROMPT_PENDING, False, []))
sent.clear()
busy = dict(ROW, sessionStatus="busy", hookState="working")
got = session_inbox.deliver_row_message(busy, "hi", False, send=fake_send(OK))
check("busy without confirm -> needsConfirm, nothing sent",
      (got.get("ok"), got.get("needsConfirm"), sent), (False, True, []))
got = session_inbox.deliver_row_message(busy, "hi", True, send=fake_send(OK))
check("busy + confirm -> queued", (got.get("ok"), got.get("state")), (True, "queued"))
got = session_inbox.deliver_row_message(ROW, "hi", False, send=fake_send(OK))
check("idle -> message sent", (got.get("ok"), got.get("state"), got.get("reason")),
      (True, "message sent", session_inbox.DELIVERED_NOTE))
got = session_inbox.deliver_row_message(ROW, "hi", False, send=fake_send(
    {"delivered": False, "maybeDelivered": False, "error": "nope"}))
check("clean failure -> typed:false", got, {"ok": False, "error": "nope", "typed": False})
got = session_inbox.deliver_row_message(ROW, "hi", False, send=fake_send(
    {"delivered": False, "maybeDelivered": True, "error": session_inbox.MAYBE_SENT}))
check("maybe-delivered failure -> no typed:false (never restore the draft)", "typed" in got, False)

print("== message_via ==")
check("pane row", session_inbox.message_via({"paneId": "w1:p1"}), "pane")
check("inbox row", session_inbox.message_via(ROW), "inbox")
check("status-only row without inbox support",
      session_inbox.message_via(dict(ROW, messageVia=None)), None)
check("unknown source never inbox",
      session_inbox.message_via(dict(ROW, source="claude-sdk-cli")), None)
check("no session id never inbox", session_inbox.message_via(dict(ROW, agentSession=None)), None)

print("== rows carry messageVia ==")
entry = {"pid": LIVE_PID, "sessionId": "s-a", "entrypoint": "claude-desktop", "status": "idle",
         "peerProtocol": 1, "messagingSocketPath": "/tmp/cc-socks/1.sock",
         "hostSessionId": "local_abc"}
rows = claude_sessions.build_status_only_rows(
    [entry, dict(entry, sessionId="s-b", peerProtocol=2),
     dict(entry, sessionId="s-c", messagingSocketPath=None),
     dict(entry, sessionId="s-d", entrypoint="cli")], set(), 0, machine="local")
check("messageVia per session", [r["messageVia"] for r in rows], ["inbox", None, None, "inbox"])
check("desktop openUrl uses hostSessionId",
      rows[0]["openUrl"], "claude://code/continue?session=local_abc")
check("cli row has no openUrl", rows[3]["openUrl"], None)

print("== server: POST /api/session/message on an inbox row ==")
_spec = importlib.util.spec_from_file_location(
    "chief_dashboard_server_inbox_test",
    os.path.join(DASHBOARD_DIR, "server", "chief-dashboard-server.py"))
_srv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_srv)

box = Sandbox()
box.write_session(LIVE_PID)
box.write_key(LIVE_PID)
claude_sessions.SESSIONS_DIR = box.sessions  # never the real ~/.claude/sessions
agent_row = dict(ROW, label="desk", cwd="/x", hasHookData=True)
_srv.get_full_state = lambda: {"computed": {"agents": [agent_row]}, "feeds": {}}
_srv._own_pane_cached = lambda ids: None
logged = []
_srv.STORE.log_session_action = lambda *a, **k: logged.append((a, k))
herdr_calls = []
_srv._pane_run_raw = lambda *a, **k: herdr_calls.append(a)

inbox = FakeInbox(box.socket_path)
with contextlib.redirect_stdout(captured_output), contextlib.redirect_stderr(captured_output):
    result = _srv.handle_session_action(
        "message", {"rowId": SESSION_ID, "actor": "po", "text": "ship it"})
check("sent via inbox", (result.get("ok"), result.get("state")), (True, "message sent"))
check("fake inbox got the message", inbox.finish(), expected_lines("ship it"))
check("audited like a pane send",
      [(a[0], a[1], a[2], a[3], k.get("status"), k.get("text")) for a, k in logged],
      [(SESSION_ID, "message", "po", "ship it", "sent", "ship it")])
check("no herdr call was made", herdr_calls, [])
check("token not in the response", TOKEN in json.dumps(result), False)

logged.clear()
result = _srv.handle_session_action("message", {"rowId": SESSION_ID, "actor": "po",
                                                "text": "line one\nline two"})
check("newline refused before sending", (result.get("ok"), result.get("typed")), (False, False))
result = _srv.handle_session_action("message", {"rowId": SESSION_ID, "actor": "chief",
                                                "text": "hi"})
check("actor chief refused", result.get("ok"), False)
result = _srv.handle_session_action("message", {"rowId": SESSION_ID, "actor": "po",
                                                "text": "/compact"})
check("/compact refused on an inbox row", result.get("error"), session_inbox.SLASH_REFUSED)
check("refusals are not audited", logged, [])

agent_row.update(sessionStatus="busy", hookState="working")
result = _srv.handle_session_action("message", {"rowId": SESSION_ID, "actor": "po", "text": "hi"})
check("busy -> needsConfirm", result.get("needsConfirm"), True)
inbox = FakeInbox(box.socket_path)
result = _srv.handle_session_action("message", {"rowId": SESSION_ID, "actor": "po", "text": "hi",
                                                "confirm": True})
inbox.finish()
check("busy + confirm -> queued, audited as queued",
      (result.get("state"), [k.get("status") for _a, k in logged], logged[-1][0][3]),
      ("queued", ["queued"], "queued: hi"))

logged.clear()
agent_row.update(sessionStatus="idle", hookState="idle")
FakeInbox(box.socket_path, listen=False)
result = _srv.handle_session_action("message", {"rowId": SESSION_ID, "actor": "po", "text": "hi"})
check("inbox down -> clean refusal (typed:false), not audited as failed",
      (result.get("ok"), result.get("typed"), logged), (False, False, []))

agent_row["messageVia"] = None
result = _srv.handle_session_action("message", {"rowId": SESSION_ID, "actor": "po", "text": "hi"})
check("status-only row without inbox -> old 'no pane' refusal", "has no pane" in result.get("error", ""), True)
agent_row["messageVia"] = "inbox"
for action in ("stop", "close"):
    result = _srv.handle_session_action(action, {"rowId": SESSION_ID, "actor": "po", "confirm": True})
    check(f"{action} still refused on a status-only row", result.get("ok"), False)
check("token never printed by the server path", TOKEN in captured_output.getvalue(), False)
box.close()

print()
if fails:
    print(f"FAIL: {len(fails)} failure(s)")
    for f in fails:
        print("  - " + f)
    sys.exit(1)
print("PASS: all session inbox checks")
