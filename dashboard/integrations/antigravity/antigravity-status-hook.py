#!/usr/bin/env python3
"""Antigravity hook -> AgentBar/Chief Dashboard status & interactive prompt bridge.

1. Updates `~/.local/state/agentbar/antigravity/<conversationId>.json` atomically
   on every hook event so AgentBar shows Working / Needs you / Blocked live.
2. On `PreToolUse` for `ask_question` or `ask_permission`, registers a held
   `HookRequest` with the Chief Dashboard (`POST /api/hook/permission` with
   `agentTool: "antigravity"`) and long-polls `/wait` so AgentBar can show its
   inline **Answer** / **Review** card (and Corner Card / Focus Mode).
   - If AgentBar answers `ask_question`: returns `{"decision": "deny", "reason": "..."}`
     carrying the user's exact answers so the agent proceeds immediately without
     re-asking.
   - If AgentBar approves `ask_permission`: returns `{"decision": "auto_approve"}`;
     on deny: `{"decision": "deny", "reason": "..."}`.
   - Fails open ALWAYS: if the dashboard is down, AgentBar is not connected, or
     the hold times out, prints `{"decision": "allow"}` so Antigravity's native
     UI takes over cleanly.
"""
import argparse
import json
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.request

STATE_DIR = os.environ.get(
    "AGENTBAR_ANTIGRAVITY_DIR",
    os.path.expanduser("~/.local/state/agentbar/antigravity"),
)
DASHBOARD_URL = os.environ.get("AGENTBAR_DASHBOARD_URL", "http://127.0.0.1:4711").rstrip("/")
HOLD_SEC = float(os.environ.get("AGENTBAR_ANTIGRAVITY_HOLD_SEC", "300"))
REGISTER_TIMEOUT_SEC = 1.5
WAIT_POLL_SEC = 25
WAIT_SOCKET_TIMEOUT_SEC = WAIT_POLL_SEC + 5
SAFE_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,128}$")

#: Never honour HTTP_PROXY for localhost dashboard calls.
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _http_json(method, url, body=None, timeout=REGISTER_TIMEOUT_SEC):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request(
        url, data=data, method=method, headers={"Content-Type": "application/json"}
    )
    with _OPENER.open(request, timeout=timeout) as response:
        return json.loads(response.read() or b"{}")


def _single_line(text, max_len=140):
    cleaned = " ".join((text or "").split())
    if len(cleaned) > max_len:
        return cleaned[: max_len - 1].rstrip() + "…"
    return cleaned


def _infer_surface(transcript_path):
    path = (transcript_path or "").replace("\\", "/")
    if "/antigravity-cli/" in path:
        return "antigravity-cli"
    if "/antigravity-ide/" in path:
        return "antigravity-ide"
    return "antigravity-app"


def _default_label(payload, existing):
    existing_label = (existing or {}).get("label")
    if existing_label:
        return existing_label
    prompt = _single_line(payload.get("lastUserInput") or "", max_len=64)
    if prompt:
        return prompt
    workspaces = payload.get("workspacePaths") or []
    if workspaces and isinstance(workspaces[0], str):
        base = os.path.basename(workspaces[0].rstrip("/"))
        if base:
            return base
    return (payload.get("conversationId") or "")[:12]


def _parse_questions_list(tool_args):
    """Parse Antigravity's `ask_question` args (list or JSON-encoded string)."""
    questions = (tool_args or {}).get("questions")
    if isinstance(questions, str):
        try:
            questions = json.loads(questions)
        except ValueError:
            return []
    if not isinstance(questions, list):
        return []
    return [q for q in questions if isinstance(q, dict)]


def _normalize_ask_question_input(tool_args):
    """Normalize Antigravity `ask_question` args into Claude `AskUserQuestion` shape."""
    normalized = []
    for idx, q in enumerate(_parse_questions_list(tool_args), start=1):
        q_text = _single_line(q.get("question") or "", max_len=500)
        if not q_text:
            continue
        raw_options = q.get("options") or []
        options = []
        for opt in raw_options:
            if isinstance(opt, str) and opt.strip():
                options.append({"label": opt.strip(), "description": ""})
            elif isinstance(opt, dict):
                label = str(opt.get("label") or "").strip()
                if label:
                    options.append({"label": label, "description": str(opt.get("description") or "").strip()})
        if not options:
            continue
        header = str(q.get("header") or "").strip() or (f"Q{idx}" if len(_parse_questions_list(tool_args)) > 1 else "Question")
        normalized.append({
            "question": q_text,
            "header": header,
            "multiSelect": bool(q.get("is_multi_select") or q.get("multiSelect")),
            "options": options,
        })
    return {"questions": normalized}


