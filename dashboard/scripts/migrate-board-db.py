#!/usr/bin/env python3
"""Migrate the session-scoped rows of an old chief-board.db into a new one.

Context: the dashboard move (P0) kept the generic board store (properties /
views / values / links / session_seen / session_action / archived_row) but
retired the work-item board. In this schema there are NOT separate tables per
row kind — every one of those tables holds both `row_kind='session'` and
`row_kind='work_item'` rows side by side, distinguished only by the
`row_kind` column (see chief_dashboard_store.py). So "drop the work-item
tables" really means: copy every row EXCEPT `row_kind='work_item'` rows, for
the tables that have a `row_kind` column. `link` and `session_action` have no
`row_kind` column; every row observed in production is session-scoped there,
so they are copied wholesale.

Usage:
    # Dry run (default) — prints what would be copied, writes nothing.
    python3 migrate-board-db.py OLD_DB_PATH NEW_DB_PATH

    # Actually copy.
    python3 migrate-board-db.py OLD_DB_PATH NEW_DB_PATH --apply

Safety:
    - The old db is opened strictly read-only (uri mode=ro). This script
      never writes to it, never runs VACUUM/checkpoint against it, and never
      touches its -wal/-shm files.
    - NEW_DB_PATH is a required, explicit argument — there is no default —
      so this can never accidentally target the real state dir.

Not idempotent: re-running --apply against a target that already has the
migrated rows will hit PRIMARY KEY collisions and abort (sqlite3 raises
IntegrityError, no partial silent duplication). Safe to re-run against an
empty/fresh target. A future version could add "--replace" (INSERT OR
REPLACE) if re-runs against a partially-migrated target are ever needed.
"""

import argparse
import sqlite3
import sys
from pathlib import Path

# Tables carried forward from the old generic board store, in FK-safe order
# (property before value, since value.property_id references property.id).
# Each entry: (table_name, has_row_kind_column).
SESSION_TABLES = [
    ("property", True),
    ("view", True),
    ("value", True),
    ("session_seen", True),
    ("archived_row", True),
    ("link", False),
    ("session_action", False),
]

# Retired work-item board data: rows with this row_kind are never migrated,
# even from tables that otherwise carry forward.
RETIRED_ROW_KIND = "work_item"

# New-schema columns not present in every old db (added by ALTER over time).
# When copying, missing source columns are filled with NULL/default so the
# INSERT lines up with the target's current schema.
OPTIONAL_COLUMNS = {
    "view": ["group_order_json"],
    "session_action": ["text", "status"],
}


def open_old_readonly(path: str) -> sqlite3.Connection:
    p = Path(path)
    if not p.is_file():
        raise SystemExit(f"old db not found: {path}")
    uri = f"file:{p.resolve()}?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def old_table_names(conn: sqlite3.Connection) -> set:
    rows = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
    ).fetchall()
    return {r["name"] for r in rows}


def old_columns(conn: sqlite3.Connection, table: str) -> list:
    return [r["name"] for r in conn.execute(f"PRAGMA table_info({table})").fetchall()]


def rows_to_migrate(conn: sqlite3.Connection, table: str, has_row_kind: bool):
    cols = old_columns(conn, table)
    if has_row_kind and "row_kind" in cols:
        query = f"SELECT * FROM {table} WHERE row_kind != ?"  # noqa: S608 (table name from fixed allowlist)
        rows = conn.execute(query, (RETIRED_ROW_KIND,)).fetchall()
    else:
        rows = conn.execute(f"SELECT * FROM {table}").fetchall()  # noqa: S608
    return cols, rows


def ensure_new_schema(target_path: str):
    """Create the target db with the current chief_dashboard_store schema by
    importing the store module and instantiating it (its __init__ runs
    CREATE TABLE IF NOT EXISTS for every table + the additive ALTERs)."""
    server_lib = Path(__file__).resolve().parent.parent / "server" / "lib"
    sys.path.insert(0, str(server_lib))
    import chief_dashboard_store  # type: ignore

    chief_dashboard_store.BoardStore(target_path)


