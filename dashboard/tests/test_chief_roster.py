#!/usr/bin/env python3
"""Direct-run tests for chief_roster.py + Desktop chiefs in
agent_tree.build_agent_tree (rollout item 12)."""
import os
import sys
import tempfile

LIB = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib")
sys.path.insert(0, LIB)

import agent_tree  # noqa: E402
import agent_tree_desktop  # noqa: E402
import chief_roster  # noqa: E402

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


CHIEF = "local_ad2a21be-9f66-4859-8217-c42c8fd8206b"
W1 = "local_8a4eea3c-375d-4469-9eb8-df12af29abdf"
W2 = "local_485c3041-0000-4000-8000-000000000001"
W3 = "local_b3ab6559-2a9d-4a0c-bedb-3ae3a5403646"
SUB = "local_88e10980-0000-4000-8000-000000000002"
OTHER = "local_ffffffff-0000-4000-8000-000000000003"

BRIEF = f"""<!--
  brief.md - Digital platform chief. Session: {CHIEF}
-->
# Digital chief brief

## Priorities
1. mention {OTHER} in prose: never a worker

## Roster - generated each check-in

| Worker | Session id |
| --- | --- |
| flag-lifecycle | {W1} |
| widget-discovery-ui / bridge | local_485c3041… / local_99999999… |

## Rules
- nothing
"""

print("parse_brief")
b = chief_roster.parse_brief(BRIEF)
check("session from header", b["sessionId"], CHIEF)
check("roster full ids only from Roster section", b["rosterIds"], [W1])
check("ellipsis prefixes", b["rosterPrefixes"], ["local_485c3041", "local_99999999"])
check("empty brief", chief_roster.parse_brief(""), {"sessionId": None, "rosterIds": [], "rosterPrefixes": []})

print("parse_config_yaml")
cfg = chief_roster.parse_config_yaml(
    '# comment\ncheckin_cron: "7 8-19/2 * * 1-6"  # every 2h\nwake: off # tracked only\n'
    "checkin_marker: '7-Eleven fleet check-in'\n  nested: ignored\nbad line\nhash: \"a # b\"\n")
check("flat keys", cfg, {"checkin_cron": "7 8-19/2 * * 1-6", "wake": "off",
                         "checkin_marker": "7-Eleven fleet check-in", "hash": "a # b"})

print("make_chief_def")
d = chief_roster.make_chief_def("/p/ssv-shared", "digital", BRIEF, "session: local_bad id\n")
check("key", d["key"], "ssv-shared/digital")
check("invalid config session -> None (not the brief's)", d["desktopSessionId"], None)
d = chief_roster.make_chief_def("/p/ssv-shared", "digital", BRIEF, "")
check("brief session used", d["desktopSessionId"], CHIEF)
check("brief path", d["briefPath"], "/p/ssv-shared/.claude/chief/digital/brief.md")


def rec(sid, parent=None, last=100.0, label=None):
    return {"desktopSessionId": sid, "cliSessionId": "cli-" + sid[6:14], "label": label or sid[6:14],
            "cwd": "/Users/x/01_Project/ssv-shared", "lastActiveTs": last, "parentDesktopId": parent,
            "openUrl": f"claude://code/continue?session={sid}"}


print("build_desktop_chiefs")
sessions = [rec(CHIEF, label="Digital platform deliver chief"),
            rec(W1), rec(W2, last=300.0), rec(W3, parent=CHIEF, last=200.0),
            rec(SUB, parent=W3, last=50.0), rec(OTHER)]
chiefs = chief_roster.build_desktop_chiefs([d], sessions)
check("one chief", len(chiefs), 1)
c = chiefs[0]
check("chief session found", c["session"]["desktopSessionId"], CHIEF)
check("children = roster + linked + grandchild, newest first",
      [x["desktopSessionId"] for x in c["children"]], [W2, W3, W1, SUB])
check("prose id not a worker", OTHER in [x["desktopSessionId"] for x in c["children"]], False)
gone = chief_roster.build_desktop_chiefs([d], [rec(W1)])
check("chief session archived/out of window -> session None", gone[0]["session"], None)
d2 = chief_roster.make_chief_def("/p/aaa", "second", f"Session: {W3}\n", "")
two = chief_roster.build_desktop_chiefs([d, d2], sessions)
check("a chief never nests under another chief", W3 in [x["desktopSessionId"] for x in
      next(x for x in two if x["key"] == "ssv-shared/digital")["children"]], False)
