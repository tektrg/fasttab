#!/usr/bin/env python3
"""Answer an OpenCode permission / question through that TUI's own local HTTP
server (Phase 3 of OpenCode/Codex support).

Route shapes are the ones served by OpenCode 1.18.30 `GET /doc`, checked live
on a throwaway `opencode serve` (2026-09-29). Two API families exist:

  v1  GET /permission                      -> [{id, sessionID, permission, patterns, metadata, always}]
      POST /permission/{id}/reply          {reply: once|always|reject, message?}
      GET /question                        -> [{id, sessionID, questions:[{question, header, options[{label}], multiple, custom}]}]
      POST /question/{id}/reply            {answers: [[label...] per question]}
      POST /question/{id}/reject
  v2  GET /api/session/{sid}/permission    -> {data: [{id, sessionID, action, resources, save}]}
      POST /api/session/{sid}/permission/{id}/reply   {reply, message?}
      GET /api/session/{sid}/question      -> {data: [...same as v1 question]}
      POST /api/session/{sid}/question/{id}/reply     {answers}
      POST /api/session/{sid}/question/{id}/reject

Nothing is guessed. Before any POST: the server URL must be loopback, the
OpenCode pid alive and ours, the request id one our plugin reported as pending
AND still listed as pending by the server itself (a missing id = someone
answered first -> refused as "answered elsewhere"). An unexpected list shape,
a 401/403, or an unlisted answer -> refused with the reason. `http` is
injectable so tests use a fake server.
"""
import json
import os
import subprocess
import threading
from urllib.parse import quote, urlparse
import urllib.error
import urllib.request

import hook_permission_summary as summary
import tui_jobs

TIMEOUT_SEC = 5
LOOPBACK_HOSTS = ("127.0.0.1", "localhost", "::1", "[::1]")
V1, V2 = "v1", "v2"
#: No proxies, ever: urllib honours HTTP_PROXY even for 127.0.0.1.
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))

_inflight = set()
_inflight_lock = threading.Lock()


class Refused(Exception):
    """Not sent. `status` is the HTTP status of our reply; `text` user-facing."""

    def __init__(self, text, status=409):
        super().__init__(text)
        self.text, self.status = text, status


def http_json(method, url, body=None, timeout=TIMEOUT_SEC):
    """(status, parsed JSON | None). HTTP errors are returned, not raised."""
    data = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request(url, data=data, method=method,
                                     headers={"Content-Type": "application/json"})
    try:
        with _OPENER.open(request, timeout=timeout) as response:
            raw, status = response.read(), response.status
    except urllib.error.HTTPError as e:
        raw, status = e.read(), e.code
    try:
        return status, json.loads(raw) if raw else None
    except ValueError:
        return status, None


def pid_owned_by_me(pid):
    """The process exists and belongs to this user (ps shows its uid)."""
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 1:
        return False
    try:
        out = subprocess.run(["ps", "-o", "uid=", "-p", str(pid)], capture_output=True,
                             text=True, timeout=2).stdout.strip()
        return out == str(os.getuid())
    except (OSError, subprocess.SubprocessError):
        return False


def loopback_base(server_url):
    """The server URL without trailing slash, only if it is http on loopback."""
    try:
        parsed = urlparse(server_url or "")
        ok = parsed.scheme == "http" and parsed.hostname in LOOPBACK_HOSTS \
            and parsed.port and not parsed.username and not parsed.path.strip("/") \
            and not parsed.query
    except ValueError:
        ok = False
    if not ok:
        raise Refused("OpenCode's server address is not a local one; not answering it", 400)
    return f"{parsed.scheme}://{parsed.netloc}"


# ── pending lists (the server's own truth) ─────────────────────────────────

def _list_ids(http, url, unwrap_data):
    """Set of pending ids at `url`, or None when the route is unavailable.
    A reply of the wrong shape raises Refused (never guessed around)."""
    status, body = http("GET", url)
    if status in (401, 403):
        raise Refused("OpenCode's server needs a password; AgentBar cannot answer it", 403)
    if status == 404:
        return None
    rows = body.get("data") if unwrap_data and isinstance(body, dict) else body
    if status != 200 or not isinstance(rows, list) \
            or not all(isinstance(r, dict) and isinstance(r.get("id"), str) for r in rows):
        raise Refused("OpenCode's pending list has an unexpected shape; refusing to answer", 502)
    return {r["id"] for r in rows}


def find_api(http, base, entry, kind, request_id):
    """V1 or V2: which pending list holds `request_id`. Refuses when neither does."""
    directory = quote(entry.get("cwd") or "", safe="")
    sid = quote(entry["sessionId"], safe="")
    v1_url = f"{base}/{kind}" + (f"?directory={directory}" if directory else "")
    v2_url = f"{base}/api/session/{sid}/{kind}"
    v1 = _list_ids(http, v1_url, False)
    if v1 is not None and request_id in v1:
        return V1
    v2 = _list_ids(http, v2_url, True)
    if v2 is not None and request_id in v2:
        return V2
    if v1 is None and v2 is None:
        raise Refused("OpenCode's server does not list pending requests; cannot verify", 502)
    raise Refused("This prompt was already answered in OpenCode.")


# ── request bodies ─────────────────────────────────────────────────────────

