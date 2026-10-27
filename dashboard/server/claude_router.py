#!/usr/bin/env python3
"""claude-router: a local streaming proxy that keeps Claude Code working when
one account hits its usage limit (brief: .claude/briefs/claude-account-rotation.md,
slice 1).

Point Claude Code at it (`ANTHROPIC_BASE_URL=http://127.0.0.1:4720`). Each
request goes to the first healthy account in `accounts.json` (priority order).
If that account answers 429 / 529 / a usage-limit error BEFORE any byte reached
the client, the account cools down (honouring retry-after / the reset header)
and the same request is replayed on the next account. A failure mid-stream is
never retried (a half-sent stream can't be spliced) — the client sees it, and
the next request goes elsewhere.

Fallback tier (`needsApproval: true`, e.g. DeepSeek) is never switched to
silently: the router answers 429 with a clear message and writes
`fallback-pending.json`; `POST /approve {"id": ...}` (AgentBar, slice 3) lets
it through until a Claude-tier account succeeds again.

Separate process on purpose: the chief dashboard restarts ~10x/day and must not
sit on the path of every live agent stream. Stdlib only.

Config  : <dashboard config dir>/accounts.json  (see accounts.example.json)
State   : <dashboard state dir>/claude-router/  (switch-log.jsonl, fallback-*.json)
Secrets : `tokenKeychain` (macOS Keychain service name) or `tokenEnv` — never in a file.
Port    : CLAUDE_ROUTER_PORT, default 4720 (4711/4712 belong to the dashboard).
"""
import email.utils
import http.client
import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import dashboard_config  # noqa: E402

DEFAULT_PORT = 4720
PROXYABLE_KINDS = ("proxy", "apikey")  # login/desktop accounts need AgentBar (slice 3/4)
LIMIT_STATUSES = (429, 529)
LIMIT_PATTERNS = ("usage limit", "rate limit", "rate_limit", "quota", "limit reached",
                  "overloaded", "insufficient credits", "credit balance")
DEFAULT_COOLDOWN = {429: 300, 529: 60, "network": 30, "limit": 300}
MAX_COOLDOWN = 6 * 3600
HOP_BY_HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
              "te", "trailer", "transfer-encoding", "upgrade", "host", "content-length"}
CLIENT_AUTH_HEADERS = {"authorization", "x-api-key"}
TOKEN_CACHE_SECONDS = 300


def accounts_path():
    return os.environ.get("CLAUDE_ROUTER_ACCOUNTS") or os.path.join(
        dashboard_config.CONFIG_HOME, "accounts.json")


def state_dir():
    return os.environ.get("CLAUDE_ROUTER_STATE") or os.path.join(
        dashboard_config.STATE_HOME, "claude-router")


def load_accounts(path=None):
    """Proxyable accounts in priority order. Raises on unreadable config."""
    with open(path or accounts_path()) as f:
        data = json.load(f)
    rows = data.get("accounts", data) if isinstance(data, dict) else data
    out = []
    for row in rows:
        if row.get("kind") in PROXYABLE_KINDS and row.get("baseUrl") and row.get("enabled", True):
            out.append(row)
    return out


_token_cache = {}


def resolve_token(account):
    """Token from Keychain (service name) or an env var. Cached briefly."""
    key = account["id"]
    hit = _token_cache.get(key)
    if hit and hit[1] > time.time():
        return hit[0]
    token = None
    if account.get("tokenEnv"):
        token = os.environ.get(account["tokenEnv"])
    elif account.get("tokenKeychain"):
        res = subprocess.run(
            ["security", "find-generic-password", "-a", os.environ.get("USER", ""),
             "-s", account["tokenKeychain"], "-w"],
            capture_output=True, text=True, timeout=10)
        token = res.stdout.strip() if res.returncode == 0 else None
    if token:
        _token_cache[key] = (token, time.time() + TOKEN_CACHE_SECONDS)
    return token


def cooldown_seconds(status, headers, now=None):
    """How long to rest an account: retry-after (secs or HTTP date), then the
    unified reset header (epoch secs), else a per-status default."""
    now = now or time.time()
    ra = headers.get("retry-after")
    if ra:
        try:
            return min(MAX_COOLDOWN, max(1, float(ra)))
        except ValueError:
            try:
                return min(MAX_COOLDOWN, max(1, email.utils.parsedate_to_datetime(ra).timestamp() - now))
            except (TypeError, ValueError):
                pass
    reset = headers.get("anthropic-ratelimit-unified-reset")
    if reset:
        try:
            return min(MAX_COOLDOWN, max(1, float(reset) - now))
        except ValueError:
            pass
    return DEFAULT_COOLDOWN.get(status, DEFAULT_COOLDOWN["limit"])


def is_limit_response(status, body):
    if status in LIMIT_STATUSES:
        return True
    if status in (400, 402, 403) or status >= 500:
        text = body[:65536].decode("utf-8", "replace").lower()
        return any(p in text for p in LIMIT_PATTERNS)
    return False


