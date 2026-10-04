#!/usr/bin/env python3
"""Feedback tab proxy (server/lib/feedback_admin_proxy.py).

SAFETY: no network — `send_request` is replaced by a fake. The secret file is
a temp file holding a SENTINEL; the real `~/.theindie-feedback-admin-secret`
is never read (the path env override is set before the module loads).
"""
import io
import json
import os
import sys
import tempfile
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
DASHBOARD_ROOT = os.path.dirname(HERE)
_tmp = tempfile.mkdtemp(prefix="feedback-proxy-test-")
SECRET_FILE = os.path.join(_tmp, "secret")
os.environ["THEINDIE_FEEDBACK_ADMIN_SECRET_FILE"] = SECRET_FILE
os.environ["THEINDIE_API_BASE"] = "https://api.example.test"
sys.path.insert(0, os.path.join(DASHBOARD_ROOT, "server", "lib"))
import feedback_admin_proxy as proxy  # noqa: E402

fails = []
SENTINEL = "SENTINEL-not-a-real-secret"
TID = "0f8fad5b-d9cb-469f-a165-70867728950e"


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


calls = []


def fake(status=200, payload=None, raise_exc=None):
    def send(request):
        calls.append(request)
        if raise_exc:
            raise raise_exc
        return status, json.dumps(payload if payload is not None else {}).encode()
    proxy.send_request = send


def write_secret(value=SENTINEL):
    with open(SECRET_FILE, "w") as f:
        f.write(value + "\n")


print("secret missing")
fake(payload={"threads": []})
payload, status = proxy.handle_get("/api/feedback/threads", {})
check("missing secret -> 503", status, 503)
check("missing secret message names the file", "~/.theindie-feedback-admin-secret" in payload["error"], True)
check("no upstream call without secret", len(calls), 0)

write_secret()
print("list")
fake(payload={"threads": [{"threadID": TID, "app": "parklet", "status": "open", "priority": "p1"}]})
payload, status = proxy.handle_get("/api/feedback/threads", {"scope": ["all"], "limit": ["1"]})
req = calls[-1]
check("list ok", (status, payload["ok"]), (200, True))
check("upstream url", req.full_url, "https://api.example.test/v1/admin/feedback/threads?scope=all&limit=1")
check("bearer sent upstream", req.get_header("Authorization"), "Bearer " + SENTINEL)
check("extra (owner) fields pass through", payload["threads"][0]["priority"], "p1")
check("hasMore when page full", payload["hasMore"], True)
check("secret never in reply", SENTINEL in json.dumps(payload), False)
check("default scope all + limit 100", proxy.handle_get("/api/feedback/threads", {}) and calls[-1].full_url.endswith("scope=all&limit=100"), True)

print("validation")
n = len(calls)
for label, query in (("bad scope", {"scope": ["x"]}), ("limit 0", {"limit": ["0"]}), ("limit 201", {"limit": ["201"]}), ("limit text", {"limit": ["1;x"]})):
    check(label, proxy.handle_get("/api/feedback/threads", query)[1], 400)
check("nested path is not a feedback route", proxy.handle_get("/api/feedback/threads/../x", {}), None)
check("bad thread id (not uuid)", proxy.handle_get("/api/feedback/threads/abc", {})[1], 400)
check("no upstream call on invalid input", len(calls), n)
check("unrelated path -> None", proxy.handle_get("/api/state", {}), None)

print("thread")
fake(payload={"thread": {"threadID": TID}, "messages": [{"author": "user", "body": "hi"}]})
payload, status = proxy.handle_get(f"/api/feedback/threads/{TID}", {})
check("thread ok", (status, len(payload["messages"])), (200, 1))
check("thread upstream path", calls[-1].full_url, f"https://api.example.test/v1/admin/feedback/threads/{TID}")

print("resolve")
fake(payload={"messageID": None})
payload, status = proxy.handle_post(f"/api/feedback/threads/{TID}/resolve", lambda: {"shippedInVersion": " 1.2 "})
check("resolve ok", (status, payload["ok"]), (200, True))
check("resolve method + body", (calls[-1].get_method(), json.loads(calls[-1].data)), ("POST", {"shippedInVersion": "1.2"}))
check("resolve unknown field", proxy.handle_post(f"/api/feedback/threads/{TID}/resolve", lambda: {"status": "x"})[1], 400)
check("resolve non-object", proxy.handle_post(f"/api/feedback/threads/{TID}/resolve", lambda: [])[1], 400)
check("resolve long message", proxy.handle_post(f"/api/feedback/threads/{TID}/resolve", lambda: {"message": "x" * 5000})[1], 400)
check("resolve bad json", proxy.handle_post(f"/api/feedback/threads/{TID}/resolve", lambda: (_ for _ in ()).throw(ValueError("x")))[1], 400)
check("post unrelated -> None", proxy.handle_post("/api/links", lambda: {}), None)

print("upstream errors")
err = urllib.error.HTTPError("u", 404, "nf", {}, io.BytesIO(b'{"error":{"code":"thread_not_found","message":"No such feedback thread"}}'))
fake(raise_exc=err)
payload, status = proxy.handle_get(f"/api/feedback/threads/{TID}", {})
check("upstream 404 passes message", (status, payload["error"]), (404, "No such feedback thread"))
fake(raise_exc=urllib.error.HTTPError("u", 401, "no", {}, io.BytesIO(b"{}")))
check("upstream 401 -> clear message", proxy.handle_get("/api/feedback/threads", {})[0]["error"], "theindie-api refused the admin secret")
fake(raise_exc=urllib.error.URLError(TimeoutError("timed out")))
payload, status = proxy.handle_get("/api/feedback/threads", {})
check("timeout -> 502", status, 502)
check("timeout message", payload["error"], "theindie-api unreachable: TimeoutError")
fake(status=200, payload=None)
proxy.send_request = lambda request: (200, b"<html>")
check("non-JSON -> 502", proxy.handle_get("/api/feedback/threads", {})[1], 502)
proxy.send_request = lambda request: (500, b'{"error":{"message":"boom"}}')
check("upstream 500 -> 502", proxy.handle_get("/api/feedback/threads", {})[1], 502)
proxy.send_request = lambda request: (200, b'{"nope":1}')
check("missing threads list -> 502", proxy.handle_get("/api/feedback/threads", {})[1], 502)

if fails:
    print("\n".join(fails))
    sys.exit(1)
print("all PASS")
