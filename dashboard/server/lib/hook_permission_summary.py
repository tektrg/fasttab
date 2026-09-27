#!/usr/bin/env python3
"""Pure presentation + answer validation for hook permission requests
(hook_permissions.py holds the store). No state, no I/O.

Two jobs:
  * turn a raw Claude Code PermissionRequest payload into the `hookRequest`
    shape AgentBar renders (questions, or a readable permission summary with
    plain-English "Always allow ..." suggestion labels);
  * turn AgentBar's answer body into the exact `decision` object Claude Code
    reads from the hook's stdout — or refuse it with a readable reason.
"""
import json
import re

QUESTION_TOOL = "AskUserQuestion"
PLAN_TOOL = "ExitPlanMode"
KIND_QUESTION = "question"
KIND_PERMISSION = "permission"

DETAIL_MAX_CHARS = 2000
#: Same cap as /api/answer's free text (_clean_free_text in the server).
ANSWER_MAX_CHARS = 500
DEFAULT_DENY_MESSAGE = "Denied from AgentBar."

_CONTROL_CHARS_RE = re.compile(r"[\x00-\x1f\x7f]")

#: Where an "addRules"/"addDirectories" suggestion would be saved -> the words
#: a human reads ("Always allow X <scope>").
_SCOPE_WORDS = {
    "localSettings": "in this project",
    "projectSettings": "in this project (shared settings)",
    "userSettings": "in every project",
    "session": "for this session",
    "cliArg": "for this run",
}
_MODE_WORDS = {
    "acceptEdits": "auto-accept edits",
    "bypassPermissions": "bypass permissions",
    "plan": "plan",
    "default": "default",
    "dontAsk": "don't ask",
}
_FILE_TOOLS = {"Edit": "Edit a file", "MultiEdit": "Edit a file",
               "Write": "Write a file", "NotebookEdit": "Edit a notebook",
               "Read": "Read a file"}


class AnswerRejected(ValueError):
    """AgentBar's answer body can't become a decision; message is user-facing."""


def request_kind(tool_name):
    return KIND_QUESTION if tool_name == QUESTION_TOOL else KIND_PERMISSION


def _cap(text, limit=DETAIL_MAX_CHARS):
    text = text or ""
    return text if len(text) <= limit else text[:limit - 1] + "…"


def normalized_questions(tool_input):
    """AskUserQuestion's questions, only the fields AgentBar renders."""
    questions = []
    for q in (tool_input or {}).get("questions") or []:
        if not isinstance(q, dict) or not isinstance(q.get("question"), str):
            continue
        questions.append({
            "question": q["question"],
            "header": q.get("header") or "",
            "multiSelect": bool(q.get("multiSelect")),
            "options": [{"label": str(o.get("label") or ""),
                         "description": str(o.get("description") or "")}
                        for o in q.get("options") or [] if isinstance(o, dict)],
        })
    return questions


def _permission_title(tool_name):
    if tool_name == "Bash":
        return "Run a shell command"
    if tool_name == PLAN_TOOL:
        return "Approve the plan"
    if tool_name in _FILE_TOOLS:
        return _FILE_TOOLS[tool_name]
    if tool_name == "WebFetch":
        return "Fetch a web page"
    if tool_name == "WebSearch":
        return "Search the web"
    if tool_name.startswith("mcp__"):
        return f"Use MCP tool {tool_name}"
    return f"Use {tool_name}"


def _permission_detail(tool_name, tool_input):
    tool_input = tool_input if isinstance(tool_input, dict) else {}
    if tool_name == "Bash" and tool_input.get("command"):
        detail = tool_input["command"]
        if tool_input.get("description"):
            detail += f"\n\n{tool_input['description']}"
        return _cap(detail)
    if tool_name == PLAN_TOOL and tool_input.get("plan"):
        return _cap(tool_input["plan"])
    for key in ("file_path", "notebook_path", "url", "query", "path"):
        if isinstance(tool_input.get(key), str) and tool_input[key]:
            return _cap(tool_input[key])
    return _cap(json.dumps(tool_input, indent=2, default=str))


def _rule_text(rule):
    tool = rule.get("toolName") or "?"
    content = rule.get("ruleContent")
    return f"{tool}({content})" if content else tool


