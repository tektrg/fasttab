#!/usr/bin/env python3
"""Send a PO message to a Claude Code session outside herdr (Claude Desktop,
a plain CLI) through Claude Code's own peer-messaging socket — the "inbox".

Why: a status-only row (claude_sessions.py) has no pane to type into. Every
interactive Claude Code process instead writes, next to its
`~/.claude/sessions/<pid>.json`:
  - `messagingSocketPath` (e.g. /tmp/cc-socks/<pid>.sock) + `peerProtocol`,
  - `<pid>.<hash>.key`, a 0600 JSON file holding `peerToken`.
Protocol (undocumented, `peerProtocol: 1`, measured on 2.1.283): one line
`{"type":"auth","token":<peerToken>}`, then one line
`{"type":"user","message":{"role":"user","content":<text>}}`. The session
shows it as "Another Claude session sent a message: <text>" — queued while
busy, and treated as a PEER, never as the user: it cannot approve a
permission or answer a question, and a slash command is just text.

Rules:
  - Resolve by `sessionId` on every send, never a cached pid: Claude Desktop
    restarts the process (new pid) when it resumes a session.
  - Trust nothing on disk blindly: the session file, the key (mode 0600) and
    the socket must be owned by this user; no symlinks; the key must be
    newer than the process (a recycled pid can leave an old key behind).
  - The token is read per send, used once, and NEVER logged, returned or
    stored — every error below is a fixed sentence.

Pure except `send_message` (filesystem + one Unix socket).
"""
import glob
import json
import os
import re
import socket
import stat

import claude_sessions

#: Row `source`s whose session can be messaged here (never `claude -p`: its
#: session files are filtered out by claude_sessions._parse_session_file).
INBOX_SOURCES = frozenset({"claude-desktop", "claude-cli"})
SEND_TIMEOUT_SEC = 4.0
#: After sending, how long to listen for an error reply before calling it sent.
REPLY_WAIT_SEC = 0.4
#: A key file may be written a moment before `startedAt` is recorded.
KEY_CLOCK_SLACK_SEC = 5
_KEY_NAME_RE = re.compile(r"^(\d+)\.([0-9a-f]{16,128})\.key$")

NOT_RUNNING = "that session is not running any more — nothing was sent"
UNSUPPORTED = ("this Claude Code version's messaging format is not supported "
               "— nothing was sent")
UNSAFE_FILES = ("the session's messaging files failed the safety check "
                "(owner, permissions or type) — nothing was sent")
CANNOT_CONNECT = "could not reach the session's inbox — nothing was sent"
REFUSED_BY_SESSION = "the session refused the message"
MAYBE_SENT = ("the connection broke while sending — the message may or may "
              "not have arrived; check the session before re-sending")
SLASH_REFUSED = ("refused: slash commands don't work here — this session "
                 "gets the text as a message from another agent, not as a "
                 "command")
PROMPT_PENDING = ("refused: this session is waiting on a question or "
                  "permission — a message can't answer it. Answer it first")
BUSY_CONFIRM = ("that session is mid-turn — the message queues and lands "
                "when the turn ends. Confirm to queue it")
DELIVERED_NOTE = ("delivered to the session's inbox — it arrives as a "
                  "message from another agent")


def message_via(agent_row):
    """How a message would reach this row: "pane" (typed into herdr),
    "inbox" (this module) or None (it can't be messaged)."""
    agent_row = agent_row or {}
    if agent_row.get("paneId"):
        return "pane"
    if agent_row.get("messageVia") == "inbox" and agent_row.get("agentSession") \
            and agent_row.get("source") in INBOX_SOURCES:
        return "inbox"
    return None


def pending_prompt(agent_row):
    """True while the session shows a question/permission prompt."""
    agent_row = agent_row or {}
    return bool(agent_row.get("hookRequest") or agent_row.get("transcriptQuestion")
                or agent_row.get("sessionStatus") == "waiting"
                or agent_row.get("hookState") == "blocked")


def is_busy(agent_row):
    return (agent_row or {}).get("sessionStatus") == "busy"


# ── Files ────────────────────────────────────────────────────────────────


def _owned_by_me(st):
    return st.st_uid == os.geteuid()


def _is_safe_regular_file(path, private):
    try:
        st = os.lstat(path)
    except OSError:
        return False
    if not stat.S_ISREG(st.st_mode) or not _owned_by_me(st):
        return False
    return not private or stat.S_IMODE(st.st_mode) == 0o600


def _is_safe_socket(path):
    if not isinstance(path, str) or not os.path.isabs(path):
        return False
    try:
        st = os.lstat(path)
        folder = os.lstat(os.path.dirname(path))
    except OSError:
        return False
    # The folder too (like ssh): if another user could write it, they could
    # swap the socket between this check and the connect and get the token.
    folder_safe = (stat.S_ISDIR(folder.st_mode) and _owned_by_me(folder)
                   and not stat.S_IMODE(folder.st_mode) & 0o022)
    return stat.S_ISSOCK(st.st_mode) and _owned_by_me(st) and folder_safe


def _key_path(sessions_dir, entry):
    """The one key file for this process, or None. Keys older than the
    process (a recycled pid's leftovers) don't count; two candidates is
    ambiguous and refused."""
    pid = entry["pid"]
    started_ms = entry.get("startedAt")
    candidates = []
    for path in glob.glob(os.path.join(glob.escape(sessions_dir), f"{pid}.*.key")):
        match = _KEY_NAME_RE.match(os.path.basename(path))
        if not match or int(match.group(1)) != pid:
            continue
        if not _is_safe_regular_file(path, private=True):
            return None
        if isinstance(started_ms, (int, float)):
            try:
                key_mtime = os.lstat(path).st_mtime
            except OSError:  # vanished since the glob
                return None
            if key_mtime < started_ms / 1000.0 - KEY_CLOCK_SLACK_SEC:
                continue
        candidates.append(path)
    return candidates[0] if len(candidates) == 1 else None


