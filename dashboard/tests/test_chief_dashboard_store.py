#!/usr/bin/env python3
"""Direct-run tests for Chief Dashboard v2 custom-column storage."""
import os
import sys
import tempfile
import threading

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib"))

from chief_dashboard_store import BoardStore, resolve_agent_row_id  # noqa: E402

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def make_store():
    tempdir = tempfile.TemporaryDirectory()
    store = BoardStore(
        os.path.join(tempdir.name, "chief-board.db"),
        os.path.join(tempdir.name, "chief-board-schema.json"),
    )
    return tempdir, store


def agent(session=None, pane="w1:p2"):
    return {
        "agentSession": session,
        "paneId": pane,
        "paneIdSanitized": pane.replace(":", "-"),
        "label": "worker",
        "cwd": "/repo",
        "focused": False,
        "hookState": "idle",
        "hookSinceSec": 10,
        "herdrStatus": "idle",
        "disagree": False,
        "hasHookData": True,
        "screenState": "WAITING",
    }


print("ROW IDENTITY")
check("agent session id wins", resolve_agent_row_id(agent("sess-1")), "sess-1")
check("pane fallback is namespaced", resolve_agent_row_id(agent()), "pane:w1-p2")

print("\nROUND TRIP")
tmp, store = make_store()
with tmp:
    prop = store.create_property({"name": "Group", "type": "text"})
    row_id = resolve_agent_row_id(agent("sess-rt"))
    store.set_value({
        "rowKind": "session",
        "rowId": row_id,
        "propertyId": prop["id"],
        "value": "v1.0.8",
    })
    board = store.build_session_board([agent("sess-rt")])
    check("stored value returns on board", board["rows"][0]["values"][prop["id"]], "v1.0.8")
    check("schema export exists", os.path.exists(store.schema_path), True)

print("\nCONCURRENT WRITES")
tmp, store = make_store()
with tmp:
    prop = store.create_property({"name": "Index", "type": "number"})

    def write_value(index):
        store.set_value({
            "rowKind": "session",
            "rowId": f"sess-{index}",
            "propertyId": prop["id"],
            "value": index,
        })

    threads = [threading.Thread(target=write_value, args=(i,)) for i in range(25)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    board = store.build_session_board([agent(f"sess-{i}") for i in range(25)])
    check("all concurrent rows persisted", len([r for r in board["rows"] if prop["id"] in r["values"]]), 25)

print("\nDELETE CASCADE")
tmp, store = make_store()
with tmp:
    prop = store.create_property({"name": "Temp", "type": "text"})
    store.set_value({"rowKind": "session", "rowId": "sess-del", "propertyId": prop["id"], "value": "x"})
    store.delete_property(prop["id"])
    board = store.build_session_board([agent("sess-del")])
    check("deleted property disappears", any(p["id"] == prop["id"] for p in board["properties"]), False)
    check("deleted property takes values", prop["id"] in board["rows"][0]["values"], False)

print("\nSELECT OPTION PRUNE")
tmp, store = make_store()
with tmp:
    prop = store.create_property({
        "name": "Status",
        "type": "select",
        "options": ["todo", "doing", "done"],
    })
    doing = prop["options"][1]
    store.set_value({"rowKind": "session", "rowId": "sess-opt", "propertyId": prop["id"], "value": doing["id"]})
    kept = [prop["options"][0], prop["options"][2]]
    store.update_property(prop["id"], {"options": kept})
    board = store.build_session_board([agent("sess-opt")])
    check("deleting a selected option clears that cell", prop["id"] in board["rows"][0]["values"], False)

print("\nLAST LINE — the column that carries what NEEDS YOU stopped saying")
# 2026-09-06: NEEDS YOU narrowed to panes stopped at a prompt, so a finished
# or quiet worker now reports itself HERE. If this column goes blank the
# dashboard loses its only answer to "what is that pane doing?".
tmp, store = make_store()
with tmp:
    props = {p["id"]: p for p in store.list_properties("session")}
    check("LAST LINE is a session property", "derived:lastline" in props, True)
    check("...and is text, so it filters and groups like any other column",
          props["derived:lastline"]["type"], "text")
    check("...and is read-only — nobody edits what a pane said",
          props["derived:lastline"]["editable"], False)

    a = agent("sess-line")
    a["screenSignal"] = "  Next: PO merges it  "
    board = store.build_session_board([a])
    check("the pane's last line rides on the row, trimmed",
          board["rows"][0]["values"]["derived:lastline"], "Next: PO merges it")

    # classify_pane's own placeholder is not something a worker said. Left as
    # a sentence it reads like a status the human might act on.
    a2 = agent("sess-blank")
    a2["screenSignal"] = "(no readable content)"
    board = store.build_session_board([a2])
    check("an unreadable pane renders blank, never a placeholder sentence",
          board["rows"][0]["values"]["derived:lastline"], "")
    a3 = agent("sess-none")
    a3["screenSignal"] = None
    board = store.build_session_board([a3])
    check("no reading at all is blank too",
          board["rows"][0]["values"]["derived:lastline"], "")

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("All chief-dashboard store checks passed.")
