#!/usr/bin/env python3
"""Direct-run tests for GET /api/personas (`personas.get_personas_state`) —
Jev persona routing P1. Drives the view-layer function directly, seeding
FEEDS with a fake herdr roster and a fake registry file under a fake HOME
(same level test_chief_dashboard_agent_tree_api.py operates at) — never a
real herdr call, never the real ~/.config/agentbar/personas.json, never the
live :4711 server."""
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DASHBOARD_ROOT = os.path.dirname(HERE)

FAKE_HOME = tempfile.mkdtemp(prefix="personas-api-test-home-")
os.environ["HOME"] = FAKE_HOME
os.environ["AGENT_TREE_FILE"] = os.path.join(FAKE_HOME, "agent-tree.json")
os.environ["AGENTBAR_PERSONAS_FILE"] = os.path.join(
    FAKE_HOME, ".config", "agentbar", "personas.json")
os.environ.setdefault("CHIEF_DASHBOARD_MACHINES", "{}")

sys.path.insert(0, os.path.join(DASHBOARD_ROOT, "server", "lib"))
import agent_tree  # noqa: E402
from chief_dashboard_feeds import FEEDS  # noqa: E402
import personas  # noqa: E402

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def cwd(*parts):
    return os.path.join(FAKE_HOME, *parts)


def agent_row(session, pane_id, path, label="worker", machine=None):
    row = {"pane_id": pane_id, "tab_id": pane_id, "agent_session": {"value": session},
           "terminal_title": label, "cwd": path}
    return row


# ── fake registry: the 4 real pilots' shape (folders relative to FAKE_HOME,
#    same ~/01_Project layout), plus one empty-description persona (must be
#    excluded) and one on a machine this test controls purely to prove the
#    'offline' flag (never really reachable in this test — see the
#    machines_status monkeypatch below). ──
os.makedirs(os.path.dirname(personas.registry_path()), exist_ok=True)
with open(personas.registry_path(), "w") as f:
    json.dump({
        "globalInstructions": personas.DEFAULT_GLOBAL_INSTRUCTIONS,
        "personas": {
            "local:~/01_Project/AptusFit": {
                "name": "chief-aptus", "description": "AptusFit product delivery front door.",
                "routesWhen": ["AptusFit product work"], "notFor": ["FastTab/AgentBar/dashboard code"],
                "idle": "resume", "resumeWithinDays": 3, "start": "in-place",
            },
            "local:~/01_Project/command-bar-macos": {
                "name": "fasttab-dev", "description": "FastTab + AgentBar Mac apps, and this dashboard.",
                "routesWhen": ["FastTab/AgentBar/dashboard work"], "notFor": ["AptusFit product delivery"],
                "idle": "resume", "resumeWithinDays": 3, "start": "in-place",
            },
            "local:~/01_Project/ssv-bi-platform": {
                "name": "bi", "description": "",  # unreviewed draft — must never be offered
                "idle": "resume", "resumeWithinDays": 3, "start": "in-place",
            },
            "local:~/01_Project": {
                "name": "portfolio",
                "description": "Cross-project/portfolio questions, and anything no more specific persona owns.",
                "routesWhen": ["cross-project questions"], "notFor": ["project-specific work with its own persona"],
                "idle": "resume", "resumeWithinDays": 3, "start": "in-place",
            },
            "air-m1:~/remote-project": {
                "name": "remote-test", "description": "A machine this test marks unreachable.",
                "idle": "resume", "resumeWithinDays": 3, "start": "in-place",
            },
        },
    }, f)

