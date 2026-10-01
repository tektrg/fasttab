#!/usr/bin/env python3
"""Direct-run tests for server/lib/personas.py's session->persona mapping
(`resolve_persona_for_cwd`) and main-session selection
(`main_session_for_persona`) — Jev persona routing P1. Pure-function tests:
no FEEDS/herdr, no real HOME (a fake one, so ~-expansion is exercised
without touching anything real)."""
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib"))

os.environ.setdefault("CHIEF_DASHBOARD_MACHINES", "{}")

import personas  # noqa: E402

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


FAKE_HOME = tempfile.mkdtemp(prefix="personas-mapping-test-home-")
os.environ["HOME"] = FAKE_HOME


def persona(address, machine, folder):
    return {
        "address": address, "machine": machine, "folder": folder,
        "resolvedFolder": personas._resolve_path(folder),
        "name": address, "description": "test persona", "routesWhen": [],
        "notFor": [], "extraInstructions": "", "idle": "resume",
        "resumeWithinDays": 3, "start": "in-place", "startScript": None,
    }


# Mirrors the brief's pilot table (folders relative to the fake HOME, same
# layout as the real ~/01_Project): portfolio CONTAINS the other three, so
# longest-match is what stops it from swallowing their sessions.
PERSONAS = {
    "local:~/01_Project/AptusFit": persona(
        "local:~/01_Project/AptusFit", "local", "~/01_Project/AptusFit"),
    "local:~/01_Project/command-bar-macos": persona(
        "local:~/01_Project/command-bar-macos", "local", "~/01_Project/command-bar-macos"),
    "local:~/01_Project": persona(
        "local:~/01_Project", "local", "~/01_Project"),
}


def cwd(*parts):
    return os.path.join(FAKE_HOME, *parts)


print("== longest folder match wins ==")
check("an AptusFit worktree cwd maps to chief-aptus, not portfolio",
      personas.resolve_persona_for_cwd(
          PERSONAS, "local",
          cwd("01_Project", "AptusFit", ".claude", "worktrees", "fe-signup")),
      "local:~/01_Project/AptusFit")
check("AptusFit's own root also maps to chief-aptus",
      personas.resolve_persona_for_cwd(PERSONAS, "local", cwd("01_Project", "AptusFit")),
      "local:~/01_Project/AptusFit")
check("a sibling project folder with no persona of its own falls through to portfolio",
      personas.resolve_persona_for_cwd(PERSONAS, "local", cwd("01_Project", "some-other-repo")),
      "local:~/01_Project")
check("outside every persona folder -> none",
      personas.resolve_persona_for_cwd(PERSONAS, "local", "/tmp/x"),
      None)
check("no cwd at all -> none",
      personas.resolve_persona_for_cwd(PERSONAS, "local", None),
      None)

print("\n== the other Mac: same ~-relative folder is the same persona (slice 4) ==")
AIR = "/Users/air-user"
check("an Air session in ~/01_Project/AptusFit maps to chief-aptus",
      personas.resolve_persona_for_cwd(PERSONAS, "air-m1", AIR + "/01_Project/AptusFit"),
      "local:~/01_Project/AptusFit")
check("an Air worktree still maps to its project, not portfolio",
      personas.resolve_persona_for_cwd(PERSONAS, "air-m1",
                                       AIR + "/01_Project/AptusFit/.claude/worktrees/x"),
      "local:~/01_Project/AptusFit")
check("Air prefix trap: ~/01_Project/AptusFit2 falls through to portfolio",
      personas.resolve_persona_for_cwd(PERSONAS, "air-m1", AIR + "/01_Project/AptusFit2"),
      "local:~/01_Project")
check("an Air path outside any home folder -> none",
      personas.resolve_persona_for_cwd(PERSONAS, "air-m1", "/tmp/01_Project/AptusFit"), None)
check("an Air path in some other folder of its home -> none",
      personas.resolve_persona_for_cwd(PERSONAS, "air-m1", AIR + "/Desktop"), None)
check("a hostile cwd never matches or crashes",
      personas.resolve_persona_for_cwd(PERSONAS, "air-m1", "$(echo INJECTED)"), None)
