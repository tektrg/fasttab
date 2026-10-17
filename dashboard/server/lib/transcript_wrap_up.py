#!/usr/bin/env python3
"""The end-of-turn question Claude Desktop asks with its `wrap_up` tool.

Claude Desktop ends a turn with a `tool_use` named `mcp__ccd_turn__wrap_up`
(input `{recap, ask?, actions?: [{label, message?, action?}]}`) and draws a
"next step" box with one button per action. A wrap_up WITHOUT `ask` is only
a recap. The turn has already ended, so nothing holds it open: answering is
just the next user message — sent through the session inbox
(`session_inbox.py`), never through the PermissionRequest hook.

Pending rule (mirrored in Swift by `WrapUpQuestionExtractor`): scanning the
transcript tail from the end, the first main-conversation line that counts
decides —
  - a real user prompt (a `user` line that is not only `tool_result` blocks
    and not `isMeta`) → the question was answered: none;
  - an assistant `tool_use` other than wrap_up → a new turn is running: none;
  - a wrap_up `tool_use` → pending iff it has a non-empty `ask` and at least
    one usable action.
Assistant text after the wrap_up (Claude often writes a closing message) does
not settle it.

Actions: `message` is what gets sent; without it, the `label`. An action that
names an app action (`action`: "commit", "create_pr", "merge"…) is a button in
Desktop's own UI that runs a Desktop feature — sending its label as chat text
would not run that feature, so it is DROPPED, not offered (decision 2026-10-15).
"""
import json

TOOL_NAME = "mcp__ccd_turn__wrap_up"
FIELD_NAME = "wrapUpQuestion"
MAX_ACTIONS = 4
_TOOL_MARKER = TOOL_NAME.encode()


def find_pending_wrap_up(tail_bytes, chunk_starts_at_file_start):
    """{ask, recap, actions: [{label, message}]} of the pending wrap_up
    question in this transcript tail, or None."""
    lines = [l for l in tail_bytes.split(b"\n") if l]
    if not chunk_starts_at_file_start and lines:
        lines = lines[1:]  # cut mid-line
    for line in reversed(lines):
        verdict = _line_verdict(line)
        if verdict is None:
            continue
        return verdict or None
    return None


def _line_verdict(line):
    """None = this line does not decide; {} = settled (no question);
    a question dict = pending."""
    if b'"user"' not in line and b'"assistant"' not in line:
        return None
    try:
        entry = json.loads(line)
    except ValueError:
        return None
    if not isinstance(entry, dict) or entry.get("isSidechain") is True or entry.get("isMeta") is True:
        return None
    message = entry.get("message")
    if not isinstance(message, dict):
        return None
    content = message.get("content")
    if entry.get("type") == "user":
        return {} if _is_real_prompt(content) else None
    if entry.get("type") != "assistant" or not isinstance(content, list):
        return None
    tool_uses = [b for b in content if isinstance(b, dict) and b.get("type") == "tool_use"]
    if not tool_uses:
        return None
    last = tool_uses[-1]
    if last.get("name") != TOOL_NAME:
        return {}
    return _question(last.get("input")) or {}


def _is_real_prompt(content):
    if isinstance(content, str):
        return bool(content.strip())
    if not isinstance(content, list):
        return False
    return any(isinstance(b, dict) and b.get("type") != "tool_result" for b in content)


def _question(tool_input):
    if not isinstance(tool_input, dict):
        return None
    ask = tool_input.get("ask")
    if not isinstance(ask, str) or not ask.strip():
        return None
    actions = [a for a in map(_action, tool_input.get("actions") or []) if a][:MAX_ACTIONS]
    if not actions:
        return None
    recap = tool_input.get("recap")
    return {"ask": ask.strip(), "recap": recap.strip() if isinstance(recap, str) else "",
            "actions": actions}


def _action(raw):
    if not isinstance(raw, dict) or raw.get("action"):
        return None
    label = raw.get("label")
    if not isinstance(label, str) or not label.strip():
        return None
    message = raw.get("message")
    message = message.strip() if isinstance(message, str) and message.strip() else label.strip()
    return {"label": label.strip(), "message": message}
