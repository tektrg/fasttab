#!/usr/bin/env python3
"""Prove chief_pass (GET /api/deliver/pass), restored 2026-09-25 per PO
decision: KEEP, made generic (see server/lib/chief_dashboard_pass.py's
module docstring for the full rationale — AptusFit's chief calls this at
the start of every supervision round, 27 sessions/3 days, and cutover would
otherwise break every one of them).

Ported from AptusFit's test_chief_dashboard_views.py CHIEF_PASS section
(build_chief_pass's pure-function behaviour: feed health, both pane-
liveness disagreement pairs, residue/orphan exclusion) plus new cases for
what P0 made generic: `tick` resolving to null (not an error) when no
configured project has deliver-tick.py, and toolbox-map loading from an
arbitrary project root rather than a hard-coded AptusFit path.

Pure functions + a synthetic filesystem fixture for the two path-resolution
helpers — no herdr, no live panes, no network, no dependency on AptusFit
actually being checked out at the default projectRoots path.
"""
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib"))

import chief_dashboard_pass as cdp  # noqa: E402

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
        "board": feed(board),
    }


def agent(pane_id, *, hook_state=None, since=600, screen_state=None,
          signal=None, herdr_status="idle", disagree=False, residue=False,
          orphan=False, label="worker", session=None):
    return {
        "paneId": pane_id, "label": label,
        "hookState": hook_state, "hookSinceSec": since, "herdrStatus": herdr_status,
        "disagree": disagree, "residue": residue, "orphanHook": orphan,
        "agentSession": session,
        "screenState": screen_state, "screenSignal": signal,
        "screenUnchangedSec": None, "subagentsRunning": 0,
        "herdrTurnReported": False,
    }


print("CHIEF_PASS (restored 2026-09-25, generic) — one merged read, both classifiers surfaced raw:")

TICK_DATA = {"mode": "chief", "runs": [], "actions": [], "warnings": [],
             "nextPollSeconds": 600, "quietHours": False, "inbox": []}

cp = cdp.build_chief_pass(
    snap(board=TICK_DATA),
    [agent("w1:p1", hook_state="idle", screen_state="WAITING")],
    toolbox=[{"name": "chief_pass", "description": "d"}])
check("a healthy pass reports zero disagreements", cp["paneDisagreementCount"], 0)
check("tick pass-through keeps deliver-tick.py --json's own shape",
      cp["tick"]["nextPollSeconds"], 600)
check("toolbox passes through unchanged",
      cp["toolboxMap"], [{"name": "chief_pass", "description": "d"}])
check("no feed reads broken in a healthy snapshot",
      cp["feedHealth"], {"broken": [], "warming": []})
check("top-level keys match AptusFit's live GET /api/deliver/pass exactly "
      "(no stale 'mode' key — that field was removed upstream 2026-09-22)",
      sorted(cp.keys()),
      sorted(["feedHealth", "tick", "panes", "paneDisagreementCount", "toolboxMap"]))

print("...a broken feed always leads, before any pane detail is trusted:")
s_broken = snap(board=TICK_DATA)
s_broken["herdr"] = feed(None, broken=True, warming=False, err="herdr down")
cp_broken = cdp.build_chief_pass(s_broken, [], toolbox=[])
check("the broken feed is named, not just counted",
      cp_broken["feedHealth"]["broken"],
      [{"feed": "herdr", "error": "herdr down"}])

print("...hookState vs herdrStatus disagreeing on the same pane is surfaced, not resolved:")
cp_disagree = cdp.build_chief_pass(
    snap(board=TICK_DATA),
    [agent("w1:p1", hook_state="idle", herdr_status="working", disagree=True,
           screen_state="WAITING")],
    toolbox=[])
check("the raw hook and herdr readings both survive, unresolved",
      (cp_disagree["panes"][0]["hookState"], cp_disagree["panes"][0]["herdrStatus"]),
      ("idle", "working"))
check("and the disagree flag fires", cp_disagree["panes"][0]["disagreeHookVsHerdr"], True)
check("...which the pass-level count reflects", cp_disagree["paneDisagreementCount"], 1)

print("...live screen vs the ~2min cached tick reading disagreeing is the OTHER pair "
      "('run both' trap: a pane read actively working while its cached reading said idle):")
