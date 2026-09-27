#!/usr/bin/env python3
"""Pending Claude Code permission prompts sent by the PermissionRequest hook
(dashboard/hooks/agentbar-permission-hook.py), answerable from AgentBar.

Lifecycle of one request (in memory only — a restart loses them all; the
hook then sees 404 and RE-SENDS the prompt (`reregister`), which is held again
only while the session file still shows it. A re-send of a request still
pending — same hook, same `tool_use_id` / tool + input — keeps that request):

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

Registered ONLY where Claude shows its own prompt while the hook runs — a
main-thread prompt of an interactive CLI or Claude Desktop session. Measured
(Claude Code 2.1.283): a background subagent's prompt (payload has
`agent_id`) and a `claude -p` / SDK run (`entrypoint` sdk-*) are NOT shown
until every hook has returned, so holding them here would leave that agent
stuck on AgentBar alone (up to the hook's 24h timeout). Those are ignored and
Claude's normal flow runs at once.

Held ONLY while an answer surface is connected (agentbar_presence.py:
AgentBar, or the web UI incl. the phone's web remote): with none seen in the
last 10s a prompt is ignored, and once all have been gone 15s every pending
one is released (`agentbar gone`) so its hook exits (and re-sends later).
"""
import hashlib
import itertools
import json
import os
import secrets
import threading
import time

import agentbar_presence
import hook_permission_summary as summary
import session_prompt_state as prompt_state

STATE_PENDING = "pending"
STATE_ANSWERED = "answered"
STATE_RESOLVED = "resolved"
STATE_EXPIRED = "expired"

WAIT_MAX_SEC = 25
#: How often a waiting /wait call re-checks "answered elsewhere".
WAIT_RECHECK_SEC = 1.0
#: No /wait call for this long = the hook process is gone.
HOOK_SILENT_RESOLVE_SEC = 90
#: An answer only reaches Claude through a hook sitting in /wait (it re-polls
#: at once, or 2s after an error): no /wait for longer = nobody to hand it to.
HOOK_LISTENING_GAP_SEC = 5
#: A registered request whose hook never made its first /wait (it gave up on
#: a slow register reply) is gone much sooner: a live hook polls at once.
HOOK_FIRST_WAIT_SEC = 10
MAX_AGE_SEC = 24 * 3600
REASON_AGENTBAR_GONE = "agentbar gone"
REASON_HOOK_SILENT = "hook stopped polling"
REASON_AGENTBAR_NOT_CONNECTED = "AgentBar / web remote not connected (nobody here to answer)"
REASON_PROMPT_GONE = "prompt no longer waiting"
#: Outcomes after which the hook may send the same prompt again later
#: (AgentBar may come back); every other ignore/finish is final for it.
RETRYABLE_REASONS = frozenset({REASON_AGENTBAR_NOT_CONNECTED, REASON_AGENTBAR_GONE})
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


def prompt_key(payload):
    """Which prompt this is, stable across re-sends of one hook: Claude's
    `tool_use_id` when the payload has one, else the tool and its input."""
    tool_use_id = payload.get("tool_use_id")
    if isinstance(tool_use_id, str) and tool_use_id:
        return "tool:" + tool_use_id
    canonical = json.dumps([payload.get("tool_name"), payload.get("tool_input") or {}],
                           sort_keys=True, default=str)
    return "input:" + hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def prompt_started_at(payload, now):
    """When the prompt came up (wall clock): the hook's `promptStartedAt` —
    kept across re-sends so "answered elsewhere" and the row's timer still
    count from the prompt — else now. Anything outside the last 24h -> now."""
    started = payload.get("promptStartedAt")
    if isinstance(started, (int, float)) and not isinstance(started, bool) \
            and now - MAX_AGE_SEC <= started <= now:
        return float(started)
    return now


class HookRequest:
    def __init__(self, request_id, payload, created_at, created_tick):
        self.request_id = request_id
        self.session_id = payload["session_id"]
        self.prompt_key = prompt_key(payload)
        self.tool_name = payload["tool_name"]
        self.tool_input = payload.get("tool_input") or {}
        suggestions = payload.get("permission_suggestions")
        self.suggestions = [s for s in suggestions if isinstance(s, dict)] \
            if isinstance(suggestions, list) else []
        self.claude_pid = payload.get("claudePid")
        self.hook_pid = payload.get("hookPid")
        #: Wall clock: compared with the session file's statusUpdatedAt, shown.
        self.created_at = created_at
        #: Monotonic ticks (every age / deadline): a wall-clock step must not
        #: stretch a /wait or keep a dead request alive.
        self.created_tick = created_tick
        self.last_wait_at = created_tick
        self.has_waited = False
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


