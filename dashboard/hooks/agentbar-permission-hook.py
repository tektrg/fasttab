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

RE-SENDS its prompt when the dashboard lost it (restarted: /wait 404, or
unreachable) or had nobody to show it to (AgentBar not connected / gone):
with backoff, only for a session whose prompt Claude shows itself (interactive
CLI / Desktop main thread — so a running hook never stalls the agent), and
only while the session file still shows THIS prompt, the Claude process
lives and RETRY_WINDOW_SEC (under the hook's own 24h timeout) is not over.

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

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "server", "lib"))
try:  # shared with the dashboard; without it the hook still works, just never re-sends
    import claude_sessions
    import session_prompt_state
except Exception:  # noqa: BLE001
    claude_sessions = session_prompt_state = None

DASHBOARD_URL = os.environ.get("AGENTBAR_DASHBOARD_URL", "http://127.0.0.1:4711").rstrip("/")
REGISTER_TIMEOUT_SEC = 1.5
WAIT_POLL_SEC = 25
#: Socket timeout for a /wait call: the server holds it up to WAIT_POLL_SEC.
WAIT_SOCKET_TIMEOUT_SEC = WAIT_POLL_SEC + 5
#: Give up after this long without one successful /wait.
UNREACHABLE_GIVE_UP_SEC = 60
RETRY_PAUSE_SEC = 2
SHELL_NAMES = {"sh", "bash", "zsh", "dash", "fish"}
#: Re-send pauses: 1s, 2s, 4s, 8s, then every 10s until the prompt is gone.
RETRY_FIRST_PAUSE_SEC = 1
RETRY_MAX_PAUSE_SEC = 10
#: Stop re-sending after this long (the settings entry's timeout is 86400).
RETRY_WINDOW_SEC = 23 * 3600

#: What one register + wait round ended with.
OUTCOME_DECIDED = "decided"
OUTCOME_FINAL = "final"      # ignored for good / answered elsewhere: exit
OUTCOME_RETRY = "retry"      # dashboard lost it or nobody to answer: maybe re-send


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
    """(request_id | None, outcome when None). Dashboard down = retry."""
    try:
        response = _http_json("POST", f"{DASHBOARD_URL}/api/hook/permission", payload)
    except Exception:
        return None, OUTCOME_RETRY
    if response.get("requestId"):
        return response["requestId"], None
    return None, OUTCOME_RETRY if response.get("retryable") else OUTCOME_FINAL


def wait_for_decision(request_id, claude_pid):
    """(outcome, decision | None)."""
    url = f"{DASHBOARD_URL}/api/hook/permission/{request_id}/wait?timeout={WAIT_POLL_SEC}"
    last_contact = time.monotonic()
    while _pid_alive(claude_pid):
        try:
            response = _http_json("GET", url, timeout=WAIT_SOCKET_TIMEOUT_SEC)
        except urllib.error.HTTPError:
            return OUTCOME_RETRY, None  # 404: dashboard restarted / request pruned
        except Exception:
            if time.monotonic() - last_contact > UNREACHABLE_GIVE_UP_SEC:
                return OUTCOME_RETRY, None
            time.sleep(RETRY_PAUSE_SEC)
            continue
        last_contact = time.monotonic()
        state = response.get("state")
        if state == "answered" and isinstance(response.get("decision"), dict):
            return OUTCOME_DECIDED, response["decision"]
        if state != "pending":
            return (OUTCOME_RETRY if response.get("retryable") else OUTCOME_FINAL), None
    return OUTCOME_FINAL, None


def _own_session_file(payload, claude_pid):
    if claude_sessions is None:
        return None
    entry = claude_sessions.read_session_for_pid(claude_pid)
    return entry if entry and entry.get("sessionId") == payload.get("session_id") else None


def may_resend(payload, claude_pid, prompt_started_at, retry_deadline):
    """Re-sending is safe and useful: Claude shows this prompt itself (so
    this hook running on never blocks it), the prompt is still up, and the
    retry window is open. Anything unknown -> False (fail open)."""
    if session_prompt_state is None or payload.get("agent_id") or time.monotonic() > retry_deadline:
        return False
    if not _pid_alive(claude_pid):
        return False
    entry = _own_session_file(payload, claude_pid)
    if not session_prompt_state.shows_own_prompt(entry, payload.get("session_id")):
        return False
    return session_prompt_state.prompt_may_still_be_up(entry, prompt_started_at)


def bridge_prompt(payload, claude_pid):
    """The decision AgentBar made, or None (Claude's own prompt decides)."""
    retry_deadline = time.monotonic() + RETRY_WINDOW_SEC
    pause = RETRY_FIRST_PAUSE_SEC
    while True:
        request_id, outcome = register(payload)
        if request_id:
            outcome, decision = wait_for_decision(request_id, claude_pid)
            if outcome == OUTCOME_DECIDED:
                return decision
            pause = RETRY_FIRST_PAUSE_SEC  # it was held: start the backoff over
        if outcome != OUTCOME_RETRY or not may_resend(
                payload, claude_pid, payload["promptStartedAt"], retry_deadline):
            return None
        time.sleep(pause)
        pause = min(pause * 2, RETRY_MAX_PAUSE_SEC)
        # A prompt answered in Claude during the pause must not come back.
        if not may_resend(payload, claude_pid, payload["promptStartedAt"], retry_deadline):
            return None
        payload["reregister"] = True


def main():
    payload = json.loads(sys.stdin.read() or "{}")
    if not isinstance(payload, dict):
        return
    claude_pid = find_claude_pid()
    payload.update({"hookPid": os.getpid(), "claudePid": claude_pid, "promptStartedAt": time.time()})
    decision = bridge_prompt(payload, claude_pid)
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
