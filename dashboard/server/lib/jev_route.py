"""POST /api/jev/route — Jev picks which persona a message is for, on the
server, so a client with no OpenRouter key (the phone PWA) can route too.

Same classification AgentBar does itself (`Sources/AgentBar/Routing/
OpenRouterJevClient.swift`): one OpenRouter Decisions request (`choice`
question, criteria = one line per persona), never retried. The client only
ever gets the pick back — `{ok, persona, confidence}` — and the user
confirms before anything is sent or started (AgentBar's persona pick never
auto-sends either: "Confirm row states the effect").

Candidates are personas only (offered, not offline — `GET /api/personas`),
not live sessions: AgentBar's session candidates depend on its own row
eligibility rules; the phone targets a persona's main session instead.

THE KEY never leaves this Mac and is never logged or returned: read per
request from `<CONFIG_HOME>/openrouter-key` (default
`~/.config/agent-dashboard/openrouter-key`; override the PATH with
`AGENT_DASHBOARD_OPENROUTER_KEY_FILE`, tests only). The file must be a
regular file (no symlink) with mode 0600 or tighter, else routing is off —
same rule as the remote token. AgentBar keeps its own copy in the Keychain
(`KeychainRoutingAPIKeyStore`); the dashboard can't read that without a
prompt, hence a second place.

DUPLICATION: `ROUTE_INSTRUCTIONS`, the endpoint, the default model and the
persona summary format are copies of the Swift client's; a drift test
(`tests/test_jev_route.py`) reads the Swift source and fails on any
difference. AgentBar's user guidance (Settings > Routing, UserDefaults) and
model override are NOT applied here — the server can't read them.

LIMITS: one request in flight at a time, at most `RATE_LIMIT_PER_WINDOW`
per `RATE_WINDOW_SEC` (in memory), `TIMEOUT_SEC` per request.
"""
import json
import os
import stat
import threading
import time
import urllib.error
import urllib.request

import chief_dashboard_actions as session_actions
import dashboard_config

ROUTE_PATH = "/api/jev/route"
DECISIONS_URL = "https://openrouter.ai/api/alpha/decisions"
DEFAULT_MODEL = "~typesafe/jev-latest"
ROUTE_QUESTION_KEY = "route"
ROUTE_INSTRUCTIONS = "Pick the persona or specific live session this message is for. Pick a specific session only when the message continues that session's work. Prefer the most specific persona."
PERSONA_ID_PREFIX = "persona:"
TIMEOUT_SEC = 8
RATE_LIMIT_PER_WINDOW = 20
RATE_WINDOW_SEC = 60
KEY_FILE_ENV = "AGENT_DASHBOARD_OPENROUTER_KEY_FILE"
MAX_REPLY_BYTES = 256 * 1024
ALLOWED_BODY_KEYS = {"text"}


class JevRouteError(Exception):
    """A refusal whose message is safe to show the user verbatim."""


def key_path():
    return os.environ.get(KEY_FILE_ENV) or os.path.join(
        dashboard_config.CONFIG_HOME, "openrouter-key")


def _shown_path(path):
    """The path as the user would type it (`~/…`) — no username in replies."""
    home = os.path.expanduser("~")
    return "~" + path[len(home):] if path.startswith(home + os.sep) else path


def load_openrouter_key(path=None):
    """The key, or raises JevRouteError saying what the user must fix."""
    path = path or key_path()
    shown = _shown_path(path)
    try:
        st = os.lstat(path)
    except OSError:
        raise JevRouteError(
            f"Jev routing is off: no OpenRouter key on the Mac. Put it in {shown} (mode 600).")
    if not stat.S_ISREG(st.st_mode) or stat.S_IMODE(st.st_mode) & 0o077:
        raise JevRouteError(
            f"Jev routing is off: {shown} must be a plain file with mode 600.")
    try:
        with open(path) as f:
            value = f.read().strip()
    except OSError:
        raise JevRouteError(f"Jev routing is off: {shown} can't be read.")
    if not value:
        raise JevRouteError(f"Jev routing is off: {shown} is empty.")
    return value


def persona_summary(persona):
    """One Decisions criterion — same text as RouteCandidateBuilder.swift."""
    summary = f"{persona['name']} — {persona['description']}."
    if persona.get("routesWhen"):
        summary += f" Routes here: {', '.join(persona['routesWhen'])}."
    if persona.get("notFor"):
        summary += f" Not for: {', '.join(persona['notFor'])}."
    return summary


def build_criteria(persona_rows):
    return {PERSONA_ID_PREFIX + p["name"]: persona_summary(p)
            for p in persona_rows if not p.get("offline")}


