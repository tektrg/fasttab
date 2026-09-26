#!/usr/bin/env python3
"""Serves what AgentBar's `SessionTranscriptReader`/`AskUserQuestionExtractor`
(Swift, `Sources/AgentBar/Answer/Transcript/`) read straight off local disk —
a session's `~/.claude/projects/*/<sessionId>.jsonl` — so the dashboard can
answer the same question for a session that lives on a REMOTE machine (the
Air) or has no local disk at all (a phone). AgentBar gotcha 9/13 in
`Sources/AgentBar/AGENTS.md` is the reason this module exists: those Swift
readers only ever see this Mac's own `~/.claude/projects`.

Two things are ported here, as faithfully as a Python port of a Swift byte
scanner can be:
  - `scan_tail_for_latest_message` == `TranscriptTailScanner.scan`
  - `find_pending_question_form`   == `AskUserQuestionExtractor.find`

Known, deliberate differences from the Swift originals (call these out to
whoever next touches either side):
  - No port of `AskUserQuestionResultExtractor`/`recordedAnswers` — that is
    only used by AgentBar's post-submit "did the batch actually land"
    verification, which is out of scope for a read-only display endpoint.
  - The plan file's local vs "not on this Mac" distinction
    (`PlanFileReader`) does not apply here: this module is always told which
    machine to read from (the dashboard already knows), so a missing file
    reads as "missing on <machine>", not the ambiguous local-Mac message
    Swift shows (which exists there only because Swift can't tell which
    machine a session belongs to).

Every entry point is pure I/O in, JSON-safe dict out — nothing here talks to
herdr, ssh, or the board; `chief-dashboard-server.py` composes this module
with `chief_dashboard_herdr.remote_shell_text` for the remote case and plain
file I/O for local.
"""
import base64
import glob
import json
import os
import re

# Mirrors SessionTranscriptReader.tailWindowBytes exactly: a long tool
# output can push the last assistant text out of the first, smaller window,
# so windows are tried smallest-first and only widened on a miss.
TAIL_WINDOW_BYTES = [256 * 1024, 1024 * 1024, 4 * 1024 * 1024]

# Mirrors TranscriptTailScanner.
MAX_MESSAGE_LENGTH = 6000
MAX_PLAN_CANDIDATES = 6
_FILE_TOOLS = {"Write", "Edit", "Read"}
_IGNORED_FILE_NAMES = {"skill.md", "claude.md", "agents.md", "readme.md", "memory.md"}
_IGNORED_PATH_PREFIXES = ("/tmp/", "/private/tmp/")

# Mirrors PlanFileReader.maxBytes.
PLAN_FILE_MAX_BYTES = 200 * 1024

_ASSISTANT_MARKER = b'"assistant"'
_ASK_USER_QUESTION_MARKER = b"AskUserQuestion"
_TOOL_RESULT_MARKER = b"tool_result"

_SAFE_SESSION_ID_RE = re.compile(r"^[A-Za-z0-9_-]+$")


def is_safe_session_id(text):
    """Mirrors SessionTranscriptReader.isSafeFileStem: only alnum/-/_, never
    empty — the session id comes straight off the dashboard's own state but
    is untrusted input to a path lookup, so this is the one gate standing
    between a query string and `../../etc/passwd`."""
    return bool(text) and bool(_SAFE_SESSION_ID_RE.match(text))


def is_plan_candidate(path):
    """Mirrors TranscriptTailScanner.isPlanCandidate."""
    if not path.startswith("/") or not path.lower().endswith(".md"):
        return False
    base = os.path.basename(path).lower()
    if base in _IGNORED_FILE_NAMES:
        return False
    return not any(path.startswith(p) for p in _IGNORED_PATH_PREFIXES)


# --------------------------------------------------------------------------
# Local disk — used when the row's machine is "local".
# --------------------------------------------------------------------------

def find_local_transcript(session_id, projects_root):
    """`<projectsRoot>/<any project folder>/<sessionId>.jsonl` — mirrors
    SessionTranscriptReader.transcriptURL (folder name is an unreliable
    flattened cwd, so every folder is searched). None if not found or the
    id fails is_safe_session_id."""
    if not is_safe_session_id(session_id):
        return None
    pattern = os.path.join(projects_root, "*", f"{session_id}.jsonl")
    matches = glob.glob(pattern)
    return matches[0] if matches else None