def _extract_question(tool_args):
    questions = _parse_questions_list(tool_args)
    if not questions:
        return None
    q_text = _single_line(questions[0].get("question") or "", max_len=240)
    if not q_text:
        return None
    return {
        "header": "Question",
        "question": q_text,
        "questionCount": len(questions),
    }


def _extract_permission_reason(tool_args):
    args = tool_args or {}
    reason = _single_line(args.get("Reason") or "", max_len=180)
    if reason:
        return reason
    action = _single_line(args.get("Action") or "", max_len=60)
    target = _single_line(args.get("Target") or "", max_len=120)
    joined = " ".join(part for part in (action, target) if part)
    return joined or "Permission needed"


def _compute_state(event, payload, existing, now_ms):
    prev_status = (existing or {}).get("status")
    status = "busy"
    waiting_for = None
    transcript_question = None

    if event == "PreToolUse":
        tool_call = payload.get("toolCall") or {}
        tool_name = tool_call.get("name") or ""
        tool_args = tool_call.get("args") or {}
        if tool_name == "ask_question":
            status = "waiting"
            waiting_for = "question"
            transcript_question = _extract_question(tool_args)
        elif tool_name == "ask_permission":
            status = "waiting"
            waiting_for = _extract_permission_reason(tool_args)
    elif event == "Stop":
        if payload.get("fullyIdle") is False:
            status = "busy"
        else:
            status = "idle"
    elif event in ("SessionStart", "PreInvocation", "PostInvocation", "PostToolUse"):
        status = "busy"

    status_updated_at = (
        (existing or {}).get("statusUpdatedAt")
        if prev_status == status and isinstance((existing or {}).get("statusUpdatedAt"), (int, float))
        else now_ms
    )

    workspaces = payload.get("workspacePaths") or []
    cwd = (
        workspaces[0]
        if workspaces and isinstance(workspaces[0], str)
        else (existing or {}).get("cwd")
    )
    transcript_path = payload.get("transcriptPath") or (existing or {}).get("transcriptPath")
    artifact_dir = payload.get("artifactDirectoryPath") or (existing or {}).get("artifactDirectoryPath")

    return {
        "conversationId": payload.get("conversationId"),
        "label": _default_label(payload, existing),
        "cwd": cwd,
        "workspacePaths": workspaces if workspaces else (existing or {}).get("workspacePaths") or [],
        "transcriptPath": transcript_path,
        "artifactDirectoryPath": artifact_dir,
        "modelName": payload.get("modelName") or (existing or {}).get("modelName"),
        "surface": _infer_surface(transcript_path),
        "status": status,
        "waitingFor": waiting_for,
        "transcriptQuestion": transcript_question,
        "lastEvent": event,
        "lastUserInput": _single_line(payload.get("lastUserInput") or "", max_len=200)
        or (existing or {}).get("lastUserInput"),
        "statusUpdatedAt": status_updated_at,
        "updatedAt": now_ms,
    }


def _write_state_file(state_dir, conv_id, record):
    os.makedirs(state_dir, exist_ok=True)
    target = os.path.join(state_dir, f"{conv_id}.json")
    fd, tmp_path = tempfile.mkstemp(prefix=f".{conv_id}.", suffix=".tmp", dir=state_dir)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(record, f, ensure_ascii=False)
        os.replace(tmp_path, target)
    except OSError:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


def _build_bridge_payload(payload):
    conv_id = payload.get("conversationId")
    tool_call = payload.get("toolCall") or {}
    tool_name = tool_call.get("name") or ""
    tool_args = tool_call.get("args") or {}

    if tool_name == "ask_question":
        normalized = _normalize_ask_question_input(tool_args)
        if not normalized["questions"]:
            return None
        return {
            "agentTool": "antigravity",
            "session_id": conv_id,
            "tool_name": "AskUserQuestion",
            "tool_input": normalized,
            "hookPid": os.getpid(),
        }

    if tool_name == "ask_permission":
        return {
            "agentTool": "antigravity",
            "session_id": conv_id,
            "tool_name": "ask_permission",
            "tool_input": tool_args if isinstance(tool_args, dict) else {},
            "hookPid": os.getpid(),
        }

    return None


