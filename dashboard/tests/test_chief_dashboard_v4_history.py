#!/usr/bin/env python3
"""Direct-run tests for Chief Dashboard v4 reach, read side: the session
action history (full message text + delivery status) and the read handlers'
query-string contract. Tmpdirs only — no herdr, no panes, no network.

The load-bearing test here is `failed rows are invisible to both gates`: a
failed send is logged so the PO can see it in the timeline, and must NOT
reach session_action_annotations() (which captions ended rows) or
last_ladder_action() (which decides which buttons the UI offers).
"""
import os
import sqlite3
import sys
import tempfile

LIB = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib")
sys.path.insert(0, LIB)

from chief_dashboard_store import BoardStore  # noqa: E402

fails = []


def check(label, got, want=True):
    ok = (got == want) if want is not True else bool(got)
    if not ok:
        fails.append(f"{label}: got {got!r}"
                     + (f" want {want!r}" if want is not True else ""))
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def fresh_store():
    tmp = tempfile.mkdtemp()
    return BoardStore(db_path=os.path.join(tmp, "b.db"),
                      schema_path=os.path.join(tmp, "s.json")), tmp


print("== migration: additive + idempotent on a pre-v4 table ==")
legacy_dir = tempfile.mkdtemp()
legacy_db = os.path.join(legacy_dir, "legacy.db")
conn = sqlite3.connect(legacy_db)
conn.execute("""CREATE TABLE session_action(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    row_id TEXT NOT NULL, action TEXT NOT NULL,
                    ts REAL NOT NULL, actor TEXT NOT NULL,
                    reason TEXT NOT NULL DEFAULT '')""")
conn.execute("INSERT INTO session_action(row_id, action, ts, actor, reason)"
             " VALUES('r1','message',100.0,'po','queued: old clipped text')")
conn.execute("INSERT INTO session_action(row_id, action, ts, actor, reason)"
             " VALUES('r1','stop',101.0,'po','idle')")
conn.commit()
conn.close()

for run in (1, 2):
    store = BoardStore(db_path=legacy_db,
                       schema_path=os.path.join(legacy_dir, "s.json"))
    c = sqlite3.connect(legacy_db)
    cols = [r[1] for r in c.execute("PRAGMA table_info(session_action)")]
    n = c.execute("SELECT COUNT(*) FROM session_action").fetchone()[0]
    c.close()
    check(f"run {run}: text column present", "text" in cols)
    check(f"run {run}: status column present", "status" in cols)
    check(f"run {run}: existing rows untouched", n, 2)

hist = store.session_action_history("r1")
check("legacy rows read status 'sent'", [e["status"] for e in hist],
      ["sent", "sent"])
msg = next(e for e in hist if e["action"] == "message")
check("legacy message text recovered from reason", msg["text"],
      "old clipped text")
check("legacy message flagged truncated", msg.get("truncated"), True)
check("legacy ladder row carries no text",
      next(e for e in hist if e["action"] == "stop")["text"], None)
check("legacy reason format is untouched",
      next(e for e in hist if e["action"] == "message")["reason"],
      "queued: old clipped text")

print("== full text is stored untruncated ==")
store, _ = fresh_store()
long_text = "x" * 500 + " END"
store.log_session_action("s1", "message", "po", long_text[:80],
                         text=long_text, status="sent")
entry = store.session_action_history("s1")[0]
check("full text round-trips", entry["text"], long_text)
check("no truncated flag when text is stored",
      "truncated" in entry, False)
check("reason still the 80-char summary", entry["reason"], long_text[:80])

print("== failed rows are invisible to both gates ==")
store, _ = fresh_store()
store.log_session_action("s2", "stop", "po", "idle · 1.2 MB", status="sent")
check("gate sees the stop", store.last_ladder_action(["s2"])["s2"], "stop")
check("note reads off the stop",
      store.ended_annotation(store.session_action_annotations(["s2"])["s2"]),
      "stopped by you")
store.log_session_action("s2", "close", "po",
                         "NOT SUBMITTED — text stuck in the input box",
                         status="failed")
check("failed close does NOT move the ladder gate",
      store.last_ladder_action(["s2"])["s2"], "stop")
check("failed close does NOT recaption the row",
      store.ended_annotation(store.session_action_annotations(["s2"])["s2"]),
      "stopped by you")
store.log_session_action("s3", "message", "po", "boom", text="boom",
                         status="failed")
check("a row whose ONLY action failed has no ladder state",
      store.last_ladder_action(["s3"])["s3"], None)
check("a row whose ONLY action failed has no annotation",
      "s3" in store.session_action_annotations(["s3"]), False)

print("== history shows failures (it gates nothing) ==")
h = store.session_action_history("s2")
check("newest first", [e["action"] for e in h], ["close", "stop"])
check("failed entry present with its status",
      [e["status"] for e in h], ["failed", "sent"])
check("failed message visible on its own row",
      store.session_action_history("s3")[0]["status"], "failed")

print("== history bounds + argument validation ==")
store, _ = fresh_store()
for i in range(12):
    store.log_session_action("s4", "message", "po", f"m{i}",
                             text=f"m{i}", status="sent")
check("limit clamps low", len(store.session_action_history("s4", 0)), 1)
check("limit clamps high", len(store.session_action_history("s4", 9999)), 12)
check("default returns all 12", len(store.session_action_history("s4")), 12)
check("unknown row is empty, not an error",
      store.session_action_history("nope"), [])
try:
    store.session_action_history("")
    check("empty rowId rejected", False, True)
except ValueError:
    check("empty rowId rejected", True, True)
try:
    store.log_session_action("s4", "message", "po", "x", status="delivered")
    check("bad status rejected", False, True)
except ValueError:
    check("bad status rejected", True, True)

print("== queued status rides alongside the frozen reason format ==")
store, _ = fresh_store()
store.log_session_action("s5", "message", "po", "queued: hello",
                         text="hello", status="queued")
e = store.session_action_history("s5")[0]
check("queued status", e["status"], "queued")
check("queued reason untouched", e["reason"], "queued: hello")
check("text has no queued prefix", e["text"], "hello")

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("ALL PASS")