cp_stale = cdp.build_chief_pass(
    snap(board=TICK_DATA,
         pane_tick={"agents": [{"paneId": "w1:p1", "screenState": "WAITING",
                                "status": "idle"}]}),
    [agent("w1:p1", hook_state="idle", herdr_status="idle",
           screen_state="ACTIVE", signal="mid-turn")],
    toolbox=[])
check("neither reading is dropped in favour of the other",
      (cp_stale["panes"][0]["liveScreenState"], cp_stale["panes"][0]["cachedScreenState"]),
      ("ACTIVE", "WAITING"))
check("and it is named as a disagreement",
      cp_stale["panes"][0]["disagreeScreenVsCachedTick"], True)

print("...residue and orphaned-hook rows are inventory, not a pane to grade:")
cp_residue = cdp.build_chief_pass(
    snap(board=TICK_DATA),
    [agent("w1:p1", hook_state="idle", screen_state="WAITING", residue=True),
     agent("w1:p2", hook_state="idle", screen_state="WAITING", orphan=True)],
    toolbox=[])
check("both are excluded from panes", cp_residue["panes"], [])

print("\nGENERIC TICK (P0 design call — no projectRoot means no error):")
cp_no_tick = cdp.build_chief_pass(snap(board=None), [], toolbox=[])
check("no board data (no configured project has deliver-tick.py) -> tick is "
      "null, not an empty dict or an error", cp_no_tick["tick"], None)
check("and that alone never reports the board feed as broken (a Feed with a "
      "successful-but-empty read is not a failure)",
      cp_no_tick["feedHealth"], {"broken": [], "warming": []})

s_board_broken = snap()
s_board_broken["board"] = feed(None, broken=True, warming=False,
                               err="deliver-tick.py exited 1")
cp_tick_broken = cdp.build_chief_pass(s_board_broken, [], toolbox=[])
check("a project that DOES have deliver-tick.py but whose run failed is "
      "still reported broken, distinctly from 'no project has it'",
      cp_tick_broken["feedHealth"]["broken"],
      [{"feed": "board", "error": "deliver-tick.py exited 1"}])
check("...and tick is still null (nothing to pass through)",
      cp_tick_broken["tick"], None)


print("\nGENERIC PATH RESOLUTION (find_project_root_with — never hard-coded "
      "to projectRoots[0]/AptusFit):")

with tempfile.TemporaryDirectory() as tmp:
    root_without = os.path.join(tmp, "no-script-here")
    root_with = os.path.join(tmp, "has-the-script")
    os.makedirs(os.path.join(root_without, "scripts"))
    os.makedirs(os.path.join(root_with, "scripts"))
    with open(os.path.join(root_with, "scripts", "deliver-tick.py"), "w") as f:
        f.write("# fixture\n")

    check("a project with no matching script is skipped",
          cdp.find_project_root_with(
              cdp.DELIVER_TICK_RELPATH, project_roots=[root_without]),
          None)
    check("the SECOND configured root is found when the first doesn't have it "
          "— proves this scans every projectRoot, not just projectRoots[0]",
          cdp.find_project_root_with(
              cdp.DELIVER_TICK_RELPATH,
              project_roots=[root_without, root_with]),
          root_with)

    print("\nGENERIC TOOLBOX LOADING (chief-board-mcp.py from any configured "
          "project root, not a hard-coded AptusFit path):")
    mcp_path = os.path.join(root_with, "scripts", "chief-board-mcp.py")
    with open(mcp_path, "w") as f:
        f.write(
            "TOOLS = [{'name': 'fixture_tool', 'description': 'd', "
            "'extraKeyDropped': True}]\n")
    toolbox = cdp.load_toolbox_map(project_roots=[root_without, root_with], force=True)
    check("loads name+description only from the found project's TOOLS list",
          toolbox, [{"name": "fixture_tool", "description": "d"}])

    check("no project root has chief-board-mcp.py -> empty toolbox, not an error",
          cdp.load_toolbox_map(project_roots=[root_without], force=True), [])

    broken_root = os.path.join(tmp, "broken-mcp")
    os.makedirs(os.path.join(broken_root, "scripts"))
    with open(os.path.join(broken_root, "scripts", "chief-board-mcp.py"), "w") as f:
        f.write("raise RuntimeError('syntax-ish failure at import time')\n")
    check("a catalogue that fails to import still reports an empty toolbox "
          "instead of taking chief_pass down with it",
          cdp.load_toolbox_map(project_roots=[broken_root], force=True), [])

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("All chief_pass checks passed.")
