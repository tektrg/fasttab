#!/usr/bin/env python3
"""Answering OpenCode / Codex prompts from AgentBar and the web UI (Phase 3).

Everything reuses the Claude bridge's shapes, so Mac app and web need almost
nothing new: a row with a pending prompt gets the same `hookRequest` view
(`requestId`, `kind`, `permission` / `questions`, plus `tool`) and is answered
by the same `POST /api/hook/permission/<requestId>/answer` body. The id prefix
says who answers:

  tuioc-<opencode request id>       OpenCode: HTTP to its own local server
                                    (opencode_answer.py; plugin-reported)
  tuicx<n>-<hex>                    Codex: a PermissionRequest hook is HOLDING
                                    it (codex_hold_store.py, register/wait/answer)
  tuikx-<hash8>-<codex session id>  Codex: no hook holds it; keystroke into the
                                    herdr pane after a fresh screen check
                                    (codex_pane_answer.py)
Rows: `attach_requests()` runs right after `tui_status_events.attach_to_rows`.
First answer wins everywhere; a prompt someone else answered is refused with
"already answered", never sent twice.
"""
import hashlib
import os
import sys
import time

import chief_dashboard_herdr as herdr
import codex_hold_store
import codex_pane_answer
import hook_permission_summary as summary
import opencode_answer
import tui_status_events

OPENCODE_PREFIX = "tuioc-"
KEYSTROKE_PREFIX = "tuikx-"
CODEX_HOLD_PREFIX = codex_hold_store.CodexHoldStore.ID_PREFIX
PREFIXES = (OPENCODE_PREFIX, KEYSTROKE_PREFIX, CODEX_HOLD_PREFIX)
LOCAL = herdr.LOCAL_MACHINE
_MISSING = ({"ok": False, "error": "unknown request"}, 404)


def owns(request_id):
    return isinstance(request_id, str) and request_id.startswith(PREFIXES)


def is_codex_hold(request_id):
    return isinstance(request_id, str) and request_id.startswith(CODEX_HOLD_PREFIX)


# ── views ──────────────────────────────────────────────────────────────────

def _opencode_view(entry, now):
    request = entry.get("request")
    if not request or entry.get("status") != "blocked":
        return None
    view = {"requestId": OPENCODE_PREFIX + request["id"], "kind": request["kind"],
            "tool": "opencode", "createdAt": entry["statusSince"],
            "sinceSec": max(0.0, now - entry["statusSince"])}
    if request["kind"] == "question":
        if not all(q["options"] for q in request["questions"]):
            return None  # a text-only question has no option row the cards can show
        view["toolName"] = "question"
        view["questions"] = [{"question": q["question"], "header": q["header"],
                              "multiSelect": q["multiple"], "options": q["options"]}
                             for q in request["questions"]]
        return view
    view["toolName"] = request["permission"] or "permission"
    detail = request["detail"] or "\n".join(request["patterns"]) or request["permission"]
    suggestions = ([{"index": 0, "label": "Always allow " + ", ".join(request["always"])}]
                   if request["always"] else [])
    view["permission"] = {"title": f"OpenCode: {view['toolName']}", "detail": detail,
                          "suggestions": suggestions}
    return view


def keystroke_request_id(entry):
    digest = hashlib.sha256((entry.get("detail") or "").encode("utf-8")).hexdigest()[:8]
    return f"{KEYSTROKE_PREFIX}{digest}-{entry['sessionId']}"


def _codex_keystroke_view(entry, now):
    if entry.get("prompt") != "permission" or not entry.get("paneId") or not entry.get("detail"):
        return None
    return {"requestId": keystroke_request_id(entry), "kind": "permission", "tool": "codex",
            "toolName": "Bash", "createdAt": entry["statusSince"],
            "sinceSec": max(0.0, now - entry["statusSince"]),
            "permission": {"title": "Codex: run a shell command", "detail": entry["detail"],
                           "suggestions": []},
            "viaPane": True}


def request_view(entry, now, hold_views):
    """The `hookRequest` for one fresh status entry, or None."""
    if entry["tool"] == "opencode":
        return _opencode_view(entry, now)
    return hold_views.get(entry["sessionId"]) or _codex_keystroke_view(entry, now)


