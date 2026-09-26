#!/usr/bin/env python3
"""Prove the chief dashboard's NEEDS YOU list.

WHAT THE LIST IS (PO ruling 2026-09-06)
---------------------------------------
ONE question: which pane is STOPPED, waiting for me to type? Exactly two
things qualify — an open AskUserQuestion picker, and a permission request —
plus `feed-broken`, which is the list saying it cannot see rather than a
worker at all.

WHY IT KEEPS SHRINKING
----------------------
Every version has failed the same way: by listing things that are TRUE but not
ACTIONABLE, until the human stops reading.

  * 2026-09-03 — 27 rows, 100% false: 17 cache-residue files from sessions
    dead up to five days, 10 live panes whose turn had simply finished.
  * 2026-09-06 — 12 rows, of which 10 were `done`: workers that had finished
    with nothing owed. Ranking them below the real blocks was not enough; a
    pile is a pile. They moved to the BOARD, which shows every session with
    its last line.

So the assertions below come in two halves: the rules that keep a real block
visible, and — just as load-bearing — the rules that keep everything else OUT.

Pure functions, synthetic snapshots — no herdr, no panes, no network.
"""
import os
import sys
import time

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib"))

import chief_dashboard_views as views  # noqa: E402

NOW = time.time()
fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def feed(data, *, broken=False, warming=False, err=None, age=1.0):
    return {"name": "f", "refreshIntervalSec": 5, "lastSuccessTs": NOW - age,
            "lastAttemptTs": NOW, "lastDurationSec": 0.1, "ageSec": age,
            "broken": broken, "warming": warming, "error": err, "data": data}


def snap(*, hook=None, herdr=None, screen=None, pane_tick=None, board=None):
    return {
        "hookCache": feed(hook or {}),
        "herdr": feed(herdr or {"agents": [], "tabs": []}),
        "paneScreen": feed(screen or {}),
        "paneTick": feed(pane_tick or {}),
        "board": feed(board if board is not None else {}),
    }


def agent(pane_id, *, hook_state=None, since=600, screen_state=None,
          signal=None, focused=False, orphan=False, label="worker",
          session=None, reason=None, question=None, hook_question=None,
          herdr_status="idle", disagree=False, residue=False):
    return {
        "paneId": None if orphan else pane_id,
        "paneIdSanitized": pane_id.replace(":", "-"),
        "label": label, "cwd": "/x", "focused": focused,
        "hookState": hook_state, "hookSinceSec": since, "herdrStatus": herdr_status,
        "disagree": disagree, "hasHookData": hook_state is not None,
        "orphanHook": orphan, "residue": residue,
        "agentSession": session, "hookReason": reason,
        "screenState": screen_state, "screenSignal": signal,
        # The sweep's PARSED picker (answerable) vs the hook's raw preview
        # (display-only, arrives first). Different sources, different rows.
        "screenQuestion": question, "hookQuestion": hook_question,
    }


def kinds(rows):
    return [r["kind"] for r in rows]


print("THE ONE QUESTION: is a pane stopped, waiting for a keystroke?")

rows = views.build_needs_you(snap(), [
    agent("w8:p2Q", hook_state="blocked", screen_state="NEEDS_HUMAN",
          reason="Claude needs your permission to use Bash", since=90)])
check("a permission prompt is a row", kinds(rows), ["blocked"])
check("and it shows the prompt, not the vendor's generic copy",
      rows[0]["detail"], "Claude needs your permission to use Bash")

rows = views.build_needs_you(snap(), [
    agent("w8:p8", hook_state="working", screen_state="NEEDS_HUMAN",
          signal="1. release/v1.0.6", since=120,
          question={"title": "Which branch?", "question": "pick one",
                    "multi": False, "options": [{"index": 1, "label": "a"}]})])
check("an open AskUserQuestion picker is its own kind, answerable inline",
      kinds(rows), ["question"])
check("...and carries the parsed block the answer buttons need",
      rows[0]["question"]["title"], "Which branch?")

rows = views.build_needs_you(snap(), [
    agent("w8:p8", hook_state="working", screen_state="NEEDS_HUMAN",
          signal="1. release/v1.0.6", since=120,
          reason="Claude needs your permission to use Bash")])
