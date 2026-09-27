#!/usr/bin/env python3
"""Direct-run tests for the read-only question fallback: a `waiting`
status-only session with no hookRequest shows its pending AskUserQuestion
from the transcript tail (transcript_pending_question.py + its wiring in
claude_sessions.build_status_only_rows and build_needs_you)."""
import json
import os
import sys
import tempfile

LIB = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib")
sys.path.insert(0, LIB)

import chief_dashboard_views as views  # noqa: E402
import claude_sessions  # noqa: E402
import transcript_pending_question as pending  # noqa: E402

fails = []
NOW = 1_790_433_800.0


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


QUESTION = {"question": "Build the push server?", "header": "Live refresh", "multiSelect": False,
            "options": [{"label": "Yes", "description": "recommended"}, {"label": "No", "description": ""}]}


def ask_line(tool_use_id, questions=(QUESTION,)):
    return json.dumps({"type": "assistant", "message": {"content": [
        {"type": "tool_use", "id": tool_use_id, "name": "AskUserQuestion",
         "input": {"questions": list(questions)}}]}})


def result_line(tool_use_id):
    return json.dumps({"type": "user", "message": {"content": [
        {"type": "tool_result", "tool_use_id": tool_use_id, "content": "answered"}]}})


def write_transcript(root, session_id, lines, folder="-Users-x-demo"):
    os.makedirs(os.path.join(root, folder), exist_ok=True)
    path = os.path.join(root, folder, f"{session_id}.jsonl")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    return path


def waiting(session_id, **extra):
    entry = {"pid": 7, "sessionId": session_id, "cwd": "/Users/x/demo", "kind": "interactive",
             "entrypoint": "claude-desktop", "status": "waiting", "statusUpdatedAt": int((NOW - 5) * 1000)}
    entry.update(extra)
    return entry


EXCERPT = {"header": "Live refresh", "question": "Build the push server?", "questionCount": 1}

print("== reader: pending question from the transcript tail ==")
with tempfile.TemporaryDirectory() as root:
    reader = pending.PendingQuestionReader(projects_root=root)
    write_transcript(root, "pending-1", [json.dumps({"type": "user", "message": {"content": "hi"}}),
                                         ask_line("toolu_a")])
    check("pending question -> excerpt", reader.excerpt_for("pending-1"), EXCERPT)
    write_transcript(root, "answered-2", [ask_line("toolu_b"), result_line("toolu_b")])
    check("answered question -> None", reader.excerpt_for("answered-2"), None)
    check("no transcript -> None", reader.excerpt_for("missing-3"), None)
    check("unsafe session id -> None", reader.excerpt_for("../etc"), None)
    write_transcript(root, "two-4", [ask_line("toolu_c", (QUESTION, {**QUESTION, "question": "And?"}))])
    check("several questions -> first + count", reader.excerpt_for("two-4")["questionCount"], 2)

    # Tail only: the question sits after far more than one window of history.
    big = write_transcript(root, "big-5", [json.dumps({"type": "user", "message": {"content": "x" * 1000}})] * 600
                           + [ask_line("toolu_d")])
    check("fixture is larger than the tail window", os.path.getsize(big) > pending.TAIL_BYTES, True)
    check("question at the end of a big file is found", reader.excerpt_for("big-5"), EXCERPT)
    small_reader = pending.PendingQuestionReader(projects_root=root, tail_bytes=64)
    check("reads at most tail_bytes", len(pending.read_regular_tail(big, 64)[0]), 64)
    check("a window too small for the line -> None, not a crash", small_reader.excerpt_for("big-5"), None)

    # Symlinks / non-regular files are never read.
    target = write_transcript(root, "real-6", [ask_line("toolu_e")], folder="elsewhere")
    os.makedirs(os.path.join(root, "linked"), exist_ok=True)
    os.symlink(target, os.path.join(root, "linked", "link-7.jsonl"))
    check("symlinked transcript -> None", reader.excerpt_for("link-7"), None)
    os.makedirs(os.path.join(root, "dirs", "dir-8.jsonl"))
    check("a directory named like a transcript -> None", reader.excerpt_for("dir-8"), None)

    # Cache: unchanged file is not re-read; a change is picked up.
    reads = []
    original_read = pending.read_regular_tail
    pending.read_regular_tail = lambda path, n: reads.append(path) or original_read(path, n)
    reader.excerpt_for("pending-1")
    check("unchanged transcript -> served from cache", reads, [])
    path = write_transcript(root, "pending-1", [ask_line("toolu_a"), result_line("toolu_a")])
    os.utime(path, ns=(1, 1))  # a different mtime even within one clock tick
    check("answered since -> None", reader.excerpt_for("pending-1"), None)
    check("... after one re-read", len(reads), 1)
    pending.read_regular_tail = original_read

    print("== annotate: waiting sessions only ==")
    write_transcript(root, "pending-9", [ask_line("toolu_f")])
    sessions = [waiting("pending-9"), waiting("busy-10", status="busy")]
    write_transcript(root, "busy-10", [ask_line("toolu_g")])
    reader.annotate(sessions)
    check("waiting session annotated", sessions[0].get(pending.FIELD_NAME), EXCERPT)
    check("busy session left alone", pending.FIELD_NAME in sessions[1], False)
    reader.annotate([waiting("pending-9")])
    check("closed sessions are forgotten", sorted(reader._path_by_session), ["pending-9"])

print("== rows + needsYou carry it, never next to a hookRequest ==")
annotated = waiting("s-q", transcriptQuestion=EXCERPT)
rows = claude_sessions.build_status_only_rows([annotated], set(), NOW, machine="local")
check("waiting row carries transcriptQuestion", rows[0]["transcriptQuestion"], EXCERPT)
check("row stays generic blocked", (rows[0]["hookState"], rows[0]["hookReason"]), ("blocked", "Input needed"))
hook_view = {"requestId": "hp1-ab", "kind": "question", "toolName": "AskUserQuestion", "sinceSec": 1.0}
rows = claude_sessions.build_status_only_rows([annotated], set(), NOW, machine="local",
                                              hook_requests={"s-q": hook_view})
check("hookRequest present -> no transcriptQuestion", rows[0]["transcriptQuestion"], None)
rows = claude_sessions.build_status_only_rows([{**annotated, "status": "busy"}], set(), NOW, machine="local")
check("no longer waiting -> no transcriptQuestion (stale annotation ignored)", rows[0]["transcriptQuestion"], None)


def feed(data):
    return {"broken": False, "warming": False, "error": None,
            "lastSuccessTs": 1.0, "ageSec": 0, "lastDurationSec": 0, "data": data}


snap = {n: feed(None) for n in ("hookCache", "paneTick", "board")}
snap["hookCache"]["data"] = {}
snap["herdr"] = feed({"agents": [], "tabs": []})
snap["paneScreen"] = feed({})
snap["claudeSessions"] = feed([annotated])
needs = views.build_needs_you(snap, views.build_agents_view(snap))
check("needsYou entry carries it", [(n["identity"], n.get("transcriptQuestion")) for n in needs],
      [("s-q", EXCERPT)])

print()
if fails:
    print(f"FAIL: {len(fails)} failure(s)")
    for f in fails:
        print("  - " + f)
    sys.exit(1)
print("PASS: all transcript pending-question checks")