# ── fake herdr roster ──
FEEDS["hookCache"].set_success({})
FEEDS["paneScreen"].set_success({})
FEEDS["paneTick"].set_success({"agents": []})
FEEDS["herdr"].set_success({
    "agents": [
        # chief-aptus: a live chief (child edge below) + a worktree worker —
        # both must map to chief-aptus, never portfolio.
        agent_row("chief-a", "w1:p1", cwd("01_Project", "AptusFit"), "chief-aptus-main"),
        agent_row("worker-a1", "w1:p2",
                  cwd("01_Project", "AptusFit", ".claude", "worktrees", "fe-signup"), "worker-a1"),
        # fasttab-dev: no chief -> falls back to the exact-cwd session.
        agent_row("fasttab-session", "w1:p3", cwd("01_Project", "command-bar-macos"), "fasttab-main"),
        # portfolio: its own exact-cwd session, PLUS a stray session in a
        # sibling project that has no persona of its own (proves portfolio
        # picks up "anything no more specific persona owns" for
        # sessionRowIds, without stealing it as its main session).
        agent_row("portfolio-session", "w1:p4", cwd("01_Project"), "portfolio-main"),
        agent_row("stray-session", "w1:p5", cwd("01_Project", "some-other-repo"), "stray"),
        # No cwd at all -> must map to no persona, appear in no list.
        agent_row("no-cwd-session", "w1:p6", None, "no-cwd"),
    ],
    "tabs": [],
})
agent_tree.attach("worker-a1", "chief-a", set_by="test-seed")
# The stray session is ALSO a chief (it has a worker) — a chief in a project
# with no persona of its own must still never become portfolio's front door.
agent_tree.attach("no-cwd-session", "stray-session", set_by="test-seed")

# machines_status() would normally read this process's real MACHINES config
# (empty here, CHIEF_DASHBOARD_MACHINES="{}") — monkeypatch it directly so
# the 'offline' flag is exercised deterministically, independent of any
# real machine reachability.
_ORIG_MACHINES_STATUS = personas.machines_status
personas.machines_status = lambda: {"air-m1": {"status": "broken"}}

try:
    result = personas.get_personas_state()
    by_address = {p["address"]: p for p in result}

    print("== shape: only offered (described, not hidden) personas, in registry order ==")
    check("exactly the 4 described personas (bi excluded — empty description)",
          sorted(by_address.keys()),
          sorted(["local:~/01_Project/AptusFit", "local:~/01_Project/command-bar-macos",
                  "local:~/01_Project", "air-m1:~/remote-project"]))
    check("every row has the documented keys",
          sorted(by_address["local:~/01_Project/AptusFit"].keys()),
          sorted(["name", "address", "description", "routesWhen", "notFor",
                  "idle", "start", "offline", "mainRowId", "sessionRowIds"]))

    print("\n== chief-aptus: chief is main; both its sessions counted, not portfolio's ==")
    aptus = by_address["local:~/01_Project/AptusFit"]
    check("mainRowId is the live chief", aptus["mainRowId"], "chief-a")
    check("sessionRowIds has the chief + its worktree worker, nothing else",
          sorted(aptus["sessionRowIds"]), sorted(["chief-a", "worker-a1"]))
    check("offline is false (local)", aptus["offline"], False)

    print("\n== fasttab-dev: no chief -> falls back to the exact-cwd session ==")
    fasttab = by_address["local:~/01_Project/command-bar-macos"]
    check("mainRowId is the exact-cwd session", fasttab["mainRowId"], "fasttab-session")
    check("sessionRowIds", fasttab["sessionRowIds"], ["fasttab-session"])

    print("\n== portfolio: owns its own session + the unclaimed stray, never AptusFit's/fasttab's ==")
    portfolio = by_address["local:~/01_Project"]
    check("mainRowId is portfolio's own exact-cwd session", portfolio["mainRowId"], "portfolio-session")
    check("sessionRowIds has its own session + the stray, not chief-a/worker-a1/fasttab-session",
          sorted(portfolio["sessionRowIds"]), sorted(["portfolio-session", "stray-session"]))

    print("\n== a session with no cwd maps to nobody ==")
    all_session_ids = {sid for p in result for sid in p["sessionRowIds"]}
    check("no-cwd-session appears in no persona's sessionRowIds",
          "no-cwd-session" in all_session_ids, False)

    print("\n== offline reflects machines_status()'s 'broken' verdict for that persona's machine ==")
    remote = by_address["air-m1:~/remote-project"]
    check("marked offline", remote["offline"], True)
    check("no sessions, no main (nothing on that machine in this roster)",
          (remote["mainRowId"], remote["sessionRowIds"]), (None, []))

    print("\n== bi (empty description) is excluded entirely, per-address ==")
    check("bi is not in the output", "local:~/01_Project/ssv-bi-platform" in by_address, False)
finally:
    personas.machines_status = _ORIG_MACHINES_STATUS

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("All personas API checks passed.")
