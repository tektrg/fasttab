#!/usr/bin/env python3
"""Exact status for OpenCode / Codex panes, pushed by each tool's own event
system (Phase 2 of OpenCode/Codex support). This store never approves,
denies or answers; it only remembers WHAT is pending (`entry["request"]`, an
OpenCode permission/question the plugin reported) for `tui_answers.py`.

Senders (repo `dashboard/integrations/`):
  * OpenCode plugin `opencode/agentbar-status.js` — session/permission/question
    events + token usage + a 30s heartbeat.
  * Codex hook `codex/agentbar-codex-hook.py` — every hooks.json event,
    incl. PermissionRequest (pass-through: it never prints a decision).
Both POST one JSON object to `POST /api/hook/tui-event` (local listener only):
  {tool: "opencode"|"codex", event, sessionId, pid, cwd, paneId (HERDR_PANE_ID),
   serverUrl?, statusType?, tokens?, contextLimit?, title?, transcriptPath?,
   lastMessage?}

The store keeps one entry per (tool, sessionId). `attach_to_rows()` lays a
FRESH entry over its herdr row (matched by pane id, else a unique cwd) the
way a Claude hook-cache entry is: hookState/hookSinceSec/hasHookData/
hookReason, plus `statusSource`, `tuiPrompt` (permission|question|None) and
`tuiContextPercent`. Fresh = the tool's pid is alive and the last event /
heartbeat / rollout write is under STALE_AFTER_SEC old; anything else is
dropped, so the row decays back to its screen reading.
"""
import os
import re
import threading
import time

import codex_rollout

PATH = "/api/hook/tui-event"
TOOLS = ("opencode", "codex")
STALE_AFTER_SEC = float(os.environ.get("TUI_STATUS_STALE_SEC", 600))
MAX_ENTRIES = 200
MAX_TEXT = 2000
SESSION_ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,128}$")
LOCAL_URL_RE = re.compile(r"^http://(127\.0\.0\.1|localhost|\[::1\]):\d{1,5}/?$")

SOURCE_BY_TOOL = {"opencode": "opencode-plugin", "codex": "codex-hook"}
ROLLOUT_SOURCE = "codex-rollout"

# (status, prompt) per event; None = the event says nothing about status.
OPENCODE_EVENTS = {
    "session.idle": ("idle", None),
    "session.error": ("idle", None),
    "permission.asked": ("blocked", "permission"),
    "permission.replied": ("working", None),
    "question.asked": ("blocked", "question"),
    "question.replied": ("working", None),
    "question.rejected": ("working", None),
    # v2 event family: same meanings.
    "permission.v2.asked": ("blocked", "permission"),
    "permission.v2.replied": ("working", None),
    "question.v2.asked": ("blocked", "question"),
    "question.v2.replied": ("working", None),
    "question.v2.rejected": ("working", None),
}
OPENCODE_ASKED_EVENTS = ("permission.asked", "permission.v2.asked",
                         "question.asked", "question.v2.asked")
OPENCODE_ANSWERED_EVENTS = ("permission.replied", "permission.v2.replied",
                            "question.replied", "question.rejected",
                            "question.v2.replied", "question.v2.rejected")
OPENCODE_STATUS_TYPES = {"busy": "working", "retry": "working", "idle": "idle"}
CODEX_EVENTS = {
    "SessionStart": ("idle", None),
    "UserPromptSubmit": ("working", None),
    "PreToolUse": ("working", None),
    "PostToolUse": ("working", None),
    "PreCompact": ("working", None),
    "PostCompact": ("working", None),
    "SubagentStart": ("working", None),
    "SubagentStop": ("working", None),
    "PermissionRequest": ("blocked", "permission"),
    "Stop": ("idle", None),
}
END_EVENTS = {("opencode", "session.deleted"), ("codex", "SessionEnd")}


def _pid_alive(pid):
    try:
        os.kill(pid, 0)
    except PermissionError:
        return True
    except (OSError, OverflowError, ValueError, TypeError):
        return False
    return True


def _text(value, limit=MAX_TEXT):
    return value[:limit] if isinstance(value, str) else None


def asks_question(message):
    """True when a reply's last line is a question — Codex asks in plain
    prose, and that turn ends `idle` while it waits for the user."""
    if not isinstance(message, str):
        return False
    lines = [l.strip().strip("*_`").strip() for l in message.strip().splitlines()]
    lines = [l for l in lines if l]
    return bool(lines) and lines[-1].endswith("?")


