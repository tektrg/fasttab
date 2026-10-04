"""Feedback tab proxy: dashboard UI -> theindie-api admin feedback routes.

Routes (both listeners; the remote one arrives already authenticated):
  GET  /api/feedback/threads?scope=all|waiting&limit=N   thread list
  GET  /api/feedback/threads/<uuid>                      thread + messages
  POST /api/feedback/threads/<uuid>/resolve              {message?, shippedInVersion?}

Upstream (theindie-api `src/routes/feedback-admin.ts`): `/v1/admin/feedback/...`
with `Authorization: Bearer <secret>`. Upstream has no cursor, only `limit`
(max 200), so "paging" here is the limit. Owner fields (notes/direction/
priority) are not in the API yet; any extra thread keys pass through
untouched so the UI can feature-detect them.

THE SECRET is read per request from `~/.theindie-feedback-admin-secret`
(override the path with `THEINDIE_FEEDBACK_ADMIN_SECRET_FILE`, tests only).
It never leaves this process: never returned, logged, or put in an error.
"""
import json
import os
import re
import urllib.error
import urllib.request
from urllib.parse import urlencode

PREFIX = "/api/feedback/threads"
API_BASE_ENV = "THEINDIE_API_BASE"
DEFAULT_API_BASE = "https://api.theindie.app"
SECRET_FILE_ENV = "THEINDIE_FEEDBACK_ADMIN_SECRET_FILE"
DEFAULT_SECRET_FILE = "~/.theindie-feedback-admin-secret"
TIMEOUT_SEC = 10
DEFAULT_LIMIT = 100
MAX_LIMIT = 200
MAX_MESSAGE_CHARS = 4000
MAX_VERSION_CHARS = 64
MAX_REPLY_BYTES = 2 * 1024 * 1024
SCOPES = ("all", "waiting")
_UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


class FeedbackProxyError(Exception):
    """A refusal whose message is safe to show the user verbatim."""

    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


def _secret():
    path = os.path.expanduser(os.environ.get(SECRET_FILE_ENV) or DEFAULT_SECRET_FILE)
    try:
        with open(path) as f:
            value = f.read().strip()
    except OSError:
        value = ""
    if not value:
        raise FeedbackProxyError(f"feedback admin secret missing: put it in {DEFAULT_SECRET_FILE}", 503)
    return value


def _api_base():
    return (os.environ.get(API_BASE_ENV) or DEFAULT_API_BASE).rstrip("/")


def _default_send(request):
    """Real network call; tests replace `send_request`."""
    with urllib.request.urlopen(request, timeout=TIMEOUT_SEC) as response:
        return response.status, response.read(MAX_REPLY_BYTES + 1)


send_request = _default_send


def _call_upstream(method, upstream_path, body=None):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request(_api_base() + upstream_path, data=data, method=method)
    request.add_header("Authorization", "Bearer " + _secret())
    request.add_header("Accept", "application/json")
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        status, raw = send_request(request)
    except urllib.error.HTTPError as e:
        status, raw = e.code, e.read(MAX_REPLY_BYTES + 1) if e.fp else b""
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        reason = getattr(e, "reason", e)
        raise FeedbackProxyError(f"theindie-api unreachable: {type(reason).__name__}", 502)
    if len(raw) > MAX_REPLY_BYTES:
        raise FeedbackProxyError("theindie-api reply too large", 502)
    try:
        payload = json.loads(raw or b"{}")
    except ValueError:
        raise FeedbackProxyError(f"theindie-api returned non-JSON (HTTP {status})", 502)
    if status >= 400:
        upstream_error = payload.get("error") if isinstance(payload, dict) else None
        message = upstream_error.get("message") if isinstance(upstream_error, dict) else None
        if status == 401:
            message = "theindie-api refused the admin secret"
        raise FeedbackProxyError(message or f"theindie-api HTTP {status}", status if status < 500 else 502)
    return payload


def _parse_limit(raw):
    if raw in (None, ""):
        return DEFAULT_LIMIT
    if not str(raw).isdigit() or not 1 <= int(raw) <= MAX_LIMIT:
        raise FeedbackProxyError(f"limit must be 1..{MAX_LIMIT}")
    return int(raw)


def _thread_id(raw):
    if not _UUID_RE.match(raw or ""):
        raise FeedbackProxyError("bad thread id")
    return raw.lower()


def list_threads(query):
    """query: parse_qs dict."""
    scope = (query.get("scope") or ["all"])[0]
    if scope not in SCOPES:
        raise FeedbackProxyError("scope must be all or waiting")
    limit = _parse_limit((query.get("limit") or [None])[0])
    payload = _call_upstream("GET", "/v1/admin/feedback/threads?" + urlencode({"scope": scope, "limit": limit}))
    threads = payload.get("threads") if isinstance(payload, dict) else None
    if not isinstance(threads, list):
        raise FeedbackProxyError("theindie-api reply has no threads list", 502)
    return {"ok": True, "threads": threads, "limit": limit, "hasMore": len(threads) >= limit}


def get_thread(thread_id):
    payload = _call_upstream("GET", f"/v1/admin/feedback/threads/{_thread_id(thread_id)}")
    return {"ok": True, "thread": payload.get("thread"), "messages": payload.get("messages") or []}


def resolve_thread(thread_id, body):
    if not isinstance(body, dict):
        raise FeedbackProxyError("body must be a JSON object")
    unknown = set(body) - {"message", "shippedInVersion"}
    if unknown:
        raise FeedbackProxyError("unknown field: " + ", ".join(sorted(unknown)))
    upstream_body = {}
    for key, max_chars in (("message", MAX_MESSAGE_CHARS), ("shippedInVersion", MAX_VERSION_CHARS)):
        value = body.get(key)
        if value is None or value == "":
            continue
        if not isinstance(value, str) or len(value) > max_chars:
            raise FeedbackProxyError(f"{key} must be text up to {max_chars} characters")
        upstream_body[key] = value.strip()
    payload = _call_upstream("POST", f"/v1/admin/feedback/threads/{_thread_id(thread_id)}/resolve", upstream_body)
    return {"ok": True, "messageID": payload.get("messageID")}


def _guard(action):
    try:
        return action(), 200
    except FeedbackProxyError as e:
        return {"ok": False, "error": str(e)}, e.status


def handle_get(path, query):
    """(payload, status) for a feedback GET, else None."""
    if path == PREFIX:
        return _guard(lambda: list_threads(query))
    if path.startswith(PREFIX + "/") and "/" not in path[len(PREFIX) + 1:]:
        return _guard(lambda: get_thread(path[len(PREFIX) + 1:]))
    return None


def handle_post(path, read_body):
    """(payload, status) for a feedback POST, else None."""
    if not (path.startswith(PREFIX + "/") and path.endswith("/resolve")):
        return None
    thread_id = path[len(PREFIX) + 1:-len("/resolve")]

    def run():
        try:
            body = read_body()
        except ValueError:
            raise FeedbackProxyError("body must be JSON")
        return resolve_thread(thread_id, body)

    return _guard(run)
