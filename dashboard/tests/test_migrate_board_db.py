#!/usr/bin/env python3
"""Direct-run tests for scripts/migrate-board-db.py.

Builds a synthetic OLD chief-board.db in a tempfile (never touches any real
db), runs the migration script as a subprocess (exactly as an operator
would), and checks:
  (a) dry-run performs no writes to the target
  (b) --apply copies the expected session-scoped tables/rows into the target
  (c) retired work_item rows are never copied
  (d) the source db file is provably unmodified after running (mtime + sha256
      hash compared before/after, for both dry-run and --apply)
"""
import hashlib
import os
import sqlite3
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MIGRATE_SCRIPT = os.path.join(ROOT, "scripts", "migrate-board-db.py")

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def check_true(label, cond):
    check(label, bool(cond), True)


def file_hash(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def make_old_db(path):
    """Build a minimal old-style chief-board.db with both session and
    work_item rows, matching the real production schema."""
    conn = sqlite3.connect(path)
    conn.executescript("""
        CREATE TABLE property(
            id TEXT PRIMARY KEY, row_kind TEXT NOT NULL, name TEXT NOT NULL,
            type TEXT NOT NULL, options_json TEXT NOT NULL DEFAULT '[]',
            position INTEGER NOT NULL, width INTEGER,
            created_ts REAL NOT NULL, updated_ts REAL NOT NULL
        );
        CREATE TABLE value(
            row_kind TEXT NOT NULL, row_id TEXT NOT NULL,
            property_id TEXT NOT NULL, value_json TEXT NOT NULL,
            updated_ts REAL NOT NULL, updated_by TEXT,
            PRIMARY KEY(row_kind, row_id, property_id)
        );
        CREATE TABLE session_seen(
            row_kind TEXT NOT NULL, row_id TEXT NOT NULL,
            last_seen_ts REAL NOT NULL, last_label TEXT, last_pane TEXT,
            PRIMARY KEY(row_kind, row_id)
        );
        CREATE TABLE view(
            id TEXT PRIMARY KEY, row_kind TEXT NOT NULL, name TEXT NOT NULL,
            layout TEXT NOT NULL DEFAULT 'table',
            columns_json TEXT NOT NULL DEFAULT '[]',
            sort_json TEXT NOT NULL DEFAULT '[]',
            filters_json TEXT NOT NULL DEFAULT '[]',
            group_by TEXT, position INTEGER NOT NULL DEFAULT 0,
            created_ts REAL NOT NULL, updated_ts REAL NOT NULL,
            group_order_json TEXT
        );
        CREATE TABLE link(
            work_row_id TEXT NOT NULL, target_kind TEXT NOT NULL,
            target_id TEXT NOT NULL, source TEXT NOT NULL,
            created_ts REAL NOT NULL,
            PRIMARY KEY(work_row_id, target_kind, target_id)
        );
        CREATE TABLE session_action(
            id INTEGER PRIMARY KEY AUTOINCREMENT, row_id TEXT NOT NULL,
            action TEXT NOT NULL, ts REAL NOT NULL, actor TEXT NOT NULL,
            reason TEXT NOT NULL DEFAULT '', text TEXT, status TEXT
        );
        CREATE TABLE archived_row(
            row_kind TEXT NOT NULL, row_id TEXT NOT NULL,
            archived INTEGER NOT NULL DEFAULT 0, ts REAL NOT NULL,
            actor TEXT NOT NULL DEFAULT '',
            PRIMARY KEY(row_kind, row_id)
        );
    """)
    now = time.time()
    # Session-scoped rows (should migrate).
    conn.execute(
        "INSERT INTO property VALUES ('prop_s1','session','Priority','select','[]',0,NULL,?,?)",
        (now, now))
    conn.execute(
        "INSERT INTO view VALUES ('view_all_sessions','session','All sessions','table','[]','[]','[]',NULL,0,?,?,NULL)",
        (now, now))
    conn.execute(
        "INSERT INTO value VALUES ('session','sess-1','prop_s1','\"high\"',?,'tester')", (now,))
    conn.execute(
        "INSERT INTO session_seen VALUES ('session','sess-1',?,'worker','w1:p1')", (now,))
    conn.execute(
        "INSERT INTO archived_row VALUES ('session','sess-old',1,?,'tester')", (now,))
    conn.execute(
        "INSERT INTO session_action(row_id,action,ts,actor,reason,text,status) "
        "VALUES ('sess-1','sent',?,'tester','hi','hi there','sent')", (now,))
    # Retired work-item rows (must NOT migrate).
    conn.execute(
        "INSERT INTO property VALUES ('prop_w1','work_item','Stage','select','[]',0,NULL,?,?)",
        (now, now))
    conn.execute(
        "INSERT INTO view VALUES ('view_all_work','work_item','All work','table','[]','[]','[]',NULL,0,?,?,NULL)",
        (now, now))
    conn.execute(
        "INSERT INTO value VALUES ('work_item','wi-1','prop_w1','\"todo\"',?,'tester')", (now,))
    conn.execute(
        "INSERT INTO archived_row VALUES ('work_item','wi-old',1,?,'tester')", (now,))
    conn.commit()
    conn.close()


def run_migrate(args):
    return subprocess.run(
        [sys.executable, MIGRATE_SCRIPT] + args,
        capture_output=True, text=True,
    )


with tempfile.TemporaryDirectory() as tmp:
    old_db = os.path.join(tmp, "old-chief-board.db")
    make_old_db(old_db)

    old_mtime_before = os.stat(old_db).st_mtime_ns
    old_hash_before = file_hash(old_db)

    # --- (a) dry run: no writes to target, source untouched ---
    dry_target = os.path.join(tmp, "dry-target.db")
    result = run_migrate([old_db, dry_target])
    check("dry run exits 0", result.returncode, 0)
    check_true("dry run reports DRY RUN mode", "DRY RUN" in result.stdout)
    check_true("dry run reports 4 session rows copyable across property/view/value/session_seen",
               "property" in result.stdout and "4" in result.stdout.split("TOTAL")[0])
    check_true("dry run creates no target file", not os.path.exists(dry_target))

    check("source mtime unchanged after dry run",
          os.stat(old_db).st_mtime_ns, old_mtime_before)
    check("source hash unchanged after dry run", file_hash(old_db), old_hash_before)

    # --- (b) --apply: copies expected tables/rows ---
    apply_target = os.path.join(tmp, "apply-target.db")
    result = run_migrate([old_db, apply_target, "--apply"])
    check("apply exits 0", result.returncode, 0)
    check_true("apply reports APPLY mode", "APPLY" in result.stdout)
    check_true("apply target file created", os.path.exists(apply_target))

    conn = sqlite3.connect(apply_target)
    conn.row_factory = sqlite3.Row

    def count(table, where=None):
        sql = f"SELECT COUNT(*) FROM {table}"
        if where:
            sql += f" WHERE {where}"
        return conn.execute(sql).fetchone()[0]

    check("session property row migrated", count("property", "row_kind='session'"), 1)
    check("session value row migrated", count("value", "row_kind='session'"), 1)
    check("session_seen row migrated", count("session_seen"), 1)
    check("archived session row migrated", count("archived_row", "row_kind='session'"), 1)
    check("session_action row migrated", count("session_action"), 1)
    check("our test session view (view_all_sessions) present",
          count("view", "id='view_all_sessions' AND row_kind='session'"), 1)

    # --- (c) retired work_item rows never copied ---
    check("work_item property NOT migrated", count("property", "row_kind='work_item'"), 0)
    check("work_item value NOT migrated", count("value", "row_kind='work_item'"), 0)
    check("work_item archived row NOT migrated", count("archived_row", "row_kind='work_item'"), 0)
    check("work_item view (view_all_work) NOT migrated",
          count("view", "id='view_all_work'"), 0)
    conn.close()

    # --- (d) source untouched after --apply too ---
    check("source mtime unchanged after --apply",
          os.stat(old_db).st_mtime_ns, old_mtime_before)
    check("source hash unchanged after --apply", file_hash(old_db), old_hash_before)

    # --- re-run --apply against the same (now non-empty) target: must not
    # silently duplicate rows; script documents this as non-idempotent and
    # should abort cleanly instead. ---
    result2 = run_migrate([old_db, apply_target, "--apply"])
    check_true("re-apply against populated target does not exit 0 (documented non-idempotent, aborts instead of duplicating)",
               result2.returncode != 0)
    conn = sqlite3.connect(apply_target)
    check("re-apply left row counts unchanged (no silent duplication)",
          conn.execute("SELECT COUNT(*) FROM session_seen").fetchone()[0], 1)
    conn.close()

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("All migrate-board-db checks passed.")