check("a NEEDS_HUMAN with no parsed block stays BLOCKED, terminal-only",
      kinds(rows), ["blocked"])
check("and the screen line beats the hook's generic copy",
      rows[0]["detail"], "1. release/v1.0.6")

check("the focused pane is NOT exempt — a prompt is a prompt",
      kinds(views.build_needs_you(snap(), [
          agent("w8:p2Q", hook_state="blocked", screen_state="NEEDS_HUMAN",
                focused=True, since=90)])), ["blocked"])

rows = views.build_needs_you(snap(), [
    agent("w8:pL", hook_state="idle", screen_state="NEEDS_LOGIN",
          signal="Not logged in · Run /login", since=300)])
check("a logged-out session IS a row (nobody would ever be told otherwise)",
      kinds(rows), ["blocked"])
check("...and it tells the human what to do",
      "/login" in (rows[0]["detail"] if rows else ""), True)
check("...with no permission box to answer (terminal-only)",
      rows[0].get("permission") if rows else "x", None)
check("a worker parked on its own monitor is NOT a row (not stopped at a prompt)",
      kinds(views.build_needs_you(snap(), [
          agent("w8:pM", hook_state="working", screen_state="WAITING_ON_BACKGROUND",
                signal="1 monitor still running")])), [])

print("\nWHAT NO LONGER REACHES THIS LIST (PO ruling 2026-09-06).")
print("Each of these was a rank of its own before. All real, none STOPPED at a")
print("prompt — so all of them live in the BOARD now, with their last line:")

check("a worker that FINISHED is not a row (this was 10 of 12 rows live)",
      kinds(views.build_needs_you(snap(), [
          agent("w8:pA", hook_state="idle", screen_state="WAITING",
                signal="All seven commits are pushed and proven.")])), [])
check("...even when its last line asks the human something outright",
      kinds(views.build_needs_you(snap(), [
          agent("w8:pB", hook_state="idle", screen_state="WAITING",
                signal="Next action is yours: say the word and I will commit.")
      ])), [])
check("...even after 47 hours of nobody acting on it",
      kinds(views.build_needs_you(snap(), [
          agent("w8:pD", hook_state="idle", screen_state="WAITING",
                since=47 * 3600, signal="parked pending your call")])), [])
check("a turn killed by an API error is not a row — nothing is waiting to be typed",
      kinds(views.build_needs_you(snap(), [
          agent("w8:p3A", hook_state="idle", screen_state="CRASHED",
                signal="API Error: overloaded_error")])), [])
check("a worker that died mid-turn is not a row — a dead pane takes no keystroke",
      kinds(views.build_needs_you(snap(), [
          agent("w8:pX", hook_state="working", since=3600, orphan=True)])), [])
check("a working pane is never a row at all",
      kinds(views.build_needs_you(snap(), [
          agent("w8:p2R", hook_state="working", screen_state="ACTIVE")])), [])

# The pane-tick heartbeat's own verdicts are a different instrument: a
# judgement about progress, not a reading of the screen. None of them mean a
# prompt is up, so none of them belong here any more.
tick = {"agents": [
    {"agentId": "s1", "verdict": "stalled", "name": "w1",
     "why": "no output, work due", "silenceSeconds": 1800},
    {"agentId": "s2", "verdict": "dropped", "name": "w2",
     "why": "owed progress, gone", "silenceSeconds": 1200},
    {"agentId": "s3", "verdict": "needs-human", "name": "w3",
     "why": "watchdog thinks you are needed", "silenceSeconds": 900},
], "chiefTrouble": {"verdict": "stalled", "why": "the chief itself is quiet"},
    "chiefPaneId": "w8:pChief"}
check("no heartbeat verdict is a row — stalled, dropped, needs-human, nor the "
      "chief's own trouble", kinds(views.build_needs_you(snap(pane_tick=tick), [])),
      [])