def read_local_tail(path, window_bytes):
    """(tail_bytes, chunk_starts_at_file_start, file_size) for one window,
    or None if the file cannot be read at all."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            starts_at_file_start = size <= window_bytes
            if not starts_at_file_start:
                fh.seek(size - window_bytes)
            data = fh.read()
        return data, starts_at_file_start, size
    except OSError:
        return None


# --------------------------------------------------------------------------
# Remote disk — one inline python3 script per call, run over the same ssh
# door as every other machine call in this server (chief_dashboard_herdr).
# The caller (chief-dashboard-server.py) owns running it; this module only
# builds the script text and parses the JSON it prints, so both are unit
# testable without ssh.
# --------------------------------------------------------------------------

def remote_tail_script(session_id, window_bytes):
    """A self-contained python3 script (run via
    chief_dashboard_herdr.remote_shell_text) that finds
    ~/.claude/projects/*/<sessionId>.jsonl on whatever machine it runs on
    and prints one JSON line: {"found": false} or {"found": true, "size":,
    "chunkStartsAtFileStart":, "tailB64": }. `session_id` is only ever
    embedded after is_safe_session_id has passed (callers must check first;
    this function does too, defensively, since a script string is as good
    as a shell command)."""
    if not is_safe_session_id(session_id):
        raise ValueError(f"unsafe session id: {session_id!r}")
    return f"""python3 - <<'PY'
import base64, glob, json, os
matches = glob.glob(os.path.expanduser("~/.claude/projects/*/{session_id}.jsonl"))
if not matches:
    print(json.dumps({{"found": False}}))
else:
    path = matches[0]
    size = os.path.getsize(path)
    window = {int(window_bytes)}
    starts_at_start = size <= window
    with open(path, "rb") as fh:
        if not starts_at_start:
            fh.seek(size - window)
        data = fh.read()
    print(json.dumps({{
        "found": True, "size": size,
        "chunkStartsAtFileStart": starts_at_start,
        "tailB64": base64.b64encode(data).decode("ascii"),
    }}))
