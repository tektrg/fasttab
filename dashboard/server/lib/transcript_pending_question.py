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
transcript path cached per session. Parsing is session_transcript's
`find_pending_question_form` (the port of AgentBar's own extractor).
"""
import os
import stat

import session_transcript

PROJECTS_ROOT = os.path.expanduser("~/.claude/projects")
#: One window only: a question just asked is at the very end of the file.
TAIL_BYTES = 256 * 1024
FIELD_NAME = "transcriptQuestion"


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
        #: path -> (file_identity, excerpt | None)
        self._excerpt_by_path = {}

    def excerpt_for(self, session_id):
        """The pending question excerpt of this session's transcript, or None."""
        path = self._transcript_path(session_id)
        if not path:
            return None
        try:
            info = os.lstat(path)
            identity = (info.st_mtime_ns, info.st_size)
        except OSError:
            self._path_by_session.pop(session_id, None)
            return None
        cached = self._excerpt_by_path.get(path)
        if cached and cached[0] == identity:
            return cached[1]
        excerpt = self._read_excerpt(path)
        self._excerpt_by_path[path] = (identity, excerpt)
        return excerpt

    def annotate(self, sessions):
        """Adds FIELD_NAME to every `waiting` session file dict (None when
        its transcript shows no pending question); forgets closed sessions."""
        waiting_ids = set()
        for entry in sessions or []:
            if isinstance(entry, dict) and entry.get("status") == "waiting":
                waiting_ids.add(entry.get("sessionId"))
                entry[FIELD_NAME] = self.excerpt_for(entry.get("sessionId"))
        self._forget_all_but(waiting_ids)
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

    def _forget_all_but(self, session_ids):
        for session_id in list(self._path_by_session):
            if session_id not in session_ids:
                self._excerpt_by_path.pop(self._path_by_session.pop(session_id), None)