check("Air main session: exact-folder Air row counts",
      personas.main_session_for_persona(
          PERSONAS["local:~/01_Project/AptusFit"],
          [{"agentSession": "air-main", "paneId": "air-m1:w1:p1", "machine": "air-m1",
            "cwd": AIR + "/01_Project/AptusFit", "hookSinceSec": 3}], chief_id=None),
      "air-main")
check("Air chief rooted in the folder is the front door",
      personas.main_chiefs_by_persona(
          PERSONAS, [{"id": "chief-air", "alive": True, "machine": "air-m1",
                      "projectRoot": AIR + "/01_Project/command-bar-macos"}], []),
      {"local:~/01_Project/command-bar-macos": "chief-air"})
check("no machine given -> none",
      personas.resolve_persona_for_cwd(PERSONAS, None, cwd("01_Project", "AptusFit")),
      None)

print("\n== prefix trap: a sibling folder that merely STARTS with a persona's name ==")
check("~/01_Project/AptusFit2 is not chief-aptus (falls through to portfolio)",
      personas.resolve_persona_for_cwd(PERSONAS, "local", cwd("01_Project", "AptusFit2")),
      "local:~/01_Project")
check("~/01_Project/AptusFit-old/sub is not chief-aptus either",
      personas.resolve_persona_for_cwd(PERSONAS, "local", cwd("01_Project", "AptusFit-old", "sub")),
      "local:~/01_Project")

print("\n== trailing slashes on either side still match ==")
slash_personas = {"local:~/01_Project/AptusFit/": persona(
    "local:~/01_Project/AptusFit/", "local", "~/01_Project/AptusFit/")}
check("persona folder with a trailing slash matches a plain cwd",
      personas.resolve_persona_for_cwd(slash_personas, "local", cwd("01_Project", "AptusFit")),
      "local:~/01_Project/AptusFit/")
check("cwd with a trailing slash matches a plain persona folder",
      personas.resolve_persona_for_cwd(PERSONAS, "local", cwd("01_Project", "AptusFit") + "/"),
      "local:~/01_Project/AptusFit")
check("a trailing slash never opens the prefix trap (AptusFit/ vs AptusFit2)",
      personas.resolve_persona_for_cwd(slash_personas, "local", cwd("01_Project", "AptusFit2")),
      None)

print("\n== symlinked folders resolve on both sides ==")
real_proj = cwd("real", "proj")
os.makedirs(os.path.join(real_proj, "sub"), exist_ok=True)
os.makedirs(cwd("links"), exist_ok=True)
os.symlink(real_proj, cwd("links", "proj"))
link_persona = {"local:~/links/proj": persona("local:~/links/proj", "local", "~/links/proj")}
real_persona = {"local:~/real/proj": persona("local:~/real/proj", "local", "~/real/proj")}
check("persona stored via a symlink matches a session in the real folder",
      personas.resolve_persona_for_cwd(link_persona, "local", os.path.join(real_proj, "sub")),
      "local:~/links/proj")
check("persona stored as the real folder matches a session cwd reached via the symlink",
      personas.resolve_persona_for_cwd(real_persona, "local", cwd("links", "proj", "sub")),
      "local:~/real/proj")

print("\n== main_chiefs_by_persona: a chief counts only where its project root IS the folder ==")
chief_rows = [
    {"agentSession": "chief-aptus-wt", "cwd": cwd("01_Project", "AptusFit", ".claude", "worktrees", "x"),
     "hookSinceSec": 30},
    {"agentSession": "chief-stray", "cwd": cwd("01_Project", "speechtodo"), "hookSinceSec": 1},
    {"agentSession": "chief-portfolio-old", "cwd": cwd("01_Project"), "hookSinceSec": 900},
    {"agentSession": "chief-portfolio-new", "cwd": cwd("01_Project"), "hookSinceSec": 60},
]


def chief(cid, root, alive=True, machine="local"):
    return {"id": cid, "projectRoot": root, "machine": machine, "alive": alive}