PY
"""


def parse_remote_tail_reply(raw_stdout):
    """The script above's stdout -> (tail_bytes, chunk_starts_at_file_start)
    or None if not found / unparsable. Raises nothing: an unreadable reply
    is treated the same as "not found" by the caller."""
    try:
        payload = json.loads(raw_stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return None
    if not payload.get("found"):
        return None
    try:
        return (base64.b64decode(payload["tailB64"]),
                bool(payload["chunkStartsAtFileStart"]))
    except (KeyError, ValueError, TypeError):
        return None


# --------------------------------------------------------------------------
# Pure parsing — port of TranscriptTailScanner.scan.
# --------------------------------------------------------------------------

def scan_tail_for_latest_message(tail_bytes, chunk_starts_at_file_start):
    """Mirrors TranscriptTailScanner.scan. Returns
    {"latestMessage": str|None, "markdownPathCandidates": [str, ...]}."""
    lines = [l for l in tail_bytes.split(b"\n") if l]
    if not chunk_starts_at_file_start and lines:
        lines = lines[1:]  # first line of a mid-file chunk is cut short
    latest_message = None
    candidates = []
    for line in reversed(lines):
        if _ASSISTANT_MARKER not in line:
            continue
        blocks = _assistant_blocks(line)
        if blocks is None:
            continue
        for block in reversed(blocks):
            if latest_message is None:
                text = _message_text(block)
                if text is not None:
                    latest_message = text
            if len(candidates) < MAX_PLAN_CANDIDATES:
                path = _markdown_path(block)
                if path is not None and path not in candidates:
                    candidates.append(path)
    return {"latestMessage": latest_message, "markdownPathCandidates": candidates}


def _assistant_blocks(line):
    try:
        entry = json.loads(line)
    except ValueError:
        return None
    if not isinstance(entry, dict):
        return None
    if entry.get("type") != "assistant" or entry.get("isSidechain") is True:
        return None
    message = entry.get("message")
    if not isinstance(message, dict) or message.get("model") == "<synthetic>":
        return None
    content = message.get("content")
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    if isinstance(content, list):
        return [b for b in content if isinstance(b, dict)]
    return None


def _message_text(block):
    if block.get("type") != "text":
        return None
    text = block.get("text")
    if not isinstance(text, str):
        return None
    trimmed = text.strip()
    if not trimmed:
        return None
    if len(trimmed) > MAX_MESSAGE_LENGTH:
        return trimmed[:MAX_MESSAGE_LENGTH - 1] + "…"
    return trimmed


def _markdown_path(block):
    if block.get("type") != "tool_use" or block.get("name") not in _FILE_TOOLS:
        return None
    input_ = block.get("input")
    if not isinstance(input_, dict):
        return None
    path = input_.get("file_path")
    if not isinstance(path, str) or not is_plan_candidate(path):
        return None
    return path


# --------------------------------------------------------------------------
# Pure parsing — port of AskUserQuestionExtractor.find.
# --------------------------------------------------------------------------

PENDING = "pending"
SETTLED = "settled"
NOT_FOUND = "notFound"


def find_pending_question_form(tail_bytes, chunk_starts_at_file_start):
    """Mirrors AskUserQuestionExtractor.find. Returns (status, form) where
    status is PENDING/SETTLED/NOT_FOUND and form is the pending form dict
    (only when status is PENDING) or None."""
    lines = [l for l in tail_bytes.split(b"\n") if l]
    if not chunk_starts_at_file_start and lines:
        lines = lines[1:]
    for position in range(len(lines) - 1, -1, -1):
        line = lines[position]
        if _ASSISTANT_MARKER not in line or _ASK_USER_QUESTION_MARKER not in line:
            continue
        call = _ask_user_question_block(line)
        if call is None:
            continue
        tool_use_id = call.get("id")
        if not isinstance(tool_use_id, str):
            continue
        if _has_result(tool_use_id, lines[position + 1:]):
            return SETTLED, None
        form = _build_form(tool_use_id, call.get("input"))
        if form is None:
            return NOT_FOUND, None
        return PENDING, form
    return NOT_FOUND, None


def _ask_user_question_block(line):
    try:
        entry = json.loads(line)
    except ValueError:
        return None
    if not isinstance(entry, dict):
        return None
    if entry.get("type") != "assistant" or entry.get("isSidechain") is True:
        return None
    message = entry.get("message")
    if not isinstance(message, dict):
        return None
    content = message.get("content")
    if not isinstance(content, list):
        return None
    for block in reversed(content):
        if (isinstance(block, dict) and block.get("type") == "tool_use"
                and block.get("name") == "AskUserQuestion"):
            return block
    return None


def _has_result(tool_use_id, later_lines):
    needle = tool_use_id.encode("utf-8")
    return any(_TOOL_RESULT_MARKER in l and needle in l for l in later_lines)


def _build_form(tool_use_id, input_):
    if not isinstance(input_, dict):
        return None
    raw_questions = input_.get("questions")
    if not isinstance(raw_questions, list) or not raw_questions:
        return None
    questions = []
    for raw in raw_questions:
        if not isinstance(raw, dict):
            return None
        question = raw.get("question")
        if not isinstance(question, str) or not question.strip():
            return None
        raw_options = raw.get("options")
        if not isinstance(raw_options, list) or not raw_options:
            return None
        options = []
        for raw_option in raw_options:
            if not isinstance(raw_option, dict):
                return None
            label = raw_option.get("label")
            if not isinstance(label, str) or not label:
                return None
            description = raw_option.get("description")
            options.append({
                "label": label,
                "description": description if isinstance(description, str) else "",
            })
        questions.append({
            "header": raw.get("header") if isinstance(raw.get("header"), str) else "",
            "question": question,
            "isMultiSelect": bool(raw.get("multiSelect")),
            "options": options,
        })
    return {"toolUseId": tool_use_id, "questions": questions}


# --------------------------------------------------------------------------
# Window-growing orchestration — port of SessionTranscriptReader.context /
# .pendingQuestionForm's "try 256KB, then 1MB, then 4MB" loop. `read_window`
# is (window_bytes) -> (tail_bytes, chunk_starts_at_file_start) | None,
# supplied by the caller so the SAME loop logic serves both a local file
# read and a remote ssh round trip (see chief-dashboard-server.py).
# --------------------------------------------------------------------------

def latest_message_from_tail(read_window):
    """Mirrors SessionTranscriptReader.context(forSession:)'s message half.
    Returns the scan dict from the last window tried (or the empty scan if
    `read_window` returns None immediately, i.e. no transcript at all)."""
    scan = {"latestMessage": None, "markdownPathCandidates": []}
    for window in TAIL_WINDOW_BYTES:
        result = read_window(window)
        if result is None:
            break
        tail, starts_at_file_start = result
        scan = scan_tail_for_latest_message(tail, starts_at_file_start)
        if scan["latestMessage"] is not None or starts_at_file_start:
            break
    return scan


def pending_question_form_from_tail(read_window):
    """Mirrors SessionTranscriptReader.pendingQuestionForm. Returns the form
    dict, or None for "no pending form" (settled, not found, or unreadable)."""
    for window in TAIL_WINDOW_BYTES:
        result = read_window(window)
        if result is None:
            return None
        tail, starts_at_file_start = result
        status, form = find_pending_question_form(tail, starts_at_file_start)
        if status == PENDING:
            return form
        if status == SETTLED:
            return None
        if starts_at_file_start:
            return None
    return None


# --------------------------------------------------------------------------
# Plan file text — port of PlanFileReader, parameterised by "home" so a
# remote read can pass that machine's own home instead of this Mac's.
# --------------------------------------------------------------------------

def resolve_plan_file_url(path, home):
    """Mirrors PlanFileReader.resolvedURL. None if not a .md path this
    reader is willing to open (absolute or ~-relative only)."""
    if not path or not path.lower().endswith(".md"):
        return None
    stripped = path.strip()
    if stripped == "~" or stripped.startswith("~/"):
        rest = stripped[2:] if stripped.startswith("~/") else ""
        return os.path.join(home, rest) if rest else home
    if stripped.startswith("/"):
        return stripped
    return None


def read_local_plan_file(path, home=None):
    """Mirrors PlanFileReader.read for the local case. Returns
    {"status": "noPath"|"unreadable"|"text", "text":, "truncated":, "reason":}."""
    home = home or os.path.expanduser("~")
    trimmed = (path or "").strip()
    if not trimmed:
        return {"status": "noPath"}
    resolved = resolve_plan_file_url(trimmed, home)
    if resolved is None:
        return {"status": "unreadable",
                "reason": f"AgentBar only reads a plan file at an absolute or ~ "
                          f"path ending in .md ({trimmed})."}
    if not os.path.isfile(resolved):
        return {"status": "unreadable",
                "reason": f"{trimmed} was not found."}
    try:
        with open(resolved, "rb") as fh:
            data = fh.read(PLAN_FILE_MAX_BYTES + 1)
    except OSError:
        return {"status": "unreadable",
                "reason": f"The plan file could not be read: {trimmed}."}
    return _plan_text_from_bytes(data, trimmed)


def _plan_text_from_bytes(data, original_path):
    truncated = len(data) > PLAN_FILE_MAX_BYTES
    kept = data[:PLAN_FILE_MAX_BYTES] if truncated else data
    decoded = kept.decode("utf-8", errors="ignore")
    if not decoded.strip():
        return {"status": "unreadable", "reason": "The plan file is empty."}
    return {"status": "text", "text": decoded, "truncated": truncated}


def remote_plan_file_script(path):
    """Inline python3 script mirroring read_local_plan_file, run on the
    remote machine so `~` expands against THAT machine's home. `path` is
    embedded verbatim inside a single-quoted heredoc-safe repr — never
    interpreted by the remote shell (it never sees the raw text, only the
    python3 invocation's own literal source)."""
    return f"""python3 - <<'PY'
import base64, json, os
path = {path!r}
trimmed = (path or "").strip()
if not trimmed:
    print(json.dumps({{"status": "noPath"}}))
elif not trimmed.lower().endswith(".md"):
    print(json.dumps({{"status": "unreadable",
        "reason": "AgentBar only reads a plan file at an absolute or ~ path ending in .md (" + trimmed + ")."}}))
else:
    home = os.path.expanduser("~")
    if trimmed == "~" or trimmed.startswith("~/"):
        resolved = os.path.join(home, trimmed[2:]) if trimmed.startswith("~/") else home
    elif trimmed.startswith("/"):
        resolved = trimmed
    else:
        resolved = None
    if resolved is None:
        print(json.dumps({{"status": "unreadable",
            "reason": "AgentBar only reads a plan file at an absolute or ~ path ending in .md (" + trimmed + ")."}}))
    elif not os.path.isfile(resolved):
        print(json.dumps({{"status": "unreadable", "reason": trimmed + " was not found."}}))
    else:
        try:
            with open(resolved, "rb") as fh:
                data = fh.read({PLAN_FILE_MAX_BYTES} + 1)
        except OSError:
            print(json.dumps({{"status": "unreadable",
                "reason": "The plan file could not be read: " + trimmed + "."}}))
        else:
            print(json.dumps({{"dataB64": base64.b64encode(data).decode("ascii")}}))
PY
"""


def parse_remote_plan_file_reply(raw_stdout, original_path):
    """The script above's stdout -> the same shape read_local_plan_file
    returns. Unparsable output reads as unreadable, never as "empty"."""
    try:
        payload = json.loads(raw_stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {"status": "unreadable",
                "reason": f"The plan file could not be read: {original_path}."}
    if "dataB64" in payload:
        try:
            data = base64.b64decode(payload["dataB64"])
        except (ValueError, TypeError):
            return {"status": "unreadable",
                    "reason": f"The plan file could not be read: {original_path}."}
        return _plan_text_from_bytes(data, original_path)
    if payload.get("status") in ("noPath", "unreadable"):
        return payload
    return {"status": "unreadable",
            "reason": f"The plan file could not be read: {original_path}."}
