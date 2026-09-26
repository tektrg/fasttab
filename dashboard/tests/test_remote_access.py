#!/usr/bin/env python3
"""Phase 1a (docs/plans/2026-09-26-agentbar-mobile-web.md): tests for
remote access over `tailscale serve` — server/lib/remote_access.py plus the
handful of Handler hooks in chief-dashboard-server.py that call it.

SAFETY: this test never binds a real socket and never calls a real herdr/
API handler — every check below exercises the auth/CSRF/audit gate methods
directly (`_reject_foreign_write`, `_remote_context`, `_remote_authenticated`,
do_GET's own gate) the same way test_chief_dashboard_origin_guard.py does,
never the downstream `/api/*` business logic those gates protect. It never
touches port 4711 and points CHIEF_DASHBOARD_CONFIG_HOME/_STATE_HOME at a
throwaway temp dir for the whole run, so it can never read or write the
real ~/.config/agent-dashboard/ files.
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
TOKEN = "s3cr3t-phase1a-token"

with open(os.path.join(CONFIG_HOME, "config.json"), "w") as f:
    json.dump({"remote": {"enabled": True, "hosts": [REMOTE_HOST]}}, f)
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


class FakeHandler(_srv.Handler):
    """Skips BaseHTTPRequestHandler.__init__ (no real socket) — same trick
    test_chief_dashboard_origin_guard.py uses — but keeps the real
    _reject_foreign_write / do_GET / _send_json / _handle_remote_login, so
    this proves the actual integration, not a reimplementation of it."""

    def __init__(self, headers, path="/", method="GET", body=b"",
                 client_ip="203.0.113.9"):
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


print("== loopback Host: remote gate never engages, even with remote.enabled ==")
h = FakeHandler({"Host": "127.0.0.1:4711"})
check("_remote_context is None on loopback", h._remote_context(), None)
rejected = h._reject_foreign_write()
check("loopback write not rejected", rejected, False)

print("== unknown Host (not loopback, not configured remote): now requires auth, ==")
print("   never falls open (QA pass 1 fix — this used to bypass GET auth) ==")
h = FakeHandler({"Host": "some-other-machine.example"})
check("_remote_context is the unrecognized-host sentinel, never None",
      h._remote_context(), remote_access.UNRECOGNIZED_REMOTE_HOST)
rejected = h._reject_foreign_write()
check("unknown-host write rejected", rejected, True)
check("unknown-host status is 401 (auth gate, not a bare Origin/Host 403)",
      h.response_status, 401)

h = FakeHandler({"Host": "some-other-machine.example"}, path="/api/state", method="GET")
h.do_GET()
check("unknown-host GET /api/state -> 401, never served unauthenticated",
      h.response_status, 401)

print("== Host-header spoofing: 'Host: 127.0.0.1' proven proxied by a ==")
print("   Tailscale identity header must NOT be trusted as loopback ==")
h = FakeHandler({"Host": "127.0.0.1:4711", "Tailscale-User-Login": "attacker@example.com"})
check("_remote_context is not None when proxying is proven, even with a loopback-looking Host",
      h._remote_context() is None, False)
h = FakeHandler({"Host": "127.0.0.1:4711", "Tailscale-User-Login": "attacker@example.com"},
                 path="/api/state", method="GET")
h.do_GET()
check("spoofed-loopback-Host GET /api/state -> 401, never served unauthenticated",
      h.response_status, 401)

print("== remote Host, GET, unauthenticated: 401 for /api/*, redirect otherwise ==")
h = FakeHandler({"Host": REMOTE_HOST}, path="/api/state", method="GET")
h.do_GET()
check("unauth GET /api/* -> 401", h.response_status, 401)
check("unauth GET /api/* body says unauthenticated",
      h.json_body().get("ok"), False)

h = FakeHandler({"Host": REMOTE_HOST}, path="/", method="GET")
h.do_GET()
check("unauth GET / -> 302", h.response_status, 302)
check("unauth GET / redirects to /remote/login",
      h.response_headers.get("Location"), "/remote/login")

print("== remote Host, GET /remote/login: always reachable, never gated ==")
h = FakeHandler({"Host": REMOTE_HOST}, path="/remote/login", method="GET")
h.do_GET()
check("login page served without auth", h.response_status, 200)
check("login page body present", b"Sign in" in h.wfile.data, True)

print("== remote Host, POST /remote/login, bad token: refused, no cookie ==")
h = FakeHandler({"Host": REMOTE_HOST}, path="/remote/login", method="POST",
                 body=json.dumps({"token": "wrong"}).encode(),
                 client_ip="203.0.113.50")
rejected = h._reject_foreign_write()
check("bad-token login handled (short-circuits do_POST)", rejected, True)
check("no Set-Cookie on bad token", "Set-Cookie" in h.response_headers, False)
check("bad token page says invalid", b"Invalid token" in h.wfile.data, True)

print("== remote Host, POST /remote/login, good token: session cookie issued ==")
h = FakeHandler({"Host": REMOTE_HOST}, path="/remote/login", method="POST",
                 body=json.dumps({"token": TOKEN}).encode(),
                 client_ip="203.0.113.51")
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
check("session bound to the matched host",
      remote_access.session_host(session_id), REMOTE_HOST)

print("== remote Host, GET with the good cookie: gate lets it through ==")
h = FakeHandler({"Host": REMOTE_HOST, "Cookie": f"{remote_access.SESSION_COOKIE_NAME}={session_id}"},
                 path="/definitely-not-a-real-route", method="GET")
h.do_GET()
check("authenticated request reaches normal routing (404, not 401)",
      h.response_status, 404)

print("== remote Host, Bearer token also authenticates (no cookie needed) ==")
h = FakeHandler({"Host": REMOTE_HOST, "Authorization": f"Bearer {TOKEN}"})
check("_remote_authenticated via bearer", h._remote_authenticated(REMOTE_HOST), True)

print("== remote Host, authenticated write, matching Origin: allowed through ==")
h = FakeHandler({"Host": REMOTE_HOST, "Origin": f"https://{REMOTE_HOST}",
                 "Cookie": f"{remote_access.SESSION_COOKIE_NAME}={session_id}"},
                 path="/api/answer", method="POST")
rejected = h._reject_foreign_write()
check("authenticated same-origin write allowed", rejected, False)
check("pending audit recorded for flush", bool(getattr(h, "_pending_remote_audit", None)), True)
# Simulate the downstream handler's own response to prove _send_json flushes
# the pending audit line with the REAL status once it's known.
h._send_json({"ok": True}, status=200)
check("pending audit cleared after flush", getattr(h, "_pending_remote_audit", None), None)

print("== remote Host, authenticated write, foreign Origin: CSRF 403 ==")
h = FakeHandler({"Host": REMOTE_HOST, "Origin": "https://evil.example",
                 "Cookie": f"{remote_access.SESSION_COOKIE_NAME}={session_id}"},
                 path="/api/answer", method="POST")
rejected = h._reject_foreign_write()
check("cross-origin write rejected", rejected, True)
check("cross-origin write status 403", h.response_status, 403)

print("== remote Host, unauthenticated write: 401, no CSRF check reached ==")
h = FakeHandler({"Host": REMOTE_HOST, "Origin": f"https://{REMOTE_HOST}"},
                 path="/api/answer", method="POST")
rejected = h._reject_foreign_write()
check("unauthenticated write rejected", rejected, True)
check("unauthenticated write status 401", h.response_status, 401)

print("== login rate limiting: repeated bad tokens from one IP get blocked ==")
blocked_ip = "203.0.113.77"
for _ in range(remote_access.LOGIN_MAX_FAILURES):
    hh = FakeHandler({"Host": REMOTE_HOST}, path="/remote/login", method="POST",
                      body=json.dumps({"token": "still-wrong"}).encode(),
                      client_ip=blocked_ip)
    hh._reject_foreign_write()
h_still_wrong = FakeHandler({"Host": REMOTE_HOST}, path="/remote/login", method="POST",
                             body=json.dumps({"token": "still-wrong"}).encode(),
                             client_ip=blocked_ip)
h_still_wrong._reject_foreign_write()
check("another wrong guess is blocked once the window is full",
      b"Too many attempts" in h_still_wrong.wfile.data, True)

print("== QA pass 1 fix: client_address is 127.0.0.1 for EVERY remote request ==")
print("   (tailscale serve always proxies over loopback), so the failure ==")
print("   window above is GLOBAL, not per-attacker — a real token must ==")
print("   still get the owner in despite it, or an attacker could lock the ==")
print("   owner's own phone out indefinitely by trickling wrong guesses ==")
h_correct_during_block = FakeHandler(
    {"Host": REMOTE_HOST}, path="/remote/login", method="POST",
    body=json.dumps({"token": TOKEN}).encode(), client_ip=blocked_ip)
rejected = h_correct_during_block._reject_foreign_write()
check("the correct token still logs in during an active lockout window",
      rejected, True)
check("correct-token login redirects home (not blocked)",
      h_correct_during_block.response_status, 302)
check("correct-token login is NOT the 'too many attempts' page",
      b"Too many attempts" in h_correct_during_block.wfile.data, False)

print("== token rotation revokes every session already issued (not just ==")
print("   future logins — previously a documented gap) ==")
h_login = FakeHandler({"Host": REMOTE_HOST}, path="/remote/login", method="POST",
                       body=json.dumps({"token": TOKEN}).encode(),
                       client_ip="203.0.113.90")
h_login._reject_foreign_write()
rotate_cookie = h_login.response_headers.get("Set-Cookie", "")
rotate_session_id = None
for part in rotate_cookie.split(";"):
    if part.strip().startswith(f"{remote_access.SESSION_COOKIE_NAME}="):
        rotate_session_id = part.strip().split("=", 1)[1]
check("session works before rotation",
      remote_access.session_host(rotate_session_id), REMOTE_HOST)
with open(remote_access.TOKEN_PATH, "w") as f:
    f.write("a-brand-new-rotated-token\n")
os.chmod(remote_access.TOKEN_PATH, 0o600)
check("session is invalidated the moment the token file is rotated",
      remote_access.session_host(rotate_session_id), None)
h_after_rotate = FakeHandler(
    {"Host": REMOTE_HOST, "Cookie": f"{remote_access.SESSION_COOKIE_NAME}={rotate_session_id}"},
    path="/api/state", method="GET")
h_after_rotate.do_GET()
check("GET with the pre-rotation cookie is refused after rotation",
      h_after_rotate.response_status, 401)
# restore the original token so later assertions in this file (if any were
# appended after this block) keep using the well-known TOKEN constant.
with open(remote_access.TOKEN_PATH, "w") as f:
    f.write(TOKEN + "\n")
os.chmod(remote_access.TOKEN_PATH, 0o600)

print("== token file permissions: a loosened mode is never trusted ==")
os.chmod(remote_access.TOKEN_PATH, 0o644)
check("world-readable token file reads as no token", remote_access.load_token(), None)
check("verify_token always fails once the file is world-readable",
      remote_access.verify_token(TOKEN), False)
os.chmod(remote_access.TOKEN_PATH, 0o600)
check("token trusted again once mode is restored to 0600",
      remote_access.load_token(), TOKEN)

print()
print("== audit log: every remote write attempt above left a JSONL line ==")
lines = audit_lines()
check("at least 5 audit lines written", len(lines) >= 5, True)
statuses = [l["status"] for l in lines]
check("401 (bad token login) present", 401 in statuses, True)
check("200 (good token login) present", 200 in statuses, True)
check("403 (CSRF) present", 403 in statuses, True)
allowed = [l for l in lines if l["route"] == "/api/answer" and l["status"] == 200]
check("allowed write's audit line carries the matched host",
      allowed[0]["host"] if allowed else None, REMOTE_HOST)

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("All phase 1a remote-access checks passed.")
