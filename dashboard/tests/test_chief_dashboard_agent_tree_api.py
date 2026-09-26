#!/usr/bin/env python3
"""GET /api/agent-tree, POST /api/agent-tree/attach|detach — thin handlers in
chief-dashboard-server.py, all logic in chief_dashboard_views.py
(get_agent_tree_state / agent_tree_attach / agent_tree_detach), backed by
scripts/lib/agent_tree.py. Drives the view-layer functions directly (same
level test_chief_dashboard_phase3.py operates at) by seeding FEEDS with fake
herdr rosters — never a real herdr call, never the real ~/.claude/agent-
tree.json.
"""
import os
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
TMP = tempfile.mkdtemp(prefix="agent-tree-dashboard-api-test-")
os.environ["AGENT_TREE_FILE"] = os.path.join(TMP, "agent-tree.json")

sys.path.insert(0, os.path.join(SCRIPTS, "server", "lib"))
import agent_tree  # noqa: E402
from chief_dashboard_feeds import FEEDS  # noqa: E402
import chief_dashboard_views as views  # noqa: E402

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def agent_row(session, pane_id, cwd, label="worker"):
    return {"pane_id": pane_id, "tab_id": pane_id, "agent_session": {"value": session},
           "terminal_title": label, "cwd": cwd}


# One project, two workers with no edge yet + a registered chief (chief-mode
# file), and a SECOND project's own agent — proves cross-project visibility
# comes for free from the dashboard's already system-wide herdr roster.
PROJECT_A = os.path.join(TMP, "01_Project", "AptusFit")
PROJECT_B = os.path.join(TMP, "01_Project", "OtherProject")
os.makedirs(os.path.join(PROJECT_A, ".claude"), exist_ok=True)
os.makedirs(os.path.join(PROJECT_B, ".claude"), exist_ok=True)

FEEDS["hookCache"].set_success({})
FEEDS["paneScreen"].set_success({})
FEEDS["paneTick"].set_success({"agents": [{"paneId": "w1:pC", "verdict": "dropped"}]})
FEEDS["herdr"].set_success({
    "agents": [
        agent_row("chief-a", "w1:pC", PROJECT_A, "chief-a"),
        agent_row("worker-a1", "w1:p1", PROJECT_A, "worker-a1"),
        agent_row("worker-a2", "w1:p2", PROJECT_A, "worker-a2"),
        agent_row("agent-b1", "w2:p1", PROJECT_B, "agent-b1"),
    ],
    "tabs": [],
})
agent_tree.attach("worker-a1", "chief-a", set_by="test-seed")

print("GET /api/agent-tree (get_agent_tree_state):")
tree = views.get_agent_tree_state()
check("has the contract's top-level keys",
      sorted(tree.keys()), ["chiefs", "generatedAt", "parentGone", "unassigned"])
chiefs_by_id = {c["id"]: c for c in tree["chiefs"]}
check("chief-a is a chief row (it has a child)", "chief-a" in chiefs_by_id, True)
check("...with its live pane and status from the pane-tick cache",
      (chiefs_by_id["chief-a"]["paneId"], chiefs_by_id["chief-a"]["status"]), ("w1:pC", "dropped"))
check("worker-a1 nests under chief-a",
      [c["id"] for c in chiefs_by_id["chief-a"]["children"]], ["worker-a1"])
unassigned_ids = {a["id"] for a in tree["unassigned"]}
check("worker-a2 (no edge, no children) is unassigned", "worker-a2" in unassigned_ids, True)
check("a SECOND project's agent is visible too (system-wide herdr roster)",
      "agent-b1" in unassigned_ids, True)
check("...tagged with its OWN project, not project A's",
      next(a for a in tree["unassigned"] if a["id"] == "agent-b1")["project"], "OtherProject")

