#!/usr/bin/env python3
"""QA pass 2 redesign: tests for remote access as a SEPARATE listener
(server/lib/remote_access.py plus the handful of Handler hooks in
chief-dashboard-server.py that call it) — no Host-header trust anywhere.

SAFETY: this test never binds a real socket and never calls a real herdr/
API handler — every check below exercises the auth/CSRF/audit gate methods
directly (`_reject_foreign_write`, `_is_remote_listener`,
`_remote_authenticated`, do_GET's own gate) the same way
test_chief_dashboard_origin_guard.py does, never the downstream `/api/*`
business logic those gates protect. It never touches port 4711 or 4712 and
points CHIEF_DASHBOARD_CONFIG_HOME/_STATE_HOME at a throwaway temp dir for
the whole run, so it can never read or write the real
~/.config/agent-dashboard/ files.

A FakeHandler is given a fake `.server` object whose `.remote_listener`
attribute stands in for "this request arrived on the separate remote
socket" — precisely the flag chief-dashboard-server.py's two real listeners
set on themselves in main()/`_start_remote_listener`.
"""
import io
import json
import os
import sys
import tempfile

DASHBOARD_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB_DIR = os.path.join(DASHBOARD_DIR, "server", "lib")
sys.path.insert(0, LIB_DIR)

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


# ---- fresh, throwaway config/state dirs, set BEFORE any import below ----
_tmp = tempfile.TemporaryDirectory()
CONFIG_HOME = os.path.join(_tmp.name, "config")
STATE_HOME = os.path.join(_tmp.name, "state")
os.makedirs(CONFIG_HOME, exist_ok=True)
os.makedirs(STATE_HOME, exist_ok=True)
os.environ["CHIEF_DASHBOARD_CONFIG_HOME"] = CONFIG_HOME
os.environ["CHIEF_DASHBOARD_STATE_HOME"] = STATE_HOME
# No machines file anywhere this test controls -> _load_machines finds
# nothing configured and returns ({}, None), never touching SSH/herdr.
os.environ["CHIEF_DASHBOARD_MACHINES"] = "{}"

REMOTE_HOST = "test-mac.tailnet.ts.net"
REMOTE_PORT = 4712
TOKEN = "s3cr3t-phase1a-token"

with open(os.path.join(CONFIG_HOME, "config.json"), "w") as f:
    json.dump({"remote": {"enabled": True, "hosts": [REMOTE_HOST], "port": REMOTE_PORT}}, f)
with open(os.path.join(CONFIG_HOME, "remote-token"), "w") as f:
    f.write(TOKEN + "\n")
os.chmod(os.path.join(CONFIG_HOME, "remote-token"), 0o600)

import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "chief_dashboard_server_remote_access_test",
    os.path.join(DASHBOARD_DIR, "server", "chief-dashboard-server.py"))
_srv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_srv)

import remote_access  # noqa: E402


class FakeWFile:
    def __init__(self):
        self.data = b""

    def write(self, chunk):
        self.data += chunk

    def flush(self):
        pass


class FakeServer:
    """Stand-in for the real QuietThreadingHTTPServer instance — only the
    one attribute the Handler actually reads is needed."""

    def __init__(self, remote_listener):
        self.remote_listener = remote_listener


class FakeHandler(_srv.Handler):
    """Skips BaseHTTPRequestHandler.__init__ (no real socket) — same trick
    test_chief_dashboard_origin_guard.py uses — but keeps the real
    _reject_foreign_write / do_GET / _send_json / _handle_remote_login, so
    this proves the actual integration, not a reimplementation of it."""

    def __init__(self, headers, path="/", method="GET", body=b"",
                 client_ip="203.0.113.9", remote_listener=False):
        self.headers = dict(headers)
        if body and "Content-Length" not in self.headers:
            self.headers["Content-Length"] = str(len(body))
        self.path = path
        self.command = method
        self.client_address = (client_ip, 51000)
        self.rfile = io.BytesIO(body)
        self.wfile = FakeWFile()
        self.response_status = None
        self.response_headers = {}
        self.server = FakeServer(remote_listener)

    def send_response(self, status, message=None):
        self.response_status = status

    def send_header(self, key, value):
        self.response_headers[key] = value

    def end_headers(self):
        pass

    def json_body(self):
        return json.loads(self.wfile.data.decode("utf-8"))


