#!/usr/bin/env python3
"""Message a SLEEPING Claude Desktop session: wake it, then deliver through
its inbox (session_inbox.py).

Why: Claude Desktop stops an unused session's `claude` process, so its row
ends (no `~/.claude/sessions/<pid>.json`, no peer socket) and a plain send
has nothing to reach. Opening the session's own deep link
(`claude://code/continue?session=local_…`, the "Open in Claude" link) makes
Desktop start a new process for the SAME Claude session id (new pid), which
brings its inbox back. So: open the link on this Mac, poll the inbox by
session id until it accepts, never longer than WAKE_WAIT_SEC.

Which rows: an ended board row whose row id (= the Claude session id) is a
`computed.sleepingSessions` entry's `cliSessionId` — the server only knows
Desktop sessions on its own Mac, which is also where `open` runs.

Rules: always a confirm first (it visibly opens Claude.app on the Mac);
same text rules as an inbox send (no slash command); a send that may have
left (`maybeDelivered`) is never retried.

A LIVE Desktop row can still be asleep underneath (seen 2026-10-25): Desktop
stops using an idle session while its process keeps the inbox open, so the
inbox accepts a message and it never lands. So a Desktop inbox send is
confirmed in the session's transcript (`deliver_live_desktop`); unconfirmed
-> wake via the deep link, resend once if the process was replaced, confirm
again, else a clear "did not arrive" error.

Pure except `open_desktop_url` (runs `open`) and the transcript reads; the
rest takes injectables.
"""
import glob
import json
import os
import subprocess
import time

import claude_sessions
import session_inbox

WAKE_WAIT_SEC = 30.0
POLL_SEC = 0.5
OPEN_TIMEOUT_SEC = 10

WAKE_CONFIRM = ("that Claude Desktop session is asleep — sending opens it in "
                "Claude on the Mac to wake it, then delivers. Confirm to wake it")
OPEN_FAILED = ("could not open the session in Claude on the Mac — nothing "
               "was sent")
WAKE_TIMEOUT = ("opened the session in Claude on the Mac, but it did not wake "
                "in time — nothing was sent. Try again, or open it on the Mac")
NOT_LANDED = ("the session accepted the message but never showed it (Claude "
              "Desktop had it asleep) — waking it did not help. Open it in "
              "Claude on the Mac and resend")
WOKE_NOTE = "woke the session in Claude on the Mac, then " + session_inbox.DELIVERED_NOTE
#: Inbox errors that just mean "not awake yet" — keep polling.
#: How long a sent message may take to show in the transcript (measured <1s).
LAND_WAIT_SEC = 5.0
#: Wake budget for a live row: land + wake + land must stay under AgentBar's
#: 30s session-action timeout (DashboardEndpoint.sessionActionTimeoutSeconds).
LIVE_WAKE_WAIT_SEC = 18.0
#: Max transcript bytes read per landing check.
_TAIL_LIMIT = 4 * 1024 * 1024
_NOT_AWAKE_YET = frozenset({session_inbox.NOT_RUNNING, session_inbox.UNSUPPORTED,
                            session_inbox.UNSAFE_FILES, session_inbox.CANNOT_CONNECT})


def _open_url_of(sleeping):
    url = (sleeping or {}).get("openUrl")
    desktop_id = (sleeping or {}).get("desktopSessionId")
    if (isinstance(desktop_id, str)
            and claude_sessions.DESKTOP_SESSION_ID_RE.fullmatch(desktop_id)
            and url == claude_sessions.DESKTOP_CONTINUE_URL.format(desktop_id)):
        return url
    return None


def find_sleeping(row_id, sleeping_sessions):
    """The sleeping Desktop session behind board row `row_id`, or None
    (no match, or a link that isn't Claude's own shape)."""
    if not row_id:
        return None
    for s in sleeping_sessions or []:
        if s.get("cliSessionId") == row_id and _open_url_of(s):
            return s
    return None


def annotate_wakeable_rows(rows, sleeping_sessions):
    """Mark ended board rows that can be woken: `derived.messageVia = "wake"`
    and their `openUrl`. The UI shows the Composer on exactly these."""
    for r in rows or []:
        if r.get("status") != "ended":
            continue
        s = find_sleeping(r.get("rowId"), sleeping_sessions)
        if s:
            derived = r.setdefault("derived", {})
            derived["messageVia"] = "wake"
            derived["openUrl"] = s["openUrl"]


