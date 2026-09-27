#!/usr/bin/env python3
"""Pending Claude Code permission prompts sent by the PermissionRequest hook
(dashboard/hooks/agentbar-permission-hook.py), answerable from AgentBar.

Lifecycle of one request (in memory only — a restart loses them all, the hook
then sees 404 and exits, and Claude's own prompt is still on screen):

  pending --answer()--> answered   (the hook's /wait returns the decision)
          --sweep()---> resolved   (answered elsewhere / Claude gone / hook gone)
                        expired    (older than 24h)

Claude Code runs every hook in parallel and takes the FIRST decision; its own
prompt keeps racing the hook. If the human answers in the TUI/Desktop, the hook
gets no signal at all — so "resolved" is inferred: the session's
~/.claude/sessions file moved on (statusUpdatedAt after the request, status no
longer `waiting`), or the Claude process died, or the hook stopped polling.

Only the oldest pending request per session is exposed (one prompt shows at a
time in the TUI too).
"""
import itertools
import os
import secrets
import threading
import time

import hook_permission_summary as summary

STATE_PENDING = "pending"
STATE_ANSWERED = "answered"
STATE_RESOLVED = "resolved"
STATE_EXPIRED = "expired"

WAIT_MAX_SEC = 25
#: How often a waiting /wait call re-checks "answered elsewhere".
WAIT_RECHECK_SEC = 1.0
#: No /wait call for this long = the hook process is gone.
HOOK_SILENT_RESOLVE_SEC = 90
MAX_AGE_SEC = 24 * 3600
#: Finished requests linger so a late /wait still reads a state, not 404.
FINISHED_KEEP_SEC = 600


def _pid_alive(pid):
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 1:
        return True  # unknown -> don't resolve on it
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except (PermissionError, OSError, OverflowError):
        return True
    return True


class HookRequest:
    def __init__(self, request_id, payload, created_at):
        self.request_id = request_id
        self.session_id = payload["session_id"]
        self.tool_name = payload["tool_name"]
        self.tool_input = payload.get("tool_input") or {}
        suggestions = payload.get("permission_suggestions")
        self.suggestions = [s for s in suggestions if isinstance(s, dict)] \
            if isinstance(suggestions, list) else []
        self.claude_pid = payload.get("claudePid")
        self.hook_pid = payload.get("hookPid")
        self.created_at = created_at
        self.last_wait_at = created_at
        self.state = STATE_PENDING
        self.state_reason = None
        self.finished_at = None
        self.decision = None

    def finish(self, state, now, reason=None, decision=None):
        self.state, self.state_reason, self.finished_at = state, reason, now
        self.decision = decision


def _valid_payload(payload):
    return (isinstance(payload, dict)
            and isinstance(payload.get("session_id"), str) and payload["session_id"]
            and isinstance(payload.get("tool_name"), str) and payload["tool_name"]
            and isinstance(payload.get("tool_input") or {}, dict))


def _session_moved_on(request, sessions_by_id):
    entry = sessions_by_id.get(request.session_id)
    if not entry:
        return False
    status_ms = entry.get("statusUpdatedAt")
    return (isinstance(status_ms, (int, float))
            and status_ms / 1000.0 > request.created_at
            and entry.get("status") != "waiting")


