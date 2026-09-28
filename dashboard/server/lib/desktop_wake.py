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

Pure except `open_desktop_url` (runs `open`); the rest takes injectables.
"""
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
WOKE_NOTE = "woke the session in Claude on the Mac, then " + session_inbox.DELIVERED_NOTE
#: Inbox errors that just mean "not awake yet" — keep polling.
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