def open_desktop_url(url):
    """`open <claude://…>` on this Mac. True when `open` succeeded."""
    try:
        return subprocess.run(["open", url], capture_output=True,
                              timeout=OPEN_TIMEOUT_SEC).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def deliver_to_sleeping(sleeping, text, confirm, open_url=None, send=None,
                        sleep=time.sleep, clock=time.monotonic,
                        wait_sec=WAKE_WAIT_SEC, poll_sec=POLL_SEC):
    """POST /api/session/message for a sleeping Desktop row, after
    validate_message_text. Same response shapes as
    session_inbox.deliver_row_message; the caller audits."""
    if text.startswith("/"):
        return {"ok": False, "error": session_inbox.SLASH_REFUSED, "typed": False}
    if not confirm:
        return {"ok": False, "needsConfirm": True, "reason": WAKE_CONFIRM}
    url = _open_url_of(sleeping)
    if not url or not (open_url or open_desktop_url)(url):
        return {"ok": False, "error": OPEN_FAILED, "typed": False}
    send = send or session_inbox.send_message
    deadline = clock() + wait_sec
    while True:
        result = send(sleeping["cliSessionId"], text)
        if result["delivered"]:
            return {"ok": True, "state": "message sent", "reason": WOKE_NOTE}
        if result["maybeDelivered"]:
            return {"ok": False, "error": result["error"]}
        if result["error"] not in _NOT_AWAKE_YET:
            return {"ok": False, "error": result["error"], "typed": False}
        if clock() >= deadline:
            return {"ok": False, "error": WAKE_TIMEOUT, "typed": False}
        sleep(poll_sec)


# ── Live Desktop rows: confirm the message landed ────────────────────────

def transcript_path(session_id, projects_dir=None):
    """`~/.claude/projects/<cwd-slug>/<session id>.jsonl`, or None."""
    if not session_id or "/" in session_id or session_id.startswith("."):
        return None
    base = projects_dir or os.path.join(os.path.expanduser("~"), ".claude", "projects")
    found = glob.glob(os.path.join(glob.escape(base), "*", glob.escape(session_id) + ".jsonl"))
    return found[0] if found else None


def transcript_size(path):
    try:
        return os.path.getsize(path) if path else 0
    except OSError:
        return 0


def _entry_text(entry):
    """The text of a transcript user line or a queued-input line."""
    if entry.get("type") == "queue-operation":
        content = entry.get("content")
    elif entry.get("type") == "user":
        content = (entry.get("message") or {}).get("content")
    else:
        return ""
    if isinstance(content, list):
        content = " ".join(p.get("text", "") for p in content if isinstance(p, dict))
    return content if isinstance(content, str) else ""


def has_landed(path, offset, text):
    """True when a user / queued line written after byte `offset` carries
    `text` (the session shows a peer message verbatim)."""
    needle = text.strip()[:200]
    if not path or not needle:
        return False
    try:
        with open(path, "rb") as f:
            f.seek(offset)
            chunk = f.read(_TAIL_LIMIT)
    except OSError:
        return False
    for line in chunk.decode("utf-8", errors="replace").splitlines():
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if isinstance(entry, dict) and needle in _entry_text(entry):
            return True
    return False


def _wait_landed(path_of, offset, text, wait_sec, poll_sec, sleep, clock):
    deadline = clock() + wait_sec
    while True:
        if has_landed(path_of(), offset, text):
            return True
        if clock() >= deadline:
            return False
        sleep(poll_sec)


def deliver_live_desktop(agent, text, confirm, deliver, open_url=None, send=None,
                         resolve=None, projects_dir=None, sleep=time.sleep,
                         clock=time.monotonic, land_wait_sec=LAND_WAIT_SEC,
                         wake_wait_sec=LIVE_WAKE_WAIT_SEC, poll_sec=POLL_SEC):
    """Inbox send to a LIVE Claude Desktop row, confirmed in its transcript.
    `deliver(agent, text, confirm)` is session_inbox.deliver_row_message.
    Not landed -> open the deep link; when Desktop starts a new process
    (new pid) the old one's queue is gone, so resend once; still not landed
    -> NOT_LANDED. Never resends to the same process (no duplicates)."""
    session_id = agent.get("agentSession")
    path_of = lambda: transcript_path(session_id, projects_dir)
    offset = transcript_size(path_of())
    result = deliver(agent, text, confirm)
    url = _open_url_of({"openUrl": agent.get("openUrl"),
                        "desktopSessionId": agent.get("hostSessionId")})
    if not result.get("ok") or not url:
        return result
    if _wait_landed(path_of, offset, text, land_wait_sec, poll_sec, sleep, clock):
        return result
    if not (open_url or open_desktop_url)(url):
        return {"ok": False, "error": NOT_LANDED}
    resolve = resolve or session_inbox.resolve_session
    send = send or session_inbox.send_message
    old_pid = agent.get("pid")
    deadline = clock() + wake_wait_sec
    while True:
        if has_landed(path_of(), offset, text):
            return {"ok": True, "state": "message sent", "reason": WOKE_NOTE}
        entry, _reason = resolve(session_id)
        if entry is not None and str(entry.get("pid")) != str(old_pid):
            resent = send(session_id, text)
            if resent["delivered"] and _wait_landed(
                    path_of, offset, text, land_wait_sec, poll_sec, sleep, clock):
                return {"ok": True, "state": "message sent", "reason": WOKE_NOTE}
            return {"ok": False, "error": resent["error"] or NOT_LANDED}
        if clock() >= deadline:
            return {"ok": False, "error": NOT_LANDED}
        sleep(poll_sec)
