#!/usr/bin/env python3
"""Direct-run tests for the OpenCode plugin relay: tui_jobs.py (queue + routes),
opencode_answer's relay path, and the REAL plugin file run under node against a
fake dashboard + fake in-process client. Never a real OpenCode session.
Hostile text uses the inert sentinel only."""
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

DASHBOARD = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(DASHBOARD, "server", "lib"))
HARNESS = os.path.join(DASHBOARD, "tests", "opencode_plugin_harness.mjs")

import opencode_answer as oa  # noqa: E402
import tui_jobs  # noqa: E402

SENTINEL = "$(echo INJECTED)"
fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


print("queue")
queue = tui_jobs.JobQueue()
out = {}
worker = threading.Thread(target=lambda: out.update(r=queue.submit(4242, "POST", "/question/que_1/reject", None, timeout=5)))
worker.start()
job = queue.wait(4242, 3)
check("plugin of that pid gets the job", (job["method"], job["path"], job["body"]), ("POST", "/question/que_1/reject", None))
check("another pid gets nothing", queue.wait(999, 0.2), None)
check("result reaches the submitter", queue.result(job["id"], 200, True), True)
worker.join(3)
check("submit returns the plugin's (status, body)", out.get("r"), (200, True))
check("second result for the same job refused", queue.result(job["id"], 200, True), False)
for bad in (("x", "GET", "/a"), (4242, "DELETE", "/permission"), (4242, "GET", "http://evil.example/x"),
            (4242, "GET", f"/x {SENTINEL}"), (True, "GET", "/permission")):
    try:
        queue.submit(*bad)
        check(f"bad job refused: {bad!r}", "accepted", "ValueError")
    except ValueError:
        check(f"bad job refused: {bad[1:]!r}", True, True)
try:
    queue.submit(4242, "GET", "/permission", timeout=0.3)
    check("no plugin -> TimeoutError", "returned", "TimeoutError")
except TimeoutError:
    check("no plugin -> TimeoutError", True, True)
check("timed-out job is not left for a late plugin", queue.wait(4242, 0.1), None)

print("routes: local only")
check("remote wait -> 404", tui_jobs.handle_get("/api/hook/tui-job/wait", {"pid": ["1"]}, True)[1], 404)
check("bad pid -> 400", tui_jobs.handle_get("/api/hook/tui-job/wait", {"pid": ["x"]}, False)[1], 400)
check("remote result -> 404", tui_jobs.handle_post("/api/hook/tui-job/j1/result", lambda: {}, True)[1], 404)
check("non-int status -> 400", tui_jobs.handle_post("/api/hook/tui-job/j1/result", lambda: {"status": "200"}, False)[1], 400)
check("unrelated path not claimed", tui_jobs.handle_get("/api/other", {}, False), None)

print("opencode_answer through the relay (fake plugin thread)")
FAKE_SERVER = {"permission": ["per_abc1"], "posts": []}


def fake_plugin(stop):
    while not stop.is_set():
        job = tui_jobs.QUEUE.wait(4242, 0.3)
        if not job:
            continue
        if job["method"] == "GET":
            rows = [{"id": i, "sessionID": "ses_1"} for i in FAKE_SERVER["permission"]] if job["path"].startswith("/permission") else []
            tui_jobs.QUEUE.result(job["id"], 200, rows)
        else:
            FAKE_SERVER["posts"].append((job["path"], job["body"]))
            tui_jobs.QUEUE.result(job["id"], 200, True)


stop = threading.Event()
threading.Thread(target=fake_plugin, args=(stop,), daemon=True).start()
entry = {"tool": "opencode", "sessionId": "ses_1", "cwd": "/scratch/proj", "pid": 4242, "relay": True, "serverUrl": "http://localhost:4096",
         "request": {"id": "per_abc1", "kind": "permission", "permission": "bash", "patterns": ["ls"], "always": [], "detail": SENTINEL}}
res, status = oa.answer(entry, {"behavior": "deny", "message": SENTINEL}, pid_check=lambda p: True)
check("deny answered via relay", (status, res.get("ok")), (200, True))
check("reply body carries sentinel as plain data", FAKE_SERVER["posts"], [("/permission/per_abc1/reply", {"reply": "reject", "message": SENTINEL})])
FAKE_SERVER["permission"], FAKE_SERVER["posts"] = [], []
res, status = oa.answer(entry, {"behavior": "allow"}, pid_check=lambda p: True)
check("id no longer pending -> 409 answered elsewhere, no reply posted", (status, FAKE_SERVER["posts"]), (409, []))
stop.set()

print("the real plugin under node")
node = shutil.which("node")
if not node:
    print("  SKIP  node not installed")
else:
    seen = {"results": [], "pids": []}

    class Dash(BaseHTTPRequestHandler):
        jobs = []

        def log_message(self, *a):
            pass

        def _send(self, payload):
            raw = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def do_GET(self):
            parsed = urlparse(self.path)
            if parsed.path.endswith("/wait"):
                seen["pids"].append(parse_qs(parsed.query).get("pid"))
                for _ in range(20):
                    if Dash.jobs:
                        return self._send({"job": Dash.jobs.pop(0)})
                    time.sleep(0.1)
                return self._send({})
            self._send({})

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length) or b"{}")
            if "/result" in self.path:
                seen["results"].append(body)
            self._send({"ok": True})

    dash = ThreadingHTTPServer(("127.0.0.1", 0), Dash)
    threading.Thread(target=dash.serve_forever, daemon=True).start()
    Dash.jobs = [
        {"id": "j1", "method": "POST", "path": "/permission/per_seen/reply", "body": {"reply": "reject"}},
        {"id": "j2", "method": "POST", "path": "/permission/per_other/reply", "body": {"reply": "once"}},
        {"id": "j3", "method": "GET", "path": "/config/providers", "body": None},
        {"id": "j4", "method": "POST", "path": f"/permission/per_seen/reply?x={SENTINEL}", "body": None},
    ]
    proc = subprocess.run([node, HARNESS], capture_output=True, text=True, timeout=60,
                          env=dict(os.environ, AGENTBAR_DASHBOARD_URL=f"http://127.0.0.1:{dash.server_address[1]}"))
    dash.shutdown()
    try:
        calls = json.loads(proc.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        calls = None
        print(proc.stdout, proc.stderr)
    check("only the pending id's allowlisted reply reached the client", calls, [
        {"method": "post", "url": "/permission/per_seen/reply", "body": {"reply": "reject"}}])
    check("job results reported (200 for the run, 400 for the refused three)", sorted(r["status"] for r in seen["results"]), [200, 400, 400, 400])
    check("polled with its own pid", bool(seen["pids"]) and seen["pids"][0][0].isdigit(), True)

if fails:
    print(f"\nFAIL: {len(fails)} failure(s)")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("\nPASS: all relay checks")