def audit_lines():
    if not os.path.exists(remote_access.AUDIT_LOG_PATH):
        return []
    with open(remote_access.AUDIT_LOG_PATH) as f:
        return [json.loads(line) for line in f if line.strip()]


print("== main (loopback) listener: remote gate never engages regardless of ==")
print("   Host/identity headers — remote_listener=False is the only switch ==")
h = FakeHandler({"Host": "127.0.0.1:4711"}, remote_listener=False)
check("_is_remote_listener is False on the main listener", h._is_remote_listener(), False)
rejected = h._reject_foreign_write()
check("main-listener write not rejected", rejected, False)

print("== main listener ignores Tailscale identity headers too (no Host ==")
print("   classification left to spoof — the flag is per-socket, not per-header) ==")
h = FakeHandler({"Host": REMOTE_HOST, "Tailscale-User-Login": "attacker@example.com"},
                 path="/api/state", method="GET", remote_listener=False)
h.do_GET()
check("main listener serves this GET unauthenticated (byte-identical to pre-remote-access)",
      h.response_status, 200)

print("== remote listener, GET, unauthenticated: 401 for /api/*, redirect otherwise ==")
h = FakeHandler({}, path="/api/state", method="GET", remote_listener=True)
h.do_GET()
check("unauth GET /api/* -> 401", h.response_status, 401)
check("unauth GET /api/* body says unauthenticated",
      h.json_body().get("ok"), False)

h = FakeHandler({}, path="/", method="GET", remote_listener=True)
h.do_GET()
check("unauth GET / -> 302", h.response_status, 302)
check("unauth GET / redirects to /remote/login",
      h.response_headers.get("Location"), "/remote/login")

print("== remote listener, GET /remote/login: always reachable, never gated ==")
h = FakeHandler({}, path="/remote/login", method="GET", remote_listener=True)
h.do_GET()
check("login page served without auth", h.response_status, 200)
check("login page body present", b"Sign in" in h.wfile.data, True)

print("== remote listener, POST /remote/login, bad token: refused, no cookie ==")
h = FakeHandler({}, path="/remote/login", method="POST",
                 body=json.dumps({"token": "wrong"}).encode(),
                 client_ip="203.0.113.50", remote_listener=True)
rejected = h._reject_foreign_write()
check("bad-token login handled (short-circuits do_POST)", rejected, True)
check("no Set-Cookie on bad token", "Set-Cookie" in h.response_headers, False)
check("bad token page says invalid", b"Invalid token" in h.wfile.data, True)

print("== remote listener, POST /remote/login, good token: session cookie issued ==")
h = FakeHandler({}, path="/remote/login", method="POST",
                 body=json.dumps({"token": TOKEN}).encode(),
                 client_ip="203.0.113.51", remote_listener=True)
rejected = h._reject_foreign_write()
check("good-token login handled", rejected, True)
check("good token redirects home", h.response_status, 302)
set_cookie = h.response_headers.get("Set-Cookie", "")
check("cookie is HttpOnly", "HttpOnly" in set_cookie, True)
check("cookie is Secure", "Secure" in set_cookie, True)
check("cookie is SameSite=Strict", "SameSite=Strict" in set_cookie, True)
session_id = None
for part in set_cookie.split(";"):
    if part.strip().startswith(f"{remote_access.SESSION_COOKIE_NAME}="):
        session_id = part.strip().split("=", 1)[1]
check("session id extracted", bool(session_id), True)
check("session is valid", remote_access.session_valid(session_id), True)

print("== remote listener, GET with the good cookie: gate lets it through ==")
h = FakeHandler({"Cookie": f"{remote_access.SESSION_COOKIE_NAME}={session_id}"},
                 path="/definitely-not-a-real-route", method="GET", remote_listener=True)
