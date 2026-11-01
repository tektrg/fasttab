"""Shared APNs delivery for every push kind (permission prompts, agent events).

  ApnsFanOut.can_reach_device()   APNs configured AND >= 1 registered device
  ApnsFanOut.send(build, collapse_id, background)
                                  runs off-thread (daemon); sends one payload to
                                  every device, drops dead tokens, never raises

Never blocks the caller: each send runs on a daemon thread, every request
bounded by apns_push.SEND_TIMEOUT_SEC. Not configured -> no-op.
"""
import sys
import threading
from urllib.parse import quote

import apns_devices
import apns_push


#: The PWA opens one agent's sheet from `?agent=<rowId>` (PhoneShell.tsx).
AGENT_QUERY_PARAM = "agent"


def agent_path(agent_key):
    """Same-origin PWA path that opens this agent; "/" when unknown."""
    if not agent_key:
        return "/"
    return f"/?{AGENT_QUERY_PARAM}={quote(str(agent_key), safe='')}"


def one_line(text, limit):
    text = " ".join(str(text or "").split())
    return text if len(text) <= limit else text[:limit - 1] + "\u2026"


def _start_daemon(work):
    threading.Thread(target=work, name="apns-push", daemon=True).start()


class ApnsFanOut:
    def __init__(self, client_factory=None, registry=None, run_async=None):
        self._client_factory = client_factory or apns_push.cached_client_from_config
        self._registry = registry or apns_devices.REGISTRY
        self._run_async = run_async or _start_daemon

    def can_reach_device(self):
        """A phone can be alerted (and can answer)."""
        return bool(self._registry.tokens()) and self._client_factory() is not None

    def send(self, build_payload, collapse_id, background=False):
        self._run_async(lambda: self._deliver(build_payload, collapse_id, background))

    def _deliver(self, build_payload, collapse_id, background):
        client = self._client_factory()
        tokens = self._registry.tokens() if client else []
        if not tokens:
            return
        payload = build_payload()
        for token in tokens:
            try:
                status, reason = client.send(token, payload, collapse_id=collapse_id, background=background)
            except Exception as e:  # noqa: BLE001 — a push failure must never surface
                print(f"[apns] send failed: {e}", file=sys.stderr)
                continue
            if status == 410 or reason in apns_push.DEAD_TOKEN_REASONS:
                self._registry.remove(token)
            elif status != 200:
                print(f"[apns] {status} {reason}", file=sys.stderr)
