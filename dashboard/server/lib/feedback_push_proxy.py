"""Feedback push proxy: phone Web Push registration -> theindie-api owner push routes.

Routes (both listeners; the remote one arrives already authenticated):
  GET  /api/feedback/push/config        {ok, configured, publicKey}  VAPID key for subscribe()
  POST /api/feedback/push/subscribe     {endpoint, keys: {p256dh, auth}, label?}
  POST /api/feedback/push/unsubscribe   {endpoint}
  POST /api/feedback/push/test          send a test push -> {ok, sent, removed, failed}

Upstream: theindie-api `/v1/admin/feedback/push/...` (src/routes/feedback-owner-push.ts),
sent by theindie-api itself, so a push arrives while this Mac sleeps. Transport and the
admin secret handling are shared with the Feedback tab proxy (`feedback_admin_proxy`):
the secret never reaches the browser.
"""
from feedback_admin_proxy import FeedbackProxyError, _call_upstream, _guard

PREFIX = "/api/feedback/push"
UPSTREAM = "/v1/admin/feedback/push"
MAX_ENDPOINT_CHARS = 1024
MAX_KEY_CHARS = 200
MAX_LABEL_CHARS = 80


def _short_text(body, key, max_chars, required=True):
    value = body.get(key)
    if value is None and not required:
        return None
    if not isinstance(value, str) or not value.strip() or len(value) > max_chars:
        raise FeedbackProxyError(f"{key} must be text up to {max_chars} characters")
    return value.strip()


def _endpoint(body):
    if not isinstance(body, dict):
        raise FeedbackProxyError("body must be a JSON object")
    endpoint = _short_text(body, "endpoint", MAX_ENDPOINT_CHARS)
    if not endpoint.startswith("https://"):
        raise FeedbackProxyError("endpoint must be an https URL")
    return endpoint


def subscribe(body):
    endpoint = _endpoint(body)
    keys = body.get("keys")
    if not isinstance(keys, dict):
        raise FeedbackProxyError("keys must be an object")
    upstream = {"endpoint": endpoint, "keys": {k: _short_text(keys, k, MAX_KEY_CHARS) for k in ("p256dh", "auth")}}
    label = _short_text(body, "label", MAX_LABEL_CHARS, required=False)
    if label:
        upstream["label"] = label
    _call_upstream("POST", UPSTREAM + "/subscriptions", upstream)
    return {"ok": True}


def unsubscribe(body):
    payload = _call_upstream("DELETE", UPSTREAM + "/subscriptions", {"endpoint": _endpoint(body)})
    return {"ok": True, "removed": bool(payload.get("removed"))}


def send_test():
    payload = _call_upstream("POST", UPSTREAM + "/test", {})
    return {"ok": True, **{k: int(payload.get(k) or 0) for k in ("sent", "removed", "failed")}}


def get_config():
    payload = _call_upstream("GET", UPSTREAM + "/config")
    key = payload.get("publicKey")
    return {"ok": True, "configured": bool(payload.get("configured")), "publicKey": key if isinstance(key, str) else None}


def handle_get(path, _query=None):
    """(payload, status) for a push GET, else None."""
    return _guard(get_config) if path == PREFIX + "/config" else None


_POSTS = {"/subscribe": subscribe, "/unsubscribe": unsubscribe}


def handle_post(path, read_body):
    """(payload, status) for a push POST, else None."""
    if path == PREFIX + "/test":
        return _guard(send_test)
    action = _POSTS.get(path[len(PREFIX):]) if path.startswith(PREFIX + "/") else None
    if action is None:
        return None

    def run():
        try:
            body = read_body()
        except ValueError:
            raise FeedbackProxyError("body must be JSON")
        return action(body)

    return _guard(run)