def suggestion_label(suggestion):
    """Plain English for one permission_suggestions entry, naming the exact
    rule/mode/directory it would save."""
    scope = _SCOPE_WORDS.get(suggestion.get("destination"), "")
    kind = suggestion.get("type")
    if kind == "addRules":
        rules = ", ".join(f"`{_rule_text(r)}`" for r in suggestion.get("rules") or []
                          if isinstance(r, dict))
        verb = "Always deny" if suggestion.get("behavior") == "deny" else "Always allow"
        text = f"{verb} {rules or 'this'}"
    elif kind == "setMode":
        mode = suggestion.get("mode")
        text = f"Switch to {_MODE_WORDS.get(mode, mode)} mode"
    elif kind == "addDirectories":
        dirs = ", ".join(f"`{d}`" for d in suggestion.get("directories") or [])
        text = f"Always allow access to {dirs or 'this directory'}"
    else:
        text = f"Apply suggested permission change ({kind})"
    return f"{text} {scope}".strip()


def build_hook_request_view(request_id, tool_name, tool_input, suggestions,
                            created_at, now):
    """The `hookRequest` object on a status-only row / its needsYou entry."""
    kind = request_kind(tool_name)
    view = {
        "requestId": request_id,
        "kind": kind,
        "toolName": tool_name,
        "createdAt": created_at,
        "sinceSec": max(0.0, now - created_at),
    }
    if kind == KIND_QUESTION:
        view["questions"] = normalized_questions(tool_input)
    else:
        view["permission"] = {
            "title": _permission_title(tool_name),
            "detail": _permission_detail(tool_name, tool_input),
            "suggestions": [{"index": i, "label": suggestion_label(s)}
                            for i, s in enumerate(suggestions or [])],
        }
    return view


def needs_you_detail(hook_request):
    if hook_request["kind"] == KIND_QUESTION:
        return "Question"
    return f"Permission: {hook_request['toolName']}"


def clean_answer_text(value):
    """One line, no control characters, capped — same rules as /api/answer."""
    if not isinstance(value, str):
        raise AnswerRejected("answer must be a string")
    text = " ".join(_CONTROL_CHARS_RE.sub(" ", value).split())
    if not text:
        raise AnswerRejected("empty answer")
    return text[:ANSWER_MAX_CHARS]


def _deny_decision(body):
    message = body.get("message")
    message = clean_answer_text(message) if message else DEFAULT_DENY_MESSAGE
    return {"behavior": "deny", "message": message}


def _question_allow_decision(tool_input, body):
    answers = body.get("answers")
    if not isinstance(answers, dict):
        raise AnswerRejected("answers must be an object keyed by question text")
    expected = {q["question"] for q in normalized_questions(tool_input)}
    if set(answers) != expected:
        raise AnswerRejected("answers must answer exactly these questions: "
                             + " | ".join(sorted(expected)))
    cleaned = {question: clean_answer_text(text) for question, text in answers.items()}
    return {"behavior": "allow", "updatedInput": {**tool_input, "answers": cleaned}}


def _permission_allow_decision(suggestions, body):
    decision = {"behavior": "allow"}
    index = body.get("suggestionIndex")
    if index is None:
        return decision
    if isinstance(index, bool) or not isinstance(index, int) \
            or not 0 <= index < len(suggestions or []):
        raise AnswerRejected(f"suggestionIndex {index!r} is not one of the "
                             f"{len(suggestions or [])} suggestions")
    decision["updatedPermissions"] = [suggestions[index]]
    return decision


def build_decision(tool_name, tool_input, suggestions, body):
    """AgentBar's answer body -> Claude Code's `decision` object."""
    if not isinstance(body, dict):
        raise AnswerRejected("body must be a JSON object")
    behavior = body.get("behavior")
    if behavior == "deny":
        return _deny_decision(body)
    if behavior != "allow":
        raise AnswerRejected("behavior must be 'allow' or 'deny'")
    if request_kind(tool_name) == KIND_QUESTION:
        return _question_allow_decision(tool_input or {}, body)
    return _permission_allow_decision(suggestions, body)