h.do_GET()
check("authenticated request reaches normal routing (404, not 401)",
      h.response_status, 404)

print("== remote listener, Bearer token also authenticates (no cookie needed) ==")
h = FakeHandler({"Authorization": f"Bearer {TOKEN}"}, remote_listener=True)
check("_remote_authenticated via bearer", h._remote_authenticated(), True)

print("== remote listener, authenticated write, matching Origin: allowed through ==")
h = FakeHandler({"Origin": f"https://{REMOTE_HOST}",
                 "Cookie": f"{remote_access.SESSION_COOKIE_NAME}={session_id}"},
                 path="/api/answer", method="POST", remote_listener=True)
rejected = h._reject_foreign_write()
check("authenticated same-origin write allowed", rejected, False)
check("pending audit recorded for flush", bool(getattr(h, "_pending_remote_audit", None)), True)
# Simulate the downstream handler's own response to prove _send_json flushes
# the pending audit line with the REAL status once it's known.
h._send_json({"ok": True}, status=200)
check("pending audit cleared after flush", getattr(h, "_pending_remote_audit", None), None)

print("== remote listener, authenticated write, Origin over http (not https): CSRF 403 ==")
h = FakeHandler({"Origin": f"http://{REMOTE_HOST}",
                 "Cookie": f"{remote_access.SESSION_COOKIE_NAME}={session_id}"},
                 path="/api/answer", method="POST", remote_listener=True)
rejected = h._reject_foreign_write()
check("plain-http Origin rejected (must be https)", rejected, True)
check("plain-http Origin write status 403", h.response_status, 403)

print("== remote listener, authenticated write, foreign Origin: CSRF 403 ==")
h = FakeHandler({"Origin": "https://evil.example",
                 "Cookie": f"{remote_access.SESSION_COOKIE_NAME}={session_id}"},
                 path="/api/answer", method="POST", remote_listener=True)
rejected = h._reject_foreign_write()
check("cross-origin write rejected", rejected, True)
check("cross-origin write status 403", h.response_status, 403)

print("== remote listener, unauthenticated write: 401, no CSRF check reached ==")
h = FakeHandler({"Origin": f"https://{REMOTE_HOST}"},
                 path="/api/answer", method="POST", remote_listener=True)
rejected = h._reject_foreign_write()
check("unauthenticated write rejected", rejected, True)
check("unauthenticated write status 401", h.response_status, 401)

print("== login rate limiting: repeated bad tokens from one IP get blocked ==")
blocked_ip = "203.0.113.77"
for _ in range(remote_access.LOGIN_MAX_FAILURES):
    hh = FakeHandler({}, path="/remote/login", method="POST",
                      body=json.dumps({"token": "still-wrong"}).encode(),
                      client_ip=blocked_ip, remote_listener=True)
    hh._reject_foreign_write()
h_still_wrong = FakeHandler({}, path="/remote/login", method="POST",
                             body=json.dumps({"token": "still-wrong"}).encode(),
                             client_ip=blocked_ip, remote_listener=True)
h_still_wrong._reject_foreign_write()
check("another wrong guess is blocked once the window is full",
      b"Too many attempts" in h_still_wrong.wfile.data, True)

print("== client_address is 127.0.0.1 for EVERY remote request (tailscale ==")
print("   serve always proxies over loopback), so the failure window above ==")
print("   is GLOBAL, not per-attacker — a real token must still get the ==")
print("   owner in despite it, or an attacker could lock the owner's own ==")
print("   phone out indefinitely by trickling wrong guesses ==")
h_correct_during_block = FakeHandler(
    {}, path="/remote/login", method="POST",
    body=json.dumps({"token": TOKEN}).encode(), client_ip=blocked_ip,
    remote_listener=True)
rejected = h_correct_during_block._reject_foreign_write()
check("the correct token still logs in during an active lockout window",
      rejected, True)
check("correct-token login redirects home (not blocked)",
      h_correct_during_block.response_status, 302)
