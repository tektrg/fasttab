#!/usr/bin/env python3
"""Agent hierarchy: which chief session supervises which worker sessions.

WHY THIS EXISTS
----------------
Today one project has ONE chief slot (`.claude/chief-pane.json`) and every
worker's Stop-hook report (`scripts/worker-report-to-chief.py`) always nudges
THAT one pane. A chief now supervises several concurrently, other projects on
this Mac (and the Air) run their own chiefs, and the PO wants to see and edit
that whole tree, not just one project's flat worker list.

STORE
-----
User-level file, OUTSIDE any repo (a session can live in any project):
`~/.claude/agent-tree.json` (override: env `AGENT_TREE_FILE`, for tests and
for pointing two machines at the same synced location later). Shape:
`{child_session_id: {"parent": parent_session_id, "setAt": epoch_seconds,
"setBy": str|None, "childSlug": str|None, "parentSlug": str|None}}`.
Edges are keyed by Claude session UUID — the one identifier that survives a
pane/tab restart (chief_dashboard_views.py already relies on the same fact
for `agentSession`).

RULES (PO ruling, binding)
---------------------------
  * No self-parenting, no cycle.
  * TWO LEVELS ONLY: a parent cannot itself have a parent (`is_child`), and
    an agent with children cannot become a child (`has_children`). This one
    rule also makes a 3+-hop cycle unreachable through attach() — the cycle
    check in `_validate_attach` is defensive, for a hand-edited file.
  * Both child and parent must be KNOWN agents at attach time — the caller
    (chief-dashboard-server.py's /api/agent-tree/attach, or a launch-time
    seeder) passes the live id set it already has; `known_ids=None` skips
    this check for callers that have already established liveness another
    way (kept optional so this module never has to know HOW a caller knows).
  * Cross-project attach is ALLOWED — that gate is a UI confirm-and-retry
    (409 needsConfirm), never a `attach()`-level rejection. `attach()` only
    reports `crossProject` back via `build_agent_tree`'s AGENT objects; it
    does not itself refuse anything on that basis.

TWO WRITE FUNCTIONS, DELIBERATELY DIFFERENT
--------------------------------------------
  * `attach()`  — explicit (a person, or the API): ALWAYS writes, so
    re-parenting a worker is a normal move, not blocked by "already has an
    edge".
  * `attach_if_absent()` — seeding (launch-time auto-link, and the one-time
    migration): a no-op when `child` already has ANY edge, so it can be
    called on every worker launch and every dashboard start without ever
    clobbering a real edge — idempotent by construction.

SLUG-FALLBACK REKEY
--------------------
A session UUID can disappear (pane closed and relaunched in the same slot)
while the SAME logical worker continues under a new UUID. `rekey_child` is
the documented, deliberately simple rule: if the OLD id still has an edge
and the NEW id has none of its own, move the edge across (parent/setBy/
slugs carry over, `setAt` refreshes). No fuzzy matching, no history beyond
one hop — a caller (e.g. a future dashboard reconciliation pass) supplies
the "same slug/label" judgement; this function only performs the move.

VIEW MODEL — `build_agent_tree()`
----------------------------------
The CONTRACT the AgentBar app is built against (field names are load-bearing
— see the delivery brief). Pure function over already-collected inputs (no
herdr/subprocess calls here — the dashboard already polls herdr and hands
this module the resulting `agents` list, same shape as
chief_dashboard_views.build_agents_view's rows: `agentSession`, `paneId`,
`label`, `cwd`, `machine`).

  chiefs[]     — every KNOWN agent (currently live, or degraded via a fresh
                 `.claude/chief-mode` registration) that has >=1 child edge,
                 OR is chief-mode-registered, OR is the currently-LIVE agent
                 whose paneId matches a project's registered
                 `.claude/chief-pane.json` (see REGISTERED CHIEF PANE below)
                 — carries `isRegisteredChief: true` alongside the existing
                 `isChiefMode`. "Known" is what makes an entry a usable drop
                 target; a parent id nobody can currently see (not live, not
                 chief-mode, not registered-pane-matched) gets no chiefs[]
                 row at all — its children fall into parentGone instead
                 (below).
  unassigned[] — known agents with no parent edge at all.
  parentGone[] — children whose edge names a parent that is NOT currently
                 known (see above) — carries `lostParent: {id, label}`.

PROJECT DERIVATION (documented deviation from a literal "git toplevel")
-------------------------------------------------------------------------
The brief describes `project` as "basename of the git toplevel of the
agent's cwd, mapping worktrees back to the owning project". Shelling out to
`git rev-parse` per agent on every ~2s SSE tick (chief-dashboard-server.py
already re-renders that often) is the wrong trade for a label. Every project
on this Mac (and its mirror on the Air) lives under a `01_Project/<name>/`
convention — `~/01_Project/AptusFit`, `~/01_Project/ssv-bi-platform`, and
critically `~/01_Project/AptusFit/.claude/worktrees/fe-<slug>` and
`~/01_Project/AptusFit/fe` too. Taking the path segment right after
`01_Project` therefore reproduces the exact worktree-mapping the brief asks
for (and also folds the `fe`/`aptusfit-backend`/`landing` nested repos under
their meta-repo project) with zero subprocess calls, local or remote. A repo
outside that convention degrades to `Path(cwd).name` — still a label, just a
less meaningful one. Flagged for the AgentBar side in the delivery report.

CHIEF-MODE DISCOVERY IS LOCAL-MACHINE ONLY (v1)
--------------------------------------------------
`.claude/chief-mode` lives on whichever machine the project checkout is on.
Reading a REMOTE machine's (the Air's) chief-mode file would mean one more
ssh round trip per project per poll; v1 only reads local project roots
(mirrors chief_dashboard_worker.py's "local machine only for v1" precedent).
An Air chief still appears in chiefs[] whenever it has a live child edge —
only the "empty chief, zero children, Air-side" case is invisible until a
later version adds the ssh read.

REGISTERED CHIEF PANE (bug fix, 2026-09-24)
--------------------------------------------
`.claude/chief-mode` needs an active chief PASS to refresh its TTL line, so
a chief that has been live and idle (zero children, no pass run) for over
CHIEF_MODE_TTL_HOURS reads as stale and used to fall through to
unassigned[] even though it's the project's one registered chief pane —
the AgentBar tree then has nowhere to drop a worker under it.
`scripts/chief-register-pane.sh` writes `<project_root>/.claude/chief-
pane.json` (`{"paneId", "sessionId", "generation", "registeredAt"}`) on
every chief pass — a second, independent signal of "this pane IS the
chief" that doesn't expire. `build_agent_tree` now reads that file for the
SAME local project roots it already scans for chief-mode (see PROJECT
DERIVATION above — no extra roots, no extra subprocess calls), and any
currently-LIVE agent (must be in `agents`, i.e. `by_id`, with `machine ==
"local"`) whose `paneId` AND session id both match gets folded into
chiefs[] with `isRegisteredChief: true` (see `verified_chief_session_id`
below — H1 fix). Local-machine-only for the same reason as chief-mode
above.

VERIFIED CHIEF SESSION (H1 fix, 2026-09-24)
--------------------------------------------
Before this fix, "whoever is currently live at chief-pane.json's `paneId`"
WAS the registered chief — no check that it's the SAME session that
registered the pane. herdr reuses pane slots (own_pane_id()'s docstring in
worker-report-to-chief.py documents this as measured behaviour), so a
chief that exits and gets replaced by an unrelated ordinary session in the
same slot used to silently make every new worker's Stop-hook report (and
this module's own `isRegisteredChief` flag) treat that stranger as the
chief. `chief-pane.json` now also carries `sessionId` (the registering
pane's own Claude session id, resolved via `herdr agent list` the same way
`own_pane_id()`/`chief-register-pane.sh` already do — see
`scripts/pane-tick-gate.py`'s `register_self`). `verified_chief_session_id`
below is the ONE shared check every caller (this module's own
`build_agent_tree`, worker-report-to-chief.py's migration-seed fallback,
and chief_dashboard_worker.py's POST /api/worker seeding) applies: trust
the registration only when the pane's CURRENT live occupant is that exact
recorded session. A legacy chief-pane.json with no `sessionId` (written
before this fix) is treated as UNVERIFIED — never seeded from, never
flagged `isRegisteredChief` — until the next `chief-register-pane.sh` pass
fills it in (safe default, not a regression: that next pass is routine,
not a one-time migration this module has to perform itself).

DETACH TOMBSTONE (H2 fix, 2026-09-24)
---------------------------------------
`detach()` used to `del` the child's entry outright. That is not STICKY
for a still-running worker: its process env still carries the
`CHIEF_PARENT` it launched with (nothing server-side can edit a live
process's env), so the very next Stop-hook report's `seed_edge_if_needed`
saw "no edge yet" and silently re-seeded the SAME parent right back,
undoing the detach. `detach()` now leaves a TOMBSTONE — `{"parent": None,
"detached": True, "setAt", "setBy"}` — instead of removing the key.
`attach_if_absent`'s existing no-op rule ("only seed when `child` has NO
entry yet") already treats a tombstoned key as "already decided, don't
touch it", so every seeding path (CHIEF_PARENT launch seed, the migration
seed, the H1 fallback) is closed for free — no per-caller change needed.
Everywhere a tombstone's `parent: None` already reads as "no parent" with
zero extra code (`resolve_parent_id`, `agent_tree_routing.py`, the
`children_by_parent`/`parentGone` loops below); only `unassigned` needed a
one-line fix, since "has a key in `edges`" no longer implies "has a
parent" — see `is_child` used there. An explicit `attach()` always
OVERWRITES the whole entry, so re-attaching clears a tombstone for free.

CROSS-MACHINE AUTHORITY
------------------------
Edges live on the machine running the dashboard (the Pro) — an Air
worker's own `~/.claude/agent-tree.json` only ever gets entries from ITS
OWN launch-time seeding, never from a later dashboard-driven attach/detach
(no sync exists between the two files), so worker-report-to-chief.py's
`deliver()` treats the CHIEF's own tree (where it always runs) as
authoritative over whatever an Air worker resolved locally at hook time.

CHIEF RESTART REKEY (bug fix, 2026-09-25)
-------------------------------------------
A chief's session id changes on every restart (`/clear`, a relaunch) even
though it keeps the SAME herdr pane and the SAME `.claude/chief-pane.json`
registration — `scripts/pane-tick-gate.py`'s `register_self` just bumps
`generation` and overwrites `sessionId`. Before this fix, every edge already
pointing at the OLD session id (`parent: OLD`) was left exactly as it was:
`resolve_parent_pane` (agent_tree_routing.py) and worker-report-to-
chief.py's `deliver()` both look up the parent's CURRENT live pane by
session id, so once the old session is gone that lookup returns nothing —
every pre-restart worker's DONE/BLOCKED nudge and heartbeat alert silently
stopped routing, forever, with no error anywhere (only the durable inbox
write survived). PO ruling: the chief ROLE of a project owns its workers: a
restart of the same chief pane/role inherits them, it is not "parent gone".
`rekey_children_of_parent(old_parent_id, new_parent_id, ...)` is the fix —
every edge whose `parent == old_parent_id` is rewritten to `new_parent_id`
in one locked read-modify-write (tombstones are never touched: their
`parent` is `None`, never equal to a real old id). `register_self` calls it
right after its own `chief-pane.json` write completes (two SEQUENTIAL
per-file locks, not one nested lock — `delivery_ops/filelock.py`'s
`locked()` is documented as "never hold more than one of these at a time";
correctness here only needs the OLD session id read under chief-pane.json's
own lock, which `register_self` already captures before releasing it).
Idempotent: once every OLD-parented edge is rekeyed, a second call with the
same OLD id finds nothing left to move and returns `[]`. Safe when the
previous registration had no `sessionId` at all (a legacy file, or the very
first registration) — `register_self` simply skips the call, same as "no
rekey happened", never a crash.

STALE-ENTRY PRUNING (bug fix, 2026-09-25)
---------------------------------------------
Tombstones (H2 DETACH TOMBSTONE above) and dead children's real edges are
never otherwise removed, so the store file grows without bound. Every write
path (`attach`, `attach_if_absent`, `detach`, `rekey_child`,
`rekey_children_of_parent` — all of them funnel through `_write_edges`) now
prunes before writing:
  * a TOMBSTONE older than `TOMBSTONE_MAX_AGE_SECONDS` (7 days) is dropped
    unconditionally — a detach that old is settled, nothing reads it as
    "recently detached" any more.
  * a REAL edge older than `EDGE_MAX_AGE_SECONDS` (30 days) is dropped ONLY
    when the caller passed a `known_live_ids` set (the same `known_ids` an
    attach/attach_if_absent caller already has for validation — see
    `_validate_attach`) AND the child is NOT in it. No `known_live_ids` at
    all (e.g. `register_self`'s rekey call, which has no live-agent poll of
    its own) means "prune tombstones only" — a live child's edge is never
    guessed away from staleness alone; only an explicit live-id set can
    positively say a child is gone.
Kept intentionally simple: one age check per entry kind, no cross-file
reconciliation, no background sweep — pruning piggybacks on writes that
were already happening.
"""
from __future__ import annotations

