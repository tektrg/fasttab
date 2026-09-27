#!/usr/bin/env python3
"""SQLite-backed custom board columns for the chief dashboard.

The computed dashboard remains owned by chief_dashboard_views.py. This module
adds the editable column registry and per-session values beside it.
"""
import contextlib
import json
import os
import re
import sqlite3
import threading
import time
import uuid

import dashboard_config
import pane_screen_signals
from chief_dashboard_feeds import sanitize_pane_id  # noqa: F401


# P0 dashboard move: the board db + its schema export used to live under
# <this checkout>/.claude/ (REPO_ROOT was this repo's own parent folder).
# They're state, not source (never committed — see .gitignore), and per
# design call #1 now live in the shared state dir instead, so they survive
# independent of wherever this checkout is and never leave stray files in a
# git worktree again.
DEFAULT_DB_PATH = os.path.join(dashboard_config.STATE_HOME, "chief-board.db")
DEFAULT_SCHEMA_PATH = os.path.join(
    dashboard_config.STATE_HOME, "chief-board-schema.json")

ROW_KIND_SESSION = "session"
ROW_KIND_WORK_ITEM = "work_item"
LINK_TARGET_KINDS = {"session", "branch", "worktree"}
LINK_SOURCE_MANUAL = "manual"
PROPERTY_TYPES = {"text", "select", "multi_select", "number", "checkbox", "date"}
OPTION_COLORS = ["gray", "blue", "green", "amber", "red", "purple", "pink"]

# Phase 2: an ended session row lingers 72h, visibly marked ended, then
# disappears. Named constant + injectable clock (BoardStore(now_fn=...))
# so tests prove expiry without waiting three days.
ENDED_TTL_SEC = 72 * 3600

VIEW_LAYOUTS = {"table", "kanban"}
FILTER_OPS = {"is", "is not", "contains", "is empty", "is not empty", ">", "<"}
SORT_DIRS = {"asc", "desc"}

DERIVED_SESSION_PROPERTIES = [
    {"id": "derived:state", "rowKind": ROW_KIND_SESSION, "name": "STATE", "type": "text", "source": "derived", "editable": False, "position": 0, "width": 90},
    {"id": "derived:screen", "rowKind": ROW_KIND_SESSION, "name": "SCREEN", "type": "text", "source": "derived", "editable": False, "position": 1, "width": 110},
    {"id": "derived:label", "rowKind": ROW_KIND_SESSION, "name": "LABEL", "type": "text", "source": "derived", "editable": False, "position": 2, "width": 220},
    {"id": "derived:pane", "rowKind": ROW_KIND_SESSION, "name": "PANE", "type": "text", "source": "derived", "editable": False, "position": 3, "width": 110},
    {"id": "derived:since", "rowKind": ROW_KIND_SESSION, "name": "SINCE", "type": "number", "source": "derived", "editable": False, "position": 4, "width": 80},
    {"id": "derived:cwd", "rowKind": ROW_KIND_SESSION, "name": "CWD", "type": "text", "source": "derived", "editable": False, "position": 5, "width": 260},
    {"id": "derived:herdr", "rowKind": ROW_KIND_SESSION, "name": "HERDR", "type": "text", "source": "derived", "editable": False, "position": 6, "width": 90},
    {"id": "derived:disagreement", "rowKind": ROW_KIND_SESSION, "name": "DISAGREE", "type": "checkbox", "source": "derived", "editable": False, "position": 7, "width": 80},
    # Phase 5 (v3 reclaim): measured RSS across the pane's foreground process
    # tree, in bytes. NUMERIC so it sorts correctly (None sorts last — an
    # unmeasurable row must never read as "cheapest to keep"). The server
    # enriches each agent with `memoryBytes` before building the board; rows
    # built without it read None and render `—`.
    {"id": "derived:memory", "rowKind": ROW_KIND_SESSION, "name": "MEMORY", "type": "number", "source": "derived", "editable": False, "position": 8, "width": 90},
    # Phase 6 (v3 reclaim): board-only archive flag. Hiding a row frees
    # nothing and touches no process. Checkbox so it sorts/filters/groups
    # with the existing machinery; non-editable so the only writers are the
    # archive endpoints (a clickable cell would bypass the actor rule).
    {"id": "archived", "rowKind": ROW_KIND_SESSION, "name": "ARCHIVED", "type": "checkbox", "source": "derived", "editable": False, "position": 9, "width": 90},
    # Phase 8 (v4 reach): % of the context window in use, parsed off the
    # pane's status line. NUMERIC so it sorts (None sorts last — an
    # unreadable row must never read as "most headroom", same rule as
    # derived:memory). The server enriches each agent with `contextPct`
    # before building the board; rows built without it read None and
    # render `—`. autocompactPct rides on the agent dict itself (it is a
    # rare badge, not a column — see the phase 8 brief).
    {"id": "derived:context", "rowKind": ROW_KIND_SESSION, "name": "CONTEXT", "type": "number", "source": "derived", "editable": False, "position": 10, "width": 80},
    # 2026-09-06: the pane's last meaningful line — the same string NEEDS YOU
    # shows as a row's reason, and for the same purpose: what is this worker
    # actually saying? NEEDS YOU now lists only panes stopped at a prompt, so
    # every finished / quiet / crashed worker reads its status HERE instead.
    # Text, not derived-state: it is prose (classify_pane.last_signal_line
    # already truncates a long recap from both ends), so it sorts
    # alphabetically, which is meaningless — but it filters and groups with
    # the same machinery as every other column, and that is what makes it
    # searchable. Unreadable panes carry "" and render blank, never a
    # placeholder sentence that could be mistaken for something the worker
    # said.
    {"id": "derived:lastline", "rowKind": ROW_KIND_SESSION, "name": "LAST LINE", "type": "text", "source": "derived", "editable": False, "position": 11, "width": 420},
    # Remote-herdr (R21): which machine owns this pane — "local" for every
    # row that exists today. Appended at the END, never reordering the
    # columns above (every saved view's column order is positional).
    {"id": "derived:machine", "rowKind": ROW_KIND_SESSION, "name": "MACHINE", "type": "text", "source": "derived", "editable": False, "position": 12, "width": 90},
]

def resolve_agent_row_id(agent_row):
    """Return the stable board row id for one live agent row."""
    session_id = agent_row.get("agentSession")
    if session_id:
        return session_id
    pane_id = agent_row.get("paneId")
    sanitized = agent_row.get("paneIdSanitized")
    if not sanitized and pane_id:
        sanitized = sanitize_pane_id(pane_id)
    if sanitized:
        return f"pane:{sanitized}"
    label = agent_row.get("label") or "unknown"
    return f"pane:{sanitize_pane_id(label)}"


#: classify_pane's placeholder when a pane has nothing readable on it.
NO_SIGNAL_PLACEHOLDER = "(no readable content)"


def _lastline(signal):
    if not signal or signal.strip() == NO_SIGNAL_PLACEHOLDER:
        return ""
    return signal.strip()


def derived_values_for_agent(agent_row):
    machine = agent_row.get("machine") or "local"
    if machine != "local":
        # R4: never read hookState here — a remote row never has one (the
        # hook only ever pushes to THIS Mac). "unknown" (not "no data") when
        # the screen itself can't be classified — "no data" would read as
        # "nothing came from the Air" when in fact a screen WAS read.
        state = pane_screen_signals.resolve_state(
            None, agent_row.get("screenState")) or "unknown"
    else:
        # ONE precedence rule (pane_screen_signals.resolve_state): the screen's
        # positive reads (live spinner, open dialog, crash, login wall) outrank
        # a stale hook word; where the screen cannot say, the hook stands.
        hook = agent_row.get("hookState") if agent_row.get("hasHookData") else None
        state = pane_screen_signals.resolve_state(
            hook, agent_row.get("screenState"),
            hook_age_sec=agent_row.get("hookSinceSec")) or "no data"
    return {
        "derived:state": state,
        "derived:screen": agent_row.get("screenState") or "—",
        "derived:label": (agent_row.get("label") or "") + (" •" if agent_row.get("focused") else ""),
        "derived:pane": agent_row.get("paneId") or agent_row.get("paneIdSanitized") or "",
        "derived:since": agent_row.get("hookSinceSec"),
        "derived:cwd": agent_row.get("cwd") or "",
        "derived:herdr": agent_row.get("herdrStatus") or "—",
        "derived:disagreement": bool(agent_row.get("disagree")),
        # Phase 5: numeric bytes from the memory sampler (None = unmeasurable).
        "derived:memory": agent_row.get("memoryBytes"),
        # Phase 8: numeric % from the status-line parser (None = unreadable).
        "derived:context": agent_row.get("contextPct"),
        # The screen's last meaningful line. "(no readable content)" is
        # classify_pane's own placeholder for an empty pane, not something a
        # worker said — blank it so the column never puts words in a mouth.
        "derived:lastline": _lastline(agent_row.get("screenSignal")),
        "derived:machine": machine,
    }


