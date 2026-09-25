#!/usr/bin/env python3
"""Direct-run tests for Chief Dashboard v2 phase 5: question latency.

Part A: the pane-screen sweep is parallel (proved live, not here).
Part B: the AskUserQuestion hook preview — sidecar parsing, phantom-pane
exclusion, and the precedence rule (hook newer than the last sweep wins;
a newer screen read saying not-NEEDS_HUMAN drops the preview).

Pure functions + tmpdirs — no herdr, no panes, no network.
"""
import json
import os
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib"))

import chief_dashboard_feeds as feeds  # noqa: E402
import chief_dashboard_views as views  # noqa: E402

fails = []
NOW = time.time()


def check(label, got, want=True):
    ok = (got == want) if want is not True else bool(got)
    if not ok:
        fails.append(f"{label}: got {got!r}" + (f" want {want!r}" if want is not True else ""))
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def feed(data, *, broken=False, warming=False, age=1.0, dur=0.1,
         last_success=None):
    return {"name": "f", "refreshIntervalSec": 5,
            "lastSuccessTs": NOW - age if last_success is None else last_success,
            "lastAttemptTs": NOW, "lastDurationSec": dur, "ageSec": age,
            "broken": broken, "warming": warming, "error": None, "data": data}


def snap(*, hook=None, screen=None, screen_age=20.0, screen_usable=True):
    ps = feed(screen or {}, age=screen_age,
              last_success=None if screen_usable else False)
    if not screen_usable:
        ps["lastSuccessTs"] = None
        ps["ageSec"] = None
    return {
        "hookCache": feed(hook or {}),
        "herdr": feed({"agents": [], "tabs": []}),
        "paneScreen": ps,
        "paneTick": feed({}),
        "gitHealth": feed({}),
        "board": feed({}),
    }


HQ = {"ts": NOW - 2, "title": "Banner", "question": "Pick a color?",
      "multi": False, "options": [{"index": 1, "label": "Red"}]}


def agent(pane_id, *, screen_state="ACTIVE", hook_question=None,
          hook_state="working", since=600, label="worker"):
    return {
        "paneId": pane_id, "paneIdSanitized": pane_id.replace(":", "-"),
        "label": label, "cwd": "/x", "focused": False,
        "hookState": hook_state, "hookSinceSec": since, "herdrStatus": "idle",
        "disagree": False, "hasHookData": True, "orphanHook": False,
        "agentSession": None, "hookReason": None,
        "screenState": screen_state, "screenSignal": None,
        "screenQuestion": None, "hookQuestion": hook_question,
    }


print("== sidecar suffix exclusion ==")
check("pane file counts", feeds.is_pane_cache_file("w8-p43"))
check(".why skipped", not feeds.is_pane_cache_file("w8-p43.why"))
check(".question.json skipped (no phantom pane)",
      not feeds.is_pane_cache_file("w8-p43.question.json"))

print("== read_hook_question ==")
tmp = tempfile.mkdtemp()
old_dir = feeds.HOOK_CACHE_DIR
feeds.HOOK_CACHE_DIR = tmp
try:
    with open(os.path.join(tmp, "w8-p43.question.json"), "w") as f:
        json.dump({"ts": NOW - 2, "title": "Banner", "question": "Pick?",
                   "multi": True, "options": [{"index": 1, "label": "Red"},
                                              {"index": "x", "label": "Bad"},
                                              {"index": 3}]}, f)
    q = feeds.read_hook_question("w8-p43")
    check("parses", q and q["question"] == "Pick?" and q["multi"] is True)
    check("bad options dropped", [o["index"] for o in q["options"]], [1])
    with open(os.path.join(tmp, "w8-p44.question.json"), "w") as f:
        f.write("{not json")
    check("malformed reads as no preview", feeds.read_hook_question("w8-p44") is None)
    with open(os.path.join(tmp, "w8-p45.question.json"), "w") as f:
        json.dump({"ts": 1, "options": []}, f)
    check("empty reads as no preview", feeds.read_hook_question("w8-p45") is None)
    check("missing reads as no preview", feeds.read_hook_question("w8-px") is None)