SCREEN_NOT_BLOCKED = ("WAITING", "ACTIVE", "WAITING_ON_BACKGROUND")


def _screen_says_no_prompt(row, screen_read_age):
    """A pane reading taken AFTER the prompt began shows no prompt: the status
    entry is stale (Codex sends no event when an approval is dismissed)."""
    since = row.get("hookSinceSec")
    return (row.get("screenState") in SCREEN_NOT_BLOCKED and screen_read_age is not None
            and since is not None and since >= screen_read_age)


def attach_requests(rows, entries, now=None, hold_views=None, screen_read_age=None):
    """Set `hookRequest` on rows `attach_to_rows` matched to an entry with a
    pending, answerable prompt. A pane-answered (keystroke) request is dropped
    when a newer screen reading shows no prompt; a held hook request and an
    OpenCode request come from their owners' own live state, not the screen.
    `screen_read_age`: seconds since the newest pane-screen sweep began."""
    now = time.time() if now is None else now
    hold_views = codex_hold_store.STORE.exposed_by_session() if hold_views is None else hold_views
    by_key = {(e["tool"], e["sessionId"]): e for e in entries}
    for row in rows:
        entry = by_key.get((row.get("agentKind"), row.get("tuiSessionId")))
        if entry and row.get("tuiPrompt"):
            view = request_view(entry, now, hold_views)
            if view and view.get("viaPane") and _screen_says_no_prompt(row, screen_read_age):
                continue
            if view:
                row["hookRequest"] = view
    return rows


# ── answers ────────────────────────────────────────────────────────────────

def _pane_read(pane_id, lines):
    out = herdr.herdr_cmd_text(LOCAL, ["pane", "read", pane_id, "--source", "recent-unwrapped",
                                       "--lines", str(lines)], repo_root=os.getcwd())
    return out.splitlines()


def _pane_send_keys(pane_id, *keys):
    print(f"chief-dashboard-server: send-keys pane={pane_id!r} keys={keys!r} (codex approval)",
          file=sys.stderr)
    herdr.herdr_cmd_text(LOCAL, ["pane", "send-keys", pane_id, *keys], repo_root=os.getcwd())


def _pane_ids():
    data = herdr.herdr_cmd_json(LOCAL, ["pane", "list"], repo_root=os.getcwd(), timeout=10)
    return {p.get("pane_id") for p in (data.get("result") or {}).get("panes") or []}


PANE_IO = {"read_pane": _pane_read, "send_keys": _pane_send_keys, "list_panes": _pane_ids}


def _fresh_entry(store, predicate):
    return next((e for e in store.fresh_entries() if predicate(e)), None)


def _log(request_id, body, result):
    behavior = body.get("behavior") if isinstance(body, dict) else None
    print(f"chief-dashboard-server: tui-answer id={request_id!r} behavior={behavior!r} "
          f"-> {result[1]} {result[0].get('error') or 'ok'}", file=sys.stderr)


def answer(request_id, body, store=None):
    """(payload, http status) for an answer to a tui-owned request id. Codex
    hold ids are answered by their store (routes call it directly)."""
    store = store or tui_status_events.STORE
    if request_id.startswith(OPENCODE_PREFIX):
        wanted = request_id[len(OPENCODE_PREFIX):]
        entry = _fresh_entry(store, lambda e: e["tool"] == "opencode"
                             and (e.get("request") or {}).get("id") == wanted)
        result = opencode_answer.answer(entry, body) if entry else (
            {"ok": False, "error": "This prompt is no longer pending in OpenCode."}, 409)
        if result[1] == 200 and entry:
            store.clear_request("opencode", entry["sessionId"], wanted)
    elif request_id.startswith(KEYSTROKE_PREFIX):
        entry = _fresh_entry(store, lambda e: e["tool"] == "codex"
                             and keystroke_request_id(e) == request_id
                             and e.get("prompt") == "permission")
        result = codex_pane_answer.answer(entry, body, **PANE_IO) if entry else (
            {"ok": False, "error": "This prompt is no longer pending in Codex."}, 409)
    else:
        return _MISSING
    _log(request_id, body, result)
    return result

