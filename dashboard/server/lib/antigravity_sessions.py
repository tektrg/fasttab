#!/usr/bin/env python3
"""Google Antigravity sessions tracked via `~/.gemini/config/hooks.json`.

The Antigravity hook (`dashboard/integrations/antigravity/antigravity-status-hook.py`)
writes one JSON state file per conversation under
`~/.local/state/agentbar/antigravity/<conversationId>.json`. This module reads
those files, tail-reads a short recap from `transcript.jsonl` (mtime-cached),
and builds status-only agent rows with `source: "antigravity"`.
"""
import json
import os
import time

import hook_permission_summary

SESSIONS_DIR = os.environ.get(
    "AGENTBAR_ANTIGRAVITY_DIR",
    os.path.expanduser("~/.local/state/agentbar/antigravity"),
)
ANTIGRAVITY_SOURCE = "antigravity"
HOOK_STATE_BY_STATUS = {"busy": "working", "waiting": "blocked", "idle": "idle"}
DEFAULT_WAITING_REASON = "Input needed"

#: Drop idle sessions older than 12 hours so the list stays focused on active work.
MAX_IDLE_AGE_SEC = 12 * 3600
#: A `busy` session with no hook update for 30 minutes is treated as idle (e.g. app closed mid-turn).
BUSY_STALE_SEC = 30 * 60
#: Tail read size for extracting a one-line recap from transcript.jsonl.
RECAP_TAIL_BYTES = 128 * 1024


def _single_line(text, max_len=240):
    cleaned = " ".join((text or "").split())
    if len(cleaned) > max_len:
        return cleaned[: max_len - 1].rstrip() + "…"
    return cleaned


class _RecapCache:
    """Caches (mtime, size) -> latest PLANNER_RESPONSE one-liner per transcript path."""

    def __init__(self):
        self._cache = {}

    def read(self, transcript_path):
        if not transcript_path or not isinstance(transcript_path, str):
            return None
        path = os.path.expanduser(transcript_path)
        try:
            st = os.stat(path)
        except OSError:
            return None
        key = (st.st_mtime_ns, st.st_size)
        cached = self._cache.get(path)
        if cached and cached[0] == key:
            return cached[1]
        recap = _read_transcript_recap(path, st.st_size)
        self._cache[path] = (key, recap)
        return recap


_RECAP_CACHE = _RecapCache()


def _read_transcript_recap(path, file_size):
    try:
        with open(path, "rb") as f:
            start = max(0, file_size - RECAP_TAIL_BYTES)
            if start > 0:
                f.seek(start)
            data = f.read()
    except OSError:
        return None
    lines = data.decode("utf-8", errors="replace").splitlines()
    if start > 0 and lines:
        lines = lines[1:]
    for raw in reversed(lines):
        if "PLANNER_RESPONSE" not in raw:
            continue
        try:
            obj = json.loads(raw)
        except ValueError:
            continue
        if obj.get("type") != "PLANNER_RESPONSE":
            continue
        content = (obj.get("content") or "").strip()
        if content:
            return _single_line(content, max_len=240)
    return None


def read_live_sessions(sessions_dir=SESSIONS_DIR, now=None):
    """Return active Antigravity session dicts from `sessions_dir`. Never raises."""
    now = time.time() if now is None else now
    if not sessions_dir or not os.path.isdir(sessions_dir):
        return []
    entries = []
    try:
        names = sorted(os.listdir(sessions_dir))
    except OSError:
        return []
    for name in names:
        if not name.endswith(".json") or name.startswith("."):
            continue
        path = os.path.join(sessions_dir, name)
        try:
            with open(path, "r", encoding="utf-8") as f:
                entry = json.load(f)
        except (OSError, ValueError):
            continue
        if not isinstance(entry, dict) or not entry.get("conversationId"):
            continue
        updated_ms = entry.get("updatedAt") or entry.get("statusUpdatedAt")
        if isinstance(updated_ms, (int, float)):
            age_sec = max(0.0, now - updated_ms / 1000.0)
            if age_sec > MAX_IDLE_AGE_SEC:
                continue
            if entry.get("status") == "busy" and age_sec > BUSY_STALE_SEC:
                entry = dict(entry, status="idle")
        recap = _RECAP_CACHE.read(entry.get("transcriptPath"))
        if recap:
            entry = dict(entry, recap=recap)
        entries.append(entry)
    return entries


def _waiting_reason(entry):
    q = entry.get("transcriptQuestion")
    if isinstance(q, dict) and q.get("question"):
        return q["question"]
    waiting_for = (entry.get("waitingFor") or "").strip()
    return (waiting_for[:1].upper() + waiting_for[1:]) if waiting_for else DEFAULT_WAITING_REASON


def build_status_only_rows(sessions, herdr_session_ids, now, machine, hook_requests=None):
    """Build dashboard agent rows for Antigravity sessions."""
    hook_requests = hook_requests or {}
    rows = []
    for entry in sessions or []:
        conv_id = entry.get("conversationId")
        if not conv_id or conv_id in herdr_session_ids:
            continue
        status = entry.get("status")
        hook_state = HOOK_STATE_BY_STATUS.get(status)
        status_ms = entry.get("statusUpdatedAt") or entry.get("updatedAt")
        seconds_in_status = (
            max(0.0, now - status_ms / 1000.0)
            if isinstance(status_ms, (int, float))
            else None
        )
        cwd = entry.get("cwd")
        hook_request = hook_requests.get(conv_id)
        transcript_question = entry.get("transcriptQuestion") if status == "waiting" and not hook_request else None
        hook_reason = _waiting_reason(entry) if status == "waiting" else entry.get("recap")
        if hook_request:
            hook_state = "blocked"
            hook_reason = hook_permission_summary.needs_you_detail(hook_request)
            seconds_in_status = hook_request.get("sinceSec", seconds_in_status)
        rows.append({
            "paneId": None,
            "tabId": None,
            "workspaceId": None,
            "label": entry.get("label") or os.path.basename((cwd or "").rstrip("/")) or conv_id,
            "cwd": cwd,
            "focused": False,
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
            "agentSession": conv_id,
            "agentKind": "antigravity",
            "hookReason": hook_reason,
            "screenState": None,
            "screenSignal": entry.get("recap") if status != "busy" else None,
            "screenQuestion": None,
            "screenPermission": None,
            "hookQuestion": None,
            "machine": machine,
            "source": ANTIGRAVITY_SOURCE,
            "sessionStatus": status,
            "secondsInStatus": seconds_in_status,
            "pid": None,
            "hostSessionId": None,
            "tmuxTarget": None,
            "openUrl": None,
            "messageVia": None,
            "hookRequest": hook_request,
            "transcriptQuestion": transcript_question,
            "wrapUpQuestion": None,
        })
    return rows
