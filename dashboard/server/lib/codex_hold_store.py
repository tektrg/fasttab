#!/usr/bin/env python3
"""Codex permission prompts held by our PermissionRequest hook, answerable
from AgentBar / the web UI (Phase 3 of OpenCode/Codex support).

Same lifecycle and endpoints as the Claude bridge (hook_permissions.py — this
is a subclass): the hook `integrations/codex/agentbar-codex-permission.py`
registers the prompt (`POST /api/hook/permission` with `agentTool: "codex"`),
long-polls `/wait`, and prints the decision Codex reads from stdout
(`hookSpecificOutput.decision` = {behavior: allow|deny, message?}; checked
against the schema embedded in codex 0.154 and live, 2026-09-29).

Differences from Claude, all measured live on codex 0.154:
  * Codex shows NO prompt of its own while a PermissionRequest hook runs (the
    TUI says "Running hook"), so a held prompt cannot be answered in the
    terminal first. "Answered elsewhere" therefore means another app's hook
    (vibe-island, AgentPeek, OpenIsland run in parallel) decided first, which
    we see as our hook process dying or the session moving on.
  * `updatedInput` / `updatedPermissions` make Codex fail closed, so no
    "always allow" suggestions are offered and question answers do not exist.
  * The hook itself gives up after AGENTBAR_CODEX_HOLD_SEC (default 300s) so
    the terminal prompt appears — the dashboard sees the hook die and resolves.
"""
import hook_permission_summary as summary
import hook_permissions as base
import tui_status_events

#: A status event this much later than the prompt = the session moved on.
MOVED_ON_GRACE_SEC = 2.0
TOOL = "codex"
REASON_CODEX_EXITED = "codex exited"


def status_store_moved_on(request, status_store=None):
    """True when Codex's own hooks reported anything after this prompt began
    other than the prompt itself (PostToolUse, Stop, a new turn ...)."""
    entry = (status_store or tui_status_events.STORE).entry_for(TOOL, request.session_id)
    if not entry:
        return False
    return (entry["lastEventAt"] > request.created_at + MOVED_ON_GRACE_SEC
            and entry["prompt"] != "permission")


class CodexHoldStore(base.HookPermissionStore):
    ID_PREFIX = "tuicx"
    PRODUCT = "Codex"

    def __init__(self, *args, moved_on=None, **kwargs):
        super().__init__(*args, **kwargs)
        self._moved_on = moved_on or status_store_moved_on

    # A Codex payload has no Claude session file to check: judge it on itself.
    def _register_refusal(self, payload, session_entry, created_at):
        if not base._valid_payload(payload):
            return "invalid payload"
        if payload.get("tool_name") == summary.QUESTION_TOOL:
            return "questions are not answered through the Codex hook"
        if not isinstance(payload.get("claudePid"), int):
            return "missing claudePid"
        if not self._presence.is_connected():
            return base.REASON_AGENTBAR_NOT_CONNECTED
        if not base._is_presentable(payload):
            return "unreadable tool input"
        return None

    def _resolve_reason(self, request, sessions_by_id, now):
        if now - request.created_tick > base.MAX_AGE_SEC:
            return "expired"
        if self._moved_on(request):
            return "answered elsewhere"
        if not self._pid_alive(request.claude_pid):
            return REASON_CODEX_EXITED
        if self._presence.is_gone():
            return base.REASON_AGENTBAR_GONE
        if not self._pid_alive(request.hook_pid):
            # Our hook was cut off: Codex stopped waiting for us (another
            # hook decided first, or the hold limit ended it).
            return "answered elsewhere"
        if now - request.last_wait_at > base.HOOK_SILENT_RESOLVE_SEC:
            return base.REASON_HOOK_SILENT
        if not request.has_waited and now - request.created_tick > base.HOOK_FIRST_WAIT_SEC:
            return base.REASON_HOOK_SILENT
        return None

    def exposed_by_session(self, sessions=None):
        views = super().exposed_by_session([])
        for view in views.values():
            view["tool"] = TOOL
        return views


#: The one Codex store the server uses.
STORE = CodexHoldStore()
