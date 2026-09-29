#!/usr/bin/env python3
"""A tiny job relay between the dashboard and an OpenCode plugin.

Why: an OpenCode TUI started without `--port` has NO listening HTTP server
(measured live on 1.18.30: `lsof` shows no LISTEN socket; the plugin's
`serverUrl` is the placeholder http://localhost:4096 and its `client` talks to
the server in-process). So the dashboard cannot POST a permission / question
reply itself. Instead our plugin, while a prompt of its session is pending,
long-polls here for "requests to perform", runs each one against its own
OpenCode (real server if it has one, else the in-process client) and posts the
result back. The dashboard builds and validates every request
(opencode_answer.py); the plugin only allowlists and executes.

  GET  /api/hook/tui-job/wait?pid=<pid>&timeout=N   plugin -> {job: {id, method, path, body}} | {}
  POST /api/hook/tui-job/<id>/result                 plugin -> {status, body}
Local listener only (a remote request gets 404).
"""
import itertools
import re
import secrets
import threading
import time

PREFIX = "/api/hook/tui-job"
#: The plugin sends this header on every poll. A web page cannot add a custom
#: header without a CORS preflight (which this server never answers), so a
#: page cannot drain or read the queue by blind requests.
RELAY_HEADER = "X-AgentBar-Relay"
WAIT_MAX_SEC = 25
#: How long the dashboard waits for the plugin to run one request.
RESULT_TIMEOUT_SEC = 8
#: A job nobody picked up in this long is dropped.
UNCLAIMED_TTL_SEC = 15
PATH_RE = re.compile(r"^/[A-Za-z0-9_/.?=%&-]{1,400}$")


class JobNotPickedUp(TimeoutError):
    """No plugin took the job: it provably ran nowhere (a plain TimeoutError
    means a plugin DID take it and never reported back — outcome unknown)."""


class JobQueue:
    def __init__(self, clock=time.monotonic):
        self._clock = clock
        self._cond = threading.Condition()
        self._queued = {}   # pid -> [job]
        self._waiting = {}  # job id -> {"event", "result"}
        self._seq = itertools.count(1)

    def submit(self, pid, method, path, body=None, timeout=RESULT_TIMEOUT_SEC):
        """Run one request in the plugin of `pid`: (status, parsed body).
        Raises TimeoutError when no plugin picks it up / answers in time."""
        if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 1:
            raise ValueError("bad pid")
        if method not in ("GET", "POST") or not PATH_RE.match(path or ""):
            raise ValueError("bad job")
        job_id = f"j{next(self._seq)}-{secrets.token_hex(8)}"  # unguessable: a result post must know it
        slot = {"event": threading.Event(), "result": None, "claimed": False}
        with self._cond:
            self._queued.setdefault(pid, []).append(
                {"id": job_id, "method": method, "path": path, "body": body,
                 "queuedAt": self._clock()})
            self._waiting[job_id] = slot
            self._cond.notify_all()
        try:
            if not slot["event"].wait(timeout):
                # Decide under the lock: `wait()` claims a job under it too, so
                # "not claimed" here can no longer turn into "claimed" after we
                # promised the caller that nothing ran.
                with self._cond:
                    claimed = slot["claimed"]
                    if not claimed:
                        self._queued[pid] = [j for j in self._queued.get(pid, []) if j["id"] != job_id]
                if not claimed:
                    raise JobNotPickedUp("the OpenCode plugin did not pick the request up")
                raise TimeoutError("the OpenCode plugin did not answer in time")
            return slot["result"]
        finally:
            with self._cond:
                self._waiting.pop(job_id, None)
                self._queued[pid] = [j for j in self._queued.get(pid, []) if j["id"] != job_id]

    def wait(self, pid, timeout_sec):
        """The next job for `pid` (blocks up to timeout_sec), or None."""
        deadline = self._clock() + max(0.0, min(float(timeout_sec), WAIT_MAX_SEC))
        with self._cond:
            while True:
                now = self._clock()
                jobs = [j for j in self._queued.get(pid, []) if now - j["queuedAt"] < UNCLAIMED_TTL_SEC]
                if jobs:
                    job = jobs[0]
                    self._queued[pid] = jobs[1:]
                    if job["id"] in self._waiting:
                        self._waiting[job["id"]]["claimed"] = True
                    return {k: job[k] for k in ("id", "method", "path", "body")}
                if now >= deadline:
                    return None
                self._cond.wait(min(1.0, deadline - now))

    def result(self, job_id, status, body):
        """The plugin's outcome for a job. False when nobody waits for it."""
        with self._cond:
            slot = self._waiting.get(job_id)
            if not slot or slot["result"] is not None:
                return False
            slot["result"] = (status, body)
            slot["event"].set()
            return True


QUEUE = JobQueue()


def handle_get(path, query, is_remote, queue=None):
    if not path.startswith(PREFIX + "/wait"):
        return None
    if is_remote:
        return {"error": "not found"}, 404
    try:
        pid = int((query.get("pid") or [""])[0])
        timeout = float((query.get("timeout") or [WAIT_MAX_SEC])[0])
    except (TypeError, ValueError):
        return {"error": "bad pid or timeout"}, 400
    job = (queue or QUEUE).wait(pid, timeout)
    return ({"job": job} if job else {}), 200


def handle_post(path, read_body, is_remote, queue=None):
    match = re.match(re.escape(PREFIX) + r"/(j\d+-[0-9a-f]{16})/result$", path)
    if not match:
        return None
    if is_remote:
        return {"error": "not found"}, 404
    try:
        body = read_body()
    except ValueError as e:
        return {"ok": False, "error": f"bad JSON body: {e}"}, 400
    status = body.get("status") if isinstance(body, dict) else None
    if not isinstance(status, int) or isinstance(status, bool):
        return {"ok": False, "error": "status must be an integer"}, 400
    accepted = (queue or QUEUE).result(match.group(1), status, body.get("body"))
    return {"ok": accepted}, 200
