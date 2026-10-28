#!/usr/bin/env python3
"""claude-router (server/claude_router.py): failover before the first byte,
cooldown from retry-after, streaming passthrough, approval-gated fallback,
/status and the switch log.

SAFETY: never calls a real API. Every upstream is a fake HTTP server on a
random 127.0.0.1 port; tokens come from env vars set here (no Keychain).
"""
import http.client
import json
import os
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
DASHBOARD_ROOT = os.path.dirname(HERE)
_tmp = tempfile.mkdtemp(prefix="claude-router-test-")
os.environ["CHIEF_DASHBOARD_CONFIG_HOME"] = os.path.join(_tmp, "config")
os.environ["CHIEF_DASHBOARD_STATE_HOME"] = os.path.join(_tmp, "state")
os.environ["FAKE_TOKEN_A"] = "token-a"
os.environ["FAKE_TOKEN_B"] = "token-b"
os.environ["FAKE_TOKEN_D"] = "token-d"
sys.path.insert(0, os.path.join(DASHBOARD_ROOT, "server"))
import claude_router  # noqa: E402

fails = []


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else f"  {detail}"))
    if not cond:
        fails.append(name)


class FakeUpstream:
    """Replies with a scripted (status, headers, chunks) and records requests."""

    def __init__(self, status=200, headers=None, chunks=(b"data: hi\n\n",)):
        self.status, self.headers, self.chunks = status, headers or {}, chunks
        self.requests = []
        up = self

        class H(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a):
                pass

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("content-length") or 0))
                up.requests.append({"path": self.path, "headers": dict(self.headers), "body": body})
                self.send_response(up.status)
                for k, v in up.headers.items():
                    self.send_header(k, v)
                payload = b"".join(up.chunks)
                self.send_header("content-length", str(len(payload)))
                self.end_headers()
                for c in up.chunks:
                    self.wfile.write(c)
                    self.wfile.flush()

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"


def start_router(accounts):
    d = tempfile.mkdtemp(dir=_tmp)
    path = os.path.join(d, "accounts.json")
    with open(path, "w") as f:
        json.dump({"accounts": accounts}, f)
    claude_router._token_cache.clear()
    srv = claude_router.make_server(0, accounts_file=path, state_directory=os.path.join(d, "state"))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def call(srv, method="POST", path="/v1/messages", body=None, headers=None):
    conn = http.client.HTTPConnection("127.0.0.1", srv.server_port, timeout=10)
    data = json.dumps(body if body is not None else {"model": "claude-x", "stream": True}).encode()
    conn.request(method, path, body=data if method == "POST" else None,
                 headers={"content-type": "application/json", **(headers or {})})
    r = conn.getresponse()
    out = (r.status, dict((k.lower(), v) for k, v in r.getheaders()), r.read())
    conn.close()
    return out


def acct(id_, url, env, **kw):
    return {"id": id_, "kind": "proxy", "tier": "claude", "baseUrl": url, "tokenEnv": env, **kw}


# 1. Forced 429 on account A -> served by B; A cooled for retry-after seconds.
a = FakeUpstream(429, {"retry-after": "120", "content-type": "application/json"},
                 (b'{"type":"error","error":{"type":"rate_limit_error"}}',))
b = FakeUpstream(200, {"content-type": "text/event-stream"}, (b"event: a\n\n", b"event: b\n\n"))
srv = start_router([acct("A", a.url, "FAKE_TOKEN_A"), acct("B", b.url, "FAKE_TOKEN_B")])
status, hdrs, body = call(srv, headers={"authorization": "Bearer client-secret"})
check("429 fails over to next account", status == 200 and body == b"event: a\n\nevent: b\n\n", (status, body))
check("both accounts were tried", len(a.requests) == 1 and len(b.requests) == 1)
check("account token replaces client auth",
      b.requests[0]["headers"].get("authorization") == "Bearer token-b"
      and "client-secret" not in json.dumps(b.requests[0]["headers"]))
st = json.loads(call(srv, "GET", "/status")[2])
a_row = next(x for x in st["accounts"] if x["id"] == "A")
check("status shows active + cooldown from retry-after",
      st["active"] == "B" and 100 <= a_row["cooldownSecondsLeft"] <= 120, st)
call(srv)
check("cooled account is skipped on next request", len(a.requests) == 1 and len(b.requests) == 2)
log = open(os.path.join(srv.state.dir, "switch-log.jsonl")).read()
check("switch log records cooldown and switch", '"cooldown"' in log and '"switch"' in log, log)

# 2. 529 and usage-limit body (403) also fail over; plain 400 does not.
for st_code, body_text, name in ((529, b'{"error":"overloaded"}', "529"),
                                 (403, b'{"error":"You have reached your usage limit"}', "usage-limit 403")):
    x = FakeUpstream(st_code, {}, (body_text,))
    y = FakeUpstream(200, {}, (b"ok",))
    s = start_router([acct("X", x.url, "FAKE_TOKEN_A"), acct("Y", y.url, "FAKE_TOKEN_B")])
    check(f"{name} fails over", call(s)[0] == 200 and len(y.requests) == 1)
