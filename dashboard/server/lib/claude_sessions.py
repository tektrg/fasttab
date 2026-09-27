#!/usr/bin/env python3
"""Claude Code sessions that live OUTSIDE herdr (P4): Claude Desktop's code
sessions and stray CLI runs (a plain Terminal tab, tmux), as status-only rows.

Source: every running Claude Code process keeps `~/.claude/sessions/<pid>.json`
up to date (name, cwd, status busy|waiting|idle, statusUpdatedAt ms). The file
outlives a killed process, so a row is only built for a pid that is still
alive AND — when the file records `procStart` — still the same process (a
recycled pid would otherwise resurrect a dead session as a phantom row).

Local machine only: the Air's sessions folder is not read (would need ssh).

Pure except `read_live_sessions` (filesystem + one `ps`). One bad file is
skipped, never fatal — same per-entry rule as the hook-cache feed.
"""
import calendar
import json
import os
import re
import subprocess
import time

import hook_permission_summary

SESSIONS_DIR = os.environ.get(
    "CLAUDE_SESSIONS_DIR", os.path.expanduser("~/.claude/sessions"))

#: `entrypoint` -> the row's `source` field. Anything else is still shown,
#: tagged `claude-<entrypoint>` so it's never mistaken for a herdr pane.
SOURCE_BY_ENTRYPOINT = {"claude-desktop": "claude-desktop", "cli": "claude-cli"}
#: Every `source` value a status-only (paneless) row can carry.
HERDR_SOURCE = "herdr"

#: Claude Code's session status -> the hook vocabulary every consumer already
#: speaks (hookState: working / blocked / idle). `waiting` = the session shows
#: a prompt it needs answered (permission box or question): a human must act.
HOOK_STATE_BY_STATUS = {"busy": "working", "waiting": "blocked", "idle": "idle"}
DEFAULT_WAITING_REASON = "Input needed"

#: Claude Desktop's own deep-link validator for `claude://code/continue`
#: (app.asar, claudeURLHandler): `session` must be "last" or match this. It
#: opens the EXISTING session with that desktop id (`hostSessionId` here) and
#: falls back to Code home when none matches — it never creates a session.
DESKTOP_SESSION_ID_RE = re.compile(r"^local_[A-Za-z0-9-]{1,64}$")
DESKTOP_CONTINUE_URL = "claude://code/continue?session={}"


def is_status_only_row(agent_row):
    """True for a row built here (no pane: no stop/close/focus/answer)."""
    source = (agent_row or {}).get("source")
    return bool(source) and source != HERDR_SOURCE


def _pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # exists, owned by someone else
    except (OSError, OverflowError, ValueError):
        return False
    return True


def _normalize_ws(text):
    return " ".join((text or "").split())


#: `procStart` / `ps -o lstart` shape: "Sat Sep 26 11:34:21 2026".
_LSTART_FORMAT = "%a %b %d %H:%M:%S %Y"
#: ps prints whole seconds; allow one second of slack.
_PROC_START_TOLERANCE_SEC = 1


def _same_process_start(recorded, ps_lstart):
    """Does the file's `procStart` name the process ps sees now? Claude Code
    writes it in UTC (measured: 11:34 in the file, 18:34 from ps at UTC+7), ps
    prints local time — so compare as instants, accepting either reading of
    the recorded one. Unparseable -> True (liveness alone decides)."""
    try:
        actual_epoch = time.mktime(time.strptime(_normalize_ws(ps_lstart), _LSTART_FORMAT))
        recorded_struct = time.strptime(_normalize_ws(recorded), _LSTART_FORMAT)
    except (ValueError, OverflowError):
        return True
    readings = (calendar.timegm(recorded_struct), time.mktime(recorded_struct))
    return any(abs(r - actual_epoch) <= _PROC_START_TOLERANCE_SEC for r in readings)


