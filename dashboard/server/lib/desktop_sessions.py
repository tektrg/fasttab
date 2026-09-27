#!/usr/bin/env python3
"""Sleeping Claude Desktop sessions: Desktop code sessions whose Claude process
is not running (Desktop stops an unused session's process), so
claude_sessions.py has no live `~/.claude/sessions/<pid>.json` for them.

Source: Claude Desktop's own session list, one JSON file per session:
`<store>/<account>/<org>/local_<uuid>.json`, where <store> is a
`claude-code-sessions` folder inside a Desktop profile (the app's
`--user-data-dir`). Profiles found here: the default
`~/Library/Application Support/Claude*/` and every `~/.claude-instances/*/`
(Desktop launched with `--user-data-dir=~/.claude-instances/<name>`). Other
files in an org folder (`scheduled-tasks.json`, `archived-sessions.idx`,
`deleted_*`, `backlog/`) are not sessions and are never read.

Last activity = the file's `lastActivityAt` (ms), else `createdAt`. Measured
2026-09-27 against the running profile: it equals the transcript's newest
user/assistant message timestamp. NOT the transcript's mtime (Claude appends
cost-state / last-prompt / permission-mode lines when a session is merely
loaded, which made month-old sessions look 2 days old) and NOT this file's
mtime (bumped by focus/metadata writes). The file is rewritten whenever
`lastActivityAt` changes, so its mtime is always >= that value: a cheap
stat filter drops every file older than the window before any JSON parse,
and parsed files are cached by (path, mtime).

Pure except `DesktopSessionScanner.scan` (filesystem only).
"""
import glob
import json
import os
import time

import claude_sessions

#: How far back the dashboard reports sleeping sessions. AgentBar narrows it to
#: the user's own list/search days (Settings, up to this many).
SLEEPING_WINDOW_DAYS = int(os.environ.get("CLAUDE_DESKTOP_SLEEPING_DAYS", "14"))
SESSION_FILE_PREFIX = "local_"
SESSION_FILE_SUFFIX = ".json"
#: Env override (os.pathsep-separated store folders) for tests / a second instance.
STORES_ENV = "CLAUDE_DESKTOP_SESSION_STORES"
_DEFAULT_STORE_GLOBS = (
    "~/Library/Application Support/Claude*/claude-code-sessions",
    "~/.claude-instances/*/claude-code-sessions",
)


def default_store_dirs():
    override = os.environ.get(STORES_ENV)
    if override is not None:
        return [d for d in override.split(os.pathsep) if d]
    dirs = []
    for pattern in _DEFAULT_STORE_GLOBS:
        dirs.extend(sorted(glob.glob(os.path.expanduser(pattern))))
    return [d for d in dirs if os.path.isdir(d)]


def _session_file_paths(store_dir):
    """Every `local_*.json` two folders down (<account>/<org>/), with its
    mtime. Unreadable folders are skipped."""
    for account in _subdirs(store_dir):
        for org in _subdirs(account):
            try:
                entries = list(os.scandir(org))
            except OSError:
                continue
            for entry in entries:
                name = entry.name
                if not (name.startswith(SESSION_FILE_PREFIX) and name.endswith(SESSION_FILE_SUFFIX)):
                    continue
                try:
                    yield entry.path, entry.stat().st_mtime
                except OSError:
                    continue


def _subdirs(path):
    try:
        return [e.path for e in os.scandir(path) if e.is_dir(follow_symlinks=False)]
    except OSError:
        return []


def _ms_to_sec(value):
    return value / 1000.0 if isinstance(value, (int, float)) and not isinstance(value, bool) and value > 0 else None


def parse_session_file(path):
    """The compact sleeping-session dict for one Desktop session file, or None
    (unreadable, archived, not a `local_…` id Claude.app can open)."""
    try:
        with open(path, "r") as f:
            entry = json.load(f)
    except Exception:
        return None
    if not isinstance(entry, dict) or entry.get("isArchived") is True:
        return None
    desktop_id = entry.get("sessionId")
    if not isinstance(desktop_id, str) or not claude_sessions.DESKTOP_SESSION_ID_RE.fullmatch(desktop_id):
        return None
    last_active = _ms_to_sec(entry.get("lastActivityAt")) or _ms_to_sec(entry.get("createdAt"))
    if last_active is None:
        return None
    cwd = entry.get("cwd") if isinstance(entry.get("cwd"), str) else None
    cli_id = entry.get("cliSessionId") if isinstance(entry.get("cliSessionId"), str) else None
    title = entry.get("title") if isinstance(entry.get("title"), str) else None
    title = " ".join(title.split()) if title else None
    return {
        "desktopSessionId": desktop_id,
        "cliSessionId": cli_id or None,
        "label": title or os.path.basename((cwd or "").rstrip("/")) or desktop_id,
        "cwd": cwd,
        "lastActiveTs": last_active,
        "openUrl": claude_sessions.DESKTOP_CONTINUE_URL.format(desktop_id),
    }


class DesktopSessionScanner:
    """Stat-filtered, (path, mtime)-cached reader of every Desktop session
    store. One instance per feed; `scan` is the whole poll."""

    def __init__(self, store_dirs=None, window_days=SLEEPING_WINDOW_DAYS):
        self._store_dirs = store_dirs
        self.window_sec = window_days * 86400
        self._cache = {}  # path -> (mtime, parsed dict | None)

    def scan(self, now=None):
        """Non-archived Desktop sessions active within the window, newest first."""
        now = time.time() if now is None else now
        cutoff = now - self.window_sec
        store_dirs = self._store_dirs if self._store_dirs is not None else default_store_dirs()
        seen, sessions = {}, []
        for store in store_dirs:
            for path, mtime in _session_file_paths(store):
                if mtime < cutoff:
                    continue  # last activity <= mtime: too old, never parsed
                cached = self._cache.get(path)
                parsed = cached[1] if cached and cached[0] == mtime else parse_session_file(path)
                seen[path] = (mtime, parsed)
                if parsed and parsed["lastActiveTs"] >= cutoff:
                    sessions.append(parsed)
        self._cache = seen
        sessions.sort(key=lambda s: -s["lastActiveTs"])
        return sessions


def build_sleeping_sessions(desktop_sessions, live_sessions, agent_rows):
    """The Desktop sessions that are NOT running now. A running one is already
    a row (status-only, or a herdr pane): matched by its Desktop id (a live
    file's `hostSessionId`) or its Claude session id (`cliSessionId` == a live
    file's `sessionId` / any row's `agentSession`). Live wins."""
    live_desktop_ids = {s.get("hostSessionId") for s in live_sessions or [] if s.get("hostSessionId")}
    live_session_ids = {s.get("sessionId") for s in live_sessions or [] if s.get("sessionId")}
    live_session_ids |= {r.get("agentSession") for r in agent_rows or [] if r.get("agentSession")}
    return [s for s in desktop_sessions or []
            if s["desktopSessionId"] not in live_desktop_ids
            and not (s.get("cliSessionId") and s["cliSessionId"] in live_session_ids)]