class HookPermissionStore:
    def __init__(self, clock=time.time, pid_alive=_pid_alive):
        self._clock = clock
        self._pid_alive = pid_alive
        self._cond = threading.Condition()
        self._requests = {}
        self._seq = itertools.count(1)

    # ---- hook side --------------------------------------------------------
    def register(self, payload, herdr_session_ids=()):
        """{requestId} for a new pending request, or {state: "ignored"}."""
        if not _valid_payload(payload) or payload["session_id"] in set(herdr_session_ids):
            return {"state": "ignored"}
        with self._cond:
            request_id = f"hp{next(self._seq)}-{secrets.token_hex(4)}"
            self._requests[request_id] = HookRequest(request_id, payload, self._clock())
            self._cond.notify_all()
        return {"requestId": request_id}

    def wait(self, request_id, timeout_sec, sessions_provider=lambda: []):
        """Long-poll: (payload, http_status). Returns as soon as the request
        leaves `pending`, else {state: pending} after timeout_sec."""
        timeout_sec = max(0.0, min(float(timeout_sec), WAIT_MAX_SEC))
        deadline = self._clock() + timeout_sec
        while True:
            self.sweep(sessions_provider())
            with self._cond:
                request = self._requests.get(request_id)
                if request is None:
                    return {"error": "unknown request"}, 404
                request.last_wait_at = self._clock()
                remaining = deadline - self._clock()
                if request.state == STATE_PENDING and remaining > 0:
                    self._cond.wait(min(WAIT_RECHECK_SEC, remaining))
                    request.last_wait_at = self._clock()
                if request.state != STATE_PENDING:
                    return self._state_payload(request), 200
                if self._clock() >= deadline:
                    return {"state": STATE_PENDING}, 200

    @staticmethod
    def _state_payload(request):
        payload = {"state": request.state}
        if request.state == STATE_ANSWERED:
            payload["decision"] = request.decision
        if request.state_reason:
            payload["reason"] = request.state_reason
        return payload

    # ---- AgentBar side ----------------------------------------------------
    def answer(self, request_id, body):
        """(payload, http_status). First decision wins: 409 once not pending."""
        with self._cond:
            request = self._requests.get(request_id)
            if request is None:
                return {"ok": False, "error": "unknown request"}, 404
            if request.state != STATE_PENDING:
                return {"ok": False, "error": f"request is {request.state}, not pending"}, 409
            try:
                decision = summary.build_decision(
                    request.tool_name, request.tool_input, request.suggestions, body)
            except summary.AnswerRejected as e:
                return {"ok": False, "error": str(e)}, 400
            request.finish(STATE_ANSWERED, self._clock(), decision=decision)
            self._cond.notify_all()
        return {"ok": True, "state": STATE_ANSWERED}, 200

    # ---- resolution + exposure -------------------------------------------
    def sweep(self, sessions):
        """Mark pending requests answered-elsewhere/abandoned; prune old ones.
        `sessions` = the claudeSessions feed's list of session-file dicts."""
        sessions_by_id = {s.get("sessionId"): s for s in sessions or [] if isinstance(s, dict)}
        now = self._clock()
        with self._cond:
            changed = False
            for request_id, request in list(self._requests.items()):
                if request.state != STATE_PENDING:
                    if now - request.finished_at > FINISHED_KEEP_SEC:
                        del self._requests[request_id]
                    continue
                reason = self._resolve_reason(request, sessions_by_id, now)
                if reason:
                    state = STATE_EXPIRED if reason == "expired" else STATE_RESOLVED
                    request.finish(state, now, reason=reason)
                    changed = True
            if changed:
                self._cond.notify_all()

    def _resolve_reason(self, request, sessions_by_id, now):
        if now - request.created_at > MAX_AGE_SEC:
            return "expired"
        if _session_moved_on(request, sessions_by_id):
            return "answered elsewhere"
        if not self._pid_alive(request.claude_pid):
            return "claude exited"
        if now - request.last_wait_at > HOOK_SILENT_RESOLVE_SEC:
            return "hook stopped polling"
        return None

    def exposed_by_session(self, sessions):
        """{session_id: hookRequest view} — the oldest pending one each."""
        self.sweep(sessions)
        now = self._clock()
        with self._cond:
            pending = sorted((r for r in self._requests.values() if r.state == STATE_PENDING),
                             key=lambda r: r.created_at)
            views = {}
            for request in pending:
                if request.session_id not in views:
                    views[request.session_id] = summary.build_hook_request_view(
                        request.request_id, request.tool_name, request.tool_input,
                        request.suggestions, request.created_at, now)
            return views


#: The one store the server uses.
STORE = HookPermissionStore()


def herdr_session_ids(herdr_feed_data):
    """Session ids herdr already shows (their prompts keep the screen path)."""
    ids = set()
    for agent in (herdr_feed_data or {}).get("agents") or []:
        value = (agent.get("agent_session") or {}).get("value")
        if value:
            ids.add(value)
    return ids