# ── Phase 3: work items ──
#
# A work item is the delivery work itself (a Notion delivery-run page today;
# `md:<path>` / `jira:<key>` later — the `<provider>:<id>` ref shape needs no
# migration when they arrive). It outlives every session under it, so notes
# and status belong here, not on session rows. Work-item rows are DURABLE:
# the 72h lingering rule is sessions-only; a work item stays until its record
# leaves the source file.

# P0 dashboard move: DERIVED_WORK_ITEM_PROPERTIES, LINK_SOURCE_AUTHORITATIVE/
# _HEURISTIC, item_numbers_in_label, parse_work_item_ref, and work_item_row_id
# are all RETIRED along with build_workitem_board below — none has a
# MOVE-set caller left (resolve_work_item_links / _resolve_named_link, the
# only callers of the authoritative/heuristic link-source constants, are
# themselves work_item-board-only and retired with it). LINK_SOURCE_MANUAL
# (defined above) is unaffected — it backs the generic, still-MOVE-set manual
# links plumbing (create_link / list_links / /api/links).


class BoardStore:
    def __init__(self, db_path=DEFAULT_DB_PATH, schema_path=DEFAULT_SCHEMA_PATH, now_fn=None):
        self.db_path = db_path
        self.schema_path = schema_path
        # Injectable clock for tests: now_fn() -> epoch seconds.
        self._now_fn = now_fn or time.time
        self._write_lock = threading.Lock()
        os.makedirs(os.path.dirname(self.db_path), exist_ok=True)
        os.makedirs(os.path.dirname(self.schema_path), exist_ok=True)
        self._init_db()
        self._seed_default_views()

    @contextlib.contextmanager
    def _connect(self):
        """Yield a connection and always close it on exit.

        `with sqlite3.connect(...) as conn` only commits/rolls back — it never
        closes, so each call used to leave a db + wal handle open until GC
        (~40 open on the live server 25 min after start, 2026-09-27).
        """
        conn = sqlite3.connect(self.db_path, timeout=30, isolation_level=None)
        try:
            conn.row_factory = sqlite3.Row
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA foreign_keys=ON")
            with conn:
                yield conn
        finally:
            conn.close()

    def _init_db(self):
        with self._connect() as conn:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS property(
                    id TEXT PRIMARY KEY,
                    row_kind TEXT NOT NULL,
                    name TEXT NOT NULL,
                    type TEXT NOT NULL,
                    options_json TEXT NOT NULL DEFAULT '[]',
                    position INTEGER NOT NULL,
                    width INTEGER,
                    created_ts REAL NOT NULL,
                    updated_ts REAL NOT NULL
                )
            """)
            conn.execute("""
                CREATE TABLE IF NOT EXISTS value(
                    row_kind TEXT NOT NULL,
                    row_id TEXT NOT NULL,
                    property_id TEXT NOT NULL REFERENCES property(id) ON DELETE CASCADE,
                    value_json TEXT NOT NULL,
                    updated_ts REAL NOT NULL,
                    updated_by TEXT,
                    PRIMARY KEY(row_kind, row_id, property_id)
                )
            """)
            conn.execute("""
                CREATE TABLE IF NOT EXISTS session_seen(
                    row_kind TEXT NOT NULL,
                    row_id TEXT NOT NULL,
                    last_seen_ts REAL NOT NULL,
                    last_label TEXT,
                    last_pane TEXT,
                    PRIMARY KEY(row_kind, row_id)
                )
            """)
            conn.execute("""
                CREATE TABLE IF NOT EXISTS view(
                    id TEXT PRIMARY KEY,
                    row_kind TEXT NOT NULL,
                    name TEXT NOT NULL,
                    layout TEXT NOT NULL DEFAULT 'table',
                    columns_json TEXT NOT NULL DEFAULT '[]',
                    sort_json TEXT NOT NULL DEFAULT '[]',
                    filters_json TEXT NOT NULL DEFAULT '[]',
                    group_by TEXT,
                    position INTEGER NOT NULL DEFAULT 0,
                    created_ts REAL NOT NULL,
                    updated_ts REAL NOT NULL
                )
            """)
            # Table layout prefs (wrap/sticky) ride inside columns_json entries
            # (no migration — _validate_columns defaults them). Kanban column
            # order is per-view state of its own, so it gets a real column:
            # NULL = server order, a list pins the group sequence (new groups
            # append at the end). ALTER, not CREATE-only: live DBs predate it.
            self._add_columns_locked(conn, "view", (
                ("group_order_json", "TEXT"),
            ))
            conn.execute("""
                CREATE TABLE IF NOT EXISTS link(
                    work_row_id TEXT NOT NULL,
                    target_kind TEXT NOT NULL,
                    target_id TEXT NOT NULL,
                    source TEXT NOT NULL,
                    created_ts REAL NOT NULL,
                    PRIMARY KEY(work_row_id, target_kind, target_id)
                )
            """)
            # Phase 5 (v3 reclaim): every stop/close/relaunch writes one row
            # here. Phase 2's lingering makes a stopped session and a crashed
            # one look identical — the log is what lets an ended row read
            # `ended · stopped by you` instead of a bare `ended`.
            # (Deliberately NOT in the schema export: it is an action log, not
            # board shape, so it never dirties chief-board-schema.json.)
            conn.execute("""
                CREATE TABLE IF NOT EXISTS session_action(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    row_id TEXT NOT NULL,
                    action TEXT NOT NULL,
                    ts REAL NOT NULL,
                    actor TEXT NOT NULL,
                    reason TEXT NOT NULL DEFAULT ''
                )
            """)
            conn.execute("""
                CREATE INDEX IF NOT EXISTS idx_session_action_row
                ON session_action(row_id, ts)
            """)
            # v4 history: `text` + `status`, added by ALTER rather than baked
            # into the CREATE above — the table predates them in every live
            # db, and a CREATE IF NOT EXISTS never revisits an existing one.
            self._add_columns_locked(conn, "session_action", (
                # FULL message text, untruncated. `reason` keeps carrying its
                # 80-char prefix-and-all summary unchanged (the annotation
                # reader renders off it), so this column is additive, not a
                # replacement. NULL on ladder actions, which have no text.
                ("text", "TEXT"),
                # 'sent' | 'queued' | 'failed'. NULL on every pre-existing row
                # and read as 'sent' — those rows were only ever written after
                # a verified success.
                ("status", "TEXT"),
            ))
            # Phase 6 (v3 reclaim): the archive flag. Board-only tidying —
            # hiding a row frees nothing and touches no process. Deliberately
            # NOT in the schema export (board state, not board shape).
            conn.execute("""
                CREATE TABLE IF NOT EXISTS archived_row(
                    row_kind TEXT NOT NULL,
                    row_id TEXT NOT NULL,
                    archived INTEGER NOT NULL DEFAULT 0,
                    ts REAL NOT NULL,
                    actor TEXT NOT NULL DEFAULT '',
                    PRIMARY KEY(row_kind, row_id)
                )
            """)

    @staticmethod
    def _add_columns_locked(conn, table, columns):
        """Additive, idempotent column migration for one table.

        SQLite has no `ADD COLUMN IF NOT EXISTS`, so the existing columns are
        read first and only the missing ones are ALTERed. Every added column
        is nullable with no default, which is what makes this safe to run on a
        live db: existing rows keep their values and read NULL for the new
        column, so a reader written before the migration still sees the same
        rows. Runs on every boot — a second run finds nothing to do.
        """
        have = {r["name"] for r in
                conn.execute(f"PRAGMA table_info({table})").fetchall()}
        for name, decl in columns:
            if name not in have:
                conn.execute(f"ALTER TABLE {table} ADD COLUMN {name} {decl}")

    def list_stored_properties(self, row_kind=ROW_KIND_SESSION):
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT * FROM property WHERE row_kind = ? ORDER BY position, created_ts",
                (row_kind,),
            ).fetchall()
        return [self._property_from_row(row) for row in rows]

    def list_properties(self, row_kind=ROW_KIND_SESSION):
        if row_kind == ROW_KIND_SESSION:
            return DERIVED_SESSION_PROPERTIES + self.list_stored_properties(row_kind)
        # P0 dashboard move: the work_item row kind's derived properties
        # (DERIVED_WORK_ITEM_PROPERTIES) are RETIRED along with
        # build_workitem_board — any other rowKind falls through to plain
        # stored properties, same as before this constant existed.
        return self.list_stored_properties(row_kind)

    def create_property(self, payload):
        row_kind = payload.get("rowKind") or ROW_KIND_SESSION
        prop_type = self._validate_type(payload.get("type") or "text")
        name = self._validate_name(payload.get("name") or payload.get("title"))
        options = self._normalize_options(payload.get("options") or [], prop_type)
        now = time.time()
        with self._write_lock, self._connect() as conn:
            max_pos = conn.execute(
                "SELECT MAX(position) AS max_position FROM property WHERE row_kind = ?",
                (row_kind,),
            ).fetchone()["max_position"]
            prop_id = payload.get("id") or f"prop_{uuid.uuid4().hex[:12]}"
            conn.execute(
                """INSERT INTO property
                   (id, row_kind, name, type, options_json, position, width, created_ts, updated_ts)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (prop_id, row_kind, name, prop_type, json.dumps(options),
                 int(max_pos if max_pos is not None else len(DERIVED_SESSION_PROPERTIES)) + 1,
                 payload.get("width"), now, now),
            )
            prop = self._get_property(conn, prop_id)
            self._export_schema_locked(conn)
            return prop

    def update_property(self, prop_id, payload):
        with self._write_lock, self._connect() as conn:
            prop = self._get_property(conn, prop_id)
            name = prop["name"]
            prop_type = prop["type"]
            options = prop["options"]
            if "name" in payload or "title" in payload:
                name = self._validate_name(payload.get("name") or payload.get("title"))
            if "type" in payload:
                prop_type = self._validate_type(payload["type"])
            if "options" in payload or "type" in payload:
                options = self._normalize_options(payload.get("options", options), prop_type)
            type_changed = prop_type != prop["type"]
            if type_changed:
                # A type change migrates existing cell values where they map
                # instead of silently dropping them (the phase-2 bug: a text
                # `v1.0.8` did not become the matching `v1.0.8` option).
                # text/number/date → select creates the option when absent;
                # anything that genuinely cannot map is cleared and REPORTED
                # in the returned `migration` summary so the UI can say so.
                migration = self._migrate_values_for_type_change(
                    conn, prop, prop_type, options)
                options = migration["options"]
                conn.execute(
                    """UPDATE property SET name = ?, type = ?, options_json = ?,
                       width = COALESCE(?, width), updated_ts = ? WHERE id = ?""",
                    (name, prop_type, json.dumps(options), payload.get("width"), time.time(), prop_id),
                )
                for row_kind, row_id, new_value in migration["updates"]:
                    conn.execute(
                        """UPDATE value SET value_json = ?, updated_ts = ?
                           WHERE row_kind = ? AND row_id = ? AND property_id = ?""",
                        (json.dumps(new_value), time.time(), row_kind, row_id, prop_id),
                    )
                for row_kind, row_id in migration["deletes"]:
                    conn.execute(
                        "DELETE FROM value WHERE row_kind = ? AND row_id = ? AND property_id = ?",
                        (row_kind, row_id, prop_id),
                    )
                updated = self._get_property(conn, prop_id)
                self._export_schema_locked(conn)
                updated["migration"] = {
                    "from": prop["type"],
                    "to": prop_type,
                    "migrated": migration["migrated"],
                    "dropped": migration["dropped"],
                    "createdOptions": migration["created_options"],
                }
                return updated
            conn.execute(
                """UPDATE property SET name = ?, type = ?, options_json = ?,
                   width = COALESCE(?, width), updated_ts = ? WHERE id = ?""",
                (name, prop_type, json.dumps(options), payload.get("width"), time.time(), prop_id),
            )
            updated = self._get_property(conn, prop_id)
            self._prune_values_for_property(conn, updated)
            self._export_schema_locked(conn)
            return updated

    def _migrate_values_for_type_change(self, conn, old_prop, new_type, base_options):
        """Map every existing cell to the new type. Returns the final option
        list (augmented with created options for select targets) plus the
        per-row updates/deletes and counts."""
        rows = conn.execute(
            "SELECT row_kind, row_id, value_json FROM value WHERE property_id = ?",
            (old_prop["id"],),
        ).fetchall()
        options = [dict(o) for o in base_options]
        by_id = {o["id"]: o for o in options}
        by_name = {o["name"].lower(): o for o in options}
        old_options = {o["id"]: o["name"] for o in old_prop["options"]}
        created_options = 0

        def ensure_option(display):
            nonlocal created_options
            clean = " ".join(str(display).split())[:60]
            if not clean:
                return None
            hit = by_name.get(clean.lower())
            if hit:
                return hit["id"]
            opt = {"id": f"opt_{uuid.uuid4().hex[:10]}", "name": clean,
                   "color": OPTION_COLORS[len(options) % len(OPTION_COLORS)]}
            options.append(opt)
            by_id[opt["id"]] = opt
            by_name[clean.lower()] = opt
            created_options += 1
            return opt["id"]

        def display_text(scalar):
            if isinstance(scalar, bool):
                return "yes" if scalar else "no"
            if old_prop["type"] in ("select", "multi_select"):
                return old_options.get(str(scalar), str(scalar))
            return str(scalar)

        def map_scalar_to_option(scalar):
            if scalar is None:
                return None
            if str(scalar) in by_id:
                return str(scalar)
            return ensure_option(display_text(scalar))

        updates, deletes = [], []
        migrated, dropped = 0, 0
        for row in rows:
            current = json.loads(row["value_json"])
            if current is None or current == "" or current == []:
                deletes.append((row["row_kind"], row["row_id"]))
                continue
            new_value = None
            ok = False
            if new_type in ("select", "multi_select"):
                if new_type == "select":
                    cands = current if isinstance(current, list) else [current]
                    if len(cands) == 1:
                        mapped = map_scalar_to_option(cands[0])
                        if mapped is not None:
                            new_value, ok = mapped, True
                    # A multi-valued cell cannot pick one option: genuinely
                    # unmappable, counted as dropped below.
                else:
                    cands = current if isinstance(current, list) else [current]
                    mapped = [m for m in (map_scalar_to_option(c) for c in cands)
                              if m is not None]
                    if mapped:
                        new_value, ok = mapped, True
            elif new_type == "text" or new_type == "date":
                if isinstance(current, list):
                    new_value = ", ".join(display_text(c) for c in current)
                else:
                    new_value = display_text(current)
                ok = True
            elif new_type == "number":
                try:
                    scalar = current[0] if isinstance(current, list) else current
                    text = display_text(scalar)
                    new_value = float(text)
                    ok = True
                except (TypeError, ValueError):
                    ok = False
            elif new_type == "checkbox":
                scalar = current[0] if isinstance(current, list) else current
                text = display_text(scalar).strip().lower()
                if isinstance(scalar, bool):
                    new_value, ok = scalar, True
                elif text in ("true", "yes", "1"):
                    new_value, ok = True, True
                elif text in ("false", "no", "0"):
                    new_value, ok = False, True
                else:
                    try:
                        new_value, ok = bool(float(text)), True
                    except (TypeError, ValueError):
                        ok = False
            if ok:
                updates.append((row["row_kind"], row["row_id"], new_value))
                migrated += 1
            else:
                deletes.append((row["row_kind"], row["row_id"]))
                dropped += 1
        return {"options": options, "updates": updates, "deletes": deletes,
                "migrated": migrated, "dropped": dropped,
                "created_options": created_options}

    def delete_property(self, prop_id):
        with self._write_lock, self._connect() as conn:
            self._get_property(conn, prop_id)
            conn.execute("DELETE FROM property WHERE id = ?", (prop_id,))
            self._export_schema_locked(conn)
        return {"ok": True}

    def set_value(self, payload):
        row_kind = payload.get("rowKind") or ROW_KIND_SESSION
        row_id = payload.get("rowId")
        prop_id = payload.get("propertyId")
        if not row_id or not prop_id:
            raise ValueError("rowKind, rowId, and propertyId are required")
        with self._write_lock, self._connect() as conn:
            prop = self._get_property(conn, prop_id)
            if prop["rowKind"] != row_kind:
                raise ValueError("property does not belong to rowKind")
            value = self._normalize_value(payload.get("value"), prop)
            if value is None:
                conn.execute(
                    "DELETE FROM value WHERE row_kind = ? AND row_id = ? AND property_id = ?",
                    (row_kind, row_id, prop_id),
                )
            else:
                conn.execute(
                    """INSERT INTO value(row_kind, row_id, property_id, value_json, updated_ts, updated_by)
                       VALUES (?, ?, ?, ?, ?, ?)
                       ON CONFLICT(row_kind, row_id, property_id) DO UPDATE SET
                       value_json = excluded.value_json,
                       updated_ts = excluded.updated_ts,
                       updated_by = excluded.updated_by""",
                    (row_kind, row_id, prop_id, json.dumps(value), time.time(),
                     payload.get("updatedBy") or "browser"),
                )
        return {"ok": True, "value": value}

    def stored_values_for_rows(self, row_kind, row_ids):
        if not row_ids:
            return {}
        placeholders = ",".join("?" for _ in row_ids)
        with self._connect() as conn:
            rows = conn.execute(
                f"""SELECT row_id, property_id, value_json FROM value
                    WHERE row_kind = ? AND row_id IN ({placeholders})""",
                [row_kind, *row_ids],
            ).fetchall()
        values = {row_id: {} for row_id in row_ids}
        for row in rows:
            values.setdefault(row["row_id"], {})[row["property_id"]] = json.loads(row["value_json"])
        return values

    def build_session_board(self, agents, view_id=None, now_ts=None):
        now = now_ts if now_ts is not None else self._now_fn()
        live_ids = [resolve_agent_row_id(a) for a in agents]
        self._touch_seen_rows(ROW_KIND_SESSION, agents, live_ids, now)
        stored_props = self.list_stored_properties(ROW_KIND_SESSION)
        live_by_id = {}
        for agent in agents:
            row_id = resolve_agent_row_id(agent)
            agent["rowId"] = row_id
            live_by_id[row_id] = agent
        ended = self._ended_rows_within_ttl(
            ROW_KIND_SESSION, set(live_ids), now)
        all_ids = live_ids + [r["rowId"] for r in ended]
        stored_by_row = self.stored_values_for_rows(ROW_KIND_SESSION, all_ids)
        # Phase 5: what the ladder last did to each row, so a stopped session
        # and a crashed one never look identical.
        annotations = self.session_action_annotations(all_ids)
        # Phase 6: board-only archive flags (hidden by default, never deleted).
        archived = self.archived_map(ROW_KIND_SESSION, all_ids)
        rows = []
        for agent in agents:
            row_id = resolve_agent_row_id(agent)
            derived = derived_values_for_agent(agent)
            stored = stored_by_row.get(row_id, {})
            is_archived = bool(archived.get(row_id, {}).get("archived"))
            rows.append({
                "rowKind": ROW_KIND_SESSION,
                "rowId": row_id,
                "status": "live",
                "archived": is_archived,
                "derived": agent,
                "values": {**derived, **stored, "status": "live",
                           "archived": is_archived},
            })
        for e in ended:
            stored = stored_by_row.get(e["rowId"], {})
            annotation = self.ended_annotation(annotations.get(e["rowId"]))
            label = e.get("last_label") or e["rowId"]
            derived_stub = {
                "derived:label": label,
                "derived:pane": e.get("last_pane") or "",
            }
            is_archived = bool(archived.get(e["rowId"], {}).get("archived"))
            rows.append({
                "rowKind": ROW_KIND_SESSION,
                "rowId": e["rowId"],
                "status": "ended",
                "archived": is_archived,
                "endedTs": e.get("last_seen_ts"),
                # `ended · stopped by you` vs a bare `ended`: intent, not accident.
                "endedNote": (f"ended · {annotation}" if annotation
                              else "ended"),
                "derived": {
                    "label": label,
                    "paneId": e.get("last_pane"),
                    "rowId": e["rowId"],
                    "ended": True,
                },
                "values": {**derived_stub, **stored, "status": "ended",
                           "archived": is_archived},
            })
        board = {
            "rowKind": ROW_KIND_SESSION,
            "properties": DERIVED_SESSION_PROPERTIES + stored_props,
            "rows": rows,
        }
        if view_id:
            view = self.get_view(view_id)
            board = self.apply_view(board, view)
            board["view"] = view
        else:
            # No view = the default: archived rows stay hidden. (With a view,
            # apply_view decides — a filter on `archived` shows them.)
            board["rows"] = [r for r in rows if not r.get("archived")]
        return board

    # ── Lingering (board layer only; views.py untouched) ──

    def _touch_seen_rows(self, row_kind, agents, live_ids, now):
        with self._write_lock, self._connect() as conn:
            for agent, row_id in zip(agents, live_ids):
                conn.execute(
                    """INSERT INTO session_seen(row_kind, row_id, last_seen_ts, last_label, last_pane)
                       VALUES (?, ?, ?, ?, ?)
                       ON CONFLICT(row_kind, row_id) DO UPDATE SET
                       last_seen_ts = excluded.last_seen_ts,
                       last_label = excluded.last_label,
                       last_pane = excluded.last_pane""",
                    (row_kind, row_id, now,
                     agent.get("label") or "",
                     agent.get("paneId") or agent.get("paneIdSanitized") or ""),
                )

    def _ended_rows_within_ttl(self, row_kind, live_ids, now):
        cutoff = now - ENDED_TTL_SEC
        with self._connect() as conn:
            seen = conn.execute(
                "SELECT row_id, last_seen_ts, last_label, last_pane FROM session_seen WHERE row_kind = ?",
                (row_kind,),
            ).fetchall()
        ended = []
        for s in seen:
            if s["row_id"] in live_ids:
                continue
            if (s["last_seen_ts"] or 0) < cutoff:
                continue
            ended.append({
                "rowId": s["row_id"],
                "last_seen_ts": s["last_seen_ts"],
                "last_label": s["last_label"],
                "last_pane": s["last_pane"],
            })
        return ended

    # ── Work items: manual links + resolved board (phase 3) ──
    #
    # Linking, strongest first: a MANUAL link the PO sets (survives every
    # resync) beats the record's own AUTHORITATIVE session/pane fields, which
    # beat the HEURISTIC guesses (itemId↔tab-label digits for sessions — slugs
    # never match labels; slug/itemId↔branch/worktree names). Every resolved
    # link carries its source and the UI shows it — a
    # guessed link the PO cannot tell from a certain one is worse than none.

    def create_link(self, payload):
        work_row_id = payload.get("workRowId") or payload.get("work_row_id")
        target_kind = payload.get("targetKind") or payload.get("target_kind")
        target_id = payload.get("targetId") or payload.get("target_id")
        if not work_row_id or not target_kind or not target_id:
            raise ValueError("workRowId, targetKind, and targetId are required")
        if target_kind not in LINK_TARGET_KINDS:
            raise ValueError("bad link target kind")
        with self._write_lock, self._connect() as conn:
            conn.execute(
                """INSERT INTO link(work_row_id, target_kind, target_id, source, created_ts)
                   VALUES (?, ?, ?, ?, ?)
                   ON CONFLICT(work_row_id, target_kind, target_id) DO UPDATE SET
                   source = excluded.source, created_ts = excluded.created_ts""",
                (work_row_id, target_kind, str(target_id), LINK_SOURCE_MANUAL, time.time()),
            )
        return {"ok": True, "workRowId": work_row_id,
                "targetKind": target_kind, "targetId": str(target_id),
                "source": LINK_SOURCE_MANUAL}

    def delete_link(self, payload):
        work_row_id = payload.get("workRowId") or payload.get("work_row_id")
        target_kind = payload.get("targetKind") or payload.get("target_kind")
        target_id = payload.get("targetId") or payload.get("target_id")
        if not work_row_id or not target_kind or not target_id:
            raise ValueError("workRowId, targetKind, and targetId are required")
        with self._write_lock, self._connect() as conn:
            conn.execute(
                "DELETE FROM link WHERE work_row_id = ? AND target_kind = ? AND target_id = ?",
                (work_row_id, target_kind, str(target_id)),
            )
        return {"ok": True}

    def list_links(self, work_row_id=None):
        with self._connect() as conn:
            if work_row_id:
                rows = conn.execute(
                    "SELECT * FROM link WHERE work_row_id = ?", (work_row_id,)).fetchall()
            else:
                rows = conn.execute("SELECT * FROM link").fetchall()
        return [{"workRowId": r["work_row_id"], "targetKind": r["target_kind"],
                 "targetId": r["target_id"], "source": r["source"],
                 "createdTs": r["created_ts"]} for r in rows]

    # ── Phase 5: session action log (stop/close/relaunch) ──
    # ── Phase 6: + archive / unarchive (board-only tidying) ──

    #: Actions the board can perform. Anything else is rejected. Archive is
    #: board-only (hides the row, frees nothing, touches no process) — and
    #: the only action the chief will ever be given (phase 7).
    SESSION_ACTIONS = ("stop", "close", "relaunch", "archive", "unarchive",
                       "message", "compact")

    #: Ladder actions touch panes; archive actions only touch the board.
    #: `was_stopped`-style gates must look at the latest LADDER action, or a
    #: later archive would hide the fact the pane was stopped (and its undo).
    LADDER_ACTIONS = ("stop", "close", "relaunch")

    #: Delivery outcomes a logged action can carry. 'sent' = verified landed,
    #: 'queued' = the worker confirmed acceptance but the text drains when its
    #: turn ends, 'failed' = the attempt did NOT land. Pre-v4 rows have NULL
    #: and are read as 'sent' (they were only written after a success).
    #:
    #: WHICH ACTIONS USE WHICH, as of the v4 read side: only `message` and
    #: `compact` can carry 'queued' or 'failed' — they are the two actions
    #: whose delivery is verified by re-reading the pane, so a failure is
    #: observable. The ladder (stop/close/relaunch) and the archive pair are
    #: still logged ONLY after the operation succeeded (a raised ladder
    #: action returns its error and writes nothing), so every ladder row
    #: reads 'sent'. 'queued' is also TERMINAL in this ledger: nothing
    #: watches a worker's queue drain, so no row is ever updated and no
    #: follow-up row is written when the message finally lands.
    ACTION_STATUSES = ("sent", "queued", "failed")
    STATUS_FAILED = "failed"

    #: `reason` prefix the server writes on a queued send. History strips it
    #: when recovering the truncated text of an old row that has no `text`.
    QUEUED_REASON_PREFIX = "queued: "

    def log_session_action(self, row_id, action, actor, reason="",
                           text=None, status="sent"):
        """Record one session action. Returns the log row.

        `reason` is written verbatim, exactly as before — the annotation
        reader renders strings off it, so its format is frozen. `text` is the
        FULL message body (NULL for ladder actions, which have none) and
        `status` is the delivery outcome; a 'failed' row is an audit entry
        ONLY and is filtered out of both gate readers below.
        """
        if action not in self.SESSION_ACTIONS:
            raise ValueError("bad session action")
        if not row_id:
            raise ValueError("row_id is required")
        if status not in self.ACTION_STATUSES:
            raise ValueError("bad session action status")
        now = time.time()
        with self._write_lock, self._connect() as conn:
            cur = conn.execute(
                """INSERT INTO session_action
                   (row_id, action, ts, actor, reason, text, status)
                   VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (row_id, action, now, actor or "", reason or "",
                 text if text else None, status),
            )
            log_id = cur.lastrowid
        return {"id": log_id, "rowId": row_id, "action": action,
                "ts": now, "actor": actor or "", "reason": reason or "",
                "text": text if text else None, "status": status}

    def session_action_history(self, row_id, limit=50):
        """Every logged action for one row, newest first — the panel's
        timeline. Includes FAILED attempts on purpose: an attempt that did
        not land is exactly what the PO needs to see, and this reader gates
        nothing (unlike the two below).

        Rows written before the `text` column existed carry only the 80-char
        summary inside `reason`; those are recovered here and flagged
        `truncated` so the UI can say the text is clipped rather than
        presenting a cut sentence as the whole message.
        """
        if not row_id:
            raise ValueError("row_id is required")
        limit = max(1, min(int(limit), 200))
        with self._connect() as conn:
            rows = conn.execute(
                """SELECT id, action, ts, actor, reason, text, status
                   FROM session_action WHERE row_id = ?
                   ORDER BY ts DESC, id DESC LIMIT ?""",
                (row_id, limit),
            ).fetchall()
        out = []
        for r in rows:
            reason = r["reason"] or ""
            text = r["text"]
            truncated = False
            if text is None and r["action"] == "message":
                recovered = reason
                if recovered.startswith(self.QUEUED_REASON_PREFIX):
                    recovered = recovered[len(self.QUEUED_REASON_PREFIX):]
                if recovered:
                    text = recovered
                    truncated = True
            entry = {"id": r["id"], "action": r["action"], "ts": r["ts"],
                     "actor": r["actor"] or "", "text": text,
                     "status": r["status"] or "sent", "reason": reason}
            if truncated:
                entry["truncated"] = True
            out.append(entry)
        return out

    def session_action_annotations(self, row_ids):
        """Latest destructive action per row: {row_id: log-row}. Empty for
        rows nobody ever stopped/closed/relaunched."""
        if not row_ids:
            return {}
        placeholders = ",".join("?" for _ in row_ids)
        # Failed attempts are excluded, NOT merely deprioritised: this reader
        # feeds `endedNote`, so a failed row reaching it would caption a row
        # with an action nobody completed (`ended · stopped by you` for a stop
        # that never happened). NULL status = a pre-v4 row = a success.
        with self._connect() as conn:
            rows = conn.execute(
                f"""SELECT row_id, action, ts, actor, reason FROM session_action
                    WHERE row_id IN ({placeholders})
                    AND (status IS NULL OR status != ?) ORDER BY ts""",
                [*row_ids, self.STATUS_FAILED],
            ).fetchall()
        out = {}
        for r in rows:
            out[r["row_id"]] = {
                "action": r["action"], "ts": r["ts"],
                "actor": r["actor"], "reason": r["reason"],
            }
        return out

    @staticmethod
    def ended_annotation(action_entry):
        """Human suffix for a lingering ended row, e.g. `stopped by you`.
        None when the row ended on its own (crash/close elsewhere) — or was
        restored via unarchive (restoring isn't an ending)."""
        if not action_entry:
            return None
        actor = "you" if action_entry.get("actor") == "po" else (
            action_entry.get("actor") or "unknown")
        verb = {"stop": "stopped", "close": "closed",
                "relaunch": "relaunched",
                "archive": "archived"}.get(action_entry.get("action"))
        if not verb:
            return None
        return f"{verb} by {actor}"

    def last_ladder_action(self, row_ids):
        """Latest stop/close/relaunch per row: {row_id: action|None}.

        Archive/unarchive write to the same log (audit trail) but must not
        move ladder gates: stop → archive must still read as stopped (Close
        stays one click, Relaunch stays offered)."""
        if not row_ids:
            return {}
        placeholders = ",".join("?" for _ in row_ids)
        ladder = ",".join("?" for _ in self.LADDER_ACTIONS)
        # Same exclusion as session_action_annotations, and here it is the
        # sharper edge: this reader decides which buttons the UI offers. A
        # failed attempt logged as if it completed would move the gate — the
        # compact-workers.sh incident, where a failed send stamped its
        # cooldown and hid the failure for 20 minutes. A failure must leave
        # the gate exactly where it was so the action is still offered.
        with self._connect() as conn:
            rows = conn.execute(
                f"""SELECT row_id, action, ts FROM session_action
                    WHERE row_id IN ({placeholders})
                    AND action IN ({ladder})
                    AND (status IS NULL OR status != ?) ORDER BY ts""",
                [*row_ids, *self.LADDER_ACTIONS, self.STATUS_FAILED],
            ).fetchall()
        out = {row_id: None for row_id in row_ids}
        for r in rows:
            out[r["row_id"]] = r["action"]
        return out

    # ── Phase 6: archive flag (board-only tidying) ──
    #
    # Archive hides a row from the default view. It frees nothing and touches
    # no process — the pane and its agent are unaffected. State lives in its
    # own table (NOT derived from the action log: a later stop must not
    # silently un-archive, nor a later archive hide a stopped pane's undo).
    # Every archive/unarchive ALSO writes the action log, so `endedNote` can
    # say who archived. Neither table is in the schema export.

    def set_archived(self, row_kind, row_id, archived, actor):
        """Set or clear the archive flag. Returns the flag row."""
        if not row_id:
            raise ValueError("row_id is required")
        now = time.time()
        with self._write_lock, self._connect() as conn:
            conn.execute(
                """INSERT INTO archived_row(row_kind, row_id, archived, ts, actor)
                   VALUES (?, ?, ?, ?, ?)
                   ON CONFLICT(row_kind, row_id) DO UPDATE SET
                   archived = excluded.archived,
                   ts = excluded.ts, actor = excluded.actor""",
                (row_kind, row_id, 1 if archived else 0, now, actor or ""),
            )
        return {"rowKind": row_kind, "rowId": row_id,
                "archived": bool(archived), "ts": now, "actor": actor or ""}

    def archived_map(self, row_kind, row_ids):
        """Archive flags: {row_id: {archived, ts, actor}}. Missing = False."""
        out = {row_id: {"archived": False, "ts": None, "actor": None}
               for row_id in (row_ids or [])}
        if not row_ids:
            return out
        placeholders = ",".join("?" for _ in row_ids)
        with self._connect() as conn:
            rows = conn.execute(
                f"""SELECT row_id, archived, ts, actor FROM archived_row
                    WHERE row_kind = ? AND row_id IN ({placeholders})""",
                [row_kind, *row_ids],
            ).fetchall()
        for r in rows:
            out[r["row_id"]] = {"archived": bool(r["archived"]),
                                "ts": r["ts"], "actor": r["actor"]}
        return out

    def get_seen_row(self, row_kind, row_id):
        """Last live sighting of one row (pane + label), for resolving
        ladder targets that already left the agent feed — a stopped pane
        still exists, and Close/Relaunch act on the PANE, not the agent."""
        with self._connect() as conn:
            s = conn.execute(
                "SELECT row_id, last_seen_ts, last_label, last_pane "
                "FROM session_seen WHERE row_kind = ? AND row_id = ?",
                (row_kind, row_id),
            ).fetchone()
        if not s:
            return None
        return {"rowId": s["row_id"], "last_seen_ts": s["last_seen_ts"],
                "last_label": s["last_label"], "last_pane": s["last_pane"]}

    def _all_seen_rows(self, row_kind):
        with self._connect() as conn:
            seen = conn.execute(
                "SELECT row_id, last_seen_ts, last_label, last_pane FROM session_seen WHERE row_kind = ?",
                (row_kind,),
            ).fetchall()
        return [{"rowId": s["row_id"], "last_seen_ts": s["last_seen_ts"],
                 "last_label": s["last_label"], "last_pane": s["last_pane"]}
                for s in seen]

    # P0 dashboard move: resolve_work_item_links, _resolve_named_link, and
    # build_workitem_board are RETIRED with the work-item board — no
    # caller left (they only fed the retired GET /api/board for
    # rowKind=work_item). chief_pass itself was restored 2026-09-25, generic
    # (see chief_dashboard_pass.py) but never read the work-item board — it
    # doesn't need these either. The session board's own link resolution
    # lives elsewhere in this file and is unaffected.

    # ── Views ──

    def list_views(self, row_kind=ROW_KIND_SESSION):
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT * FROM view WHERE row_kind = ? ORDER BY position, created_ts",
                (row_kind,),
            ).fetchall()
        return [self._view_from_row(r) for r in rows]

    def get_view(self, view_id):
        with self._connect() as conn:
            row = conn.execute("SELECT * FROM view WHERE id = ?", (view_id,)).fetchone()
        if not row:
            raise ValueError("view not found")
        return self._view_from_row(row)

    def create_view(self, payload):
        row_kind = payload.get("rowKind") or ROW_KIND_SESSION
        name = self._validate_view_name(payload.get("name"))
        layout = self._validate_layout(payload.get("layout") or "table")
        columns = self._validate_columns(payload.get("columns") if "columns" in payload else payload.get("columns_json"))
        sorts = self._validate_sorts(payload.get("sort") if "sort" in payload else payload.get("sort_json"))
        filters = self._validate_filters(payload.get("filters") if "filters" in payload else payload.get("filters_json"))
        group_by = payload.get("groupBy", payload.get("group_by"))
        if group_by is not None and group_by != "":
            group_by = str(group_by)
        else:
            group_by = None
        group_order = self._validate_group_order(
            payload.get("groupOrder", payload.get("group_order")))
        now = self._now_fn()
        with self._write_lock, self._connect() as conn:
            max_pos = conn.execute(
                "SELECT MAX(position) AS m FROM view WHERE row_kind = ?",
                (row_kind,),
            ).fetchone()["m"]
            view_id = payload.get("id") or f"view_{uuid.uuid4().hex[:12]}"
            conn.execute(
                """INSERT INTO view(id, row_kind, name, layout, columns_json, sort_json,
                   filters_json, group_by, group_order_json, position, created_ts, updated_ts)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (view_id, row_kind, name, layout, json.dumps(columns),
                 json.dumps(sorts), json.dumps(filters), group_by,
                 json.dumps(group_order) if group_order is not None else None,
                 int(max_pos + 1) if max_pos is not None else 0, now, now),
            )
            row = conn.execute("SELECT * FROM view WHERE id = ?", (view_id,)).fetchone()
            self._export_schema_locked(conn)
            return self._view_from_row(row)

    def update_view(self, view_id, payload):
        with self._write_lock, self._connect() as conn:
            row = conn.execute("SELECT * FROM view WHERE id = ?", (view_id,)).fetchone()
            if not row:
                raise ValueError("view not found")
            current = self._view_from_row(row)
            name = current["name"]
            layout = current["layout"]
            columns = current["columns"]
            sorts = current["sort"]
            filters = current["filters"]
            group_by = current["groupBy"]
            group_order = current.get("groupOrder")
            position = current["position"]
            if "name" in payload:
                name = self._validate_view_name(payload["name"])
            if "layout" in payload:
                layout = self._validate_layout(payload["layout"])
            if "columns" in payload or "columns_json" in payload:
                columns = self._validate_columns(
                    payload.get("columns") if "columns" in payload else payload.get("columns_json"))
            if "sort" in payload or "sort_json" in payload:
                sorts = self._validate_sorts(
                    payload.get("sort") if "sort" in payload else payload.get("sort_json"))
            if "filters" in payload or "filters_json" in payload:
                filters = self._validate_filters(
                    payload.get("filters") if "filters" in payload else payload.get("filters_json"))
            if "groupBy" in payload or "group_by" in payload:
                gb = payload.get("groupBy", payload.get("group_by"))
                group_by = str(gb) if gb else None
                # A saved order names groups of the OLD prop — keeping it
                # would pin nonsense onto the new grouping. Clear unless the
                # same PATCH carries an explicit replacement.
                if "groupOrder" not in payload and "group_order" not in payload:
                    group_order = None
            if "groupOrder" in payload or "group_order" in payload:
                group_order = self._validate_group_order(
                    payload.get("groupOrder", payload.get("group_order")))
            if "position" in payload:
                position = int(payload["position"])
            conn.execute(
                """UPDATE view SET name=?, layout=?, columns_json=?, sort_json=?,
                   filters_json=?, group_by=?, group_order_json=?, position=?, updated_ts=? WHERE id=?""",
                (name, layout, json.dumps(columns), json.dumps(sorts),
                 json.dumps(filters), group_by,
                 json.dumps(group_order) if group_order is not None else None,
                 position, self._now_fn(), view_id),
            )
            updated = conn.execute("SELECT * FROM view WHERE id = ?", (view_id,)).fetchone()
            self._export_schema_locked(conn)
            return self._view_from_row(updated)

    def delete_view(self, view_id):
        with self._write_lock, self._connect() as conn:
            row = conn.execute("SELECT * FROM view WHERE id = ?", (view_id,)).fetchone()
            if not row:
                raise ValueError("view not found")
            conn.execute("DELETE FROM view WHERE id = ?", (view_id,))
            self._export_schema_locked(conn)
        return {"ok": True}

    def apply_view(self, board, view):
        """Server-side view resolution: filter, then stable multi-column sort,
        then (kanban) group. The browser renders; it never resolves.

        Phase 6: archived rows are hidden by default — unless the view carries
        an explicit filter on `archived`, in which case that filter alone
        decides (e.g. the seeded Archived view shows only archived rows).
        Archived never leaks into a view that did not ask for it, and no
        stored view needs migrating."""
        props_by_id = {p["id"]: p for p in board.get("properties", [])}
        rows = list(board.get("rows", []))
        rows = [r for r in rows if self._row_matches_filters(r, view.get("filters") or [], props_by_id)]
        if not any(f.get("propertyId") == "archived"
                   for f in (view.get("filters") or [])):
            rows = [r for r in rows
                    if not r.get("values", {}).get("archived")]
        rows = self._sort_rows(rows, view.get("sort") or [], props_by_id)
        out = {**board, "rows": rows}
        if (view.get("layout") == "kanban") and view.get("groupBy"):
            out["groups"] = self._group_rows(
                rows, view["groupBy"], props_by_id,
                order=view.get("groupOrder") or view.get("group_order"))
        return out

    def _get_property(self, conn, prop_id):
        row = conn.execute("SELECT * FROM property WHERE id = ?", (prop_id,)).fetchone()
        if not row:
            raise ValueError("property not found")
        return self._property_from_row(row)

    def _property_from_row(self, row):
        return {
            "id": row["id"],
            "rowKind": row["row_kind"],
            "name": row["name"],
            "type": row["type"],
            "options": json.loads(row["options_json"] or "[]"),
            "source": "stored",
            "editable": True,
            "position": row["position"],
            "width": row["width"],
            "createdTs": row["created_ts"],
            "updatedTs": row["updated_ts"],
        }

    def _export_schema_locked(self, conn):
        rows = conn.execute(
            "SELECT * FROM property ORDER BY row_kind, position, created_ts").fetchall()
        views = conn.execute(
            "SELECT * FROM view ORDER BY row_kind, position, created_ts").fetchall()
        payload = {
            "version": 1,
            "exportedTs": time.time(),
            "properties": [self._property_from_row(row) for row in rows],
            "views": [self._view_from_row(row) for row in views],
        }
        # Every server boot re-exports. Without this check the only thing that
        # changes is `exportedTs`, so a shared tree goes dirty on every restart
        # and someone hand-restores the file (three times during phase 4).
        # Compare on content alone; the timestamp is not content.
        try:
            with open(self.schema_path, encoding="utf-8") as f:
                current = json.load(f)
            if all(current.get(k) == payload[k]
                   for k in ("version", "properties", "views")):
                return
        except (OSError, ValueError):
            pass
        tmp_path = self.schema_path + ".tmp"
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(payload, f, indent=2, sort_keys=True)
            f.write("\n")
        os.replace(tmp_path, self.schema_path)

    # ── View helpers ──

    def _view_from_row(self, row):
        keys = set(row.keys())
        group_order = None
        if "group_order_json" in keys and row["group_order_json"]:
            try:
                group_order = json.loads(row["group_order_json"])
            except ValueError:
                group_order = None
        return {
            "id": row["id"],
            "rowKind": row["row_kind"],
            "name": row["name"],
            "layout": row["layout"],
            "columns": json.loads(row["columns_json"] or "[]"),
            "sort": json.loads(row["sort_json"] or "[]"),
            "filters": json.loads(row["filters_json"] or "[]"),
            "groupBy": row["group_by"],
            "groupOrder": group_order,
            "position": row["position"],
            "createdTs": row["created_ts"],
            "updatedTs": row["updated_ts"],
        }

    def _seed_default_views(self):
        with self._write_lock, self._connect() as conn:
            now = self._now_fn()
            session_count = conn.execute(
                "SELECT COUNT(*) AS c FROM view WHERE row_kind = ?",
                (ROW_KIND_SESSION,),
            ).fetchone()["c"]
            if not session_count:
                group_prop = conn.execute(
                    "SELECT id FROM property WHERE row_kind = ? AND lower(name) = 'group'",
                    (ROW_KIND_SESSION,),
                ).fetchone()
                group_by = group_prop["id"] if group_prop else None
                defaults = [
                    ("view_needs_you", "Needs you", "table", [], [], [], None, 0),
                    ("view_all_sessions", "All sessions", "table", [], [], [], None, 1),
                    ("view_by_group", "By group", "kanban", [], [], [], group_by, 2),
                ]
                for vid, name, layout, cols, sorts, filters, gb, pos in defaults:
                    conn.execute(
                        """INSERT INTO view(id, row_kind, name, layout, columns_json, sort_json,
                           filters_json, group_by, group_order_json, position, created_ts, updated_ts)
                           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                        (vid, ROW_KIND_SESSION, name, layout, json.dumps(cols),
                         json.dumps(sorts), json.dumps(filters), gb, None, pos, now, now),
                    )
            # Phase 6: the Archived view shows ONLY archived rows (its filter
            # references `archived`, which also disables the default-hide in
            # apply_view). Ensured by id so existing DBs gain it without any
            # migration of the user's own views.
            has_archived = conn.execute(
                "SELECT COUNT(*) AS c FROM view WHERE id = 'view_archived'",
            ).fetchone()["c"]
            if not has_archived:
                max_pos = conn.execute(
                    "SELECT MAX(position) AS m FROM view WHERE row_kind = ?",
                    (ROW_KIND_SESSION,),
                ).fetchone()["m"]
                conn.execute(
                    """INSERT INTO view(id, row_kind, name, layout, columns_json, sort_json,
                       filters_json, group_by, group_order_json, position, created_ts, updated_ts)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    ("view_archived", ROW_KIND_SESSION, "Archived", "table",
                     json.dumps([]), json.dumps([]),
                     json.dumps([{"propertyId": "archived", "op": "is",
                                  "value": True}]),
                     None, None,
                     int(max_pos + 1) if max_pos is not None else 3,
                     now, now),
                )
            # P0 dashboard move: work-item default-view seeding ("All work",
            # "By stage") is RETIRED with the work-item board — no producer
            # left to populate ROW_KIND_WORK_ITEM rows. Session-view seeding
            # above (view_needs_you / view_all_sessions / view_by_group /
            # view_archived) is unaffected.
            try:
                self._export_schema_locked(conn)
            except Exception:
                pass

    def _validate_view_name(self, name):
        cleaned = " ".join(str(name or "").split())[:80]
        if not cleaned:
            raise ValueError("view name is required")
        return cleaned

    def _validate_layout(self, layout):
        if layout not in VIEW_LAYOUTS:
            raise ValueError("bad view layout")
        return layout

    def _validate_columns(self, columns):
        if columns is None:
            return []
        if isinstance(columns, str):
            columns = json.loads(columns or "[]")
        out = []
        for c in columns or []:
            if not isinstance(c, dict) or not c.get("propertyId"):
                raise ValueError("bad view column")
            out.append({
                "propertyId": str(c["propertyId"]),
                "hidden": bool(c.get("hidden", False)),
                "width": int(c["width"]) if c.get("width") is not None else None,
                # Table layout prefs: wrap long text instead of one line,
                # pin the column to the left while scrolling sideways.
                # Absent on pre-existing entries → default off, so every old
                # view renders exactly as before until the PO opts in.
                "wrap": bool(c.get("wrap", False)),
                "sticky": bool(c.get("sticky", c.get("pinned", False))),
            })
        return out

    def _validate_group_order(self, order):
        """Kanban column sequence pins group keys, or None for server order.

        Empty list and None both mean "no pin" (a PATCH that clears every
        column sends [] — it must reset, not pin an empty board)."""
        if order is None:
            return None
        if isinstance(order, str):
            order = json.loads(order or "null")
            if order is None:
                return None
        cleaned = []
        for k in order or []:
            k = str(k)
            if k and k not in cleaned:
                cleaned.append(k)
        return cleaned or None

    def _validate_sorts(self, sorts):
        if sorts is None:
            return []
        if isinstance(sorts, str):
            sorts = json.loads(sorts or "[]")
        out = []
        for s in sorts or []:
            if not isinstance(s, dict) or not s.get("propertyId"):
                raise ValueError("bad view sort")
            direction = str(s.get("dir") or "asc").lower()
            if direction not in SORT_DIRS:
                raise ValueError("bad sort direction")
            out.append({"propertyId": str(s["propertyId"]), "dir": direction})
        return out

    def _validate_filters(self, filters):
        if filters is None:
            return []
        if isinstance(filters, str):
            filters = json.loads(filters or "[]")
        out = []
        for f in filters or []:
            if not isinstance(f, dict) or not f.get("propertyId") or not f.get("op"):
                raise ValueError("bad view filter")
            if f["op"] not in FILTER_OPS:
                raise ValueError("bad filter operator")
            out.append({
                "propertyId": str(f["propertyId"]),
                "op": f["op"],
                "value": f.get("value"),
            })
        return out

    def _filter_value(self, row, property_id, props_by_id):
        if property_id == "status":
            return row.get("status")
        values = row.get("values", {})
        if property_id in values:
            return values[property_id]
        return None

    def _row_matches_filters(self, row, filters, props_by_id):
        for f in filters:
            op = f.get("op")
            cell = self._filter_value(row, f.get("propertyId"), props_by_id)
            want = f.get("value")
            if op == "is empty":
                if not self._is_empty(cell):
                    return False
            elif op == "is not empty":
                if self._is_empty(cell):
                    return False
            elif op == "is":
                if not self._equals(cell, want, props_by_id.get(f.get("propertyId"))):
                    return False
            elif op == "is not":
                if self._equals(cell, want, props_by_id.get(f.get("propertyId"))):
                    return False
            elif op == "contains":
                if want is None or str(want).lower() not in self._cell_text(cell, props_by_id.get(f.get("propertyId"))).lower():
                    return False
            elif op in (">", "<"):
                if not self._compare(cell, want, op):
                    return False
            else:
                raise ValueError("bad filter operator")
        return True

    def _is_empty(self, cell):
        if cell is None:
            return True
        if isinstance(cell, str):
            return cell.strip() == ""
        if isinstance(cell, list):
            return len(cell) == 0
        return False

    def _cell_text(self, cell, prop):
        if cell is None:
            return ""
        if isinstance(cell, list):
            if prop and prop.get("options"):
                names = {o["id"]: o["name"] for o in prop["options"]}
                return ", ".join(names.get(str(i), str(i)) for i in cell)
            return ", ".join(str(i) for i in cell)
        if isinstance(cell, bool):
            return "yes" if cell else "no"
        if prop and prop.get("type") == "select":
            names = {o["id"]: o["name"] for o in prop.get("options", [])}
            return names.get(str(cell), str(cell))
        return str(cell)

    def _equals(self, cell, want, prop):
        if isinstance(cell, list):
            if isinstance(want, list):
                return sorted(str(i) for i in cell) == sorted(str(i) for i in want)
            return str(want) in [str(i) for i in cell]
        if isinstance(cell, bool):
            return bool(want) is cell if isinstance(want, bool) else str(cell).lower() == str(want).lower()
        if isinstance(cell, (int, float)) and want is not None:
            try:
                return float(cell) == float(want)  # type: ignore[arg-type]
            except (TypeError, ValueError):
                pass
        return str(cell or "") == str(want or "")

    def _compare(self, cell, want, op):
        try:
            left = self._comparable(cell)
            right = self._comparable(want)
            if left is None or right is None:
                return False
            return left > right if op == ">" else left < right
        except TypeError:
            return False

    def _comparable(self, v):
        if v is None or v == "":
            return None
        if isinstance(v, bool):
            return 1.0 if v else 0.0
        if isinstance(v, (int, float)):
            return float(v)
        s = str(v).strip()
        try:
            return float(s)
        except ValueError:
            return s.lower()

    def _sort_rows(self, rows, sorts, props_by_id):
        if not sorts:
            return rows
        # Stable multi-column: apply keys in reverse order.
        out = list(rows)
        for s in reversed(sorts):
            pid = s["propertyId"]
            reverse = s.get("dir") == "desc"
            out.sort(
                key=lambda r: (self._sort_key(self._filter_value(r, pid, props_by_id))),
                reverse=reverse,
            )
        return out

    def _sort_key(self, cell):
        if cell is None or cell == "":
            return (1, "")
        if isinstance(cell, bool):
            return (0, 1.0 if cell else 0.0)
        if isinstance(cell, (int, float)):
            return (0, float(cell))
        if isinstance(cell, list):
            return (0, ", ".join(str(i) for i in cell).lower())
        try:
            return (0, float(str(cell).strip()))
        except ValueError:
            return (0, str(cell).lower())

    def _group_rows(self, rows, group_by, props_by_id, order=None):
        prop = props_by_id.get(group_by)
        groups: dict[str, list] = {}
        seen: list[str] = []
        for r in rows:
            cell = self._filter_value(r, group_by, props_by_id)
            keys = self._group_keys(cell, prop)
            for k in keys:
                if k not in groups:
                    groups[k] = []
                    seen.append(k)
                groups[k].append(r["rowId"])
        # A saved kanban order pins the sequence; unknown keys are ignored
        # and brand-new groups append at the end, so a drop never loses a
        # column that appeared after the order was saved.
        if order:
            pinned = [k for k in order if k in groups]
            ordered = pinned + [k for k in seen if k not in pinned]
        else:
            ordered = seen
        return {
            "propertyId": group_by,
            "editable": bool(prop and prop.get("editable", True)),
            "source": (prop or {}).get("source", "stored"),
            "groups": [{"key": k, "rowIds": groups[k]} for k in ordered],
        }

    def _group_keys(self, cell, prop):
        if cell is None or cell == "" or cell == []:
            return ["(none)"]
        if isinstance(cell, list):
            return [str(i) for i in cell]
        if isinstance(cell, bool):
            return ["yes" if cell else "no"]
        return [str(cell)]

    def _prune_values_for_property(self, conn, prop):
        allowed = {option["id"] for option in prop["options"]}
        if prop["type"] not in {"select", "multi_select"}:
            return
        rows = conn.execute(
            "SELECT row_kind, row_id, value_json FROM value WHERE property_id = ?",
            (prop["id"],),
        ).fetchall()
        for row in rows:
            current = json.loads(row["value_json"])
            cleaned = None
            if prop["type"] == "select":
                cleaned = current if current in allowed else None
            else:
                cleaned = [item for item in current if item in allowed]
                if not cleaned:
                    cleaned = None
            if cleaned == current:
                continue
            if cleaned is None:
                conn.execute(
                    "DELETE FROM value WHERE row_kind = ? AND row_id = ? AND property_id = ?",
                    (row["row_kind"], row["row_id"], prop["id"]),
                )
            else:
                conn.execute(
                    """UPDATE value SET value_json = ?, updated_ts = ?
                       WHERE row_kind = ? AND row_id = ? AND property_id = ?""",
                    (json.dumps(cleaned), time.time(), row["row_kind"], row["row_id"], prop["id"]),
                )

    def _normalize_value(self, value, prop):
        if value is None or value == "":
            return None
        prop_type = prop["type"]
        if prop_type == "text" or prop_type == "date":
            return str(value)
        if prop_type == "number":
            return float(value)
        if prop_type == "checkbox":
            return bool(value)
        allowed = {option["id"] for option in prop["options"]}
        if prop_type == "select":
            if value not in allowed:
                raise ValueError("value is not a select option")
            return value
        if prop_type == "multi_select":
            values = value if isinstance(value, list) else [value]
            normalized = [str(v) for v in values if str(v) in allowed]
            return normalized or None
        raise ValueError("unsupported property type")

    def _validate_type(self, prop_type):
        if prop_type not in PROPERTY_TYPES:
            raise ValueError("bad property type")
        return prop_type

    def _validate_name(self, name):
        cleaned = " ".join(str(name or "").split())[:80]
        if not cleaned:
            raise ValueError("property name is required")
        return cleaned

    def _normalize_options(self, options, prop_type):
        if prop_type not in {"select", "multi_select"}:
            return []
        normalized = []
        seen_names = set()
        for index, option in enumerate(options):
            if isinstance(option, str):
                name = option
                option_id = None
                color = None
            else:
                name = option.get("name") or option.get("label")
                option_id = option.get("id")
                color = option.get("color")
            clean_name = " ".join(str(name or "").split())[:60]
            if not clean_name or clean_name.lower() in seen_names:
                continue
            seen_names.add(clean_name.lower())
            normalized.append({
                "id": option_id or f"opt_{uuid.uuid4().hex[:10]}",
                "name": clean_name,
                "color": color or OPTION_COLORS[index % len(OPTION_COLORS)],
            })
        return normalized


STORE = BoardStore()
