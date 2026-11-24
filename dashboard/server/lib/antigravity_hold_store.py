#!/usr/bin/env python3
"""Antigravity PreToolUse prompts held by our hook, answerable from AgentBar / web UI.

Same lifecycle and endpoints as Claude (`hook_permissions.py`) and Codex
(`codex_hold_store.py`): `antigravity-status-hook.py` registers an `ask_question`
or `ask_permission` call (`POST /api/hook/permission` with `agentTool: "antigravity"`),
long-polls `/wait`, and prints the Antigravity `PreToolUse` JSON decision on stdout.
"""
import hook_permission_summary as summary
import hook_permissions as base

TOOL = "antigravity"


def is_antigravity_hold(request_id):
    return isinstance(request_id, str) and request_id.startswith(AntigravityHoldStore.ID_PREFIX)


class AntigravityHoldStore(base.HookPermissionStore):
    ID_PREFIX = "ag"
    PRODUCT = "Antigravity"

    def _register_refusal(self, payload, session_entry, created_at):
        if not base._valid_payload(payload):
            return "invalid payload"
        if not self._presence.is_connected():
            return base.REASON_AGENTBAR_NOT_CONNECTED
        if payload.get("tool_name") == summary.QUESTION_TOOL:
            questions = summary.normalized_questions(payload.get("tool_input") or {})
            if not questions or any(not q["options"] for q in questions):
                return "unreadable question options"
        if not base._is_presentable(payload):
            return "unreadable tool input"
        return None

    def _resolve_reason(self, request, sessions_by_id, now):
        if now - request.created_tick > base.MAX_AGE_SEC:
            return "expired"
        if self._presence.is_gone():
            return base.REASON_AGENTBAR_GONE
        if request.hook_pid and not self._pid_alive(request.hook_pid):
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


STORE = AntigravityHoldStore()