def _read_token(key_path):
    """The peer token, re-checking the opened file itself (no swap between
    the check and the read). None on anything unexpected."""
    try:
        fd = os.open(key_path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        return None
    try:
        st = os.fstat(fd)
        if (not stat.S_ISREG(st.st_mode) or not _owned_by_me(st)
                or stat.S_IMODE(st.st_mode) != 0o600 or st.st_size > 4096):
            return None
        with os.fdopen(fd, "r") as f:
            fd = None
            data = json.load(f)
    except (OSError, ValueError):
        return None
    finally:
        if fd is not None:
            os.close(fd)
    token = data.get("peerToken") if isinstance(data, dict) else None
    return token if isinstance(token, str) and token else None


def resolve_session(session_id, sessions_dir=None, read_sessions=None):
    """(entry, None) for the ONE live process running `session_id`, else
    (None, reason). Always re-read — the pid changes on a Desktop resume."""
    sessions_dir = sessions_dir or claude_sessions.SESSIONS_DIR
    read_sessions = read_sessions or claude_sessions.read_live_sessions
    matches = [e for e in read_sessions(sessions_dir)
               if e.get("sessionId") == session_id]
    if not matches:
        return None, NOT_RUNNING
    if len(matches) > 1:
        return None, ("two running processes claim that session — "
                      "nothing was sent")
    entry = matches[0]
    if not claude_sessions.supports_inbox(entry):
        return None, UNSUPPORTED
    return entry, None


# ── Sending ──────────────────────────────────────────────────────────────


def _wire_lines(token, text):
    auth = json.dumps({"type": "auth", "token": token}) + "\n"
    user = json.dumps({"type": "user",
                       "message": {"role": "user", "content": text}}) + "\n"
    return (auth + user).encode("utf-8")


def _reply_is_refusal(reply):
    """An error line from the session (bad token, bad format). Anything else,
    or silence, counts as accepted — so a refusal arriving after
    REPLY_WAIT_SEC is reported as delivered."""
    for line in reply.decode("utf-8", errors="replace").splitlines():
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if isinstance(obj, dict) and (obj.get("type") == "error"
                                      or obj.get("ok") is False
                                      or obj.get("error")):
            return True
    return False


def send_message(session_id, text, sessions_dir=None, read_sessions=None,
                 timeout=SEND_TIMEOUT_SEC, reply_wait=REPLY_WAIT_SEC):
    """Deliver `text` to the session's inbox. Returns
    {"delivered": bool, "maybeDelivered": bool, "error": str|None}.
    `maybeDelivered` = bytes may have left before the failure (never
    auto-retry that one)."""
    sessions_dir = sessions_dir or claude_sessions.SESSIONS_DIR
    entry, reason = resolve_session(session_id, sessions_dir, read_sessions)
    if entry is None:
        return _not_sent(reason)
    if entry.get("status") == "waiting":  # fresh re-check; the row may be seconds old
        return _not_sent(PROMPT_PENDING)
    json_path = os.path.join(sessions_dir, f"{entry['pid']}.json")
    socket_path = entry["messagingSocketPath"]
    key_path = _key_path(sessions_dir, entry)
    if (key_path is None or not _is_safe_regular_file(json_path, private=False)
            or not _is_safe_socket(socket_path)):
        return _not_sent(UNSAFE_FILES)
    token = _read_token(key_path)
    if token is None:
        return _not_sent(UNSAFE_FILES)
    payload = _wire_lines(token, text)
    token = None
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(timeout)
        try:
            sock.connect(socket_path)
        except OSError:
            return _not_sent(CANNOT_CONNECT)
        try:
            sock.sendall(payload)
        except OSError:
            return {"delivered": False, "maybeDelivered": True, "error": MAYBE_SENT}
        sock.settimeout(reply_wait)
        try:
            reply = sock.recv(4096)
        except OSError:
            reply = b""  # silence (timeout) is the normal success
        if reply and _reply_is_refusal(reply):
            return _not_sent(REFUSED_BY_SESSION)
        return {"delivered": True, "maybeDelivered": True, "error": None}
    finally:
        sock.close()


def _not_sent(reason):
    return {"delivered": False, "maybeDelivered": False, "error": reason}


def deliver_row_message(agent_row, text, confirm, send=None):
    """POST /api/session/message for an inbox row (`message_via` == "inbox"),
    after validate_message_text. Same response shapes as the pane path:
    {ok, state, reason} | {ok:false, needsConfirm, reason} |
    {ok:false, error, typed:false} (nothing sent) | {ok:false, error}
    (may have arrived). The caller audits."""
    if text.startswith("/"):
        return {"ok": False, "error": SLASH_REFUSED, "typed": False}
    if pending_prompt(agent_row):
        return {"ok": False, "error": PROMPT_PENDING, "typed": False}
    busy = is_busy(agent_row)
    if busy and not confirm:
        return {"ok": False, "needsConfirm": True, "reason": BUSY_CONFIRM}
    result = (send or send_message)(agent_row["agentSession"], text)
    if not result["delivered"]:
        out = {"ok": False, "error": result["error"]}
        if not result["maybeDelivered"]:
            out["typed"] = False
        return out
    return {"ok": True, "state": "queued" if busy else "message sent",
            "reason": DELIVERED_NOTE}
