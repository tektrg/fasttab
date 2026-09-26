#!/usr/bin/env python3
"""Table layout prefs (wrap/sticky) + kanban column order (groupOrder).

wrap/sticky ride inside view.columns entries (no migration — absent means
off, so old views render exactly as before). groupOrder is a real view
column (NULL = server order); a saved order pins the sequence, unknown keys
are ignored, brand-new groups append at the end, and switching groupBy
clears a stale order unless the same PATCH carries a replacement.
"""
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib"))

from chief_dashboard_store import BoardStore  # noqa: E402

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


print("COLUMN WRAP/STICKY VALIDATION")
tmp, store, clock = make_store()
with tmp:
    # Absent keys default off — pre-existing views keep rendering one line.
    cols = store._validate_columns([{"propertyId": "a"}])
    check("defaults off", cols,
          [{"propertyId": "a", "hidden": False, "width": None,
            "wrap": False, "sticky": False}])
    cols = store._validate_columns([
        {"propertyId": "a", "hidden": True, "width": 200,
         "wrap": True, "sticky": True}])
    check("prefs preserved", cols,
          [{"propertyId": "a", "hidden": True, "width": 200,
            "wrap": True, "sticky": True}])
    # Round-trip through the DB, not just the validator.
    view = store.create_view({
        "name": "prefs", "layout": "table",
        "columns": [{"propertyId": "a", "hidden": False, "width": 200,
                     "wrap": True, "sticky": True}]})
    check("create round-trips prefs", store.get_view(view["id"])["columns"],
          [{"propertyId": "a", "hidden": False, "width": 200,
            "wrap": True, "sticky": True}])
    updated = store.update_view(view["id"], {
        "columns": [{"propertyId": "a", "hidden": False, "width": None,
                     "wrap": False, "sticky": False}]})
    check("update clears prefs", updated["columns"],
          [{"propertyId": "a", "hidden": False, "width": None,
            "wrap": False, "sticky": False}])

print("GROUP ORDER VALIDATION")
tmp, store, clock = make_store()
with tmp:
    check("None stays None", store._validate_group_order(None), None)
    check("empty resets", store._validate_group_order([]), None)
    check("dedupes", store._validate_group_order(["b", "a", "b"]), ["b", "a"])
    check("json string", store._validate_group_order('["b", "a"]'), ["b", "a"])
    view = store.create_view({"name": "k", "layout": "kanban"})
    check("default None", store.get_view(view["id"])["groupOrder"], None)
    updated = store.update_view(view["id"], {"groupOrder": ["b", "a"]})
    check("update pins", updated["groupOrder"], ["b", "a"])
    cleared = store.update_view(view["id"], {"groupOrder": []})
    check("empty clears", cleared["groupOrder"], None)

print("KANBAN ORDER APPLIES SERVER-SIDE")
tmp, store, clock = make_store()
with tmp:
    prop = store.create_property(
        {"name": "Status", "type": "select",
         "options": ["todo", "doing", "done"]})
    ids = {o["name"]: o["id"] for o in prop["options"]}
    store.set_value({"rowKind": "session", "rowId": "s1",
                     "propertyId": prop["id"], "value": ids["todo"]})
    store.set_value({"rowKind": "session", "rowId": "s2",
                     "propertyId": prop["id"], "value": ids["done"]})
    view = store.create_view({"name": "kan", "layout": "kanban",
                              "groupBy": prop["id"]})
    board = store.build_session_board(
        [agent("s1"), agent("s2")], view_id=view["id"])
    check("server order without pin",
          [g["key"] for g in board["groups"]["groups"]],
          [ids["todo"], ids["done"]])
    store.update_view(view["id"],
                      {"groupOrder": [ids["done"], ids["todo"], "ghost"]})
    board = store.build_session_board(
        [agent("s1"), agent("s2")], view_id=view["id"])
    check("pinned order wins, ghost ignored",
          [g["key"] for g in board["groups"]["groups"]],
          [ids["done"], ids["todo"]])
    check("cards follow the pin",
          {g["key"]: g["rowIds"] for g in board["groups"]["groups"]},
          {ids["done"]: ["s2"], ids["todo"]: ["s1"]})
    # A group that appears after the pin was saved appends at the end.
    store.set_value({"rowKind": "session", "rowId": "s3",
                     "propertyId": prop["id"], "value": ids["doing"]})
    board = store.build_session_board(
        [agent("s1"), agent("s2"), agent("s3")], view_id=view["id"])
    check("new group appends",
          [g["key"] for g in board["groups"]["groups"]],
          [ids["done"], ids["todo"], ids["doing"]])

print("GROUPBY SWITCH CLEARS A STALE PIN")
tmp, store, clock = make_store()
with tmp:
    first = store.create_property({"name": "A", "type": "select",
                                   "options": ["x", "y"]})
    second = store.create_property({"name": "B", "type": "select",
                                    "options": ["p", "q"]})
    view = store.create_view({"name": "kan", "layout": "kanban",
                              "groupBy": first["id"],
                              "groupOrder": ["x", "y"]})
    switched = store.update_view(view["id"], {"groupBy": second["id"]})
    check("switch clears", switched["groupOrder"], None)
    view2 = store.create_view({"name": "kan2", "layout": "kanban",
                               "groupBy": first["id"],
                               "groupOrder": ["x"]})
    explicit = store.update_view(
        view2["id"], {"groupBy": second["id"], "groupOrder": ["q", "p"]})
    check("explicit replacement survives", explicit["groupOrder"], ["q", "p"])

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("All table-prefs checks passed.")
