"""Permission prompt -> APNs push to every registered iOS device (see
apns_push.py for the category/action contract).

  notify_registered(request_id, payload)  one AGENT_PERMISSION alert per
                                          request id (a hook re-send keeps
                                          its id, so it is not pushed again)
  notify_answered(request_id)             silent "withdrawn" push, same
                                          apns-collapse-id, so the app can
                                          clear the delivered notification

Never blocks the hook path: every send runs on a daemon thread, each
request bounded by apns_push.SEND_TIMEOUT_SEC. Not configured -> no-op.
"""
import os
import sys
import threading

import apns_devices
import apns_push
import hook_permission_summary as summary

CATEGORY_PERMISSION = "AGENT_PERMISSION"
#: The Watch's long look scrolls, so show the whole command, not a teaser.
SUMMARY_MAX_CHARS = 240
#: Remembered request ids (dedupe); old ones are dropped past this size.
SEEN_MAX = 500


def _one_line(text, limit=SUMMARY_MAX_CHARS):
    text = " ".join(str(text or "").split())
    return text if len(text) <= limit else text[:limit - 1] + "…"


def agent_name(payload):
    """The folder the agent runs in (its persona's folder name)."""
    cwd = payload.get("cwd") if isinstance(payload, dict) else None
    return os.path.basename(os.path.normpath(cwd)) if isinstance(cwd, str) and cwd else "Agent"


def short_summary(payload):
    """'Run a shell command: npm test' -> one line, <= SUMMARY_MAX_CHARS."""
    view = summary.build_hook_request_view(
        "push", payload["tool_name"], payload.get("tool_input") or {}, [], 0.0, 0.0)
    if view["kind"] == summary.KIND_QUESTION:
        questions = view.get("questions") or []
        return _one_line(questions[0]["question"] if questions else "Question")
    permission = view["permission"]
    detail = permission["detail"] or ""
    return _one_line(f"{permission['title']}: {detail}" if detail else permission["title"])


def permission_alert(request_id, payload):
    agent = agent_name(payload)
    text = short_summary(payload)
    return {"aps": {"alert": {"title": agent, "body": text}, "sound": "default",
                    "interruption-level": "time-sensitive", "category": CATEGORY_PERMISSION, "thread-id": agent},
            "requestId": request_id, "agent": agent, "summary": text,
            "toolName": payload.get("tool_name")}


class PermissionPusher:
    def __init__(self, client_factory=apns_push.client_from_config, registry=None,
                 run_async=None):
        self._client_factory = client_factory
        self._registry = registry or apns_devices.REGISTRY
        self._run_async = run_async or _start_daemon
        self._lock = threading.Lock()
        self._seen = {}

    def _first_time(self, request_id):
        with self._lock:
            if request_id in self._seen:
                return False
            self._seen[request_id] = True
            while len(self._seen) > SEEN_MAX:
                self._seen.pop(next(iter(self._seen)))
            return True

    def can_reach_device(self):
        """APNs configured AND at least one registered device: a phone can
        answer, so the hook bridge may hold prompts for it."""
        return bool(self._registry.tokens()) and self._client_factory() is not None

    def notify_registered(self, request_id, payload):
        if not request_id or not isinstance(payload, dict) or not self._first_time(request_id):
            return
        self._run_async(lambda: self._fan_out(lambda: permission_alert(request_id, payload), request_id, False))

    def notify_answered(self, request_id):
        with self._lock:
            if request_id not in self._seen:
                return
        self._run_async(lambda: self._fan_out(
            lambda: {"aps": {"content-available": 1}, "withdrawn": request_id}, request_id, True))

    def _fan_out(self, build_payload, request_id, background):
        client = self._client_factory()
        tokens = self._registry.tokens() if client else []
        if not tokens:
            return
        payload = build_payload()
        for token in tokens:
            try:
                status, reason = client.send(token, payload, collapse_id=request_id, background=background)
            except Exception as e:  # noqa: BLE001 — a push failure must never surface
                print(f"[apns] send failed: {e}", file=sys.stderr)
                continue
            if status == 410 or reason in apns_push.DEAD_TOKEN_REASONS:
                self._registry.remove(token)
            elif status != 200:
                print(f"[apns] {status} {reason}", file=sys.stderr)


def _start_daemon(work):
    threading.Thread(target=work, name="apns-push", daemon=True).start()


PUSHER = PermissionPusher()
