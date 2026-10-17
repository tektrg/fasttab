"""Feedback "new" dot: which feedback threads the owner has already looked at.

Stored server-side (one JSON file in the dashboard state folder) so every
browser that opens this dashboard agrees on what is new.

  GET  /api/feedback/seen   -> {ok, seen: {threadID: lastMessageAt}}
  POST /api/feedback/seen   {seen: {threadID: lastMessageAt}} -> merged map

A thread counts as seen up to the `lastMessageAt` (ms) recorded here; a newer
customer message makes it new again. Merge keeps the larger value per thread.
"""
import json
import os
import re
import threading

import dashboard_config

PATH = "/api/feedback/seen"
FILE_NAME = "feedback-seen.json"
MAX_THREADS = 5000
_ID_RE = re.compile(r"^[0-9a-fA-F-]{36}$")
_lock = threading.Lock()


def _file():
    return os.path.join(dashboard_config.STATE_HOME, FILE_NAME)


def load():
    try:
        with open(_file()) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return {k: v for k, v in data.items() if isinstance(v, (int, float))} if isinstance(data, dict) else {}


def merge(update):
    """Merge {threadID: ms}; returns the stored map. Raises ValueError on bad input."""
    if not isinstance(update, dict) or len(update) > MAX_THREADS:
        raise ValueError("seen must be an object of threadID -> lastMessageAt")
    for key, value in update.items():
        if not _ID_RE.fullmatch(key) or isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError("seen must be an object of threadID -> lastMessageAt")
    with _lock:
        seen = load()
        for key, value in update.items():
            key = key.lower()
            seen[key] = max(seen.get(key, 0), value)
        os.makedirs(os.path.dirname(_file()), exist_ok=True)
        tmp = _file() + ".tmp"
        with open(tmp, "w") as f:
            json.dump(seen, f)
        os.replace(tmp, _file())
        return seen


def handle_get(path):
    return ({"ok": True, "seen": load()}, 200) if path == PATH else None


def handle_post(path, read_body):
    if path != PATH:
        return None
    try:
        body = read_body()
        return {"ok": True, "seen": merge(body.get("seen") if isinstance(body, dict) else None)}, 200
    except ValueError as e:
        return {"ok": False, "error": str(e)}, 400