check("sub-worker of chief W3 goes to W3 (nearest), not digital",
      [x["desktopSessionId"] for x in next(x for x in two if x["key"] == "aaa/second")["children"]], [SUB])
cyc = [rec(CHIEF), rec(W1, parent=W2), rec(W2, parent=W1)]
check("spawnedFrom cycle terminates (both are roster members)",
      len(chief_roster.build_desktop_chiefs([d], cyc)[0]["children"]), 2)

print("ChiefFolderReader")
with tempfile.TemporaryDirectory() as tmp:
    root = os.path.join(tmp, "ssv-shared")
    folder = os.path.join(root, ".claude", "chief", "digital")
    os.makedirs(folder)
    with open(os.path.join(folder, "brief.md"), "w") as f:
        f.write(BRIEF)
    os.makedirs(os.path.join(root, ".claude", "chief", "empty"))
    reader = chief_roster.ChiefFolderReader(homes=[root, os.path.join(tmp, "missing")])
    defs = reader.read()
    check("finds the folder, skips an empty one and a missing home", [x["key"] for x in defs], ["ssv-shared/digital"])
    with open(os.path.join(folder, "config.yaml"), "w") as f:
        f.write('checkin_cron: "0 9 * * *"\n')
    check("config picked up on change", reader.read()[0]["config"].get("checkin_cron"), "0 9 * * *")

def build(agents, edges, desktop_chiefs=None):
    tree = agent_tree.build_agent_tree(agents, edges, chief_mode_roots=[])
    return agent_tree_desktop.merge_desktop_chiefs(tree, desktop_chiefs or [], agents, edges)


print("merge_desktop_chiefs onto build_agent_tree")
chiefs = chief_roster.build_desktop_chiefs([d], sessions)
live_chief_row = {"agentSession": "cli-live-chief", "hostSessionId": CHIEF, "paneId": None,
                  "label": "Digital platform deliver chief", "cwd": "/Users/x/01_Project/ssv-shared",
                  "machine": "local"}
live_worker = {"agentSession": "cli-" + W1[6:14], "hostSessionId": W1, "paneId": None, "label": "flag",
               "cwd": "/Users/x/01_Project/ssv-shared", "machine": "local"}
chiefs[0]["checkIn"] = {"state": "ok"}
tree = build([live_chief_row, live_worker], {}, chiefs)
check("one chief row", len(tree["chiefs"]), 1)
ch = tree["chiefs"][0]
check("chief id = live process session id", ch["id"], "cli-live-chief")
check("chief fields", (ch["source"], ch["chiefKey"], ch["alive"], ch["checkIn"]),
      ("claude-desktop", "ssv-shared/digital", True, {"state": "ok"}))
kids = {k["id"]: k for k in ch["children"]}
check("4 workers nested", len(kids), 4)
check("live worker alive", kids["cli-" + W1[6:14]]["alive"], True)
check("sleeping worker keyed by cliSessionId, not alive", kids["cli-" + W2[6:14]]["alive"], False)
check("workers not also unassigned", tree["unassigned"], [])

edges = {"cli-" + W2[6:14]: {"parent": None, "detached": True, "setAt": 1},
         "cli-" + W3[6:14]: {"parent": "cli-live-chief-other", "setAt": 1}}
tree = build([live_chief_row, live_worker], edges, chiefs)
kids = [k["id"] for k in tree["chiefs"][0]["children"]]
check("user detach tombstone wins over roster", "cli-" + W2[6:14] in kids, False)
check("explicit edge elsewhere wins", "cli-" + W3[6:14] in kids, False)

tree = build([], {}, chiefs)
check("sleeping chief still a chief row (alive False)", (len(tree["chiefs"]), tree["chiefs"][0]["alive"],
                                                         tree["chiefs"][0]["id"]), (1, False, "cli-" + CHIEF[6:14]))
gone = chief_roster.build_desktop_chiefs([d], [rec(W1)])
tree = build([live_worker], {}, gone)
check("gone chief: no row, worker stays unassigned", (tree["chiefs"], [u["id"] for u in tree["unassigned"]]),
      ([], ["cli-" + W1[6:14]]))
tree = build([live_worker], {})
check("no desktop_chiefs param: old behaviour", len(tree["unassigned"]), 1)

if fails:
    print("\nFAILED:\n  " + "\n  ".join(fails))
    sys.exit(1)
print("\nAll chief_roster tests passed.")