def decision_to_antigravity_response(tool_name, decision):
    """Map dashboard hook bridge decision -> Antigravity PreToolUse stdout JSON."""
    if not isinstance(decision, dict):
        return {"decision": "allow"}
    behavior = decision.get("behavior")

    if tool_name == "ask_question":
        if behavior == "allow":
            answers = ((decision.get("updatedInput") or {}).get("answers")) or {}
            if isinstance(answers, dict) and answers:
                parts = [f'"{q}" = "{a}"' for q, a in answers.items()]
                return {
                    "decision": "deny",
                    "reason": (
                        "Answered by user in AgentBar (do not re-ask; proceed using these answers): "
                        + "; ".join(parts)
                    ),
                }
        if behavior == "deny":
            return {
                "decision": "deny",
                "reason": decision.get("message") or "Dismissed in AgentBar.",
            }
        return {"decision": "allow"}

    if tool_name == "ask_permission":
        if behavior == "allow":
            return {"decision": "auto_approve"}
        if behavior == "deny":
            return {
                "decision": "deny",
                "reason": decision.get("message") or "Denied from AgentBar.",
            }
    return {"decision": "allow"}


def _bridge_pre_tool_use(payload, dashboard_url=DASHBOARD_URL, hold_sec=HOLD_SEC, http_json=_http_json):
    bridge_payload = _build_bridge_payload(payload)
    if not bridge_payload:
        return None
    tool_name = (payload.get("toolCall") or {}).get("name") or ""
    try:
        reg = http_json("POST", f"{dashboard_url}/api/hook/permission", bridge_payload, REGISTER_TIMEOUT_SEC)
    except Exception:
        return None
    request_id = (reg or {}).get("requestId")
    if not request_id:
        return None

    deadline = time.monotonic() + hold_sec
    url = f"{dashboard_url}/api/hook/permission/{request_id}/wait?timeout={WAIT_POLL_SEC}"
    while time.monotonic() < deadline:
        try:
            resp = http_json("GET", url, None, WAIT_SOCKET_TIMEOUT_SEC)
        except Exception:
            return None
        state = (resp or {}).get("state")
        if state == "answered" and isinstance(resp.get("decision"), dict):
            return decision_to_antigravity_response(tool_name, resp["decision"])
        if state != "pending":
            return None
    return None


def _response_for_event(event):
    if event == "PreToolUse":
        return {"decision": "allow"}
    if event == "Stop":
        return {"decision": ""}
    return {}


def handle_hook(event, payload, state_dir=STATE_DIR, now_ms=None, enable_bridge=None):
    conv_id = (payload or {}).get("conversationId")
    if not isinstance(conv_id, str) or not SAFE_ID_RE.fullmatch(conv_id):
        return _response_for_event(event)

    target = os.path.join(state_dir, f"{conv_id}.json")
    existing = None
    try:
        with open(target, "r", encoding="utf-8") as f:
            existing = json.load(f)
    except (OSError, ValueError):
        existing = None

    ts = int(time.time() * 1000) if now_ms is None else now_ms
    record = _compute_state(event, payload, existing, ts)
    _write_state_file(state_dir, conv_id, record)

    should_bridge = (
        enable_bridge
        if enable_bridge is not None
        else os.environ.get("AGENTBAR_ANTIGRAVITY_BRIDGE", "1") != "0"
    )
    if event == "PreToolUse" and should_bridge and record.get("status") == "waiting":
        bridged = _bridge_pre_tool_use(payload)
        if bridged is not None:
            # Answered in AgentBar: mark conversation busy again immediately.
            resumed = _compute_state("PostToolUse", payload, record, int(time.time() * 1000))
            _write_state_file(state_dir, conv_id, resumed)
            return bridged

    return _response_for_event(event)


def main():
    parser = argparse.ArgumentParser(description="Antigravity -> AgentBar status hook")
    parser.add_argument("--event", required=True)
    args = parser.parse_args()

    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        payload = {}

    try:
        response = handle_hook(args.event, payload)
    except Exception:
        response = _response_for_event(args.event)

    sys.stdout.write(json.dumps(response))
    sys.stdout.flush()


if __name__ == "__main__":
    main()