def _question_reason(message):
    last = [l.strip() for l in message.strip().splitlines() if l.strip()][-1]
    return "Question: " + last[:120]


def _opencode_context_percent(tokens, limit):
    if not isinstance(tokens, dict) or not isinstance(limit, (int, float)) or limit <= 0:
        return None
    cache = tokens.get("cache") if isinstance(tokens.get("cache"), dict) else {}
    parts = [tokens.get("input"), tokens.get("output"), tokens.get("reasoning"),
             cache.get("read"), cache.get("write")]
    used = sum(p for p in parts if isinstance(p, (int, float)) and not isinstance(p, bool))
    return round(min(100.0, 100.0 * used / limit), 1) if used else None


def _event_status(tool, event, payload):
    """(status, prompt, reason) the event implies, or None."""
    if tool == "opencode":
        if event == "session.status":
            status = OPENCODE_STATUS_TYPES.get(payload.get("statusType"))
            return (status, None, None) if status else None
        mapped = OPENCODE_EVENTS.get(event)
    else:
        mapped = CODEX_EVENTS.get(event)
    if not mapped:
        return None
    status, prompt = mapped
    title = _text(payload.get("title"), 120)
    reason = None
    if prompt == "permission":
        reason = f"Permission: {title}" if title else "Permission needed"
    elif prompt == "question":
        reason = f"Question: {title}" if title else "Question"
    elif event == "session.error":
        reason = "Error"
    elif tool == "codex" and event == "Stop" and asks_question(payload.get("lastMessage")):
        status, prompt = "blocked", "question"
        reason = _question_reason(payload["lastMessage"])
    return status, prompt, reason


def _validate(payload):
    """(tool, event, sessionId) or raises ValueError."""
    if not isinstance(payload, dict):
        raise ValueError("body must be a JSON object")
    tool, event = payload.get("tool"), payload.get("event")
    if tool not in TOOLS:
        raise ValueError("unknown tool")
    if not isinstance(event, str) or not 0 < len(event) <= 64:
        raise ValueError("bad event")
    session_id = payload.get("sessionId")
    if event == "heartbeat":
        session_id = None
    elif not isinstance(session_id, str) or not SESSION_ID_RE.match(session_id):
        raise ValueError("bad sessionId")
    return tool, event, session_id


MAX_LIST = 20
REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9_]{1,80}$")


def _text_list(value, limit=300):
    if not isinstance(value, list):
        return []
    return [s for s in (_text(v, limit) for v in value[:MAX_LIST]) if s is not None]


def _clean_question(raw):
    if not isinstance(raw, dict) or not isinstance(raw.get("question"), str):
        return None
    options = [{"label": _text(o.get("label"), 300) or "", "description": _text(o.get("description"), 500) or ""}
               for o in (raw.get("options") or [])[:MAX_LIST] if isinstance(o, dict)]
    return {"question": _text(raw["question"]), "header": _text(raw.get("header"), 120) or "",
            "multiple": bool(raw.get("multiple")), "custom": raw.get("custom") is not False,
            "options": options}


def clean_request(raw):
    """The plugin's `request` object, bounded and typed — or None when it is
    not a whole permission / question (then nothing is offered for answering)."""
    if not isinstance(raw, dict) or not isinstance(raw.get("id"), str) \
            or not REQUEST_ID_RE.match(raw["id"]):
        return None
    if raw.get("kind") == "permission":
        return {"id": raw["id"], "kind": "permission",
                "permission": _text(raw.get("permission"), 200) or "",
                "patterns": _text_list(raw.get("patterns")),
                "always": _text_list(raw.get("always")),
                "detail": _text(raw.get("detail"), 1000) or ""}
    if raw.get("kind") == "question" and isinstance(raw.get("questions"), list):
        questions = [_clean_question(q) for q in raw["questions"][:8]]
        if questions and all(questions):
            return {"id": raw["id"], "kind": "question", "questions": questions}
    return None


