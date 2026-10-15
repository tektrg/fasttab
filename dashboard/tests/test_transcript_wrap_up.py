#!/usr/bin/env python3
"""Direct-run tests for Claude Desktop's end-of-turn wrap_up question:
transcript_wrap_up.find_pending_wrap_up, the reader annotation of `idle`
sessions, and its wiring into build_status_only_rows / build_needs_you."""
import json
import os
import sys
import tempfile

LIB = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib")
sys.path.insert(0, LIB)

import chief_dashboard_views as views  # noqa: E402
import claude_sessions  # noqa: E402
import session_inbox  # noqa: E402
import transcript_pending_question as pending  # noqa: E402
import transcript_wrap_up as wrap_up  # noqa: E402

fails = []
NOW = 1_790_433_800.0


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


ACTIONS = [{"label": "Start slice 1", "message": "Start DATA-314 slice 1 now."},
           {"label": "Adjust plan first"},
           {"label": "Commit", "action": "commit"}]


def assistant(*blocks, **extra):
    return json.dumps({"type": "assistant", "message": {"content": list(blocks)}, **extra})


def wrap_up_line(ask="Start building DATA-314 with slice 1?", actions=ACTIONS):
    tool_input = {"recap": "Plan is ready."}
    if ask is not None:
        tool_input["ask"] = ask
    tool_input["actions"] = actions
    return assistant({"type": "tool_use", "id": "toolu_w", "name": wrap_up.TOOL_NAME, "input": tool_input})


def user(content, **extra):
    return json.dumps({"type": "user", "message": {"content": content}, **extra})


TOOL_RESULT = user([{"type": "tool_result", "tool_use_id": "toolu_w", "content": "Shown"}])
CLOSING_TEXT = assistant({"type": "text", "text": "I filed the ticket."})
QUESTION = {"ask": "Start building DATA-314 with slice 1?", "recap": "Plan is ready.",
            "actions": [{"label": "Start slice 1", "message": "Start DATA-314 slice 1 now."},
                        {"label": "Adjust plan first", "message": "Adjust plan first"}]}


def find(lines, starts=True):
    return wrap_up.find_pending_wrap_up(("\n".join(lines) + "\n").encode(), starts)


print("== find_pending_wrap_up ==")
check("ask present -> pending (closing text after it does not settle)",
      find([user("go"), wrap_up_line(), TOOL_RESULT, CLOSING_TEXT, json.dumps({"type": "system"})]), QUESTION)
check("ask absent -> None (a recap only)", find([wrap_up_line(ask=None), TOOL_RESULT]), None)
check("user replied after -> None", find([wrap_up_line(), TOOL_RESULT, user("Start DATA-314 slice 1 now.")]), None)
check("user replied with text blocks -> None",
      find([wrap_up_line(), TOOL_RESULT, user([{"type": "text", "text": "ok"}])]), None)
check("isMeta user line does not settle", find([wrap_up_line(), user("caveat", isMeta=True)]), QUESTION)
check("new turn tool_use after -> None",
      find([wrap_up_line(), TOOL_RESULT, assistant({"type": "tool_use", "id": "t2", "name": "Bash", "input": {}})]), None)
check("newer wrap_up without ask wins -> None", find([wrap_up_line(), TOOL_RESULT, wrap_up_line(ask=None)]), None)
check("actions without message use the label",
      find([wrap_up_line(actions=[{"label": "Yes"}])])["actions"], [{"label": "Yes", "message": "Yes"}])
check("only app actions -> None", find([wrap_up_line(actions=[{"label": "Commit", "action": "commit"}])]), None)
check("sidechain wrap_up ignored", find([assistant({"type": "tool_use", "id": "x", "name": wrap_up.TOOL_NAME,
                                                    "input": {"ask": "?", "actions": [{"label": "a"}]}},
                                                   isSidechain=True)]), None)
check("first line of a mid-file chunk is skipped", find([wrap_up_line()], starts=False), None)
check("no wrap_up -> None", find([user("hi"), CLOSING_TEXT]), None)


def write_transcript(root, session_id, lines):
    os.makedirs(os.path.join(root, "-Users-x-demo"), exist_ok=True)
    with open(os.path.join(root, "-Users-x-demo", f"{session_id}.jsonl"), "w") as f:
        f.write("\n".join(lines) + "\n")


def session(session_id, status):
    return {"pid": 7, "sessionId": session_id, "cwd": "/Users/x/demo", "kind": "interactive",
            "entrypoint": "claude-desktop", "status": status, "statusUpdatedAt": int((NOW - 5) * 1000),
            "messagingSocketPath": "/tmp/x.sock", "peerProtocol": 1}


print("== reader annotates idle sessions ==")
with tempfile.TemporaryDirectory() as root:
    reader = pending.PendingQuestionReader(projects_root=root)
    write_transcript(root, "s-w", [wrap_up_line(), TOOL_RESULT])
    idle, busy = session("s-w", "idle"), session("s-w", "busy")
    reader.annotate([idle, busy])
    check("idle session gets wrapUpQuestion", idle.get("wrapUpQuestion"), QUESTION)
    check("busy session gets nothing", "wrapUpQuestion" in busy, False)
    write_transcript(root, "s-w", [wrap_up_line(), TOOL_RESULT, user("done")])
    check("transcript change re-read -> None", reader.wrap_up_for("s-w"), None)
annotated = {**session("s-w", "idle"), "wrapUpQuestion": QUESTION}

print("== rows + needsYou ==")
rows = claude_sessions.build_status_only_rows([annotated], set(), NOW, machine="local")
check("row carries wrapUpQuestion", rows[0]["wrapUpQuestion"], QUESTION)
check("row stays idle (inbox message allowed)", (rows[0]["hookState"], session_inbox.pending_prompt(rows[0])),
      ("idle", False))
rows = claude_sessions.build_status_only_rows([{**annotated, "status": "busy"}], set(), NOW, machine="local")
check("not idle -> stale annotation ignored", rows[0]["wrapUpQuestion"], None)


def feed(data):
    return {"broken": False, "warming": False, "error": None,
            "lastSuccessTs": 1.0, "ageSec": 0, "lastDurationSec": 0, "data": data}


snap = {n: feed(None) for n in ("hookCache", "paneTick", "board")}
snap["hookCache"]["data"] = {}
snap["herdr"] = feed({"agents": [], "tabs": []})
snap["paneScreen"] = feed({})
snap["claudeSessions"] = feed([annotated])
needs = views.build_needs_you(snap, views.build_agents_view(snap))
check("needsYou entry: blocked, detail = ask, carries the question",
      [(n["kind"], n["identity"], n["detail"], n.get("wrapUpQuestion")) for n in needs],
      [("blocked", "s-w", QUESTION["ask"], QUESTION)])
snap["claudeSessions"] = feed([{**annotated, "wrapUpQuestion": None}])
check("no question -> no needsYou entry", views.build_needs_you(snap, views.build_agents_view(snap)), [])

print()
if fails:
    print(f"FAIL: {len(fails)} failure(s)")
    for f in fails:
        print("  - " + f)
    sys.exit(1)
print("PASS: all wrap_up question checks")