def _proc_start_by_pid(pids):
    """{pid: 'Sat Sep 26 11:34:21 2026'} from ONE ps call; {} if ps fails
    (then only the liveness check applies)."""
    if not pids:
        return {}
    try:
        out = subprocess.run(
            ["ps", "-o", "pid=,lstart=", "-p", ",".join(str(p) for p in pids)],
            capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return {}
    starts = {}
    for line in out.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[0].isdigit():
            starts[int(parts[0])] = _normalize_ws(parts[1])
    return starts


def _parse_session_file(path):
    """The file's dict when it names a usable interactive session, else None."""
    try:
        with open(path, "r") as f:
            entry = json.load(f)
    except Exception:
        return None
    if not isinstance(entry, dict):
        return None
    pid, session_id = entry.get("pid"), entry.get("sessionId")
    if not isinstance(pid, int) or not isinstance(session_id, str) or not session_id:
        return None
    # `claude -p` / SDK one-shots are not sessions anyone switches to.
    if entry.get("kind") not in (None, "interactive"):
        return None
    return entry


def read_live_sessions(sessions_dir=None, pid_alive=_pid_alive,
                       proc_start_by_pid=_proc_start_by_pid):
    """Every live session file's dict, newest status first. A missing folder
    is an empty list (Claude Code not installed), not an error."""
    sessions_dir = sessions_dir or SESSIONS_DIR
    if not os.path.isdir(sessions_dir):
        return []
    candidates = []
    for fname in os.listdir(sessions_dir):
        if not fname.endswith(".json"):
            continue
        entry = _parse_session_file(os.path.join(sessions_dir, fname))
        if entry and pid_alive(entry["pid"]):
            candidates.append(entry)
    starts = proc_start_by_pid([e["pid"] for e in candidates])
    live = []
    for entry in candidates:
        recorded = entry.get("procStart")
        actual = starts.get(entry["pid"])
        if recorded and actual and not _same_process_start(recorded, actual):
            continue  # pid recycled by an unrelated process
        live.append(entry)
    live.sort(key=lambda e: -(e.get("statusUpdatedAt") or 0))
    return live


def _desktop_open_url(entry):
    host_id = entry.get("hostSessionId")
    if (entry.get("entrypoint") == "claude-desktop" and isinstance(host_id, str)
            and DESKTOP_SESSION_ID_RE.fullmatch(host_id)):  # `$` alone lets "…\n" through
        return DESKTOP_CONTINUE_URL.format(host_id)
    return None


def _waiting_reason(entry):
    waiting_for = (entry.get("waitingFor") or "").strip()
    return (waiting_for[:1].upper() + waiting_for[1:]) if waiting_for else DEFAULT_WAITING_REASON


def build_status_only_rows(sessions, herdr_session_ids, now, machine,
                           hook_requests=None):
    """Agent rows (same keys build_agents_view emits for a herdr pane) for
    every session NOT already a herdr row. `now` in seconds.
    `hook_requests`: {session_id: hookRequest} from hook_permissions — a
    session with one reads `blocked` even before its file says `waiting`."""
    hook_requests = hook_requests or {}
    rows = []
    for entry in sessions or []:
        session_id = entry.get("sessionId")
        if not session_id or session_id in herdr_session_ids:
            continue
        status = entry.get("status")
        hook_state = HOOK_STATE_BY_STATUS.get(status)
        status_ms = entry.get("statusUpdatedAt") or entry.get("updatedAt")
        seconds_in_status = (max(0.0, now - status_ms / 1000.0)
                             if isinstance(status_ms, (int, float)) else None)
        cwd = entry.get("cwd")
        entrypoint = entry.get("entrypoint") or "unknown"
        hook_request = hook_requests.get(session_id)
        hook_reason = _waiting_reason(entry) if status == "waiting" else None
        if hook_request:
            hook_state = "blocked"
            hook_reason = hook_permission_summary.needs_you_detail(hook_request)
        rows.append({
            "paneId": None,
            "tabId": None,
            "workspaceId": None,
            "label": entry.get("name") or os.path.basename((cwd or "").rstrip("/")) or session_id,
            "cwd": cwd,
            "focused": False,
            # The session's own status, in hook vocabulary, so derived:state,
            # the board and AgentBar's section rules read it unchanged.
            "hookState": hook_state,
            "hookSinceSec": seconds_in_status,
            "herdrStatus": None,
            "disagree": False,
            "screenUnchangedSec": None,
            "subagentsRunning": 0,
            "herdrTurnReported": False,
            "hasHookData": hook_state is not None,
            "backgroundWaitExpired": False,
            "residue": False,
            "agentSession": session_id,
            "hookReason": hook_reason,
            "screenState": None,
            "screenSignal": None,
            "screenQuestion": None,
            "screenPermission": None,
            "hookQuestion": None,
            "machine": machine,
            "source": SOURCE_BY_ENTRYPOINT.get(entrypoint, f"claude-{entrypoint}"),
            "sessionStatus": status,
            "secondsInStatus": seconds_in_status,
            "pid": entry.get("pid"),
            "hostSessionId": entry.get("hostSessionId"),
            # "session:@window.%pane" when the CLI runs inside tmux, else None.
            "tmuxTarget": entry.get("tmux"),
            "openUrl": _desktop_open_url(entry),
            # Answerable prompt sent by the PermissionRequest hook, or None.
            "hookRequest": hook_request,
        })
    return rows