print("\nRESIDUE IS STILL NEVER A ROW (the 27-false-row bug, rule 1):")
rows = views.build_needs_you(snap(), [
    agent("w8:pE", hook_state="blocked", since=5 * 86400, orphan=True),
    agent("w1:p41", hook_state="idle", since=4 * 86400, orphan=True),
])
check("a dead session's leftover 'blocked' file is not a row", kinds(rows), [])

print("\nTHE SELF-ALARM STILL OUTRANKS EVERYTHING (plan.md: non-negotiable).")
print("Without it an empty page would read 'nothing needs you' while blind:")
s = snap()
s["board"] = feed(None, broken=True, err="poll crashed", age=900)
rows = views.build_needs_you(s, [
    agent("w8:p1", hook_state="blocked", screen_state="NEEDS_HUMAN")])
check("a broken feed sorts above even a real block", kinds(rows),
      ["feed-broken", "blocked"])
s = snap()
s["paneTick"] = feed(None, broken=True, warming=True, err="no successful poll yet")
check("a feed still warming up on a cold start raises no alarm",
      kinds(views.build_needs_you(s, [])), [])

print("\nFAIL-OPEN, BUT NOT INTO NOISE:")
check("a pushed 'blocked' whose ONE pane could not be read is still shown",
      kinds(views.build_needs_you(snap(), [
          agent("w8:p7", hook_state="blocked", screen_state=None, since=300)])),
      ["blocked"])

s2 = snap()
s2["paneScreen"] = {"name": "paneScreen", "refreshIntervalSec": 45,
                    "lastSuccessTs": None, "lastAttemptTs": NOW,
                    "lastDurationSec": 0.1, "ageSec": None, "broken": True,
                    "warming": False, "error": "herdr unreachable", "data": None}
rows = views.build_needs_you(s2, [
    agent("w8:p7", hook_state="blocked", screen_state=None, since=300),
    agent("w8:p8", hook_state="blocked", screen_state=None, since=400)])
check("but when NO pane can be read, stale 'blocked' does not flood the list",
      kinds(rows), ["feed-broken"])

print("\nA SCREEN READING IS ONLY WORTH WHAT ITS AGE ALLOWS:")
# The permission notifier fires ~6s after a prompt appears; the screen feed
# refreshes every 45s. A reading taken BEFORE the block began must not veto it.
s3 = snap(screen={"w8-p7": {"state": "ACTIVE", "signal": "running"}})
s3["paneScreen"]["ageSec"] = 40.0
check("a 40s-old 'ACTIVE' cannot veto a 6s-old block",
      kinds(views.build_needs_you(s3, [
          agent("w8:p7", hook_state="blocked", screen_state="ACTIVE",
                signal="running", since=6,
                reason="Claude needs your permission to use Bash")])),
      ["blocked"])

s4 = snap(screen={"w8-p7": {"state": "WAITING", "signal": "done"}})
s4["paneScreen"]["ageSec"] = 5.0
check("but a 5s-old 'WAITING' does overrule an hour-old block — and now that "
      "drops the row entirely, it does not demote it",
      kinds(views.build_needs_you(s4, [
          agent("w8:p7", hook_state="blocked", screen_state="WAITING",
                signal="done", since=3600)])), [])

s4b = snap(screen={"w8-p7": {"state": "WAITING_ON_BACKGROUND", "signal": "1 monitor"}})
s4b["paneScreen"]["ageSec"] = 5.0
check("a 5s-old 'WAITING_ON_BACKGROUND' (parked on a monitor) also overrules "
      "an hour-old block: nothing is drawn for a person to answer",
      kinds(views.build_needs_you(s4b, [
          agent("w8:p7", hook_state="blocked", screen_state="WAITING_ON_BACKGROUND",
                signal="1 monitor", since=3600)])), [])

slow = snap(screen={"w8-pI": {"state": "WAITING", "signal": "done"}})
slow["paneScreen"]["ageSec"] = 20.0
slow["paneScreen"]["lastDurationSec"] = 40.0   # a degraded herdr: 60s worst case
check("a 30s-old block outranks a reading that COULD be 60s old",
      kinds(views.build_needs_you(slow, [
          agent("w8:pI", hook_state="blocked", screen_state="WAITING", since=30,
                reason="Claude needs your permission to use Bash")])),
      ["blocked"])

