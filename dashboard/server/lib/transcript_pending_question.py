#!/usr/bin/env python3
"""Read-only fallback for a `waiting` status-only session (Claude Desktop /
CLI outside herdr) whose prompt the hook bridge does NOT hold (hook not
installed, dashboard restarted before the hook re-sent it, AgentBar away):
the pending AskUserQuestion read from the tail of the session's transcript
(`~/.claude/projects/*/<sessionId>.jsonl`), so AgentBar can at least SHOW
what is being asked. Nothing here can answer it — that stays in Claude.

Cheap by construction (called from the 3s claudeSessions feed): only
`waiting` sessions, one tail window of at most TAIL_BYTES, symlinks and
non-regular files skipped, results cached by (path, mtime, size) and the
transcript path cached per session. `idle` sessions get the same read for
Claude Desktop's end-of-turn wrap_up question (`transcript_wrap_up`), as
WRAP_UP_FIELD — answerable, unlike the AskUserQuestion excerpt, because the
turn is over and a plain inbox message is the answer. Parsing is session_transcript's
`find_pending_question_form` (the port of AgentBar's own extractor).
"""
import os
import stat

import session_transcript
import transcript_wrap_up

PROJECTS_ROOT = os.path.expanduser("~/.claude/projects")
#: One window only: a question just asked is at the very end of the file.
TAIL_BYTES = 256 * 1024
FIELD_NAME = "transcriptQuestion"
WRAP_UP_FIELD = transcript_wrap_up.FIELD_NAME


def question_excerpt(form):
    """The display excerpt of a pending form: its first question."""
    first = form["questions"][0]
    return {"header": first["header"], "question": first["question"],
            "questionCount": len(form["questions"])}


def read_regular_tail(path, max_bytes):
    """(tail_bytes, starts_at_file_start, file_identity) of a regular,
    non-symlink file, or None."""
    try:
        info = os.lstat(path)
        if not stat.S_ISREG(info.st_mode):
            return None
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(fd, "rb") as fh:
            starts_at_file_start = info.st_size <= max_bytes
            if not starts_at_file_start:
                fh.seek(info.st_size - max_bytes)
            return fh.read(max_bytes), starts_at_file_start, (info.st_mtime_ns, info.st_size)
    except OSError:
        return None


class PendingQuestionReader:
    def __init__(self, projects_root=None, tail_bytes=TAIL_BYTES):
        self._projects_root = projects_root or PROJECTS_ROOT
        self._tail_bytes = tail_bytes
        self._path_by_session = {}
        #: (path, finder) -> (file_identity, finding | None)
        self._excerpt_by_path = {}

    def excerpt_for(self, session_id):
        """The pending question excerpt of this session's transcript, or None."""
        return self._cached_finding(session_id, self._read_excerpt)

    def wrap_up_for(self, session_id):
        """The pending wrap_up question of this session's transcript, or None."""
        return self._cached_finding(session_id, self._read_wrap_up)

    def _cached_finding(self, session_id, finder):
        path = self._transcript_path(session_id)
        if not path:
            return None
        try:
            info = os.lstat(path)
            identity = (info.st_mtime_ns, info.st_size)
        except OSError:
            self._path_by_session.pop(session_id, None)
            return None
        key = (path, finder.__name__)
        cached = self._excerpt_by_path.get(key)
        if cached and cached[0] == identity:
            return cached[1]
        finding = finder(path)
        self._excerpt_by_path[key] = (identity, finding)
        return finding

    def annotate(self, sessions):
        """Adds FIELD_NAME to every `waiting` session file dict and
        WRAP_UP_FIELD to every `idle` or `waiting` one (None when its transcript shows no
        pending question); forgets other sessions."""
        read_ids = set()
        for entry in sessions or []:
            if not isinstance(entry, dict):
                continue
            status = entry.get("status")
            if status == "waiting":
                read_ids.add(entry.get("sessionId"))
                entry[FIELD_NAME] = self.excerpt_for(entry.get("sessionId"))
            if status in ("idle", "waiting"):
                # A wrap_up with `blocked: true` leaves the session `waiting`.
                read_ids.add(entry.get("sessionId"))
                entry[WRAP_UP_FIELD] = self.wrap_up_for(entry.get("sessionId"))
        self._forget_all_but(read_ids)
        return sessions

    def _transcript_path(self, session_id):
        path = self._path_by_session.get(session_id)
        if path is None:
            path = session_transcript.find_local_transcript(session_id, self._projects_root)
            if path:
                self._path_by_session[session_id] = path
        return path

    def _read_excerpt(self, path):
        tail = read_regular_tail(path, self._tail_bytes)
        if tail is None:
            return None
        status, form = session_transcript.find_pending_question_form(tail[0], tail[1])
        return question_excerpt(form) if status == session_transcript.PENDING else None

    def _read_wrap_up(self, path):
        tail = read_regular_tail(path, self._tail_bytes)
        return None if tail is None else transcript_wrap_up.find_pending_wrap_up(tail[0], tail[1])

    def _forget_all_but(self, session_ids):
        for session_id in list(self._path_by_session):
            if session_id not in session_ids:
                path = self._path_by_session.pop(session_id)
                for key in [k for k in self._excerpt_by_path if k[0] == path]:
                    del self._excerpt_by_path[key]
