#!/usr/bin/env python3
"""Codex PermissionRequest hook: lets AgentBar / the web UI approve or deny a
Codex command approval.

Registers the prompt with the dashboard, long-polls for the answer, prints the
decision Codex reads (`hookSpecificOutput.decision` = {behavior, message?}).
Only prints a complete decision; any other outcome exits 0 with NOTHING on
stdout, which means "no decision" and Codex then draws its own prompt.

FAILS OPEN, ALWAYS: dashboard down, AgentBar not connected (the dashboard
answers `ignored`), a bad reply, an exception -> silent exit 0 within ~1.5s.

HOLD LIMIT: Codex draws NO prompt of its own while this hook runs (measured on
codex 0.154: the TUI just says "Running hook"), so a held prompt cannot be
answered in the terminal. After AGENTBAR_CODEX_HOLD_SEC (default 300) the hook
gives up and Codex shows its normal prompt. Set it to 0 to never hold.

Registered by dashboard/integrations/install.py (PermissionRequest, alongside
the status hook, which stays the one that reports state).
Env: AGENTBAR_DASHBOARD_URL (default http://127.0.0.1:4711).
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

DASHBOARD_URL = os.environ.get("AGENTBAR_DASHBOARD_URL", "http://127.0.0.1:4711").rstrip("/")
PERMISSION_PATH = "/api/hook/permission"
REGISTER_TIMEOUT_SEC = 1.5
WAIT_POLL_SEC = 25
UNREACHABLE_GIVE_UP_SEC = 30
RETRY_PAUSE_SEC = 2
MAX_STDIN_BYTES = 1024 * 1024
SHELL_NAMES = {"sh", "bash", "zsh", "dash", "fish"}
#: No proxies: urllib honours HTTP_PROXY even for 127.0.0.1.
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def hold_limit_sec():
    try:
        return max(0.0, float(os.environ.get("AGENTBAR_CODEX_HOLD_SEC", "300")))
    except ValueError:
        return 300.0


def _http_json(method, url, body=None, timeout=REGISTER_TIMEOUT_SEC):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request(url, data=data, method=method,
                                     headers={"Content-Type": "application/json"})
    with _OPENER.open(request, timeout=timeout) as response:
        return json.loads(response.read() or b"{}")


def find_codex_pid():
    """Our parent, or its parent when a shell sits between (ps, 2 hops max)."""
    pid = os.getppid()
    try:
        for _ in range(2):
            out = subprocess.run(["ps", "-o", "ppid=,comm=", "-p", str(pid)],
                                 capture_output=True, text=True, timeout=0.5).stdout.strip()
            ppid, _, comm = out.partition(" ")
            if os.path.basename(comm.strip()).lstrip("-") not in SHELL_NAMES or int(ppid) <= 1:
                break
            pid = int(ppid)
    except Exception:  # noqa: BLE001
        pass
    return pid


def _pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True
    return True


def register(payload):
    """The request id, or None (ignored / dashboard down)."""
    try:
        return _http_json("POST", DASHBOARD_URL + PERMISSION_PATH, payload).get("requestId")
    except Exception:  # noqa: BLE001
        return None


def wait_for_decision(request_id, codex_pid, deadline):
    """The decision dict AgentBar made, or None."""
    last_contact = time.monotonic()
    while _pid_alive(codex_pid) and time.monotonic() < deadline:
        # Never poll past the hold limit: the server would hold the call open.
        poll_sec = max(1, min(WAIT_POLL_SEC, int(deadline - time.monotonic())))
        url = f"{DASHBOARD_URL}{PERMISSION_PATH}/{request_id}/wait?timeout={poll_sec}"
        try:
            response = _http_json("GET", url, timeout=poll_sec + 5)
        except urllib.error.HTTPError:
            return None  # 404: the dashboard restarted; Codex's own prompt takes over
        except Exception:  # noqa: BLE001
            if time.monotonic() - last_contact > UNREACHABLE_GIVE_UP_SEC:
                return None
            time.sleep(RETRY_PAUSE_SEC)
            continue
        last_contact = time.monotonic()
        state = response.get("state")
        if state == "answered" and isinstance(response.get("decision"), dict):
            return response["decision"]
        if state != "pending":
            return None
    return None


def decision_output(decision):
    """The stdout Codex reads; only the fields its schema allows."""
    if decision.get("behavior") not in ("allow", "deny"):
        return None
    clean = {"behavior": decision["behavior"]}
    if isinstance(decision.get("message"), str):
        clean["message"] = decision["message"]
    return json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                                              "decision": clean}})


def main():
    limit = hold_limit_sec()
    if limit <= 0:
        return
    payload = json.loads(sys.stdin.buffer.read(MAX_STDIN_BYTES) or b"{}")
    if not isinstance(payload, dict) or payload.get("agent_id"):
        return
    started = time.time()
    codex_pid = find_codex_pid()
    payload.update({"agentTool": "codex", "hookPid": os.getpid(), "claudePid": codex_pid,
                    "promptStartedAt": started})
    request_id = register(payload)
    if not request_id:
        return
    decision = wait_for_decision(request_id, codex_pid, time.monotonic() + limit)
    output = decision_output(decision) if decision else None
    if output:
        sys.stdout.write(output + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    try:
        main()
    except BaseException:  # noqa: BLE001 — fail open, including SIGINT/SystemExit
        pass
    sys.exit(0)