import contextlib
import fcntl
import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_TREE_FILE = Path.home() / ".claude" / "agent-tree.json"

#: Mirrors the delivery-ops plugin's chief_mode.py CHIEF_MODE_TTL_HOURS, so a
#: chief-mode line this module treats as "live" agrees with what the plugin's
#: own gate honors elsewhere. Not imported from the plugin (this module reads
#: OTHER projects' chief-mode files by explicit path, not just the cwd
#: project `_delivery_ops_shim.project_root()` would resolve to) — kept as a
#: documented duplicate constant instead.
CHIEF_MODE_TTL_HOURS = 72

#: STALE-ENTRY PRUNING (module docstring) — how old a tombstone / a real
#: edge for a no-longer-known child must be before a write drops it.
TOMBSTONE_MAX_AGE_SECONDS = 7 * 24 * 3600
EDGE_MAX_AGE_SECONDS = 30 * 24 * 3600

ERROR_SELF = "self"
ERROR_CYCLE = "cycle"
ERROR_TWO_LEVEL = "two-level"
ERROR_UNKNOWN_AGENT = "unknown-agent"


class AgentTreeError(ValueError):
    """A rejected attach. `.code` is one of the ERROR_* constants above —
    chief-dashboard-server.py maps it straight to {"error": code, "message":
    str(self)} at HTTP 400."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


# ── store: file + lock ──────────────────────────────────────────────────

def tree_file_path() -> Path:
    override = os.environ.get("AGENT_TREE_FILE")
    return Path(override) if override else DEFAULT_TREE_FILE


def _lock_path(path: Path) -> Path:
    return path.with_suffix(path.suffix + ".lock")


@contextlib.contextmanager
def _locked(path: Path):
    """Exclusive lock around one read-modify-write. A sidecar `.lock` file,
    same idiom as worker_self_report.session_lock: the data file itself is
    atomically REPLACED on every write, so a lock on its old inode would not
    exclude a concurrent writer."""
    lock_path = _lock_path(path)
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with open(lock_path, "a") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def read_edges(path: Path | None = None) -> dict:
    path = path or tree_file_path()
    try:
        data = json.loads(Path(path).read_text())
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def _prune(edges: dict, known_live_ids=None, now=None) -> dict:
    """STALE-ENTRY PRUNING (module docstring) — pure, called from inside
    `_write_edges` on every write. Returns a NEW dict; never mutates
    `edges` in place (callers may still hold a reference to the pre-prune
    version, e.g. for a return value already computed)."""
    now = now if now is not None else time.time()
    kept = {}
    for child_id, edge in edges.items():
        e = edge or {}
        set_at = e.get("setAt")
        age = (now - set_at) if isinstance(set_at, (int, float)) else 0
        if e.get("detached"):
            if age > TOMBSTONE_MAX_AGE_SECONDS:
                continue
        elif known_live_ids is not None and age > EDGE_MAX_AGE_SECONDS \
                and child_id not in known_live_ids:
            continue
        kept[child_id] = edge
    return kept


def _write_edges(path: Path, edges: dict, known_live_ids=None) -> None:
    edges = _prune(edges, known_live_ids)
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(edges, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


# ── structural queries (pure, over an edges dict) ──────────────────────────

def has_children(edges: dict, agent_id: str) -> bool:
    return any((e or {}).get("parent") == agent_id for e in edges.values())


def is_child(edges: dict, agent_id: str) -> bool:
    return agent_id in edges and bool((edges[agent_id] or {}).get("parent"))


def _validate_attach(edges: dict, child: str, parent: str, known_ids) -> None:
    if child == parent:
        raise AgentTreeError(ERROR_SELF, "an agent cannot be its own parent")
    if known_ids is not None:
        if child not in known_ids:
            raise AgentTreeError(ERROR_UNKNOWN_AGENT, f"unknown agent: {child}")
        if parent not in known_ids:
            raise AgentTreeError(ERROR_UNKNOWN_AGENT, f"unknown agent: {parent}")
    if is_child(edges, parent):
        raise AgentTreeError(
            ERROR_TWO_LEVEL,
            f"{parent} already reports to a parent — a parent cannot itself have a parent")
    if has_children(edges, child):
        raise AgentTreeError(
            ERROR_TWO_LEVEL,
            f"{child} already has children — an agent with children cannot become a child")
    # Defensive cycle guard: unreachable via attach() alone once the two
    # rules above hold, but a hand-edited store file could still chain one.
    walker, hops, seen = parent, 0, {child}
    while walker in edges and hops < 64:
        if walker in seen:
            raise AgentTreeError(ERROR_CYCLE, f"attaching {child} under {parent} would create a cycle")
        seen.add(walker)
        walker = (edges[walker] or {}).get("parent")
        hops += 1


def _edge(parent, child_slug, parent_slug, set_by) -> dict:
    edge = {"parent": parent, "setAt": time.time(), "setBy": set_by}
    if child_slug:
        edge["childSlug"] = child_slug
    if parent_slug:
        edge["parentSlug"] = parent_slug
    return edge


def attach(child, parent, *, known_ids=None, child_slug=None, parent_slug=None,
           set_by=None, path=None) -> dict:
    """Explicit attach — see module docstring. Raises AgentTreeError on
    self/cycle/two-level/unknown-agent. Returns the edge written."""
    path = path or tree_file_path()
    with _locked(path):
        edges = read_edges(path)
        _validate_attach(edges, child, parent, known_ids)
        edges[child] = _edge(parent, child_slug, parent_slug, set_by)
        _write_edges(path, edges, known_live_ids=known_ids)
        return dict(edges[child])


def attach_if_absent(child, parent, *, known_ids=None, child_slug=None,
                     parent_slug=None, set_by=None, path=None) -> dict | None:
    """Seeding attach — see module docstring. None (no-op) when `child`
    already has an edge; otherwise the same validation as attach()."""
    path = path or tree_file_path()
    with _locked(path):
        edges = read_edges(path)
        if child in edges:
            return None
        _validate_attach(edges, child, parent, known_ids)
        edges[child] = _edge(parent, child_slug, parent_slug, set_by)
        _write_edges(path, edges, known_live_ids=known_ids)
        return dict(edges[child])


def detach(child, *, set_by=None, path=None, known_ids=None) -> bool:
    """Explicit detach — see module docstring's DETACH TOMBSTONE (H2 fix).
    Leaves `child` tombstoned (`parent: None, detached: True`) rather than
    deleting its entry, so a still-running worker's next Stop-hook report
    can never silently re-seed the same parent (`attach_if_absent`'s no-op
    rule already treats any existing entry, tombstoned or not, as "leave it
    alone"). False (no-op) when `child` has no entry at all, or is already
    tombstoned — idempotent either way. `read_edges()`/`build_agent_tree`
    still show a tombstoned child as unassigned (no parent), and an
    explicit `attach()` clears the tombstone by overwriting the entry."""
    path = path or tree_file_path()
    with _locked(path):
        edges = read_edges(path)
        existing = edges.get(child)
        if existing is None or (existing or {}).get("detached"):
            return False
        edges[child] = {"parent": None, "detached": True, "setAt": time.time(), "setBy": set_by}
        _write_edges(path, edges, known_live_ids=known_ids)
        return True


def rekey_child(old_id, new_id, *, path=None, known_ids=None) -> bool:
    """Move `old_id`'s edge to `new_id` (see module docstring). False (no
    change) when there is nothing to move or `new_id` already has its own
    edge — never overwrites a real edge."""
    path = path or tree_file_path()
    with _locked(path):
        edges = read_edges(path)
        if old_id not in edges or new_id in edges:
            return False
        edge = dict(edges.pop(old_id))
        edge["setAt"] = time.time()
        edges[new_id] = edge
        _write_edges(path, edges, known_live_ids=known_ids)
        return True


def rekey_children_of_parent(old_parent_id, new_parent_id, *, set_by=None,
                             path=None, known_ids=None) -> list[str]:
    """CHIEF RESTART REKEY (module docstring) — move every edge whose
    `parent == old_parent_id` to `parent = new_parent_id`, in one locked
    read-modify-write. Returns the list of child ids rekeyed (empty when
    there was nothing to do).

    Idempotent: once no edge points at `old_parent_id` any more, a repeat
    call is a pure no-op. Safe/no-op (never raises) when `old_parent_id` or
    `new_parent_id` is falsy, or they're equal — covers a legacy caller
    with no previous session id to rekey FROM (register_self's "previous
    registration had no sessionId" case) and a same-session re-registration
    alike. A tombstone (`parent: None`) never matches a real `old_parent_id`
    and so is never touched by this. `known_ids` is passed straight through
    to `_write_edges` for STALE-ENTRY PRUNING (module docstring); omit it
    (the default) when the caller has no live-agent set on hand — that
    still prunes stale tombstones, just not stale real edges."""
    if not old_parent_id or not new_parent_id or old_parent_id == new_parent_id:
        return []
    path = path or tree_file_path()
    with _locked(path):
        edges = read_edges(path)
        rekeyed = []
        for child_id, edge in edges.items():
            if (edge or {}).get("parent") == old_parent_id:
                new_edge = dict(edge)
                new_edge["parent"] = new_parent_id
                new_edge["setAt"] = time.time()
                new_edge["setBy"] = set_by
                edges[child_id] = new_edge
                rekeyed.append(child_id)
        if rekeyed:
            _write_edges(path, edges, known_live_ids=known_ids)
        return rekeyed


# ── seeding / migration ─────────────────────────────────────────────────

def worker_report_session_ids(repo_root) -> list[str]:
    """Every session id that has ever posted a worker self-report in this
    repo (scripts/lib/worker_self_report.py's marker files under
    `.claude/worker-reports/<session-id>.json`) — a durable, file-based
    stand-in for "this session is a DELIVERY_SLUG/CHIEF_WORKER worker",
    since only a session `worker_session_id()`-gated (worker-report-to-
    chief.py) ever writes one."""
    reports_dir = Path(repo_root) / ".claude" / "worker-reports"
    if not reports_dir.is_dir():
        return []
    return [p.stem for p in reports_dir.glob("*.json") if p.is_file()]


def migrate_seed_from_chief(repo_root, known_ids, chief_id, *,
                            set_by="migration", path=None) -> list[str]:
    """One-time (idempotent — safe to call on every dashboard start)
    migration: every currently-live worker for this repo
    (`worker_report_session_ids` ∩ `known_ids`) with NO edge yet gets
    parent = `chief_id`, so today's single-chief-slot behaviour does not
    silently stop the moment this feature ships. `attach_if_absent` never
    moves an edge that already exists, so a worker someone already
    re-parented by hand is left alone. Returns the child ids it seeded."""
    if not chief_id or chief_id not in (known_ids or ()):
        return []
    seeded = []
    for child_id in worker_report_session_ids(repo_root):
        if child_id == chief_id or child_id not in known_ids:
            continue
        if attach_if_absent(child_id, chief_id, known_ids=known_ids,
                            set_by=set_by, path=path) is not None:
            seeded.append(child_id)
    return seeded


# ── project derivation (pure, no subprocess — see module docstring) ────────

def project_for_cwd(cwd):
    """(project_name, project_root) for an agent's cwd, or (None, None) for
    an empty cwd. See the module docstring's PROJECT DERIVATION note."""
    if not cwd:
        return None, None
    parts = Path(cwd).parts
    if "01_Project" in parts:
        idx = parts.index("01_Project")
        if idx + 1 < len(parts):
            return parts[idx + 1], str(Path(*parts[: idx + 2]))
    name = Path(cwd).name
    return (name or None), cwd


def _read_chief_mode_ids(project_root, now=None) -> set:
    """Session ids with a fresh `on <iso> <session-id>` line in
    `<project_root>/.claude/chief-mode` — see module docstring on why this
    is a local re-implementation of the plugin's chief_mode.py `_lines`/
    `read_chiefs` rather than an import of it (this reads MANY explicit
    project roots, not just the cwd-resolved one). A malformed/2-field
    (legacy, session-less) line is skipped, same as the plugin does."""
    path = Path(project_root) / ".claude" / "chief-mode"
    try:
        raw = path.read_text()
    except OSError:
        return set()
    now = now or datetime.now(timezone.utc)
    ids = set()
    for line in raw.splitlines():
        parts = line.strip().split()
        if len(parts) < 3 or parts[0] != "on":
            continue
        try:
            stamp = datetime.fromisoformat(parts[1].replace("Z", "+00:00"))
        except ValueError:
            continue
        if stamp.tzinfo is None:
            stamp = stamp.replace(tzinfo=timezone.utc)
        if (now - stamp).total_seconds() / 3600 <= CHIEF_MODE_TTL_HOURS:
            ids.add(parts[2])
    return ids


def _read_chief_pane_registration(project_root) -> dict:
    """Raw `<project_root>/.claude/chief-pane.json` content ({} when
    missing/unreadable/not an object), written by
    `scripts/chief-register-pane.sh --register-self` on every chief pass —
    see module docstring's REGISTERED CHIEF PANE / VERIFIED CHIEF SESSION
    notes. `sessionId` is absent in a legacy file written before the H1
    fix; callers must run it through `verified_chief_session_id` rather
    than trusting `paneId` alone."""
    path = Path(project_root) / ".claude" / "chief-pane.json"
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def verified_chief_session_id(pane_id, recorded_session_id, live_session_id) -> str | None:
    """H1 fix (2026-09-24) — see module docstring's VERIFIED CHIEF SESSION
    note. Trust a chief-pane.json registration only when the CURRENT live
    occupant of `pane_id` (`live_session_id`, the caller's own fresh
    lookup — a local `herdr agent list`, a dashboard's already-polled
    roster, or this module's own `by_id` view) is the SAME session that
    registered it. Pure (no I/O), so every caller supplies whatever
    pane/session lookup it already has on hand instead of this module
    reaching for herdr itself. Returns None (unverified) when `pane_id` or
    `recorded_session_id` is missing (a legacy chief-pane.json with no
    `sessionId` yet — safe default: do not resolve off an unverified pane
    occupant) or when the live occupant doesn't match; otherwise returns
    `recorded_session_id`."""
    if not pane_id or not recorded_session_id:
        return None
    if live_session_id != recorded_session_id:
        return None
    return recorded_session_id


# ── view model — the CONTRACT (see module docstring) ────────────────────

def _degraded_agent(agent_id, edges, machine="local"):
    """An AGENT object for an id we know only from an edge — dead child,
    or a parent nobody currently reports as live/chief-mode."""
    edge = edges.get(agent_id) or {}
    label = edge.get("childSlug") or edge.get("parentSlug") or agent_id[:8]
    return {"id": agent_id, "label": label, "project": None, "projectRoot": None,
            "machine": machine, "paneId": None, "alive": False, "status": None,
            "crossProject": False}


def build_agent_tree(agents, edges, *, status_by_pane=None,
                     chief_mode_roots=None, now=None) -> dict:
    """The CONTRACT. `agents` is the dashboard's already-polled roster (local
    + every configured remote machine — chief_dashboard_views.build_agents_
    view's rows: needs `agentSession`, `paneId`, `label`, `cwd`, `machine`).
    `edges` is `read_edges()`'s result. `status_by_pane` is an optional
    {paneId: status} map (the dashboard's own per-row severity — see
    chief_dashboard_views._pane_tick_by_pane_id). `chief_mode_roots`
    defaults to every LOCAL project root seen in `agents` (see module
    docstring's chief-mode-is-local-only note); pass an explicit list in
    tests instead of relying on that discovery."""
    status_by_pane = status_by_pane or {}
    now_ts = now if now is not None else time.time()

    by_id = {}
    local_roots_seen = set()
    for a in agents:
        sid = a.get("agentSession")
        if not sid:
            continue
        machine = a.get("machine") or "local"
        project, root = project_for_cwd(a.get("cwd"))
        if machine == "local" and root:
            local_roots_seen.add(root)
        pane_id = a.get("paneId")
        by_id[sid] = {
            "id": sid, "label": a.get("label") or sid[:8], "project": project,
            "projectRoot": root, "machine": machine, "paneId": pane_id,
            "alive": True, "status": status_by_pane.get(pane_id),
            "crossProject": False,
        }

    roots = sorted(local_roots_seen) if chief_mode_roots is None else list(chief_mode_roots)
    now_utc = datetime.fromtimestamp(now_ts, tz=timezone.utc)
    chief_mode_ids = set()
    registered_panes = {}  # paneId -> recorded sessionId (None for a legacy file)
    for root in roots:
        for cid in _read_chief_mode_ids(root, now=now_utc):
            chief_mode_ids.add(cid)
            if cid not in by_id:  # degrade: known only via chief-mode, not currently live
                by_id[cid] = {
                    "id": cid, "label": edges.get(cid, {}).get("childSlug") or cid[:8],
                    "project": Path(root).name, "projectRoot": root, "machine": "local",
                    "paneId": None, "alive": False, "status": None, "crossProject": False,
                }
        reg = _read_chief_pane_registration(root)
        reg_pane_id = reg.get("paneId")
        if isinstance(reg_pane_id, str) and reg_pane_id:
            registered_panes[reg_pane_id] = reg.get("sessionId")

    # A currently-live local agent whose paneId matches a registered
    # chief-pane.json IS the chief for that project even when its
    # chief-mode TTL line is stale (see module docstring's REGISTERED CHIEF
    # PANE note) — but only when its OWN session id is the one that
    # registered the pane (verified_chief_session_id — H1 fix): a reused
    # pane slot must never promote an unrelated stranger.
    registered_chief_ids = set()
    for sid, meta in by_id.items():
        if not (meta.get("alive") and meta.get("machine") == "local"):
            continue
        pane_id = meta.get("paneId")
        if pane_id not in registered_panes:
            continue
        if verified_chief_session_id(pane_id, registered_panes[pane_id], sid) == sid:
            registered_chief_ids.add(sid)

    children_by_parent: dict[str, list[str]] = {}
    for child_id, edge in edges.items():
        parent_id = (edge or {}).get("parent")
        if parent_id:
            children_by_parent.setdefault(parent_id, []).append(child_id)

    def as_child(agent_id, parent_id):
        base = by_id.get(agent_id) or _degraded_agent(agent_id, edges)
        obj = dict(base)
        parent_project = (by_id.get(parent_id) or {}).get("project")
        obj["crossProject"] = bool(obj.get("project") and parent_project
                                   and obj["project"] != parent_project)
        return obj

    known_parent_ids = {p for p in children_by_parent if p in by_id}
    chief_ids = known_parent_ids | chief_mode_ids | registered_chief_ids

    chiefs = []
    for parent_id in sorted(chief_ids):
        base = by_id[parent_id]
        chiefs.append({
            "id": parent_id, "label": base["label"], "project": base["project"],
            "projectRoot": base["projectRoot"], "machine": base["machine"],
            "paneId": base["paneId"], "alive": base["alive"],
            "isChiefMode": parent_id in chief_mode_ids,
            "isRegisteredChief": parent_id in registered_chief_ids,
            "status": base["status"],
            "children": [as_child(cid, parent_id)
                        for cid in sorted(children_by_parent.get(parent_id, []))],
        })

    # `is_child` (not "agent_id not in edges"): a detached child still has a
    # KEY in edges (the H2 tombstone), just no parent — it must still read
    # as unassigned, not silently vanish from both lists.
    unassigned = [dict(meta) for agent_id, meta in sorted(by_id.items())
                 if agent_id not in chief_ids and not is_child(edges, agent_id)]

    parent_gone = []
    for child_id, edge in sorted(edges.items()):
        parent_id = (edge or {}).get("parent")
        if not parent_id or parent_id in chief_ids:
            continue  # nested under its chief row above
        entry = as_child(child_id, parent_id)
        parent_label = ((by_id.get(parent_id) or {}).get("label")
                        or edge.get("parentSlug") or str(parent_id)[:8])
        entry["lostParent"] = {"id": parent_id, "label": parent_label}
        parent_gone.append(entry)

    return {
        "generatedAt": datetime.fromtimestamp(now_ts, tz=timezone.utc).isoformat(timespec="seconds"),
        "chiefs": chiefs, "unassigned": unassigned, "parentGone": parent_gone,
    }
