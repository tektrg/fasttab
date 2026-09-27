#!/usr/bin/env python3
"""Claude Code PermissionRequest hook: lets AgentBar answer a permission
prompt or an AskUserQuestion for a Claude session that has no herdr pane
(Claude Desktop, a plain terminal).

Sends the prompt to the dashboard, long-polls for AgentBar's answer, prints
Claude's `hookSpecificOutput` decision. Claude's own prompt stays on screen
the whole time and races this hook — whichever answers first wins.

FAILS OPEN, ALWAYS: dashboard down, a bad response, a timeout, any exception
-> exit 0 with NOTHING on stdout (= "no decision", Claude's normal prompt
decides). The only thing ever printed is one complete decision.

Settings entry (PermissionRequest, matcher "*", timeout 86400):
  python3 /abs/path/dashboard/hooks/agentbar-permission-hook.py
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
REGISTER_TIMEOUT_SEC = 1.5
WAIT_POLL_SEC = 25
#: Socket timeout for a /wait call: the server holds it up to WAIT_POLL_SEC.
WAIT_SOCKET_TIMEOUT_SEC = WAIT_POLL_SEC + 5
#: Give up after this long without one successful /wait.
UNREACHABLE_GIVE_UP_SEC = 60
RETRY_PAUSE_SEC = 2
SHELL_NAMES = {"sh", "bash", "zsh", "dash", "fish"}


#: No proxies, ever: urllib honours HTTP_PROXY even for 127.0.0.1, which would
#: send every prompt (commands, file contents) to the proxy host.
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _http_json(method, url, body=None, timeout=REGISTER_TIMEOUT_SEC):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request(
        url, data=data, method=method, headers={"Content-Type": "application/json"})
    with _OPENER.open(request, timeout=timeout) as response:
        return json.loads(response.read() or b"{}")


def _parent_and_name(pid):
    out = subprocess.run(["ps", "-o", "ppid=,comm=", "-p", str(pid)],
                         capture_output=True, text=True, timeout=1).stdout.strip()
    ppid, _, comm = out.partition(" ")
    return int(ppid), os.path.basename(comm.strip()).lstrip("-")


def find_claude_pid():
    """The Claude process: our parent, or its parent when a shell sits between."""
    pid = os.getppid()
    try:
        for _ in range(3):
            parent, name = _parent_and_name(pid)
            if name not in SHELL_NAMES or parent <= 1:
                return pid
            pid = parent
    except Exception:
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
    response = _http_json("POST", f"{DASHBOARD_URL}/api/hook/permission", payload)
    return response.get("requestId")


def wait_for_decision(request_id, claude_pid):
    """The decision dict, or None (resolved elsewhere / gone / unreachable)."""
    url = f"{DASHBOARD_URL}/api/hook/permission/{request_id}/wait?timeout={WAIT_POLL_SEC}"
    last_contact = time.monotonic()
    while _pid_alive(claude_pid):
        try:
            response = _http_json("GET", url, timeout=WAIT_SOCKET_TIMEOUT_SEC)
        except urllib.error.HTTPError:
            return None  # 404: dashboard restarted / request pruned
        except Exception:
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


def main():
    payload = json.loads(sys.stdin.read() or "{}")
    claude_pid = find_claude_pid()
    payload.update({"hookPid": os.getpid(), "claudePid": claude_pid})
    request_id = register(payload)
    if not request_id:
        return  # ignored (herdr pane / unsupported)
    decision = wait_for_decision(request_id, claude_pid)
    if decision is None:
        return
    output = json.dumps({"hookSpecificOutput": {
        "hookEventName": "PermissionRequest", "decision": decision}})
    sys.stdout.write(output + "\n")
    sys.stdout.flush()


if __name__ == "__main__":
    try:
        main()
    except BaseException:  # noqa: BLE001 — fail open, including SIGINT/SystemExit
        pass
    sys.exit(0)