class RouterState:
    """Cooldowns, fallback approval and the switch log. Thread-safe."""

    def __init__(self, directory):
        self.dir = directory
        os.makedirs(directory, exist_ok=True)
        self.lock = threading.Lock()
        self.cooldown_until = {}
        self.active = None
        self.last_switch = None

    def _path(self, name):
        return os.path.join(self.dir, name)

    def log(self, event, **fields):
        row = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "event": event, **fields}
        with self.lock, open(self._path("switch-log.jsonl"), "a") as f:
            f.write(json.dumps(row) + "\n")
        return row

    def cool(self, account_id, seconds, reason):
        with self.lock:
            self.cooldown_until[account_id] = time.time() + seconds
        self.log("cooldown", account=account_id, seconds=round(seconds), reason=reason)

    def healthy(self, account_id):
        return self.cooldown_until.get(account_id, 0) <= time.time()

    def mark_served(self, account_id):
        with self.lock:
            previous, self.active = self.active, account_id
        if previous != account_id:
            self.last_switch = self.log("switch", **{"from": previous, "to": account_id})

    def approved(self):
        try:
            with open(self._path("fallback-approved.json")) as f:
                return json.load(f).get("id")
        except (OSError, ValueError):
            return None

    def approve(self, account_id):
        with open(self._path("fallback-approved.json"), "w") as f:
            json.dump({"id": account_id, "at": time.time()}, f)
        self.clear_pending()
        self.log("fallback-approved", account=account_id)

    def revoke_approval(self):
        if os.path.exists(self._path("fallback-approved.json")):
            os.remove(self._path("fallback-approved.json"))
            self.log("fallback-approval-cleared")

    def set_pending(self, account_id, label):
        path = self._path("fallback-pending.json")
        if not os.path.exists(path):
            with open(path, "w") as f:
                json.dump({"id": account_id, "label": label, "since": time.time()}, f)
            self.log("fallback-pending", account=account_id)

    def pending(self):
        try:
            with open(self._path("fallback-pending.json")) as f:
                return json.load(f)
        except (OSError, ValueError):
            return None

    def clear_pending(self):
        if os.path.exists(self._path("fallback-pending.json")):
            os.remove(self._path("fallback-pending.json"))

    def status(self, accounts):
        now = time.time()
        return {
            "active": self.active,
            "lastSwitch": self.last_switch,
            "pendingApproval": self.pending(),
            "approvedFallback": self.approved(),
            "accounts": [{
                "id": a["id"], "label": a.get("label", a["id"]), "tier": a.get("tier", "claude"),
                "needsApproval": bool(a.get("needsApproval")),
                "cooldownUntil": self.cooldown_until.get(a["id"]) if not self.healthy(a["id"]) else None,
                "cooldownSecondsLeft": max(0, round(self.cooldown_until.get(a["id"], 0) - now)),
            } for a in accounts],
        }


def anthropic_error(message, kind="rate_limit_error"):
    return json.dumps({"type": "error", "error": {"type": kind, "message": message}}).encode()


class RouterHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "claude-router"

    def log_message(self, fmt, *args):  # quiet; the switch log is the record
        pass

    # --- local endpoints -------------------------------------------------
    def do_GET(self):
        if self.path.split("?")[0] == "/status":
            return self._json(200, self.server.state.status(self._accounts_or_empty()))
        return self._proxy()

    def do_POST(self):
        if self.path == "/approve":
            body = self._read_body()
            account_id = (json.loads(body or b"{}") or {}).get("id")
            ids = [a["id"] for a in self._accounts_or_empty() if a.get("needsApproval")]
            if account_id not in ids:
                return self._json(400, {"error": f"unknown fallback account; one of {ids}"})
            self.server.state.approve(account_id)
            return self._json(200, {"approved": account_id})
        if self.path == "/approve/clear":
            self._read_body()
            self.server.state.revoke_approval()
            self.server.state.clear_pending()
            return self._json(200, {"cleared": True})
        return self._proxy()

    do_PUT = do_DELETE = do_PATCH = do_POST

    # --- helpers ---------------------------------------------------------
    def _accounts_or_empty(self):
        try:
            return load_accounts(self.server.accounts_file)
        except (OSError, ValueError):
            return []

    def _read_body(self):
        length = int(self.headers.get("content-length") or 0)
        return self.rfile.read(length) if length else b""

    def _json(self, status, obj):
        self._send(status, json.dumps(obj, indent=1).encode(), "application/json")

    def _send(self, status, body, ctype="application/json", extra=None):
        self.send_response(status)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    # --- the proxy -------------------------------------------------------
    def _proxy(self):
        state = self.server.state
        body = self._read_body()
        try:
            accounts = load_accounts(self.server.accounts_file)
        except (OSError, ValueError) as exc:
            return self._send(500, anthropic_error(f"claude-router: accounts.json unreadable: {exc}", "api_error"))
        last_error = None
        for account in accounts:
            if not state.healthy(account["id"]):
                continue
            is_fallback = account.get("tier") == "fallback" or account.get("needsApproval")
            if account.get("needsApproval") and state.approved() != account["id"]:
                state.set_pending(account["id"], account.get("label", account["id"]))
                wait = min([state.cooldown_until.get(a["id"], 0) - time.time()
                            for a in accounts if not a.get("needsApproval")] or [60])
                msg = (f"claude-router: every Claude account is at its limit. Switching to "
                       f"'{account.get('label', account['id'])}' needs your approval "
                       f"(AgentBar, or: curl -X POST localhost:{self.server.server_port}/approve "
                       f"-d '{{\"id\":\"{account['id']}\"}}'). Next Claude account frees in ~{max(1, round(wait / 60))} min.")
                return self._send(429, anthropic_error(msg), extra={"retry-after": str(max(1, round(wait)))})
            outcome = self._try_account(account, body)
            if outcome == "served":
                if not is_fallback:
                    state.revoke_approval()
                    state.clear_pending()
                return
            last_error = outcome
        status, payload, headers = last_error or (529, anthropic_error(
            "claude-router: every account is cooling down; see GET /status", "overloaded_error"), {})
        self._send(status, payload, extra={k: v for k, v in headers.items() if k == "retry-after"})

    def _try_account(self, account, body):
        """'served' once bytes reached the client; else (status, body, headers)
        after cooling this account down."""
        state = self.server.state
        token = resolve_token(account)
        if not token:
            state.cool(account["id"], 300, "no token (Keychain/env lookup failed)")
            return (502, anthropic_error(f"claude-router: no token for {account['id']}", "api_error"), {})
        out_body = body
        if account.get("model") and body:
            try:
                req = json.loads(body)
                if isinstance(req, dict) and "model" in req:
                    req["model"] = account["model"]
                    out_body = json.dumps(req).encode()
            except ValueError:
                pass
        url = urlsplit(account["baseUrl"].rstrip("/"))
        path = (url.path or "") + self.path
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in HOP_BY_HOP and k.lower() not in CLIENT_AUTH_HEADERS}
        if account.get("authHeader") == "x-api-key":
            headers["x-api-key"] = token
        else:
            headers["authorization"] = f"Bearer {token}"
        headers["content-length"] = str(len(out_body))
        conn_cls = http.client.HTTPSConnection if url.scheme == "https" else http.client.HTTPConnection
        conn = conn_cls(url.hostname, url.port, timeout=float(account.get("timeoutSeconds", 600)))
        try:
            conn.request(self.command, path, body=out_body, headers=headers)
            resp = conn.getresponse()
        except (OSError, http.client.HTTPException) as exc:
            conn.close()
            state.cool(account["id"], DEFAULT_COOLDOWN["network"], f"network: {exc}")
            return (502, anthropic_error(f"claude-router: {account['id']} unreachable", "api_error"), {})
        resp_headers = {k.lower(): v for k, v in resp.getheaders()}
        if resp.status >= 400:
            err_body = resp.read()
            conn.close()
            if is_limit_response(resp.status, err_body):
                state.cool(account["id"], cooldown_seconds(resp.status, resp_headers),
                           f"HTTP {resp.status}")
                return (resp.status, err_body, resp_headers)
            # Ordinary client error (bad request, auth): pass through, no failover.
            state.mark_served(account["id"])
            self._send(resp.status, err_body, resp_headers.get("content-type", "application/json"))
            return "served"
        state.mark_served(account["id"])
        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() not in HOP_BY_HOP:
                self.send_header(k, v)
        self.send_header("transfer-encoding", "chunked")
        self.end_headers()
        try:
            while True:
                chunk = resp.read1(65536)
                if not chunk:
                    break
                self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
        except (OSError, http.client.HTTPException) as exc:
            # Mid-stream: can't splice another account in. Drop; next request reroutes.
            state.cool(account["id"], DEFAULT_COOLDOWN["network"], f"mid-stream: {exc}")
            self.close_connection = True
        finally:
            conn.close()
        return "served"


def make_server(port=None, host="127.0.0.1", accounts_file=None, state_directory=None):
    server = ThreadingHTTPServer((host, port if port is not None else DEFAULT_PORT), RouterHandler)
    server.daemon_threads = True
    server.accounts_file = accounts_file or accounts_path()
    server.state = RouterState(state_directory or state_dir())
    return server


def main():
    port = int(os.environ.get("CLAUDE_ROUTER_PORT", DEFAULT_PORT))
    server = make_server(port)
    server.state.log("start", port=port, accounts=server.accounts_file)
    print(f"claude-router on 127.0.0.1:{port} accounts={server.accounts_file}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
