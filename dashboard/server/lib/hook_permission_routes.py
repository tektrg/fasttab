#!/usr/bin/env python3
"""HTTP routing for the PermissionRequest hook bridge (hook_permissions.py).
Kept out of chief-dashboard-server.py so the server only dispatches.

  POST /api/hook/permission              hook -> {requestId} | {state: ignored}
  GET  /api/hook/permission/<id>/wait    hook long-poll (?timeout=N, N <= 25)
  POST /api/hook/permission/<id>/answer  AgentBar / web UI -> {ok, state} | 4xx {error}

OpenCode / Codex prompts use the SAME three endpoints (Phase 3): a Codex hook
registers with `agentTool: "codex"` and its `/wait` is routed by the request-id
prefix; `answer` for an OpenCode / Codex-keystroke id goes to `tui_answers`
(see that module for the ids).

On the remote (tailscale) listener only `answer` exists — the phone's web
remote answers there (authenticated, CSRF-checked and audited like every
remote write); register and wait stay local (404): the hook runs on this Mac.
"""
import claude_sessions
import codex_hold_store
import hook_permissions
import tui_answers
from chief_dashboard_feeds import FEEDS

PREFIX = "/api/hook/permission"
NOT_FOUND = ({"error": "not found"}, 404)


def is_hook_path(path):
    return path == PREFIX or path.startswith(PREFIX + "/")


def _feed_data(name):
    feed = FEEDS.get(name)
    return feed.snapshot().get("data") if feed else None


def _live_sessions():
    return _feed_data("claudeSessions") or []


def _session_entry(payload):
    """The session file of the hook's session, read straight from the hook's
    Claude pid (a re-send is judged on the prompt's CURRENT status; the feed
    samples only every 3s), else the feed's copy."""
    session_id = payload.get("session_id") if isinstance(payload, dict) else None
    if not session_id:
        return None
    fresh = claude_sessions.read_session_for_pid(payload.get("claudePid"))
    if fresh and fresh.get("sessionId") == session_id:
        return fresh
    for entry in _live_sessions():
        if isinstance(entry, dict) and entry.get("sessionId") == session_id:
            return entry
    return None


def _request_route(path):
    """"/api/hook/permission/<id>/<action>" -> (id, action) or (None, None)."""
    parts = path[len(PREFIX) + 1:].split("/") if path.startswith(PREFIX + "/") else []
    if len(parts) == 2 and parts[0]:
        return parts[0], parts[1]
    return None, None


def _parse_timeout(query):
    try:
        return float((query.get("timeout") or [hook_permissions.WAIT_MAX_SEC])[0])
    except (TypeError, ValueError):
        return hook_permissions.WAIT_MAX_SEC


def request_id_of(path):
    """The request id in a per-request path (audit row), else None."""
    return _request_route(path)[0]


def _store_for(request_id):
    return codex_hold_store.STORE if tui_answers.is_codex_hold(request_id) else hook_permissions.STORE


def handle_get(path, query, is_remote, store=None):
    request_id, action = _request_route(path)
    store = store or _store_for(request_id)
    if is_remote or action != "wait":
        return NOT_FOUND
    return store.wait(request_id, _parse_timeout(query), _live_sessions)


def handle_post(path, read_body, is_remote, store=None, session_entry=None):
    """`read_body` is called lazily so a 404 never reads the request body.
    `session_entry(payload)` finds the hook session's file (tests fake it)."""
    session_entry = session_entry or _session_entry
    request_id, action = _request_route(path)
    if is_remote and action != "answer":
        return NOT_FOUND
    try:
        if path == PREFIX:
            payload = read_body()
            if isinstance(payload, dict) and payload.get("agentTool") == "codex":
                return (store or codex_hold_store.STORE).register(payload), 200
            return (store or hook_permissions.STORE).register(payload, session_entry(payload)), 200
        if action == "answer":
            body = read_body()
            if request_id.startswith((tui_answers.OPENCODE_PREFIX, tui_answers.KEYSTROKE_PREFIX)):
                return tui_answers.answer(request_id, body)
            return (store or _store_for(request_id)).answer(request_id, body)
    except ValueError as e:  # malformed JSON body
        return {"ok": False, "error": f"bad JSON body: {e}"}, 400
    return NOT_FOUND