finally:
    feeds.HOOK_CACHE_DIR = old_dir

print("== precedence: hook newer than the sweep ==")
rows = views.build_needs_you(
    snap(screen_age=20.0), [agent("w8:p1", hook_question=dict(HQ))])
qs = [r for r in rows if r["kind"] == "question"]
check("one question row", len(qs), 1)
check("no answerable copy", "question" not in qs[0])
check("preview attached", qs[0].get("questionPreview", {}).get("question"), "Pick a color?")
check("detail names it loading", "loading" in qs[0]["detail"])

print("== precedence: newer sweep saying ACTIVE drops the preview ==")
old_hq = dict(HQ, ts=NOW - 60)
rows = views.build_needs_you(
    snap(screen_age=5.0), [agent("w8:p1", screen_state="ACTIVE",
                                 hook_question=old_hq, hook_state="idle",
                                 since=999)])
check("no question row", [r for r in rows if r["kind"] == "question"], [])

print("== screen-parsed copy wins when present ==")
screen_q = {"title": "T", "question": "Q?", "multi": False, "options": [],
            "cursorIndex": 1, "otherIndex": None, "hasSubmit": False}
a = agent("w8:p1", screen_state="NEEDS_HUMAN", hook_question=dict(HQ))
a["screenQuestion"] = screen_q
a["screenSignal"] = "pick one"
rows = views.build_needs_you(snap(screen_age=20.0), [a])
qs = [r for r in rows if r["kind"] == "question"]
check("one question row", len(qs), 1)
check("answerable copy present", qs[0].get("question"), screen_q)
check("no preview alongside", "questionPreview" not in qs[0])

print("== screen never succeeded: preview still shows (fail open) ==")
rows = views.build_needs_you(snap(screen_usable=False),
                             [agent("w8:p1", hook_question=dict(HQ))])
check("preview shown", any(r["kind"] == "question" and "questionPreview" in r
                           for r in rows))

print("== hook script: ask/clear/release ==")
repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
script = os.path.join(repo_root, "chief-question-hook.sh")
tmp2 = tempfile.mkdtemp()
env = dict(os.environ, TMPDIR=tmp2, HERDR_PANE_ID="w8:p7")
payload = json.dumps({"tool_name": "AskUserQuestion",
                      "tool_input": {"questions": [
                          {"question": "Pick?", "header": "H",
                           "multiSelect": True,
                           "options": [{"label": "A", "description": "First"},
                                       {"label": "B"}]}]}})
p = subprocess.run(["bash", script, "ask"], input=payload, capture_output=True,
                   text=True, timeout=20, env=env)
check("ask exits 0", p.returncode, 0)
sidecar = os.path.join(tmp2, "delivery-ops-herdr", "w8-p7.question.json")
d = json.load(open(sidecar))
check("sidecar shape", (d["question"], d["title"], d["multi"],
                        [(o["label"], o.get("description", "")) for o in d["options"]]),
      ("Pick?", "H", True, [("A", "First"), ("B", "")]))
open(os.path.join(tmp2, "delivery-ops-herdr", "w8-p7.why"), "w").write("r")
p = subprocess.run(["bash", script, "clear"], input="{}", capture_output=True,
                   text=True, timeout=20, env=env)
check("clear exits 0 + removes sidecar", p.returncode == 0
      and not os.path.exists(sidecar))
p = subprocess.run(["bash", script, "ask"], input=payload, capture_output=True,
                   text=True, timeout=20, env=env)
p = subprocess.run(["bash", script, "release"], input="{}", capture_output=True,
                   text=True, timeout=20, env=env)
left = os.listdir(os.path.join(tmp2, "delivery-ops-herdr"))
check("release drops both sidecars", left, [])

print()
if fails:
    print(f"{len(fails)} FAILURES")
    sys.exit(1)
print("all phase-5 checks pass")
