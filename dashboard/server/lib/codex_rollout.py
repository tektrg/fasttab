#!/usr/bin/env python3
"""Codex rollout reader: turn state + exact context % from a session's
`~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<session uuid>.jsonl`.

Codex (the ChatGPT-bundled alpha) changes this format between builds, so
every read is tolerant: a line that isn't JSON, or a field that moved, is
skipped — never an exception, never a guessed number.

  read_rollout(path) -> {"status": working|idle|None, "contextPercent": float|None,
                         "lastMessage": str|None, "mtime": float} | None

Rules (measured on 0.154.0-alpha.6.2, 2026-09-28):
  * a `task_started` event with no later `task_complete`/`turn_aborted` = working
  * context % = last `token_count` info.last_token_usage.total_tokens /
    info.model_context_window (the window also rides on `task_started`)
  * `task_complete.last_agent_message` is the reply text (question detection)
Only the tail is read (TAIL_BYTES), cached by (path, mtime, size).
"""
import glob
import json
import os
import stat

CODEX_HOME_ENV = "CODEX_HOME"
TAIL_BYTES = 256 * 1024
TURN_START_TYPES = ("task_started", "turn_started")
TURN_END_TYPES = ("task_complete", "turn_complete", "turn_aborted", "task_aborted")

_cache = {}  # path -> ((mtime, size), result)


def codex_home():
    return os.path.expanduser(os.environ.get(CODEX_HOME_ENV) or "~/.codex")


def find_rollout(session_id, transcript_path=None):
    """The rollout file of one session: the hook's transcript_path when it is a
    regular file under the Codex home, else a glob by session id. None if
    nothing matches (a new session writes its file a moment later)."""
    home = os.path.realpath(codex_home())
    if isinstance(transcript_path, str) and transcript_path:
        real = os.path.realpath(os.path.expanduser(transcript_path))
        if real.startswith(home + os.sep) and _is_regular_file(real):
            return real
    if not isinstance(session_id, str) or not session_id.replace("-", "").isalnum():
        return None
    matches = glob.glob(os.path.join(home, "sessions", "*", "*", "*",
                                     f"rollout-*{session_id}.jsonl"))
    matches = [m for m in matches if _is_regular_file(m)]
    return max(matches, key=os.path.getmtime) if matches else None


def _is_regular_file(path):
    try:
        return stat.S_ISREG(os.lstat(path).st_mode)
    except OSError:
        return False


def _tail_lines(path, size):
    with open(path, "rb") as f:
        if size > TAIL_BYTES:
            f.seek(size - TAIL_BYTES)
            f.readline()  # drop the partial first line
        return f.read().decode("utf-8", "replace").splitlines()


def _context_percent(info):
    if not isinstance(info, dict):
        return None
    last = info.get("last_token_usage")
    used = last.get("total_tokens") if isinstance(last, dict) else None
    window = info.get("model_context_window")
    if not _is_number(used) or not _is_number(window) or window <= 0:
        return None
    return round(min(100.0, 100.0 * used / window), 1)


def _is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def parse_lines(lines):
    """Fold rollout lines into {status, contextPercent, lastMessage}."""
    status = None
    context_percent = None
    last_message = None
    for line in lines:
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        payload = entry.get("payload") if isinstance(entry, dict) else None
        if not isinstance(payload, dict) or entry.get("type") != "event_msg":
            continue
        kind = payload.get("type")
        if kind in TURN_START_TYPES:
            status = "working"
            last_message = None
        elif kind in TURN_END_TYPES:
            status = "idle"
            message = payload.get("last_agent_message")
            last_message = message if isinstance(message, str) else None
        elif kind == "token_count":
            context_percent = _context_percent(payload.get("info")) or context_percent
    return {"status": status, "contextPercent": context_percent,
            "lastMessage": last_message}


def read_rollout(path):
    """Parsed tail of one rollout file, or None when unreadable."""
    try:
        st = os.stat(path)
        key = (st.st_mtime, st.st_size)
        cached = _cache.get(path)
        if cached and cached[0] == key:
            return cached[1]
        result = parse_lines(_tail_lines(path, st.st_size))
        result["mtime"] = st.st_mtime
    except (OSError, TypeError):
        return None
    _cache[path] = (key, result)
    return result
