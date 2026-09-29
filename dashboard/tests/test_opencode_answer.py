#!/usr/bin/env python3
"""Direct-run tests for opencode_answer.py against a FAKE OpenCode server.

Never a real OpenCode session. The fake serves the route shapes read from a
throwaway `opencode serve` 1.18.30 `GET /doc` (2026-09-29): v1 lists/replies
and v2 lists/replies. Hostile text uses the inert sentinel only.
"""
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DASHBOARD = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(DASHBOARD, "server", "lib"))

import opencode_answer as oa  # noqa: E402

SENTINEL = "$(echo INJECTED)"
fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


class FakeOpenCode(BaseHTTPRequestHandler):
    """State on the class: pending ids per family, every request seen."""
    v1_permission, v2_permission, v1_question, v2_question = [], [], [], []
    seen = []
    list_status = 200
    list_body_override = None
    post_status = 200

    def log_message(self, *a):
        pass

    def _reply(self, status, body):
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        path = self.path.split("?")[0]
        FakeOpenCode.seen.append(("GET", self.path, None))
        if FakeOpenCode.list_status != 200:
            return self._reply(FakeOpenCode.list_status, {"error": "x"})
        if FakeOpenCode.list_body_override is not None:
            return self._reply(200, FakeOpenCode.list_body_override)
        if path == "/permission":
            return self._reply(200, [{"id": i, "sessionID": "ses_1"} for i in FakeOpenCode.v1_permission])
        if path == "/question":
            return self._reply(200, [{"id": i, "sessionID": "ses_1"} for i in FakeOpenCode.v1_question])
        if path == "/api/session/ses_1/permission":
            return self._reply(200, {"data": [{"id": i, "sessionID": "ses_1"} for i in FakeOpenCode.v2_permission]})
        if path == "/api/session/ses_1/question":
            return self._reply(200, {"data": [{"id": i, "sessionID": "ses_1"} for i in FakeOpenCode.v2_question]})
        self._reply(404, {})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"null")
        FakeOpenCode.seen.append(("POST", self.path, body))
        self._reply(FakeOpenCode.post_status, True)


FakeOpenCode.post_status = 200
server = ThreadingHTTPServer(("127.0.0.1", 0), FakeOpenCode)
threading.Thread(target=server.serve_forever, daemon=True).start()
URL = f"http://127.0.0.1:{server.server_address[1]}"


def reset(**lists):
    FakeOpenCode.v1_permission, FakeOpenCode.v2_permission = [], []
    FakeOpenCode.v1_question, FakeOpenCode.v2_question = [], []
    FakeOpenCode.seen, FakeOpenCode.list_status = [], 200
    FakeOpenCode.list_body_override, FakeOpenCode.post_status = None, 200
    for name, ids in lists.items():
        setattr(FakeOpenCode, name, list(ids))


def posts():
    return [(path, body) for verb, path, body in FakeOpenCode.seen if verb == "POST"]


PERMISSION = {"id": "per_abc1", "kind": "permission", "permission": "bash",
              "patterns": ["ls *"], "always": ["ls *"], "detail": "ls -la"}
QUESTION = {"id": "que_abc1", "kind": "question", "questions": [
    {"question": "Which db?", "header": "DB", "multiple": False, "custom": True,
     "options": [{"label": "sqlite", "description": ""}, {"label": "pg", "description": ""}]}]}
MULTI = {"id": "que_multi", "kind": "question", "questions": [
    {"question": "Pick tools", "header": "", "multiple": True, "custom": False,
     "options": [{"label": "a", "description": ""}, {"label": "b", "description": ""}]}]}


def entry(request, url=URL, pid=4242):
    return {"tool": "opencode", "sessionId": "ses_1", "cwd": "/scratch/proj", "pid": pid,
            "serverUrl": url, "request": request}


def run(request, body, url=URL, pid_ok=True, **kw):
    return oa.answer(entry(request, url), body, pid_check=lambda pid: pid_ok)


print("permission: allow / always / deny (v1)")
reset(v1_permission=["per_abc1"])
res, status = run(PERMISSION, {"behavior": "allow"})
check("allow -> 200 answered", (status, res.get("ok")), (200, True))
check("allow posts reply once to the v1 route", posts(), [("/permission/per_abc1/reply", {"reply": "once"})])
check("directory query sent on the list", any("directory=%2Fscratch%2Fproj" in p for _, p, _ in FakeOpenCode.seen), True)
reset(v1_permission=["per_abc1"])
run(PERMISSION, {"behavior": "allow", "suggestionIndex": 0})
check("suggestion 0 -> always", posts()[0][1], {"reply": "always"})
reset(v1_permission=["per_abc1"])
run(PERMISSION, {"behavior": "deny", "message": f"no {SENTINEL}"})
check("deny -> reject with message as plain data", posts()[0][1], {"reply": "reject", "message": f"no {SENTINEL}"})
reset(v1_permission=["per_abc1"])
res, status = run(PERMISSION, {"behavior": "allow", "suggestionIndex": 3})
check("unoffered suggestion -> 400, nothing posted", (status, posts()), (400, []))
res, status = run({**PERMISSION, "always": []}, {"behavior": "allow", "suggestionIndex": 0})
check("no 'always' patterns -> suggestion refused", status, 400)
res, status = run(PERMISSION, {"behavior": "maybe"})
check("bad behavior -> 400", status, 400)

