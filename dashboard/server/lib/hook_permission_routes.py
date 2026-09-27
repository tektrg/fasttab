#!/usr/bin/env python3
"""HTTP routing for the PermissionRequest hook bridge (hook_permissions.py).
Kept out of chief-dashboard-server.py so the server only dispatches.

  POST /api/hook/permission              hook -> {requestId} | {state: ignored}
  GET  /api/hook/permission/<id>/wait    hook long-poll (?timeout=N, N <= 25)
  POST /api/hook/permission/<id>/answer  AgentBar -> {ok, state} | 4xx {error}

Local listener only: every route answers 404 on the remote (tailscale)
listener — the hook runs on this Mac, and answering a permission prompt from
the phone is not in scope.
"""
import claude_sessions
import hook_permissions
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


def handle_get(path, query, is_remote, store=None):
    store = store or hook_permissions.STORE
    request_id, action = _request_route(path)
    if is_remote or action != "wait":
        return NOT_FOUND
    return store.wait(request_id, _parse_timeout(query), _live_sessions)


def handle_post(path, read_body, is_remote, store=None, session_entry=None):
    """`read_body` is called lazily so a 404 never reads the request body.
    `session_entry(payload)` finds the hook session's file (tests fake it)."""
    store = store or hook_permissions.STORE
    session_entry = session_entry or _session_entry
    if is_remote:
        return NOT_FOUND
    try:
        if path == PREFIX:
            payload = read_body()
            herdr_ids = hook_permissions.herdr_session_ids(_feed_data("herdr"))
            return store.register(payload, herdr_ids, session_entry(payload)), 200
        request_id, action = _request_route(path)
        if action == "answer":
            return store.answer(request_id, read_body())
    except ValueError as e:  # malformed JSON body
        return {"ok": False, "error": f"bad JSON body: {e}"}, 400
    return NOT_FOUND