got = personas.main_chiefs_by_persona(PERSONAS, [
    # agent_tree.project_for_cwd folds the worktree back to the checkout.
    chief("chief-aptus-wt", cwd("01_Project", "AptusFit")),
    chief("chief-stray", cwd("01_Project", "speechtodo")),
    chief("chief-portfolio-old", cwd("01_Project")),
    chief("chief-portfolio-new", cwd("01_Project")),
    chief("chief-dead", cwd("01_Project", "command-bar-macos"), alive=False),
], chief_rows)
check("AptusFit chief (running in a worktree) is chief-aptus's front door",
      got.get("local:~/01_Project/AptusFit"), "chief-aptus-wt")
check("a chief in a persona-less sibling project never becomes portfolio's front door; "
      "portfolio's own most recently active chief does",
      got.get("local:~/01_Project"), "chief-portfolio-new")
check("a dead chief is nobody's front door",
      "local:~/01_Project/command-bar-macos" in got, False)
check("only the stray chief in the persona-less project -> portfolio has no chief",
      personas.main_chiefs_by_persona(
          PERSONAS, [chief("chief-stray", cwd("01_Project", "speechtodo"))], chief_rows),
      {})
check("chiefs with no row data tie-break by id (deterministic)",
      personas.main_chiefs_by_persona(
          PERSONAS, [chief("b", cwd("01_Project")), chief("a", cwd("01_Project"))], []),
      {"local:~/01_Project": "a"})

print("\n== main_session_for_persona: tree root (chief) preferred ==")
aptus = PERSONAS["local:~/01_Project/AptusFit"]
rows_in_aptus = [
    {"agentSession": "chief-a", "paneId": "w1:p1", "cwd": cwd("01_Project", "AptusFit"),
     "hookSinceSec": 500},
    {"agentSession": "worker-a1", "paneId": "w1:p2",
     "cwd": cwd("01_Project", "AptusFit"), "hookSinceSec": 5},
]
check("chief id wins even though a worker row is more recently active",
      personas.main_session_for_persona(aptus, rows_in_aptus, chief_id="chief-a"),
      "chief-a")

print("\n== main_session_for_persona: no chief -> most recently active EXACT-cwd row ==")
check("lower hookSinceSec (more recent) wins",
      personas.main_session_for_persona(aptus, rows_in_aptus, chief_id=None),
      "worker-a1")

print("\n== main_session_for_persona: a subfolder (worktree) row never counts as 'exact' ==")
rows_worktree_only = [
    {"agentSession": "worker-wt", "paneId": "w1:p3",
     "cwd": cwd("01_Project", "AptusFit", ".claude", "worktrees", "fe-signup"),
     "hookSinceSec": 1},
]
check("no exact-cwd row and no chief -> none",
      personas.main_session_for_persona(aptus, rows_worktree_only, chief_id=None), None)

print("\n== main_session_for_persona: no rows at all, no chief -> none ==")
check("empty", personas.main_session_for_persona(aptus, [], chief_id=None), None)

print("\n== main_session_for_persona: a row missing hookSinceSec never crashes the sort ==")
rows_mixed_recency = [
    {"agentSession": "no-hook-data", "paneId": "w1:p4",
     "cwd": cwd("01_Project", "AptusFit"), "hookSinceSec": None},
    {"agentSession": "has-hook-data", "paneId": "w1:p5",
     "cwd": cwd("01_Project", "AptusFit"), "hookSinceSec": 42},
]
check("the row WITH hook data (more recently active) wins over one with none",
      personas.main_session_for_persona(aptus, rows_mixed_recency, chief_id=None),
      "has-hook-data")

print("\n== main_session_for_persona: a pane-less (Desktop / plain CLI) row never counts ==")
rows_with_desktop = [
    {"agentSession": "herdr-session", "paneId": "w1:p6",
     "cwd": cwd("01_Project", "AptusFit"), "hookSinceSec": 120},
    {"agentSession": "desktop-session", "paneId": None,
     "cwd": cwd("01_Project", "AptusFit"), "hookSinceSec": 5},
]
check("the herdr row wins even though the Desktop row is more recently active",
      personas.main_session_for_persona(aptus, rows_with_desktop, chief_id=None),
      "herdr-session")
check("only a Desktop row -> none (AgentBar can't message it)",
      personas.main_session_for_persona(aptus, rows_with_desktop[1:], chief_id=None), None)

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("All personas mapping checks passed.")