def build_request_body(text, criteria, model=DEFAULT_MODEL):
    return {
        "model": model,
        "state": text,
        "questions": {ROUTE_QUESTION_KEY: {
            "type": "choice",
            "instructions": ROUTE_INSTRUCTIONS,
            "criteria": criteria,
        }},
    }


def urllib_post_json(url, headers, body_bytes, timeout):
    """(status, reply bytes). Raises on connection failure / timeout."""
    request = urllib.request.Request(url, data=body_bytes, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as resp:
            return resp.status, resp.read(MAX_REPLY_BYTES)
    except urllib.error.HTTPError as e:
        return e.code, b""


def parse_pick(status, reply_bytes, criteria):
    """{ok, persona, confidence} or raises JevRouteError."""
    if not 200 <= status < 300:
        raise JevRouteError(f"Jev routing failed (HTTP {status}).")
    try:
        route = (json.loads(reply_bytes).get("answers") or {}).get(ROUTE_QUESTION_KEY) or {}
    except (ValueError, AttributeError):
        raise JevRouteError("Jev routing returned an unreadable reply.")
    choice = route.get("choice") if isinstance(route, dict) else None
    if not isinstance(choice, str) or not choice:
        raise JevRouteError("Jev did not pick an agent.")
    if choice not in criteria:
        raise JevRouteError("Jev picked an unknown agent.")
    confidence = route.get("confidence")
    # Missing confidence is 0.0, never a guess (same rule as the Swift client).
    if not isinstance(confidence, (int, float)) or isinstance(confidence, bool):
        confidence = 0.0
    return {"ok": True, "persona": choice[len(PERSONA_ID_PREFIX):],
            "confidence": float(confidence)}


class RateLimiter:
    """One request in flight, and at most `limit` starts per `window` s."""

    def __init__(self, limit=RATE_LIMIT_PER_WINDOW, window=RATE_WINDOW_SEC, clock=time.monotonic):
        self.limit, self.window, self.clock = limit, window, clock
        self._lock = threading.Lock()
        self._in_flight = False
        self._starts = []

    def acquire(self):
        with self._lock:
            if self._in_flight:
                raise JevRouteError("Jev is already routing a message — try again in a moment.")
            now = self.clock()
            self._starts = [t for t in self._starts if now - t < self.window]
            if len(self._starts) >= self.limit:
                raise JevRouteError("Too many Jev routing requests — wait a minute.")
            self._starts.append(now)
            self._in_flight = True

    def release(self):
        with self._lock:
            self._in_flight = False


class RouteDeps:
    """Seams for tests: where personas, the key and the network come from."""

    def __init__(self, personas_fn=None, key_fn=None, post_fn=None, limiter=None):
        self.personas_fn = personas_fn or _default_personas
        self.key_fn = key_fn or load_openrouter_key
        self.post_fn = post_fn or urllib_post_json
        self.limiter = limiter or LIMITER


def _default_personas():
    import personas  # lazy: personas imports chief_dashboard_views
    return personas.get_personas_state()


LIMITER = RateLimiter()


def route_message(body, deps=None):
    """POST /api/jev/route {text} -> {ok, persona, confidence} | {ok:false, error}."""
    deps = deps or RouteDeps()
    if not isinstance(body, dict):
        return {"ok": False, "error": "body must be a JSON object"}
    extra = sorted(set(body) - ALLOWED_BODY_KEYS)
    if extra:
        return {"ok": False, "error": f"unexpected field(s): {', '.join(extra)}"}
    ok, cleaned = session_actions.validate_message_text(body.get("text"))
    if not ok:
        return {"ok": False, "error": cleaned}
    try:
        criteria = build_criteria(deps.personas_fn())
        if not criteria:
            raise JevRouteError("No persona to route to — add one in AgentBar Settings > Personas.")
        key = deps.key_fn()
        deps.limiter.acquire()
        try:
            status, reply = deps.post_fn(
                DECISIONS_URL,
                {"Content-Type": "application/json", "Accept": "application/json",
                 "Authorization": f"Bearer {key}"},
                json.dumps(build_request_body(cleaned, criteria)).encode(),
                TIMEOUT_SEC)
        except TimeoutError:
            raise JevRouteError("Jev routing timed out.")
        except (OSError, urllib.error.URLError) as e:
            reason = getattr(e, "reason", None)
            if isinstance(reason, TimeoutError) or "timed out" in str(e):
                raise JevRouteError("Jev routing timed out.")
            raise JevRouteError("Jev routing could not reach OpenRouter.")
        finally:
            deps.limiter.release()
        return parse_pick(status, reply, criteria)
    except JevRouteError as e:
        return {"ok": False, "error": str(e)}
