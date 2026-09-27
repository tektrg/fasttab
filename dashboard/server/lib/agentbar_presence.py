#!/usr/bin/env python3
"""Is an ANSWER SURFACE connected right now — AgentBar (the Mac app) or the
dashboard web UI (the phone's web remote, or a browser tab) — i.e. something
that can answer hook prompts?

The hook answer bridge (hook_permissions.py) may only HOLD a Claude prompt
while someone can answer it. Without this guard, a prompt of a session whose
own prompt Claude hides (or a user who never looks at AgentBar) would wait
on nobody.

"Seen" = any request on the LOCAL listener carrying `X-AgentBar: 1`
(AgentBar sends it on every request, `DashboardEndpoint.swift`), plus every
successful write to such a client's `/api/events` SSE stream (the server
pushes every ~2s, so a connected stream is "seen" every ~2s; a dropped one
fails its next write). AgentBar's fallback when SSE is down is polling
`/api/state` every 3s — also a seen request.

Web UI: its `/api/events` stream counts, on either listener, only when opened
with `?answerSurface=web` — the SPA build that renders `hookRequest` cards
sends it (dashboard/ui/src/api.ts); an older cached build that can't answer
doesn't, and neither does curl or the legacy page. On the remote (phone)
listener the stream is only reached after auth. An iOS PWA sent to the
background drops its stream, so the phone stops counting within ~15s; the
hook keeps re-sending (backoff <= 10s) and the prompt is back soon after the
PWA is reopened.

One timestamp, no connection bookkeeping: a frozen AgentBar whose socket
buffer filled blocks its SSE write, so it stops being "seen" too.
"""
import threading
import time

HEADER_NAME = "X-AgentBar"
HEADER_VALUE = "1"
#: `/api/events?answerSurface=web` = the web UI can answer hook prompts.
ANSWER_SURFACE_PARAM = "answerSurface"
WEB_ANSWER_SURFACE = "web"
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


def is_web_answer_stream(query):
    """`query` (parse_qs dict) of an `/api/events` request: the web UI that
    renders and answers hook prompts opened it."""
    return WEB_ANSWER_SURFACE in ((query or {}).get(ANSWER_SURFACE_PARAM) or [])


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
