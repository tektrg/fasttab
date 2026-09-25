#!/usr/bin/env python3
"""Direct-run tests for Chief Dashboard v2 phase 2: views + lingering.

Proves expiry with an injected clock — no test waits 72h.
"""
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib"))

from chief_dashboard_store import BoardStore, ENDED_TTL_SEC  # noqa: E402

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def make_store(now=1000000.0):
    tempdir = tempfile.TemporaryDirectory()
    clock = {"t": now}
    store = BoardStore(
        os.path.join(tempdir.name, "chief-board.db"),
        os.path.join(tempdir.name, "chief-board-schema.json"),
        now_fn=lambda: clock["t"],
    )
    return tempdir, store, clock


def agent(session, label="worker"):
    return {
        "agentSession": session,
        "paneId": "w1:p2",
        "paneIdSanitized": "w1-p2",
        "label": label,
        "cwd": "/repo",
        "focused": False,
        "hookState": "idle",
        "hookSinceSec": 10,
        "herdrStatus": "idle",
        "disagree": False,
        "hasHookData": True,
        "screenState": "WAITING",
    }


print("DEFAULT VIEWS")
tmp, store, clock = make_store()
with tmp:
    views = store.list_views()
    # v3 phase 6 seeds a 4th default view ("Archived") so archived rows
    # stay reachable rather than being deleted.
    check("four defaults seeded", len(views), 4)
    check("default names", [v["name"] for v in views],
          ["Needs you", "All sessions", "By group", "Archived"])
    check("by group is kanban", [v for v in views if v["name"] == "By group"][0]["layout"], "kanban")

print("\nLINGERING")
tmp, store, clock = make_store()
with tmp:
    prop = store.create_property({"name": "Group", "type": "text"})
    store.set_value({"rowKind": "session", "rowId": "sess-gone",
                     "propertyId": prop["id"], "value": "v1.0.8"})
    store.build_session_board([agent("sess-live"), agent("sess-gone")])
    clock["t"] += 60
    board = store.build_session_board([agent("sess-live")])
    by_id = {r["rowId"]: r for r in board["rows"]}
    check("gone row lingers", "sess-gone" in by_id, True)
    check("lingering row marked ended", by_id["sess-gone"]["status"], "ended")
    check("stored value still readable",
          by_id["sess-gone"]["values"].get(prop["id"]), "v1.0.8")
    check("live row stays live", by_id["sess-live"]["status"], "live")
    clock["t"] += ENDED_TTL_SEC + 10
    board2 = store.build_session_board([agent("sess-live")])
    check("past TTL it disappears",
          any(r["rowId"] == "sess-gone" for r in board2["rows"]), False)

print("\nVIEW CRUD + SERVER FILTER/SORT")
tmp, store, clock = make_store()
with tmp:
    prop = store.create_property({"name": "Group", "type": "text"})
    store.set_value({"rowKind": "session", "rowId": "sess-b",
                     "propertyId": prop["id"], "value": "beta"})
    store.set_value({"rowKind": "session", "rowId": "sess-a",
                     "propertyId": prop["id"], "value": "alpha"})
    view = store.create_view({
        "name": "Alpha only",
        "layout": "table",
        "filters": [{"propertyId": prop["id"], "op": "is", "value": "alpha"}],
        "sort": [{"propertyId": "derived:label", "dir": "asc"}],
    })
    check("view persists filters", view["filters"],
          [{"propertyId": prop["id"], "op": "is", "value": "alpha"}])
    board = store.build_session_board(
        [agent("sess-b", "beta"), agent("sess-a", "alpha")], view_id=view["id"])
    check("server filters rows", [r["rowId"] for r in board["rows"]], ["sess-a"])
    check("board carries resolved view", board["view"]["id"], view["id"])
    renamed = store.update_view(view["id"], {"name": "Alpha renamed"})
    check("rename sticks", renamed["name"], "Alpha renamed")
    store.delete_view(view["id"])
    try:
        store.get_view(view["id"])
        check("deleted view gone", "still there", "gone")
    except ValueError:
        check("deleted view gone", "gone", "gone")

print("\nMULTI-COLUMN SORT IS STABLE")
tmp, store, clock = make_store()
with tmp:
    nprop = store.create_property({"name": "N", "type": "number"})
    for i, rid in enumerate(["s1", "s2", "s3"]):
        store.set_value({"rowKind": "session", "rowId": rid,
                         "propertyId": nprop["id"], "value": [2, 1, 1][i]})
    view = store.create_view({
        "name": "sort", "layout": "table",
        "sort": [{"propertyId": nprop["id"], "dir": "asc"},
                 {"propertyId": "derived:label", "dir": "asc"}],
    })
    board = store.build_session_board(
        [agent("s1", "b"), agent("s2", "c"), agent("s3", "a")], view_id=view["id"])
    check("stable multi sort", [r["rowId"] for r in board["rows"]], ["s3", "s2", "s1"])

print("\nKANBAN GROUPING")
tmp, store, clock = make_store()
with tmp:
    prop = store.create_property(
        {"name": "Status", "type": "select", "options": ["todo", "done"]})
    todo = prop["options"][0]["id"]
    done = prop["options"][1]["id"]
    store.set_value({"rowKind": "session", "rowId": "s1",
                     "propertyId": prop["id"], "value": todo})
    store.set_value({"rowKind": "session", "rowId": "s2",
                     "propertyId": prop["id"], "value": done})
    view = store.create_view({"name": "kan", "layout": "kanban", "groupBy": prop["id"]})
    board = store.build_session_board([agent("s1"), agent("s2")], view_id=view["id"])
    groups = {g["key"]: g["rowIds"] for g in board["groups"]["groups"]}
    check("stored group is editable", board["groups"]["editable"], True)
    check("todo group holds s1", groups.get(todo), ["s1"])
    check("done group holds s2", groups.get(done), ["s2"])
    dview = store.create_view(
        {"name": "derived kanban", "layout": "kanban", "groupBy": "derived:state"})
    dboard = store.build_session_board([agent("s1")], view_id=dview["id"])
    check("derived group flagged read-only", dboard["groups"]["editable"], False)

print("\nSCHEMA EXPORT CARRIES VIEWS")
tmp, store, clock = make_store()
with tmp:
    store.create_view({"name": "Saved", "layout": "table"})
    with open(store.schema_path, encoding="utf-8") as f:
        payload = json.load(f)
    check("views exported", any(v["name"] == "Saved" for v in payload.get("views", [])), True)

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("All phase-2 checks passed.")
