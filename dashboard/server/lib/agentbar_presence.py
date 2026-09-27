#!/usr/bin/env python3
"""Is AgentBar (the Mac app that answers hook prompts) connected right now?

The hook answer bridge (hook_permissions.py) may only HOLD a Claude prompt
while someone can answer it from AgentBar. Without this guard, a prompt of a
session whose own prompt Claude hides (or a user who never looks at
AgentBar) would wait on nobody.

"Seen" = any request on the LOCAL listener carrying `X-AgentBar: 1`
(AgentBar sends it on every request, `DashboardEndpoint.swift`), plus every
successful write to such a client's `/api/events` SSE stream (the server
pushes every ~2s, so a connected stream is "seen" every ~2s; a dropped one
fails its next write). AgentBar's fallback when SSE is down is polling
`/api/state` every 3s — also a seen request. Browser tabs of the SPA don't
send the header and don't count.

One timestamp, no connection bookkeeping: a frozen AgentBar whose socket
buffer filled blocks its SSE write, so it stops being "seen" too.
"""
import threading
import time

HEADER_NAME = "X-AgentBar"
HEADER_VALUE = "1"
#: Seen this recently = connected: a new prompt may be held for it.
CONNECTED_WITHIN_SEC = 10
#: Not seen for this long = gone: pending prompts are released (hooks exit,
#: Claude's own prompt decides). Longer than CONNECTED_WITHIN_SEC so an SSE
#: reconnect (1s pause, up to 15s backoff) or poll gap doesn't drop them.
GONE_AFTER_SEC = 15


def is_agentbar_request(headers, is_remote_listener):
    """AgentBar's own request on the local listener (never the phone's)."""
    if is_remote_listener or headers is None:
        return False
    return (headers.get(HEADER_NAME) or "").strip() == HEADER_VALUE


class AgentBarPresence:
    def __init__(self, clock=time.time):
        self._clock = clock
        self._lock = threading.Lock()
        self._last_seen_at = None

    def note_seen(self):
        with self._lock:
            self._last_seen_at = self._clock()

    def seconds_since_seen(self):
        """None = never seen since this server started."""
        with self._lock:
            if self._last_seen_at is None:
                return None
            return max(0.0, self._clock() - self._last_seen_at)

    def is_connected(self):
        since = self.seconds_since_seen()
        return since is not None and since <= CONNECTED_WITHIN_SEC

    def is_gone(self):
        since = self.seconds_since_seen()
        return since is None or since > GONE_AFTER_SEC


#: The one tracker the server uses.
PRESENCE = AgentBarPresence()
