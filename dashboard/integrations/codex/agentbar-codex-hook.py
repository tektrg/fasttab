#!/usr/bin/env python3
"""Codex hook (every ~/.codex/hooks.json event, incl. PermissionRequest):
forwards the event to the dashboard's status listener. STATUS ONLY.

NEVER DECIDES, NEVER BLOCKS: prints nothing (so Codex's own prompt and the
other vendors' hooks decide), always exits 0, and gives the dashboard at
most POST_TIMEOUT_SEC. Any error = silent exit.

Env: AGENTBAR_DASHBOARD_URL (default http://127.0.0.1:4711). Registered by
dashboard/integrations/install.py.
"""
import json
import os
import subprocess
import sys
import urllib.request

DASHBOARD_URL = os.environ.get("AGENTBAR_DASHBOARD_URL", "http://127.0.0.1:4711").rstrip("/")
EVENT_PATH = "/api/hook/tui-event"
POST_TIMEOUT_SEC = 0.8
MAX_STDIN_BYTES = 1024 * 1024
MAX_MESSAGE_CHARS = 2000
SHELL_NAMES = {"sh", "bash", "zsh", "dash", "fish"}
#: No proxies: urllib honours HTTP_PROXY even for 127.0.0.1.
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _first(payload, *keys):
    for key in keys:
        value = payload.get(key)
        if isinstance(value, str) and value:
            return value
    return None


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


def build_event(payload):
    """The dashboard's event body from a Codex hook payload (tolerant keys)."""
    tool_input = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    title = _first(payload, "tool_name") or ""
    command = tool_input.get("command")
    if isinstance(command, list):
        command = " ".join(str(c) for c in command)
    if isinstance(command, str) and command:
        title = f"{title}: {command}" if title else command
    message = _first(payload, "last_assistant_message", "last-assistant-message",
                     "last_agent_message")
    return {
        "tool": "codex",
        "event": _first(payload, "hook_event_name", "hookEventName", "event") or "",
        "sessionId": _first(payload, "session_id", "sessionId", "thread_id"),
        "cwd": _first(payload, "cwd") or os.getcwd(),
        "transcriptPath": _first(payload, "transcript_path", "transcriptPath"),
        "title": title[:120] or None,
        "lastMessage": message[-MAX_MESSAGE_CHARS:] if message else None,
        "pid": find_codex_pid(),
        "paneId": os.environ.get("HERDR_PANE_ID") or None,
    }


def post_event(event, url=DASHBOARD_URL, timeout=POST_TIMEOUT_SEC):
    request = urllib.request.Request(
        url + EVENT_PATH, data=json.dumps(event).encode("utf-8"),
        headers={"Content-Type": "application/json"}, method="POST")
    with _OPENER.open(request, timeout=timeout) as response:
        response.read()


def main():
    try:
        payload = json.loads(sys.stdin.buffer.read(MAX_STDIN_BYTES) or b"{}")
        if isinstance(payload, dict):
            post_event(build_event(payload))
    except Exception:  # noqa: BLE001  fail open: dashboard down, bad input, anything
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