x = FakeUpstream(500, {}, (b'{"error":"All credentials for model claude-x are cooling down"}',))
y = FakeUpstream(200, {}, (b"ok",))
s = start_router([acct("pool", x.url, "FAKE_TOKEN_A"), acct("Y", y.url, "FAKE_TOKEN_B")])
check("exhausted CLIProxyAPI pool fails over", call(s)[0] == 200 and len(y.requests) == 1)
x = FakeUpstream(400, {}, (b'{"error":"bad request"}',))
y = FakeUpstream(200, {}, (b"ok",))
s = start_router([acct("X", x.url, "FAKE_TOKEN_A"), acct("Y", y.url, "FAKE_TOKEN_B")])
check("plain 400 passes through without failover", call(s)[0] == 400 and len(y.requests) == 0)

# 3. Unreachable upstream fails over.
y = FakeUpstream(200, {}, (b"ok",))
s = start_router([acct("dead", "http://127.0.0.1:9", "FAKE_TOKEN_A"), acct("Y", y.url, "FAKE_TOKEN_B")])
check("connection refused fails over", call(s)[0] == 200)

# 4. Fallback tier is approval-gated, then model-mapped once approved.
a = FakeUpstream(429, {"retry-after": "600"}, (b"limit",))
d = FakeUpstream(200, {}, (b"deepseek",))
fb = acct("ds", d.url, "FAKE_TOKEN_D", tier="fallback", needsApproval=True,
          model="deepseek-v4.1-flash", kind="apikey")
s = start_router([acct("A", a.url, "FAKE_TOKEN_A"), fb])
status, hdrs, body = call(s)
check("fallback not used without approval", status == 429 and len(d.requests) == 0, (status, body))
check("clear approval message", b"needs your approval" in body and b"/approve" in body, body)
check("pending flag written", (s.state.pending() or {}).get("id") == "ds")
check("approve rejects unknown id", call(s, path="/approve", body={"id": "nope"})[0] == 400)
check("approve accepts fallback id", call(s, path="/approve", body={"id": "ds"})[0] == 200)
status, _, body = call(s)
check("approved fallback serves", status == 200 and body == b"deepseek")
check("model mapped for fallback", json.loads(d.requests[0]["body"])["model"] == "deepseek-v4.1-flash")
check("pending cleared after approval", s.state.pending() is None)

# 5. All cooling down -> last upstream error surfaces.
a = FakeUpstream(429, {"retry-after": "30"}, (b'{"e":1}',))
s = start_router([acct("A", a.url, "FAKE_TOKEN_A")])
check("single account 429 surfaces to client", call(s)[0] == 429)
check("then 529 'every account cooling'", call(s)[0] == 529)

# 6. Missing token -> account skipped, never sent unauthenticated.
y = FakeUpstream(200, {}, (b"ok",))
s = start_router([acct("notoken", "http://127.0.0.1:9", "NO_SUCH_ENV"), acct("Y", y.url, "FAKE_TOKEN_B")])
check("missing token skips account", call(s)[0] == 200)

# 6b. Remote listener: key required, approval endpoints localhost-only.
y = FakeUpstream(200, {}, (b"ok",))
d = tempfile.mkdtemp(dir=_tmp)
apath = os.path.join(d, "accounts.json")
with open(apath, "w") as f:
    json.dump({"accounts": [acct("Y", y.url, "FAKE_TOKEN_B")]}, f)
rs = claude_router.make_server(0, accounts_file=apath, state_directory=os.path.join(d, "st"),
                               remote_secret="s3cret")
threading.Thread(target=rs.serve_forever, daemon=True).start()
check("remote: no key -> 401", call(rs)[0] == 401)
check("remote: wrong key -> 401", call(rs, headers={"authorization": "Bearer nope"})[0] == 401)
check("remote: key works", call(rs, headers={"authorization": "Bearer s3cret"})[0] == 200)
check("remote: key never forwarded upstream",
      "s3cret" not in json.dumps(y.requests[-1]["headers"]))
check("remote: x-api-key works", call(rs, headers={"x-api-key": "s3cret"})[0] == 200)
check("remote: status needs key", call(rs, "GET", "/status")[0] == 401
      and call(rs, "GET", "/status", headers={"x-api-key": "s3cret"})[0] == 200)
check("remote: approve refused even with key",
      call(rs, path="/approve", body={"id": "x"}, headers={"x-api-key": "s3cret"})[0] == 403)

# 7. cooldown_seconds parsing.
now = time.time()
check("reset header epoch", 290 <= claude_router.cooldown_seconds(
    429, {"anthropic-ratelimit-unified-reset": str(now + 300)}, now) <= 300)
check("garbage retry-after -> default", claude_router.cooldown_seconds(429, {"retry-after": "soon"}) == 300)

print(f"\n{'FAILED ' + str(len(fails)) if fails else 'ALL PASS'}")
sys.exit(1 if fails else 0)
