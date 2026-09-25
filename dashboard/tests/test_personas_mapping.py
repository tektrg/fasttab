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

print("\n== machine mismatch -> none, even for an otherwise-matching folder ==")
check("same folder, different machine, doesn't match",
      personas.resolve_persona_for_cwd(PERSONAS, "air-m1", cwd("01_Project", "AptusFit")),
      None)
check("no machine given -> none",
      personas.resolve_persona_for_cwd(PERSONAS, None, cwd("01_Project", "AptusFit")),
      None)

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

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("All personas mapping checks passed.")