def _is_presentable(payload):
    """AgentBar's view of it can be built. Checked once, at register: a
    tool_input of the wrong shape would otherwise break /api/state for every
    client for as long as it stayed pending."""
    try:
        summary.build_hook_request_view("check", payload["tool_name"], payload.get("tool_input") or {},
                                        payload.get("permission_suggestions") or [], 0.0, 0.0)
        return True
    except Exception:  # noqa: BLE001 — any shape problem = don't hold it
        return False


def _session_moved_on(request, sessions_by_id):
    """The session's status changed after this prompt started: it is gone
    (answered in Claude, or the NEXT prompt is up)."""
    return prompt_state.session_moved_on(sessions_by_id.get(request.session_id), request.created_at)


def ignore_reason(payload, herdr_session_ids, session_entry):
    """Why this hook payload must not be held here (None = register it).
    `session_entry`: the session file dict for payload's session, or None."""
    if not _valid_payload(payload):
        return "invalid payload"
    if payload["session_id"] in set(herdr_session_ids):
        return "herdr pane (answered from its screen)"
    if payload.get("agent_id"):
        return "subagent prompt (Claude shows it only after the hook returns)"
    if not session_entry or session_entry.get("sessionId") != payload["session_id"]:
        return "no live session file for this session"
    if not prompt_state.shows_own_prompt(session_entry, payload["session_id"]):
        return f"{session_entry.get('entrypoint')} session (no prompt of its own on screen)"
    return None