class TuiStatusStore:
    def __init__(self, clock=time.time, pid_alive=_pid_alive):
        self._lock = threading.Lock()
        self._entries = {}
        self._clock = clock
        self._pid_alive = pid_alive

    def ingest(self, payload):
        """One event -> ({ok, state}, http status). Never raises."""
        try:
            tool, event, session_id = _validate(payload)
        except ValueError as e:
            return {"ok": False, "error": str(e)}, 400
        now = self._clock()
        pid = payload.get("pid")
        pid = pid if isinstance(pid, int) and not isinstance(pid, bool) and pid > 0 else None
        with self._lock:
            if event == "heartbeat":
                touched = 0
                for entry in self._entries.values():
                    if entry["tool"] == tool and pid and entry["pid"] == pid:
                        entry["lastSeen"] = now
                        touched += 1
                return {"ok": True, "state": "heartbeat", "sessions": touched}, 200
            key = (tool, session_id)
            if (tool, event) in END_EVENTS:
                self._entries.pop(key, None)
                return {"ok": True, "state": "ended"}, 200
            entry = self._entries.get(key) or self._new_entry(tool, session_id, now)
            self._update_identity(entry, payload, pid)
            self._update_request(entry, event, payload)
            self._update_context(entry, payload)
            implied = _event_status(tool, event, payload)
            if implied and implied[0]:
                status, prompt, reason = implied
                if status != entry["status"] or prompt != entry["prompt"]:
                    entry["statusSince"] = now
                entry.update(status=status, prompt=prompt, reason=reason,
                             lastEventAt=now)
            entry["lastSeen"] = now
            self._entries[key] = entry
            self._evict_oldest()
        return {"ok": True, "state": entry["status"] or "unknown"}, 200

    @staticmethod
    def _new_entry(tool, session_id, now):
        return {"tool": tool, "sessionId": session_id, "pid": None, "cwd": None,
                "paneId": None, "serverUrl": None, "relay": False, "canMessage": False,
                "transcriptPath": None,
                "status": None, "prompt": None, "reason": None,
                "request": None, "detail": None,
                "statusSince": now, "lastEventAt": now, "lastSeen": now,
                "contextPercent": None}

    @staticmethod
    def _update_identity(entry, payload, pid):
        if pid:
            entry["pid"] = pid
        for field in ("cwd", "paneId", "transcriptPath"):
            value = _text(payload.get(field), 4096)
            if value:
                entry[field] = value
        if payload.get("relay") is True:
            entry["relay"] = True  # the plugin runs replies itself (tui_jobs)
        if payload.get("messages") is True:
            entry["canMessage"] = True  # ...and can also submit a prompt (Phase 4)
        url = payload.get("serverUrl")
        if isinstance(url, str) and LOCAL_URL_RE.match(url):
            entry["serverUrl"] = url.rstrip("/")

    @staticmethod
    def _update_request(entry, event, payload):
        """The pending OpenCode request the plugin reported (cleared when it
        is answered / rejected, or when any other event says the turn moved on
        past it), and Codex's full permission text."""
        if entry["tool"] == "opencode":
            if event in OPENCODE_ASKED_EVENTS:
                entry["request"] = clean_request(payload.get("request"))
            elif event in OPENCODE_ANSWERED_EVENTS:
                answered = payload.get("requestId")
                if not entry["request"] or not answered or entry["request"]["id"] == answered:
                    entry["request"] = None
            elif event in ("session.idle", "session.error"):
                entry["request"] = None
        elif event == "PermissionRequest":
            entry["detail"] = _text(payload.get("detail"), 4000)
        else:
            entry["detail"] = None

    @staticmethod
    def _update_context(entry, payload):
        percent = _opencode_context_percent(payload.get("tokens"),
                                            payload.get("contextLimit"))
        if percent is not None:
            entry["contextPercent"] = percent

    def _evict_oldest(self):
        while len(self._entries) > MAX_ENTRIES:
            oldest = min(self._entries, key=lambda k: self._entries[k]["lastSeen"])
            del self._entries[oldest]

    def fresh_entries(self):
        """Copies of every entry still worth believing (Codex ones folded with
        their rollout). Dead-pid entries are dropped from the store."""
        now = self._clock()
        with self._lock:
            for key in [k for k, e in self._entries.items()
                        if e["pid"] and not self._pid_alive(e["pid"])]:
                del self._entries[key]
            entries = [dict(e) for e in self._entries.values()]
        fresh = []
        for entry in entries:
            entry["source"] = SOURCE_BY_TOOL[entry["tool"]]
            if entry["tool"] == "codex":
                _fold_rollout(entry)
            if entry["status"] and now - entry["lastSeen"] < STALE_AFTER_SEC:
                fresh.append(entry)
        return fresh

    def clear_request(self, tool, session_id, request_id):
        """Forget a pending request we just answered (the tool's own
        `replied` event would do it a moment later)."""
        with self._lock:
            entry = self._entries.get((tool, session_id))
            if entry and entry.get("request") and entry["request"]["id"] == request_id:
                entry["request"] = None

    def entry_for(self, tool, session_id):
        """A copy of one entry (fresh or not), or None."""
        with self._lock:
            entry = self._entries.get((tool, session_id))
            return dict(entry) if entry else None

    def clear(self):
        with self._lock:
            self._entries.clear()


