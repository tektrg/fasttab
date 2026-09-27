#!/usr/bin/env python3
"""Is a Claude prompt still on screen? Read from the session's own
`~/.claude/sessions/<pid>.json` (status busy|waiting|idle + statusUpdatedAt ms).

Shared by the dashboard's pending store (hook_permissions.py) and the
PermissionRequest hook itself (hooks/agentbar-permission-hook.py, which
imports this file to decide whether re-sending its prompt still makes sense).
Stdlib only, no I/O: both callers pass the session file dict they read.
"""

#: Session-file `entrypoint`s whose prompt Claude shows while the hook runs
#: (so a hook that keeps running never stalls the agent).
PROMPT_SHOWING_ENTRYPOINTS = frozenset({"cli", "claude-desktop"})

#: A fresh `waiting` write this soon after the prompt started is the SAME
#: prompt's status landing late; later than this it is the next prompt (the
#: one we care about got answered in Claude and the session moved on).
WAITING_REWRITE_GRACE_SEC = 1.0


def shows_own_prompt(session_entry, session_id):
    """True when `session_entry` is `session_id`'s file and Claude shows that
    session's prompts itself while hooks run (interactive CLI / Desktop)."""
    return (isinstance(session_entry, dict)
            and session_entry.get("sessionId") == session_id
            and session_entry.get("entrypoint") in PROMPT_SHOWING_ENTRYPOINTS)


def session_moved_on(session_entry, prompt_started_at):
    """The session's status changed after the prompt started (wall-clock
    seconds): that prompt is gone. `waiting` again counts too once past the
    rewrite grace — that is the NEXT prompt. No file / no timestamp -> False."""
    if not isinstance(session_entry, dict):
        return False
    status_ms = session_entry.get("statusUpdatedAt")
    if not isinstance(status_ms, (int, float)) or status_ms / 1000.0 <= prompt_started_at:
        return False
    if session_entry.get("status") != "waiting":
        return True
    return status_ms / 1000.0 - prompt_started_at > WAITING_REWRITE_GRACE_SEC


def prompt_may_still_be_up(session_entry, prompt_started_at):
    """Hook side: re-sending this prompt can still help. A file with no
    statusUpdatedAt can't date a status change, so there only `waiting`
    counts — else a hook would re-send for up to its whole retry window
    after the prompt was answered while the dashboard stayed down."""
    if not isinstance(session_entry, dict):
        return False
    if not isinstance(session_entry.get("statusUpdatedAt"), (int, float)):
        return session_entry.get("status") == "waiting"
    return not session_moved_on(session_entry, prompt_started_at)


def prompt_still_waiting(session_entry, prompt_started_at):
    """The session file says a prompt is up and it is (still) this one."""
    return (isinstance(session_entry, dict) and session_entry.get("status") == "waiting"
            and not session_moved_on(session_entry, prompt_started_at))