print("\nPOST /api/agent-tree/attach (agent_tree_attach):")
payload, status = views.agent_tree_attach("worker-a2", "chief-a")
check("same-project attach needs no confirm -> 200 ok", (payload.get("ok"), status), (True, 200))
check("...no cross-project warning", payload.get("warning"), None)
check("...and the edge is actually written",
      agent_tree.read_edges().get("worker-a2", {}).get("parent"), "chief-a")

payload, status = views.agent_tree_attach("agent-b1", "chief-a")
check("cross-project without confirm -> 409 needsConfirm",
      (status, payload.get("error"), payload.get("needsConfirm")),
      (409, "cross-project", True))
check("...and nothing was written", "agent-b1" in agent_tree.read_edges(), False)

payload, status = views.agent_tree_attach("agent-b1", "chief-a", confirm_cross_project=True)
check("cross-project WITH confirm -> 200 ok, warning names both projects",
      (status, payload.get("ok"), "OtherProject" in (payload.get("warning") or "")
       and "AptusFit" in (payload.get("warning") or "")), (200, True, True))

payload, status = views.agent_tree_attach("chief-a", "worker-a1")
check("two-level violation surfaces agent_tree's own error code",
      (status, payload.get("error")), (400, "two-level"))

payload, status = views.agent_tree_attach("ghost-child", "ghost-parent")
check("neither id in the live roster -> unknown-agent",
      (status, payload.get("error")), (400, "unknown-agent"))

payload, status = views.agent_tree_attach(None, "chief-a")
check("missing child -> 400, no crash", (status, payload.get("error") is not None), (400, True))

print("\nPOST /api/agent-tree/detach (agent_tree_detach):")
payload, status = views.agent_tree_detach("worker-a2")
check("detach reports ok", (payload, status), ({"ok": True}, 200))
# H2 fix (2026-09-24): detach() leaves a tombstone (parent=None, detached=
# True), not a deleted key — so a still-running worker's next Stop-hook
# report can never silently re-seed the same parent. See agent_tree.py's
# DETACH TOMBSTONE docstring note and test_agent_tree.py's own coverage.
check("...the edge has no parent (tombstoned, not deleted)",
      (agent_tree.read_edges().get("worker-a2") or {}).get("parent"), None)
check("...tombstone marked detached",
      (agent_tree.read_edges().get("worker-a2") or {}).get("detached"), True)
payload, status = views.agent_tree_detach("never-had-an-edge")
check("detaching an id with no edge is still ok, not an error",
      (payload, status), ({"ok": True}, 200))

# M-B regression (QA 2026-09-26, reproduced against this dashboard's old
# forked agent_tree.py): the dashboard roster passed as attach's known_ids
# is validation-only. An Air worker whose rows are momentarily missing from
# the roster (Air ssh blip) must keep its edge through dashboard attach/
# detach, even when that edge (or its launch-pending seed) is old by setAt.
print("\nattach/detach never prune by the dashboard roster (M-B regression):")
long_ago = time.time() - 90 * 24 * 3600
edges = agent_tree.read_edges()
edges["air-worker"] = {"parent": "chief-a", "setAt": long_ago, "setBy": "test-seed"}
edges["air-pending"] = {"parent": "chief-a", "setAt": long_ago, "setBy": "test-seed",
                        "launchPending": True}
agent_tree._write_edges(agent_tree.tree_file_path(), edges)
payload, status = views.agent_tree_attach("worker-a2", "chief-a")
check("attach with Air rows absent from the roster -> 200 ok", (payload.get("ok"), status), (True, 200))
check("...a 90-day-old live Air worker's edge survives",
      (agent_tree.read_edges().get("air-worker") or {}).get("parent"), "chief-a")
check("...a 90-day-old launch-pending Air edge survives",
      (agent_tree.read_edges().get("air-pending") or {}).get("parent"), "chief-a")
views.agent_tree_detach("worker-a2")
check("detach leaves both Air edges intact too",
      sorted(k for k in ("air-worker", "air-pending") if (agent_tree.read_edges().get(k) or {}).get("parent")),
      ["air-pending", "air-worker"])

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("All chief-dashboard agent-tree API checks passed.")