def copy_table(old_conn, new_conn, table: str, has_row_kind: bool, apply: bool):
    old_cols, rows = rows_to_migrate(old_conn, table, has_row_kind)
    if not rows:
        return 0, old_cols

    new_cols_all = [r[1] for r in new_conn.execute(f"PRAGMA table_info({table})").fetchall()]
    # Only copy columns that exist in BOTH old and new (old db may predate an
    # additive ALTER; new schema may have dropped nothing so far, but this
    # keeps the script correct if it ever does).
    common_cols = [c for c in old_cols if c in new_cols_all]

    if apply:
        placeholders = ", ".join(["?"] * len(common_cols))
        col_list = ", ".join(common_cols)
        insert_sql = f"INSERT INTO {table} ({col_list}) VALUES ({placeholders})"  # noqa: S608
        for row in rows:
            values = [row[c] for c in common_cols]
            new_conn.execute(insert_sql, values)

    return len(rows), common_cols


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("old_db", help="Path to the OLD chief-board.db (read-only, e.g. the live AptusFit one)")
    parser.add_argument("new_db", help="Path to the NEW target db (required, explicit — never defaults)")
    parser.add_argument("--apply", action="store_true", help="Actually copy rows. Without this flag: dry run only.")
    args = parser.parse_args()

    old_conn = open_old_readonly(args.old_db)
    present = old_table_names(old_conn)

    plan = []
    for table, has_row_kind in SESSION_TABLES:
        if table not in present:
            print(f"  (skip) {table}: not present in old db")
            continue
        cols, rows = rows_to_migrate(old_conn, table, has_row_kind)
        plan.append((table, has_row_kind, len(rows)))

    print(f"Old db: {args.old_db}")
    print(f"New db: {args.new_db}")
    print(f"Mode:   {'APPLY (writing)' if args.apply else 'DRY RUN (no writes)'}")
    print()
    print("Tables that WOULD be copied (session-scoped rows only; "
          f"'{RETIRED_ROW_KIND}' rows excluded where the table has a row_kind column):")
    total = 0
    for table, has_row_kind, count in plan:
        tag = "filtered by row_kind" if has_row_kind else "copied wholesale (no row_kind column)"
        print(f"  {table:<16} {count:>6} rows   ({tag})")
        total += count
    print(f"  {'TOTAL':<16} {total:>6} rows")

    # Also report what's explicitly excluded, for visibility.
    excluded_total = 0
    for table, has_row_kind in SESSION_TABLES:
        if not has_row_kind or table not in present:
            continue
        cols = old_columns(old_conn, table)
        if "row_kind" not in cols:
            continue
        n = old_conn.execute(
            f"SELECT COUNT(*) FROM {table} WHERE row_kind = ?", (RETIRED_ROW_KIND,)  # noqa: S608
        ).fetchone()[0]
        if n:
            print(f"  (excluded) {table}: {n} row_kind='{RETIRED_ROW_KIND}' rows NOT migrated")
            excluded_total += n

    if not args.apply:
        print()
        print("Dry run only — no writes made. Re-run with --apply to copy.")
        old_conn.close()
        return

    # --apply: create/open target with the current schema, then copy.
    new_db_existed = Path(args.new_db).exists()
    ensure_new_schema(args.new_db)
    new_conn = sqlite3.connect(args.new_db)
    new_conn.row_factory = sqlite3.Row
    new_conn.execute("PRAGMA foreign_keys=ON")

    if not new_db_existed:
        # BoardStore.__init__ (called by ensure_new_schema above) seeds four
        # default views (view_needs_you / view_all_sessions / view_by_group /
        # view_archived) into any db that has none yet. The old db's own
        # `view` rows use those same fixed ids, so on a freshly-created
        # target they'd collide on INSERT. Since we're about to copy the
        # authoritative rows from the old db, clear the auto-seeded ones
        # first — but ONLY on a target this script just created; a
        # pre-existing target is left untouched (see IntegrityError handling
        # below for that case).
        with new_conn:
            new_conn.execute("DELETE FROM view")

    print()
    print(f"Applying to {args.new_db} ({'existed' if new_db_existed else 'created fresh'})...")
    try:
        with new_conn:
            copied_total = 0
            for table, has_row_kind, _ in plan:
                n, cols = copy_table(old_conn, new_conn, table, has_row_kind, apply=True)
                print(f"  {table:<16} copied {n:>6} rows (columns: {', '.join(cols)})")
                copied_total += n
        print(f"Done. {copied_total} rows copied.")
    except sqlite3.IntegrityError as exc:
        print(f"ABORTED: {exc}")
        print("This usually means the target already has these rows (not idempotent — "
              "see module docstring). Use a fresh target db.")
        sys.exit(1)
    finally:
        new_conn.close()
        old_conn.close()


if __name__ == "__main__":
    main()