def _fold_rollout(entry):
    """Context % from the rollout always; its turn state only when it was
    written after the last hook event and no permission prompt is open (a
    pending approval never shows in the rollout)."""
    path = codex_rollout.find_rollout(entry["sessionId"], entry.get("transcriptPath"))
    rollout = codex_rollout.read_rollout(path) if path else None
    if not rollout:
        return
    if rollout["contextPercent"] is not None:
        entry["contextPercent"] = rollout["contextPercent"]
    entry["lastSeen"] = max(entry["lastSeen"], rollout["mtime"])
    if (rollout["status"] and rollout["mtime"] > entry["lastEventAt"]
            and entry["prompt"] != "permission"):
        status, prompt, reason = rollout["status"], None, None
        if status == "idle" and asks_question(rollout["lastMessage"]):
            status, prompt = "blocked", "question"
            reason = _question_reason(rollout["lastMessage"])
        if (status, prompt) != (entry["status"], entry["prompt"]):
            entry["statusSince"] = rollout["mtime"]
        entry.update(status=status, prompt=prompt, reason=reason,
                     source=ROLLOUT_SOURCE)


def _match(row, entries, by_cwd):
    pane_id = row.get("paneId")
    for entry in entries:
        if pane_id and entry.get("paneId") == pane_id:
            return entry
    kind = row.get("agentKind")
    if kind in TOOLS and row.get("cwd"):
        candidates = by_cwd.get((kind, row["cwd"])) or []
        if len(candidates) == 1 and not candidates[0].get("paneId"):
            return candidates[0]
    return None


def attach_to_rows(rows, entries, now=None, local_machine="local", herdr_source="herdr"):
    """Lay fresh entries over matching LOCAL herdr rows that have no Claude
    hook data. A cwd match needs exactly one herdr row of that tool there
    and exactly one entry (two OpenCodes in one folder stay unmatched)."""
    now = time.time() if now is None else now
    local = [r for r in rows if r.get("machine") == local_machine
             and r.get("source") == herdr_source and not r.get("hasHookData")]
    rows_per_cwd = {}
    for r in local:
        if r.get("agentKind") in TOOLS and r.get("cwd"):
            rows_per_cwd.setdefault((r["agentKind"], r["cwd"]), []).append(r)
    by_cwd = {}
    for e in entries:
        if e.get("cwd"):
            by_cwd.setdefault((e["tool"], e["cwd"]), []).append(e)
    for key, group in rows_per_cwd.items():
        if len(group) > 1:
            by_cwd.pop(key, None)
    for row in local:
        entry = _match(row, entries, by_cwd)
        if not entry:
            continue
        row.update({
            "hookState": entry["status"],
            "hookSinceSec": max(0.0, now - entry["statusSince"]),
            "hasHookData": True,
            "hookReason": entry["reason"],
            "statusSource": entry["source"],
            "tuiPrompt": entry["prompt"],
            "tuiContextPercent": entry["contextPercent"],
            "tuiSessionId": entry["sessionId"],
        })
    return rows


STORE = TuiStatusStore()


def handle_post(path, read_body, is_remote, store=None):
    """Route for the server's do_POST; None when the path isn't ours."""
    if path != PATH:
        return None
    if is_remote:
        return {"error": "not found"}, 404
    try:
        payload = read_body()
    except ValueError as e:
        return {"ok": False, "error": f"bad JSON body: {e}"}, 400
    return (store or STORE).ingest(payload)