print("permission via the v2 family")
reset(v2_permission=["per_abc1"])
res, status = run(PERMISSION, {"behavior": "allow"})
check("v2-only id -> v2 reply route", (status, posts()), (200, [("/api/session/ses_1/permission/per_abc1/reply", {"reply": "once"})]))

print("questions")
reset(v1_question=["que_abc1"])
res, status = run(QUESTION, {"behavior": "allow", "answers": {"Which db?": "pg"}})
check("pick -> answers [[label]]", (status, posts()), (200, [("/question/que_abc1/reply", {"answers": [["pg"]]})]))
reset(v1_question=["que_abc1"])
run(QUESTION, {"behavior": "allow", "answers": {"Which db?": SENTINEL}})
check("free text kept literal (never run)", posts()[0][1], {"answers": [[SENTINEL]]})
reset(v1_question=["que_multi"])
run(MULTI, {"behavior": "allow", "answers": {"Pick tools": "a, b"}})
check("multi-select 'a, b' -> two labels", posts()[0][1], {"answers": [["a", "b"]]})
reset(v1_question=["que_multi"])
res, status = run(MULTI, {"behavior": "allow", "answers": {"Pick tools": "zzz"}})
check("custom text refused when the question takes only options", (status, posts()), (400, []))
reset(v1_question=["que_abc1"])
res, status = run(QUESTION, {"behavior": "allow", "answers": {"Other?": "x"}})
check("answers for other questions -> 400", (status, posts()), (400, []))
reset(v1_question=["que_abc1"])
run(QUESTION, {"behavior": "deny"})
check("deny a question -> reject route, no body", posts(), [("/question/que_abc1/reject", None)])
reset(v2_question=["que_abc1"])
run(QUESTION, {"behavior": "allow", "answers": {"Which db?": "sqlite"}})
check("v2 question reply route", posts()[0][0], "/api/session/ses_1/question/que_abc1/reply")

print("answered elsewhere / not pending")
reset()
res, status = run(PERMISSION, {"behavior": "allow"})
check("id not listed -> 409 'already answered', nothing posted", (status, posts(), "already answered" in res["error"]), (409, [], True))
res, status = oa.answer(entry(None), {"behavior": "allow"}, pid_check=lambda p: True)
check("no pending request on the entry -> 409", status, 409)
reset(v1_permission=["per_abc1"])
FakeOpenCode.post_status = 404
res, status = run(PERMISSION, {"behavior": "allow"})
check("POST 404 (raced) -> 409 answered", (status, "already answered" in res["error"]), (409, True))

print("loopback / pid / schema guards")
for bad in ("http://10.0.0.5:4096", "http://evil.example:80", "https://127.0.0.1:4096",
            "http://127.0.0.1@evil.example:80", "http://127.0.0.1:4096/x", "ftp://127.0.0.1:21", None, "", "http://127.0.0.1"):
    reset(v1_permission=["per_abc1"])
    res, status = run(PERMISSION, {"behavior": "allow"}, url=bad)
    check(f"non-loopback/odd url refused: {bad!r}", (status, posts(), FakeOpenCode.seen), (400, [], []))
reset(v1_permission=["per_abc1"])
res, status = run(PERMISSION, {"behavior": "allow"}, pid_ok=False)
check("pid dead / not ours -> 409, no request at all", (status, FakeOpenCode.seen), (409, []))
reset(v1_permission=["per_abc1"])
FakeOpenCode.list_body_override = {"unexpected": "shape"}
res, status = run(PERMISSION, {"behavior": "allow"})
check("unexpected list shape -> 502 refuse, nothing posted", (status, posts()), (502, []))
FakeOpenCode.list_body_override = [{"nope": 1}]
res, status = run(PERMISSION, {"behavior": "allow"})
check("list rows without ids -> refuse", (status, posts()), (502, []))
reset(v1_permission=["per_abc1"])
FakeOpenCode.list_status = 401
res, status = run(PERMISSION, {"behavior": "allow"})
check("401 -> 403 password message", (status, "password" in res["error"], posts()), (403, True, []))
reset(v1_permission=["per_abc1"])
FakeOpenCode.list_status = 404
res, status = run(PERMISSION, {"behavior": "allow"})
check("no list routes at all -> 502 cannot verify", (status, posts()), (502, []))
check("body must be an object", oa.answer(entry(PERMISSION), "allow", pid_check=lambda p: True)[1], 400)

print("one answer at a time per request")
reset(v1_permission=["per_abc1"])
with oa._claim("per_abc1"):
    res, status = run(PERMISSION, {"behavior": "allow"})
check("second answer while one is in flight -> 409, nothing posted", (status, posts()), (409, []))
res, status = run(PERMISSION, {"behavior": "allow"})
check("claim released afterwards", status, 200)

print("pid_owned_by_me")
check("this test process is ours", oa.pid_owned_by_me(os.getpid()), True)
check("pid 1 / bogus / bool are not", (oa.pid_owned_by_me(1), oa.pid_owned_by_me(-5), oa.pid_owned_by_me(True), oa.pid_owned_by_me(None)),
      (False, False, False, False))

server.shutdown()
if fails:
    print(f"\nFAIL: {len(fails)} failure(s)")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("\nPASS: all OpenCode answer checks")