class HookPermissionStore:
    def __init__(self, clock=time.time, ticks=time.monotonic, pid_alive=_pid_alive, presence=None):
        self._clock = clock
        self._ticks = ticks
        self._pid_alive = pid_alive
        #: Who can answer: AgentBar's connection (tests pass a fake).
        self._presence = presence or agentbar_presence.PRESENCE
        self._cond = threading.Condition()
        self._requests = {}
        self._seq = itertools.count(1)

    # ---- hook side --------------------------------------------------------
    def register(self, payload, herdr_session_ids=(), session_entry=None):
        """{requestId} for a pending request, or {state: "ignored", reason,
        retryable}. A re-send (`reregister`, after a dashboard restart or
        AgentBar coming back) is held only while the session file still shows
        that prompt; the same prompt sent twice keeps ONE request."""
        created_at = prompt_started_at(payload, self._clock()) if isinstance(payload, dict) else None
        reason = self._register_refusal(payload, herdr_session_ids, session_entry, created_at)
        if reason:
            return {"state": "ignored", "reason": reason, "retryable": reason in RETRYABLE_REASONS}
        with self._cond:
            existing = self._pending_resend_of(payload)
            if existing:
                existing.claude_pid = payload.get("claudePid")
                existing.last_wait_at = self._ticks()
                existing.has_waited = False
                return {"requestId": existing.request_id}
            request_id = f"hp{next(self._seq)}-{secrets.token_hex(4)}"
            self._requests[request_id] = HookRequest(request_id, payload, created_at, self._ticks())
            self._cond.notify_all()
        return {"requestId": request_id}

    def _register_refusal(self, payload, herdr_session_ids, session_entry, created_at):
        reason = ignore_reason(payload, herdr_session_ids, session_entry)
        if not reason and payload.get("reregister") \
                and not prompt_state.prompt_still_waiting(session_entry, created_at):
            reason = REASON_PROMPT_GONE
        if not reason and not self._presence.is_connected():
            reason = REASON_AGENTBAR_NOT_CONNECTED
        if not reason and not _is_presentable(payload):
            reason = "unreadable tool input"
        return reason

    def _pending_resend_of(self, payload):
        """The still-pending request this payload RE-SENDS: same session, same
        hook process, same prompt. Only the hook that sent a prompt re-sends
        it; another hook with the same tool + input is a DIFFERENT prompt (a
        retried command, a parallel identical call) — merging it into the old
        request would get it resolved as "answered elsewhere" once the old
        prompt's answer shows in the session file, losing the new one."""
        if not payload.get("reregister"):
            return None
        key, hook_pid = prompt_key(payload), payload.get("hookPid")
        return next((r for r in self._requests.values() if r.state == STATE_PENDING
                     and r.session_id == payload["session_id"] and r.hook_pid == hook_pid
                     and r.prompt_key == key), None)

    def wait(self, request_id, timeout_sec, sessions_provider=lambda: []):
        """Long-poll: (payload, http_status). Returns as soon as the request
        leaves `pending`, else {state: pending} after timeout_sec."""
        timeout_sec = max(0.0, min(float(timeout_sec), WAIT_MAX_SEC))
        deadline = self._ticks() + timeout_sec
        while True:
            self.sweep(sessions_provider())
            with self._cond:
                request = self._requests.get(request_id)
                if request is None:
                    return {"error": "unknown request"}, 404
                request.last_wait_at = self._ticks()
                request.has_waited = True
                remaining = deadline - self._ticks()
                if request.state == STATE_PENDING and remaining > 0:
                    self._cond.wait(min(WAIT_RECHECK_SEC, remaining))
                    request.last_wait_at = self._ticks()
                if request.state != STATE_PENDING:
                    return self._state_payload(request), 200
                if self._ticks() >= deadline:
                    return {"state": STATE_PENDING}, 200

    @staticmethod
    def _state_payload(request):
        payload = {"state": request.state}
        if request.state == STATE_ANSWERED:
            payload["decision"] = request.decision
        if request.state_reason:
            payload["reason"] = request.state_reason
        if request.state_reason in RETRYABLE_REASONS:
            payload["retryable"] = True
        return payload

    # ---- AgentBar side ----------------------------------------------------
    def answer(self, request_id, body):
        """(payload, http_status). First decision wins: 409 once not pending."""
        with self._cond:
            request = self._requests.get(request_id)
            if request is None:
                return {"ok": False, "error": "unknown request"}, 404
            now = self._ticks()
            if request.state == STATE_PENDING and not self._hook_listening(request, now):
                request.finish(STATE_RESOLVED, now, reason=REASON_HOOK_SILENT)
                self._cond.notify_all()
            if request.state != STATE_PENDING:
                return {"ok": False, "error": _not_pending_message(request)}, 409
            try:
                decision = summary.build_decision(
                    request.tool_name, request.tool_input, request.suggestions, body)
            except summary.AnswerRejected as e:
                return {"ok": False, "error": str(e)}, 400
            request.finish(STATE_ANSWERED, now, decision=decision)
            self._cond.notify_all()
        return {"ok": True, "state": STATE_ANSWERED}, 200

    # ---- resolution + exposure -------------------------------------------
    def sweep(self, sessions):
        """Mark pending requests answered-elsewhere/abandoned; prune old ones.
        `sessions` = the claudeSessions feed's list of session-file dicts."""
        sessions_by_id = {s.get("sessionId"): s for s in sessions or [] if isinstance(s, dict)}
        now = self._ticks()
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
        if now - request.created_tick > MAX_AGE_SEC:
            return "expired"
        if _session_moved_on(request, sessions_by_id):
            return "answered elsewhere"
        if not self._pid_alive(request.claude_pid):
            return "claude exited"
        if self._presence.is_gone():
            return REASON_AGENTBAR_GONE
        if not self._pid_alive(request.hook_pid):
            return REASON_HOOK_SILENT
        if now - request.last_wait_at > HOOK_SILENT_RESOLVE_SEC:
            return REASON_HOOK_SILENT
        if not request.has_waited and now - request.created_tick > HOOK_FIRST_WAIT_SEC:
            return REASON_HOOK_SILENT
        return None

    def _hook_listening(self, request, now):
        """An answer handed over now would reach Claude. A /wait whose hook was
        killed keeps looping server-side until its timeout, so the hook's pid
        is the sharper signal; the gap covers a hook between two polls."""
        return (self._pid_alive(request.hook_pid)
                and now - request.last_wait_at <= HOOK_LISTENING_GAP_SEC)

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


def _not_pending_message(request):
    """409 text AgentBar shows verbatim in its footer."""
    if request.state == STATE_ANSWERED:
        return "This prompt was already answered from AgentBar or the web remote."
    if request.state_reason == "answered elsewhere":
        return "This prompt was already answered in Claude."
    if request.state_reason == REASON_HOOK_SILENT:
        return "Claude stopped waiting for this answer; answer it in Claude."
    if request.state_reason == REASON_AGENTBAR_GONE:
        return ("AgentBar and the web remote lost their dashboard connection; "
                "answer this prompt in Claude.")
    return f"This prompt is no longer waiting ({request.state_reason or request.state})."


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
