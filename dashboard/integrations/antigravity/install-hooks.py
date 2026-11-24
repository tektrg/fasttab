#!/usr/bin/env python3
"""Install or update the AgentBar Antigravity status hook in ~/.gemini/config/hooks.json.

Preserves all other hooks already present in hooks.json. Safe to run repeatedly.
"""
import json
import os
import sys
import tempfile

HOOKS_JSON_PATH = os.path.expanduser("~/.gemini/config/hooks.json")
HOOK_KEY = "agentbar-status"
SCRIPT_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "antigravity-status-hook.py",
)


def build_hook_entry(script_path=SCRIPT_PATH):
    def cmd(event, timeout=5):
        return {
            "type": "command",
            "command": f"python3 {script_path} --event {event}",
            "timeout": timeout,
        }

    return {
        "enabled": True,
        "SessionStart": [cmd("SessionStart")],
        "PreInvocation": [cmd("PreInvocation")],
        "PostInvocation": [cmd("PostInvocation")],
        "PreToolUse": [
            {
                "matcher": "ask_question|ask_permission",
                "hooks": [cmd("PreToolUse", timeout=360)],
            }
        ],
        "PostToolUse": [
            {
                "matcher": "ask_question|ask_permission",
                "hooks": [cmd("PostToolUse")],
            }
        ],
        "Stop": [cmd("Stop")],
    }


def install(hooks_path=HOOKS_JSON_PATH, script_path=SCRIPT_PATH):
    os.makedirs(os.path.dirname(hooks_path), exist_ok=True)
    data = {}
    if os.path.exists(hooks_path):
        with open(hooks_path, "r", encoding="utf-8") as f:
            raw = f.read().strip()
            if raw:
                data = json.loads(raw)
        if not isinstance(data, dict):
            raise ValueError(f"{hooks_path} must contain a JSON object at top level")

    data[HOOK_KEY] = build_hook_entry(script_path)

    fd, tmp_path = tempfile.mkstemp(prefix=".hooks.", suffix=".tmp", dir=os.path.dirname(hooks_path))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.replace(tmp_path, hooks_path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise
    return hooks_path


if __name__ == "__main__":
    path = install()
    print(f"Installed '{HOOK_KEY}' hook into {path}")