def permission_reply_body(request, body):
    """The reply for a permission (once / always / reject), or AnswerRejected."""
    behavior = body.get("behavior")
    if behavior == "deny":
        message = body.get("message")
        reply = {"reply": "reject"}
        if message:
            reply["message"] = summary.clean_answer_text(message)
        return reply
    if behavior != "allow":
        raise summary.AnswerRejected("behavior must be 'allow' or 'deny'")
    index = body.get("suggestionIndex")
    if index is None:
        return {"reply": "once"}
    if isinstance(index, bool) or index != 0 or not request["always"]:
        raise summary.AnswerRejected(f"suggestionIndex {index!r} is not one of the offered suggestions")
    return {"reply": "always"}


def _labels_for(question, text):
    """The answer strings for one question: the option label(s) picked, else
    the typed text when the question accepts one."""
    labels = [o["label"] for o in question["options"]]
    if text in labels:
        return [text]
    if question["multiple"]:
        parts = text.split(", ")
        if parts and all(p in labels for p in parts):
            return parts
    if question["custom"]:
        return [text]
    raise summary.AnswerRejected(f"{text!r} is not an option of: {question['question']}")


def question_reply_body(request, body):
    answers = body.get("answers")
    if not isinstance(answers, dict):
        raise summary.AnswerRejected("answers must be an object keyed by question text")
    expected = [q["question"] for q in request["questions"]]
    if set(answers) != set(expected) or len(set(expected)) != len(expected):
        raise summary.AnswerRejected("answers must answer exactly these questions: "
                                     + " | ".join(sorted(expected)))
    return {"answers": [_labels_for(q, summary.clean_answer_text(answers[q["question"]]))
                        for q in request["questions"]]}


# ── the answer ─────────────────────────────────────────────────────────────

def _endpoint(base, api, entry, kind, request_id, action):
    rid = quote(request_id, safe="")
    if api == V1:
        return f"{base}/{kind}/{rid}/{action}"
    return f"{base}/api/session/{quote(entry['sessionId'], safe='')}/{kind}/{rid}/{action}"


def _build_post(request, body):
    """(action, json body | None) for the reply to `request`."""
    if request["kind"] == "permission":
        return "reply", permission_reply_body(request, body)
    if body.get("behavior") == "deny":
        return "reject", None
    if body.get("behavior") != "allow":
        raise summary.AnswerRejected("behavior must be 'allow' or 'deny'")
    return "reply", question_reply_body(request, body)


def relay_http(pid, queue=None):
    """An `http` callable that runs each request inside the OpenCode plugin of
    `pid` (tui_jobs) instead of over TCP. A default OpenCode TUI has no
    listening server, so this is the path that works for it."""
    from urllib.parse import urlparse as _parse

    def call(method, url, body=None):
        parts = _parse(url)
        path = parts.path + (f"?{parts.query}" if parts.query else "")
        try:
            return (queue or tui_jobs.QUEUE).submit(pid, method, path, body)
        except TimeoutError as e:
            raise Refused(f"{e}; answer it in OpenCode", 502)
    return call


def answer(entry, body, http=None, pid_check=pid_owned_by_me):
    """(payload, http status). `entry`: the fresh status entry (a copy) whose
    `request` the caller matched by id. Never raises. Entries whose plugin
    relays (`relay`) are answered through it; others over loopback HTTP."""
    request = entry.get("request")
    try:
        if not isinstance(body, dict):
            raise summary.AnswerRejected("body must be a JSON object")
        if not request:
            raise Refused("This prompt is no longer pending in OpenCode.")
        relayed = bool(entry.get("relay")) and http is None
        base = "http://relay.invalid" if relayed else loopback_base(entry.get("serverUrl"))
        if not pid_check(entry.get("pid")):
            raise Refused("OpenCode is no longer running (or is not yours).")
        if http is None:
            http = relay_http(entry["pid"]) if relayed else http_json
        action, post_body = _build_post(request, body)
        kind = request["kind"]
        with _claim(request["id"]):
            api = find_api(http, base, entry, kind, request["id"])
            url = _endpoint(base, api, entry, kind, request["id"], action)
            status, reply = http("POST", url, post_body)
        return _outcome(status, reply)
    except summary.AnswerRejected as e:
        return {"ok": False, "error": str(e)}, 400
    except Refused as e:
        return {"ok": False, "error": e.text}, e.status
    except Exception as e:  # noqa: BLE001 — network trouble: report, never crash the handler
        return {"ok": False, "error": f"could not reach OpenCode: {e}"}, 502


def _outcome(status, reply):
    if status == 404:
        return {"ok": False, "error": "This prompt was already answered in OpenCode."}, 409
    if status in (401, 403):
        return {"ok": False, "error": "OpenCode's server needs a password; AgentBar cannot answer it"}, 403
    if 200 <= status < 300 and reply is not False:
        return {"ok": True, "state": "answered"}, 200
    return {"ok": False, "error": f"OpenCode refused the answer (HTTP {status})"}, 502


class _claim:
    """One answer in flight per request id: the second surface gets a 409."""

    def __init__(self, request_id):
        self.request_id = request_id

    def __enter__(self):
        with _inflight_lock:
            if self.request_id in _inflight:
                raise Refused("This prompt is being answered right now.")
            _inflight.add(self.request_id)

    def __exit__(self, *exc):
        with _inflight_lock:
            _inflight.discard(self.request_id)