check("correct-token login is NOT the 'too many attempts' page",
      b"Too many attempts" in h_correct_during_block.wfile.data, False)

print("== token rotation revokes every session already issued (not just ==")
print("   future logins — previously a documented gap) ==")
h_login = FakeHandler({}, path="/remote/login", method="POST",
                       body=json.dumps({"token": TOKEN}).encode(),
                       client_ip="203.0.113.90", remote_listener=True)
h_login._reject_foreign_write()
rotate_cookie = h_login.response_headers.get("Set-Cookie", "")
rotate_session_id = None
for part in rotate_cookie.split(";"):
    if part.strip().startswith(f"{remote_access.SESSION_COOKIE_NAME}="):
        rotate_session_id = part.strip().split("=", 1)[1]
check("session works before rotation",
      remote_access.session_valid(rotate_session_id), True)
with open(remote_access.TOKEN_PATH, "w") as f:
    f.write("a-brand-new-rotated-token\n")
os.chmod(remote_access.TOKEN_PATH, 0o600)
check("session is invalidated the moment the token file is rotated",
      remote_access.session_valid(rotate_session_id), False)
h_after_rotate = FakeHandler(
    {"Cookie": f"{remote_access.SESSION_COOKIE_NAME}={rotate_session_id}"},
    path="/api/state", method="GET", remote_listener=True)
h_after_rotate.do_GET()
check("GET with the pre-rotation cookie is refused after rotation",
      h_after_rotate.response_status, 401)
# restore the original token so later assertions in this file (if any were
# appended after this block) keep using the well-known TOKEN constant.
with open(remote_access.TOKEN_PATH, "w") as f:
    f.write(TOKEN + "\n")
os.chmod(remote_access.TOKEN_PATH, 0o600)

print("== sessions survive a dashboard restart (persisted, hashed, 0600) ==")
persist_session_id = remote_access.create_session()
sessions_mode = os.stat(remote_access.SESSIONS_PATH).st_mode & 0o777
check("sessions file is mode 0600", sessions_mode, 0o600)
with open(remote_access.SESSIONS_PATH) as f:
    sessions_text = f.read()
check("sessions file never holds a raw session id (hashes only)",
      persist_session_id in sessions_text or (session_id or "") in sessions_text, False)
remote_access._SESSIONS = None  # = a fresh server process
check("session still valid after a restart",
      remote_access.session_valid(persist_session_id), True)
check("a session revoked by rotation stays revoked after a restart",
      remote_access.session_valid(rotate_session_id), False)
with open(remote_access.TOKEN_PATH, "w") as f:
    f.write("rotated-while-down\n")
os.chmod(remote_access.TOKEN_PATH, 0o600)
remote_access._SESSIONS = None
check("rotation while the server was down revokes a persisted session",
      remote_access.session_valid(persist_session_id), False)
with open(remote_access.TOKEN_PATH, "w") as f:
    f.write(TOKEN + "\n")
os.chmod(remote_access.TOKEN_PATH, 0o600)
persist_session_id = remote_access.create_session()
os.chmod(remote_access.SESSIONS_PATH, 0o644)
remote_access._SESSIONS = None
check("a group/world-readable sessions file is ignored (logged out, not trusted)",
      remote_access.session_valid(persist_session_id), False)
with open(remote_access.SESSIONS_PATH, "w") as f:
    f.write("{not json")
os.chmod(remote_access.SESSIONS_PATH, 0o600)
remote_access._SESSIONS = None
check("a corrupt sessions file starts empty, no crash",
      remote_access.session_valid(persist_session_id), False)
fresh_session_id = remote_access.create_session()
check("login still works (and rewrites the file) after a corrupt one",
      remote_access.session_valid(fresh_session_id), True)
remote_access._SESSIONS = None
check("the rewritten file loads on the next restart",
      remote_access.session_valid(fresh_session_id), True)

print("== token file permissions: a loosened mode is never trusted ==")
os.chmod(remote_access.TOKEN_PATH, 0o644)
check("world-readable token file reads as no token", remote_access.load_token(), None)
check("verify_token always fails once the file is world-readable",
      remote_access.verify_token(TOKEN), False)
