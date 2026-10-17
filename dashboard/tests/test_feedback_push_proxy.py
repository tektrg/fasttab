#!/usr/bin/env python3
"""Phone Web Push registration proxy (server/lib/feedback_push_proxy.py).

SAFETY: no network — `feedback_admin_proxy.send_request` is replaced by a fake.
The secret file is a temp file holding a SENTINEL; the real secret is never read.
"""
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DASHBOARD_ROOT = os.path.dirname(HERE)
_tmp = tempfile.mkdtemp(prefix="feedback-push-proxy-test-")
SECRET_FILE = os.path.join(_tmp, "secret")
os.environ["THEINDIE_FEEDBACK_ADMIN_SECRET_FILE"] = SECRET_FILE
os.environ["THEINDIE_API_BASE"] = "https://api.example.test"
sys.path.insert(0, os.path.join(DASHBOARD_ROOT, "server", "lib"))
import feedback_admin_proxy as transport  # noqa: E402
import feedback_push_proxy as push  # noqa: E402

fails = []
SENTINEL = "SENTINEL-not-a-real-secret"
ENDPOINT = "https://web.push.apple.com/abc"
KEYS = {"p256dh": "BPk", "auth": "au"}
calls = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def fake(status=200, payload=None):
    def send(request):
        calls.append(request)
        return status, json.dumps(payload if payload is not None else {}).encode()
    transport.send_request = send


with open(SECRET_FILE, "w") as f:
    f.write(SENTINEL)

print("config")
fake(payload={"configured": True, "publicKey": "BKEY"})
payload, status = push.handle_get("/api/feedback/push/config")
check("config ok", (status, payload), (200, {"ok": True, "configured": True, "publicKey": "BKEY"}))
check("config upstream", (calls[-1].get_method(), calls[-1].full_url), ("GET", "https://api.example.test/v1/admin/feedback/push/config"))
check("bearer upstream", calls[-1].get_header("Authorization"), "Bearer " + SENTINEL)
check("unrelated GET -> None", push.handle_get("/api/feedback/threads"), None)

print("subscribe")
fake(status=201, payload={"ok": True})
payload, status = push.handle_post("/api/feedback/push/subscribe", lambda: {"endpoint": ENDPOINT, "keys": KEYS, "label": " iPhone ", "extra": "dropped"})
check("subscribe ok", (status, payload), (200, {"ok": True}))
check("subscribe upstream", (calls[-1].get_method(), calls[-1].full_url), ("POST", "https://api.example.test/v1/admin/feedback/push/subscriptions"))
check("subscribe body (only known fields)", json.loads(calls[-1].data), {"endpoint": ENDPOINT, "keys": KEYS, "label": "iPhone"})
check("secret never in reply", SENTINEL in json.dumps(payload), False)

print("validation (no upstream call)")
n = len(calls)
for label, body in (
    ("http endpoint", {"endpoint": "http://x", "keys": KEYS}),
    ("missing keys", {"endpoint": ENDPOINT}),
    ("keys not object", {"endpoint": ENDPOINT, "keys": "x"}),
    ("missing auth", {"endpoint": ENDPOINT, "keys": {"p256dh": "x"}}),
    ("huge endpoint", {"endpoint": ENDPOINT + "x" * 2000, "keys": KEYS}),
    ("non-object body", []),
):
    check(label, push.handle_post("/api/feedback/push/subscribe", lambda b=body: b)[1], 400)
check("bad json", push.handle_post("/api/feedback/push/subscribe", lambda: (_ for _ in ()).throw(ValueError("x")))[1], 400)
check("no upstream call on invalid input", len(calls), n)
check("unknown push path -> None", push.handle_post("/api/feedback/push/other", lambda: {}), None)

print("hostile label passed as data, not run")
fake(status=201, payload={"ok": True})
push.handle_post("/api/feedback/push/subscribe", lambda: {"endpoint": ENDPOINT, "keys": KEYS, "label": "$(echo INJECTED)"})
check("label sent verbatim", json.loads(calls[-1].data)["label"], "$(echo INJECTED)")

print("unsubscribe + test")
fake(payload={"ok": True, "removed": True})
payload, status = push.handle_post("/api/feedback/push/unsubscribe", lambda: {"endpoint": ENDPOINT})
check("unsubscribe", (status, payload, calls[-1].get_method()), (200, {"ok": True, "removed": True}, "DELETE"))
fake(payload={"sent": 1, "removed": 1, "failed": 0, "waiting": 3})
payload, status = push.handle_post("/api/feedback/push/test", lambda: {})
check("test push", (status, payload), (200, {"ok": True, "sent": 1, "removed": 1, "failed": 0, "waiting": 3}))
check("test upstream", calls[-1].full_url, "https://api.example.test/v1/admin/feedback/push/test")

print("upstream not configured")
transport.send_request = lambda request: (503, b'{"error":{"code":"web_push_unavailable","message":"Owner Web Push is not configured (WEB_PUSH_VAPID_* secrets)"}}')
payload, status = push.handle_post("/api/feedback/push/test", lambda: {})
check("503 -> 502 with upstream message", (status, "WEB_PUSH_VAPID" in payload["error"]), (502, True))

if fails:
    print("\n".join(fails))
    sys.exit(1)
print("all PASS")