print("\nTHE JUST-OPENED PICKER: the hook sees it before the sweep does.")
fresh_preview = {"ts": NOW - 1, "title": "Ship it?", "question": "merge now?",
                 "multi": False, "options": [{"index": 1, "label": "yes"}]}
s6 = snap(screen={"w8-pP": {"state": "ACTIVE", "signal": "working"}})
s6["paneScreen"]["ageSec"] = 30.0
rows = views.build_needs_you(s6, [
    agent("w8:pP", hook_state="working", screen_state="ACTIVE",
          signal="working", since=30, hook_question=fresh_preview)])
check("a picker opened AFTER the last sweep is listed now, from the hook",
      kinds(rows), ["question"])
check("...as a PREVIEW with no parsed block, so nothing is answerable yet",
      (rows[0].get("question"), rows[0]["questionPreview"]["title"]),
      (None, "Ship it?"))
stale_preview = dict(fresh_preview, ts=NOW - 300)
check("but a preview the sweep has since read past is retired",
      kinds(views.build_needs_you(s6, [
          agent("w8:pP", hook_state="working", screen_state="ACTIVE",
                signal="working", since=30, hook_question=stale_preview)])), [])

print("\nONE PANE, ONE ROW:")
rows = views.build_needs_you(snap(), [
    agent("w8:pP", hook_state="blocked", screen_state="NEEDS_HUMAN", since=120,
          hook_question=fresh_preview,
          question={"title": "Ship it?", "question": "merge now?",
                    "multi": False, "options": [{"index": 1, "label": "yes"}]})])
check("a picker both parsed and previewed is one row, the answerable one",
      (len(rows), rows[0]["kind"], rows[0]["question"] is not None),
      (1, "question", True))

print("\nWITHHOLDING JUDGEMENT WHEN A FEED CANNOT SUPPORT IT:")
s5 = snap()
s5["herdr"] = {"name": "herdr", "refreshIntervalSec": 5, "lastSuccessTs": None,
               "lastAttemptTs": NOW, "lastDurationSec": 0.1, "ageSec": None,
               "broken": True, "warming": False, "error": "herdr down",
               "data": None}
HOOK_ONLY = {"w8-p9": {"seq": NOW - 300, "state": "blocked", "reason": None}}
check("a pane herdr no longer lists IS residue while herdr is healthy",
      [a["residue"] for a in views.build_agents_view(snap(hook=HOOK_ONLY))],
      [True])
check("but with herdr never up, that same pane is NOT written off as residue "
      "— every pane would look orphaned and every real block would vanish",
      [a["residue"] for a in views.build_agents_view(
          {**s5, "hookCache": feed(HOOK_ONLY)})],
      [False])

print("\nA PARKED PANE'S 2h CEILING REACHES THE UI ROW:")
PARKED_HERDR = {"agents": [{"pane_id": "w8:p9", "tab_id": "t", "agent_status": "idle"}],
                "tabs": [{"tab_id": "t", "label": "w"}]}
def parked_row(hook_age_sec):
    rows = views.build_agents_view(snap(
        hook={"w8-p9": {"seq": NOW - hook_age_sec, "state": "idle", "reason": None}},
        herdr=PARKED_HERDR,
        screen={"w8-p9": {"state": "WAITING_ON_BACKGROUND", "signal": "1 monitor"}}))
    return rows[0]
check("parked 30 min: not expired", parked_row(1800)["backgroundWaitExpired"], False)
check("parked 2h05m: expired (the UI stops painting it green)",
      parked_row(7500)["backgroundWaitExpired"], True)

print("\nTHE ROWS CARRY ONLY THE THREE KINDS:")
check("URGENCY has no rank left for anything else",
      sorted(views.URGENCY), ["blocked", "feed-broken", "question"])

# P0 dashboard move: the "CHIEF_PASS (v5 Phase 2)" section (build_chief_pass —
# feed health + tick pacing + toolbox map merged read) is dropped here.
# build_chief_pass / GET /api/deliver/pass are RETIRED (no MOVE-set caller;
# AgentBar never called it — see p0-dependency-audit.md).

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("All chief-dashboard NEEDS YOU checks passed.")