os.chmod(remote_access.TOKEN_PATH, 0o600)
check("token trusted again once mode is restored to 0600",
      remote_access.load_token(), TOKEN)

print("== phase 2a PWA assets: reachable on the remote listener WITHOUT auth ==")
print("   (manifest/icons/sw.js — iOS install flows fetch these before the ==")
print("   page's own cookie jar is necessarily involved) — everything else ==")
print("   on the remote listener still requires a session/token ==")
_pwa_tmp = tempfile.TemporaryDirectory()
_orig_ui_dist = _srv.Handler.UI_DIST
_srv.Handler.UI_DIST = _pwa_tmp.name
os.makedirs(os.path.join(_pwa_tmp.name, "icons"), exist_ok=True)
with open(os.path.join(_pwa_tmp.name, "manifest.webmanifest"), "w") as f:
    f.write('{"name": "AgentBar"}')
with open(os.path.join(_pwa_tmp.name, "sw.js"), "w") as f:
    f.write("// sw")
with open(os.path.join(_pwa_tmp.name, "icons", "icon-192.png"), "wb") as f:
    f.write(b"\x89PNG-fake-192")
with open(os.path.join(_pwa_tmp.name, "icons", "icon-512.png"), "wb") as f:
    f.write(b"\x89PNG-fake-512")
with open(os.path.join(_pwa_tmp.name, "apple-touch-icon.png"), "wb") as f:
    f.write(b"\x89PNG-fake-touch")
try:
    for pwa_path in _srv.Handler.PWA_PUBLIC_PATHS:
        h = FakeHandler({}, path=pwa_path, method="GET", remote_listener=True)
        h.do_GET()
        check(f"unauth GET {pwa_path} on remote listener -> 200", h.response_status, 200)
        check(f"{pwa_path} body non-empty", len(h.wfile.data) > 0, True)

    h = FakeHandler({}, path="/manifest.webmanifest", method="GET", remote_listener=True)
    h.do_GET()
    check("manifest Content-Type", h.response_headers.get("Content-Type"),
          "application/manifest+json")

    print("== every other remote-listener route is still gated — the PWA ==")
    print("   allowlist is exactly those 5 paths, nothing more ==")
    h = FakeHandler({}, path="/api/state", method="GET", remote_listener=True)
    h.do_GET()
    check("unauth GET /api/state on remote listener still 401", h.response_status, 401)
    h = FakeHandler({}, path="/assets/index.js", method="GET", remote_listener=True)
    h.do_GET()
    check("unauth GET /assets/* on remote listener still redirects to login",
          h.response_status, 302)

    print("== the main (loopback) listener also serves these paths (unchanged ==")
    print("   loopback behaviour — same route, no auth gate on that listener) ==")
    h = FakeHandler({}, path="/sw.js", method="GET", remote_listener=False)
    h.do_GET()
    check("main listener serves /sw.js", h.response_status, 200)
finally:
    _srv.Handler.UI_DIST = _orig_ui_dist
    _pwa_tmp.cleanup()

print()
print("== load_remote_settings: port defaults to 4712, honours config override ==")
enabled, hosts, port = remote_access.load_remote_settings()
check("enabled from config", enabled, True)
check("hosts from config", hosts, {REMOTE_HOST})
check("port from config", port, REMOTE_PORT)

print()
print("== audit log: every remote write attempt above left a JSONL line ==")
lines = audit_lines()
check("at least 5 audit lines written", len(lines) >= 5, True)
statuses = [l["status"] for l in lines]
check("401 (bad token login) present", 401 in statuses, True)
check("200 (good token login) present", 200 in statuses, True)
check("403 (CSRF) present", 403 in statuses, True)
allowed = [l for l in lines if l["route"] == "/api/answer" and l["status"] == 200]
check("allowed write's audit line present", bool(allowed), True)
check("audit lines never carry a 'host' field (Host is no longer trusted for anything)",
      all("host" not in l for l in lines), True)

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("All remote-access checks passed.")
