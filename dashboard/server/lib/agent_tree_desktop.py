#!/usr/bin/env python3
"""Desktop chiefs in the agent tree (chief redesign rollout item 12).

agent_tree.py is a byte-identical copy of AptusFit's (drift test
`tests/test_agent_tree_upstream_parity.py`; never edit it here), so Desktop
chiefs are merged ON TOP of its `build_agent_tree` result instead.

A Claude Desktop chief (a `<project>/.claude/chief/<name>/` folder naming a
Desktop session, chief_roster.py) and its workers (Desktop linked sessions
+ the brief's roster) join the tree WITHOUT being written to
agent-tree.json: Desktop already records the link, and a resume changes the
Claude session id, so the nesting is derived fresh on every build.

RULES
  * Row ids are what AgentBar keys rows by: the live process's Claude
    session id when it runs, else the Desktop file's `cliSessionId`
    (AgentBar's sleeping row), else the Desktop id.
  * A sleeping (not running) chief or worker shows `alive: False`.
  * The user's own edges win: a worker with ANY entry in agent-tree.json
    (an explicit attach elsewhere, or a detach tombstone) is left alone.
  * Two levels, one parent: a worker that is already a child somewhere, or
    is a chief itself, is skipped.
  * A chief whose Desktop session is gone (archived / deleted / outside the
    scan window) gets no row; its workers stay where they are.

Extra fields on a Desktop chief row: `source: "claude-desktop"`,
`chiefKey`, `chiefName`, `desktopSessionId`, `briefPath`, `checkIn`
(chief_timer.ChiefTimer.view, or None). Pure.
"""
import agent_tree


def row_id(record, live_by_desktop_id):
    desktop_id = record.get("desktopSessionId")
    return live_by_desktop_id.get(desktop_id) or record.get("cliSessionId") or desktop_id


def _sleeping_node(record, rid):
    project, root = agent_tree.project_for_cwd(record.get("cwd"))
    return {"id": rid, "label": record.get("label") or rid[:8], "project": project,
            "projectRoot": root, "machine": "local", "paneId": None, "alive": False,
            "status": None, "crossProject": False}


def merge_desktop_chiefs(tree, desktop_chiefs, agents, edges):
    """Returns a new tree dict (input not mutated)."""
    tree = {**tree, "chiefs": [dict(c, children=list(c.get("children") or []))
                               for c in tree.get("chiefs") or []],
            "unassigned": list(tree.get("unassigned") or [])}
    live_by_desktop_id = {a.get("hostSessionId"): a.get("agentSession") for a in agents or []
                          if a.get("hostSessionId") and a.get("agentSession")}
    chiefs_by_id = {c["id"]: c for c in tree["chiefs"]}
    unassigned_by_id = {u["id"]: u for u in tree["unassigned"]}
    nested = {k["id"] for c in tree["chiefs"] for k in c["children"]}
    nested |= {p["id"] for p in tree.get("parentGone") or []}

    def take_node(record, rid):
        """The node for `rid`: its live unassigned entry (removed from
        unassigned), else a sleeping node."""
        node = unassigned_by_id.pop(rid, None)
        return dict(node) if node else _sleeping_node(record, rid)

    present = [c for c in desktop_chiefs or [] if c.get("session")]
    chief_rids = {row_id(c["session"], live_by_desktop_id) for c in present}
    for chief in present:
        rid = row_id(chief["session"], live_by_desktop_id)
        row = chiefs_by_id.get(rid)
        if row is None:
            if rid in nested:
                continue  # already someone's worker: two levels only
            node = take_node(chief["session"], rid)
            row = {"id": rid, "label": node["label"], "project": node["project"],
                   "projectRoot": node["projectRoot"], "machine": node["machine"],
                   "paneId": node["paneId"], "alive": node["alive"], "isChiefMode": False,
                   "isRegisteredChief": False, "status": node["status"], "children": []}
            tree["chiefs"].append(row)
            chiefs_by_id[rid] = row
        row.update({"source": "claude-desktop", "chiefKey": chief["key"],
                    "chiefName": chief.get("name"), "desktopSessionId": chief.get("desktopSessionId"),
                    "briefPath": chief.get("briefPath"), "checkIn": chief.get("checkIn")})
        for record in chief.get("children") or []:
            cid = row_id(record, live_by_desktop_id)
            if (cid == rid or cid in chief_rids or cid in chiefs_by_id or cid in edges
                    or cid in nested):
                continue
            child = take_node(record, cid)
            child["crossProject"] = bool(child.get("project") and row.get("project")
                                         and child["project"] != row["project"])
            row["children"].append(child)
            nested.add(cid)
    tree["unassigned"] = [u for u in tree["unassigned"] if u["id"] in unassigned_by_id]
    tree["chiefs"].sort(key=lambda c: c["id"])
    return tree
