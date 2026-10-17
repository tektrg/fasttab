#!/usr/bin/env python3
"""Feedback new-dot seen store (server/lib/feedback_seen.py). Temp state dir only."""
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ["CHIEF_DASHBOARD_STATE_HOME"] = tempfile.mkdtemp(prefix="feedback-seen-test-")
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "server", "lib"))
import feedback_seen as seen  # noqa: E402

fails = []
A = "0f8fad5b-d9cb-469f-a165-70867728950e"


def check(label, got, want):
    print(("PASS " if got == want else "FAIL ") + label + ("" if got == want else f": got {got!r} want {want!r}"))
    if got != want:
        fails.append(label)


check("empty store", seen.handle_get(seen.PATH), ({"ok": True, "seen": {}}, 200))
check("other path ignored", seen.handle_get("/api/feedback/threads"), None)
check("post other path ignored", seen.handle_post("/api/x", lambda: {}), None)
reply, status = seen.handle_post(seen.PATH, lambda: {"seen": {A.upper(): 100}})
check("merge stores lowercased", (reply["seen"], status), ({A: 100}, 200))
seen.handle_post(seen.PATH, lambda: {"seen": {A: 50}})
check("older value never lowers seen", seen.load(), {A: 100})
seen.handle_post(seen.PATH, lambda: {"seen": {A: 200}})
check("newer value raises seen", seen.load(), {A: 200})
check("persisted to file", json.load(open(os.path.join(os.environ["CHIEF_DASHBOARD_STATE_HOME"], seen.FILE_NAME))), {A: 200})
for label, body in (("bad id", {"seen": {"../x": 1}}), ("bool value", {"seen": {A: True}}), ("not object", {"seen": [A]}), ("no seen", {})):
    check("refuses " + label, seen.handle_post(seen.PATH, lambda b=body: b)[1], 400)


def bad_json():
    raise ValueError("bad json")


check("refuses bad json", seen.handle_post(seen.PATH, bad_json)[1], 400)
check("store unchanged after refusals", seen.load(), {A: 200})
sys.exit(1 if fails else 0)
