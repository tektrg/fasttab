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
When the chief's tree has NO entry yet, `deliver()` (2026-09-25 fix) now
also PERSISTS the worker-resolved fallback into it via `attach_if_absent` —
so a worker that only ever got seeded on its OWN (non-chief) machine still
ends up in the Pro's tree, just on its first report instead of at launch.
See also `worker_launch_settings.seed_launch_edge` (scripts/lib/
worker_launch_settings.py): the PREFERRED path writes the edge straight into
this file at launch time, on whichever machine actually runs that builder
CODE (not necessarily the worker's own machine — `open-remote-pane.sh new`
runs entirely on the Pro, ssh'ing only the herdr calls, so its seed is a
plain local write here with no cross-machine gap at all); this section's
CHIEF_PARENT/deliver() fallback only matters for the launch doors or
callers that can't reach this file directly at launch time.

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

STALE-ENTRY PRUNING (bug fix, 2026-09-25; M-B correction, QA pass 4, 2026-09-26)
---------------------------------------------------------------------------------
Tombstones (H2 DETACH TOMBSTONE above) and dead children's real edges are
never otherwise removed, so the store file grows without bound. Every write
path (`attach`, `attach_if_absent`, `detach`, `rekey_child`,
`rekey_children_of_parent` — all of them funnel through `_write_edges`) now
prunes before writing:
  * a TOMBSTONE older than `TOMBSTONE_MAX_AGE_SECONDS` (7 days) is dropped
    unconditionally — a detach that old is settled, nothing reads it as
    "recently detached" any more.
  * a REAL or PENDING edge older than its own age threshold is dropped ONLY
    when the write passes a `known_live_ids` roster AND the child is NOT in
    it — but M-B CORRECTION (QA pass 4, 2026-09-26): `attach`, `attach_if_
    absent`, `detach`, `rekey_child` and `rekey_children_of_parent` never
    pass one any more, EVER — the `known_ids` an attach/attach_if_absent
    caller has is for `_validate_attach` ONLY. It is very often PARTIAL (a
    local-machine-only `herdr agent list` in chief-dashboard-server.py's
    one-time migration; whatever chief_dashboard_views.py's FEEDS cache
    happens to hold for a dashboard-driven attach), and QA reproduced the
    exact consequence: a local-only migration attach pruned a >24h pending
    Air edge purely because Air was absent from that partial validation
    set. `mark_children_live` (`scripts/pane-tick-writer.py`'s heartbeat,
    roster-complete-aware — see its own docstring) is now the ONLY caller
    in this module that ever prunes a real/pending edge by roster absence.
    Every other write here still prunes tombstones (unconditional, above)
    but never guesses a live child's edge is gone from age/absence alone.
Kept intentionally simple: one age check per entry kind, no cross-file
reconciliation, no background sweep — pruning piggybacks on writes that
were already happening.

GHOST NODE — LAUNCH-PENDING EDGES (QA fix, 2026-09-25)
---------------------------------------------------------
A launch-time seed (`worker_launch_settings.seed_launch_edge`, called from
`scripts/worker-launch-settings.py`, `chief_dashboard_worker.create_worker`,
`remote_pane_mirror.cmd_new`) writes the edge the INSTANT a launch is
dispatched, before anything confirms the pre-assigned `--session-id` ever
actually booted. A launch that never boots (bad settings JSON, a crashed
`claude-aptus`, a remote pane that never came up) then leaves a GHOST NODE:
an edge for a session that never existed, permanently visible under its
chief (`alive: false`) — the ordinary STALE-ENTRY PRUNING above never
catches it, since that only fires at 30 days AND only when a caller happens
to pass `known_live_ids` (most of these seeding call sites don't have a
live-roster poll on hand at seed time).

Two-part fix, additive to the edge shape (`launchPending: true`, an
optional key — a reader that doesn't know it still sees a normal edge):

  1. KNOWN (POSITIVE) boot failure -> hard-remove. `attach_if_absent(...,
     pending=True)` marks the edge `launchPending: true`. The one door that
     gets a POSITIVE boot-failure signal today (`remote_pane_mirror.
     wait_for_remote_agent` — the pane itself is gone, or its foreground has
     already reverted to a bare shell prompt with no agent process, i.e. the
     launched command already exited/crashed) calls `remove_child()` — a
     genuine `del`, NOT `detach()`'s sticky tombstone: the tombstone exists
     to survive a still-running worker's env re-seeding it (DETACH TOMBSTONE
     above), but a session that never booted has no live process and
     nothing to guard against re-seeding — a tombstone here would be a
     permanent, semantically-wrong "someone explicitly detached this" record
     for a launch that simply never came up. `remove_child()` itself only
     ever deletes an entry that is STILL `launchPending` (L1 fix, QA pass 2)
     — it must never be able to delete a real dashboard-driven attach or a
     detach tombstone, only a still-unconfirmed launch seed. A bare TIMEOUT
     (`wait_for_remote_agent` ran out of its wait budget with no positive
     signal either way — a slow but still-in-progress boot) is NOT treated
     as a failure and must never remove the edge.
  2. NO positive boot-failure signal at all (`chief_dashboard_worker.
     create_worker` has no boot check; `scripts/worker-launch-settings.py`'s
     CLI can't observe the pane it typed a launch line into either; a REMOTE
     timeout from case 1 above also falls through to here) -> `_prune` drops
     a `launchPending` edge older than `LAUNCH_PENDING_MAX_AGE_SECONDS`
     (24h) — but ONLY GATED THE SAME WAY as the ordinary 30-day rule above:
     a `known_live_ids` roster must be supplied AND must NOT include the
     child. H1 REGRESSION (QA pass 2, 2026-09-25): this used to fire
     UNCONDITIONALLY (no roster needed) on the theory that "a launch is
     confirmed live well within a day, or it never will be" — true for a
     worker that produces a REPORTABLE Stop-hook turn, false for most
     CHIEF_WORKER=1 shared-tree workers, which routinely go a full session
     without one (`worker-report-to-chief.py`'s `plan_report` only fires on
     a fingerprint CHANGE) — so a perfectly healthy worker's edge was being
     deleted out from under it at 24h and never re-seeded, reintroducing the
     exact "worker not nested" bug this whole feature exists to fix. Fixed
     by requiring the SAME positive roster evidence the 30-day rule already
     requires — age alone, with no roster to check against, proves nothing
     for a pending edge any more than it does for a confirmed one.

  `launchPending` is cleared (`mark_child_live()` / `mark_children_live()`)
  the moment a caller has ACTUAL evidence the child is alive:
    * `worker-report-to-chief.py`'s `run_hook` calls `mark_child_live` for
      EVERY Stop-hook firing (a hook firing at all IS proof of life),
      BEFORE `plan_report`'s reportable-turn gate — not inside
      `seed_edge_if_needed`/`deliver()`, which (H1 REGRESSION above) only
      run on a REPORTABLE turn and so under-cover most workers.
    * `scripts/pane-tick-writer.py`'s ~2-minute heartbeat already collects
      every LIVE `agent_session` id, local + every configured remote
      machine (the Air) — it calls the batch
      `mark_children_live(live_ids, roster_complete)` every tick, which
      both clears `launchPending` for every match AND (when
      `roster_complete`) passes that same roster through to the write as
      `known_live_ids`, actually exercising case 2's gated prune on a
      REGULAR cadence, not just incidentally whenever some other write
      happens to occur. This is the primary, most-complete liveness signal
      — it is the only one that covers an Air worker (whose own machine
      never writes into the Pro's tree at all) and a worker that never
      produces a single reportable turn.

  M1 REGRESSION (QA pass 3, 2026-09-26): `roster_complete` matters as much
  as the roster itself. `_herdr_pane_info` asks local herdr AND every
  configured remote machine; ANY of those failing (one machine briefly
  asleep or unreachable) makes the roster PARTIAL, not empty — and a caller
  that passed a partial roster through as `known_live_ids` let `_prune` read
  "not in this (incomplete) roster" as "confirmed gone" for every child that
  down machine alone owns. QA reproduced it: 11 of 15 real children are Air,
  and a single bad tick deleted both a >24h pending Air child AND a >30-day
  CONFIRMED Air edge. Fixed: `mark_children_live` only passes the roster
  through to `known_live_ids` when `roster_complete` is True; an incomplete
  roster still clears `launchPending` for whoever it did see (a partial
  sighting is still real evidence) but prunes NOTHING.

  A confirmed (non-pending) edge ages out via the 30-day/`known_live_ids`
  rule from then on, same as any other edge — but that rule now measures
  SILENCE, not age: `lastSeenAt` (refreshed by `mark_children_live`, at most
  once per `LAST_SEEN_REFRESH_MIN_INTERVAL_SECONDS`, only during a COMPLETE
  roster tick) if present, else `setAt` (an edge no complete tick has ever
  confirmed yet) — age-since-`setAt` alone would prune a perfectly healthy,
  long-lived edge the instant a transient roster gap coincided with it
  merely being OLD, which is the normal case for every edge past 30 days.
  `launchPending` only ever makes an edge prunable SOONER, never keeps one
  around longer.
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

#: GHOST NODE — LAUNCH-PENDING EDGES (module docstring) — how old an
#: unconfirmed (`launchPending: true`) launch-time seed must be before a
#: write drops it. L3 correction (QA pass 3, 2026-09-26): this DOES need a
#: `known_live_ids` roster, same as EDGE_MAX_AGE_SECONDS below — a stale
#: comment here once claimed otherwise, which is exactly the H1 REGRESSION
#: (QA pass 2) this module's docstring describes: age alone proves nothing
#: without a roster to check the child against.
LAUNCH_PENDING_MAX_AGE_SECONDS = 24 * 3600

#: `mark_children_live`'s `lastSeenAt` throttle (QA pass 3, 2026-09-26): the
#: EDGE_MAX_AGE_SECONDS silence clock above is a 30-DAY threshold, so
#: bumping `lastSeenAt` on every single ~2-minute heartbeat tick is far more
#: precision than that clock needs — and it makes `_write_edges`'s L5
#: no-op-write skip never actually fire for a tree with any live child at
#: all (a fresh timestamp every write is, by definition, never identical to
#: the last write). Refresh at most this often per child instead.
LAST_SEEN_REFRESH_MIN_INTERVAL_SECONDS = 3600

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
    version, e.g. for a return value already computed).

    `known_live_ids` must be a COMPLETE, trustworthy roster whenever it is
    not None — a caller unsure whether it saw everyone (a partial herdr
    answer, one machine down) must pass None, never its partial set, or this
    prunes every child that machine happens to own (QA pass 3, 2026-09-26,
    M1 REGRESSION: `mark_children_live` used to pass its roster through even
    when incomplete — see that function's docstring)."""
    now = now if now is not None else time.time()
    kept = {}
    for child_id, edge in edges.items():
        e = edge or {}
        set_at = e.get("setAt")
        age = (now - set_at) if isinstance(set_at, (int, float)) else 0
        if e.get("detached"):
            if age > TOMBSTONE_MAX_AGE_SECONDS:
                continue
        elif e.get("launchPending"):
            # GHOST NODE (module docstring) — H1 REGRESSION FIX (QA pass 2,
            # 2026-09-25): SAME gating as the known_live_ids rule below, just
            # a shorter age threshold. Never unconditional — most workers
            # never produce a "reportable" Stop-hook turn, so age alone
            # proves nothing without a roster to check against (that used to
            # prune perfectly healthy workers at 24h and never re-seed them).
            if known_live_ids is not None and age > LAUNCH_PENDING_MAX_AGE_SECONDS \
                    and child_id not in known_live_ids:
                continue
        else:
            # M1 fix (QA pass 3, 2026-09-26): measure SILENCE, not age — how
            # long since a complete roster last actually saw this child
            # (`lastSeenAt`, refreshed by `mark_children_live`), falling back
            # to `age` (time since the edge was SET) only for an edge no
            # complete-roster tick has ever confirmed yet. Age-since-setAt
            # alone would prune a perfectly healthy, long-lived edge the
            # instant a transient roster gap (this machine briefly
            # unreachable) coincided with it merely being OLD, which is the
            # normal case for every edge that has lived past 30 days.
            last_seen = e.get("lastSeenAt")
            silence = (now - last_seen) if isinstance(last_seen, (int, float)) else age
            if known_live_ids is not None and silence > EDGE_MAX_AGE_SECONDS \
                    and child_id not in known_live_ids:
                continue
        kept[child_id] = edge
    return kept


def _write_edges(path: Path, edges: dict, known_live_ids=None) -> None:
    """L5 fix (QA pass 3, 2026-09-26): skip the disk write entirely when the
    post-prune content is byte-identical to what's already on disk. A caller
    like `mark_children_live` runs on EVERY ~2-minute heartbeat tick — most
    of which change nothing at all once `lastSeenAt` is throttled
    (LAST_SEEN_REFRESH_MIN_INTERVAL_SECONDS) — so without this, every single
    tick still replaced the file and bumped its mtime for no reason, which
    every other reader (the dashboard, `read_edges` callers elsewhere) would
    otherwise see as constant unexplained churn."""
    edges = _prune(edges, known_live_ids)
    path = Path(path)
    serialized = json.dumps(edges, indent=2, sort_keys=True) + "\n"
    try:
        if path.read_text() == serialized:
            return
    except Exception:
        pass  # doesn't exist yet, or unreadable — fall through to a real write
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(f".{os.getpid()}.tmp")
    tmp.write_text(serialized)
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


def _edge(parent, child_slug, parent_slug, set_by, pending=False) -> dict:
    edge = {"parent": parent, "setAt": time.time(), "setBy": set_by}
    if child_slug:
        edge["childSlug"] = child_slug
    if parent_slug:
        edge["parentSlug"] = parent_slug
    if pending:
        # GHOST NODE — LAUNCH-PENDING EDGES (module docstring): additive-only
        # marker, omitted entirely for the common (non-launch-seed) case so
        # every existing edge's shape is unchanged.
        edge["launchPending"] = True
    return edge


def attach(child, parent, *, known_ids=None, child_slug=None, parent_slug=None,
           set_by=None, path=None) -> dict:
    """Explicit attach — see module docstring. Raises AgentTreeError on
    self/cycle/two-level/unknown-agent. Returns the edge written.

    M-B fix (QA pass 4, 2026-09-26): `known_ids` is used for VALIDATION
    ONLY (`_validate_attach`) — it is NEVER forwarded to `_write_edges` as a
    prune roster. A caller's `known_ids` here is very often a PARTIAL
    roster (e.g. chief-dashboard-server.py's one-time migration passes a
    LOCAL-MACHINE-ONLY `herdr agent list`; chief_dashboard_views.py's
    dashboard-attach handler passes whatever FEEDS happens to have cached,
    which can be stale/incomplete for a remote machine mid-poll) — passing
    a partial set through as `known_live_ids` let `_prune` read "not in
    this (partial) set" as "confirmed gone" for every child an unreachable
    machine alone owns, the exact same failure class as the M1 REGRESSION
    (QA pass 3) fixed for `mark_children_live`, just via a different call
    path. `mark_children_live` (roster-complete-aware) is now the ONLY
    caller that ever prunes a real/pending edge by roster absence — every
    other write here only ever prunes unconditional tombstone/no-roster
    staleness (see `_prune`)."""
    path = path or tree_file_path()
    with _locked(path):
        edges = read_edges(path)
        _validate_attach(edges, child, parent, known_ids)
        edges[child] = _edge(parent, child_slug, parent_slug, set_by)
        _write_edges(path, edges)
        return dict(edges[child])


def attach_if_absent(child, parent, *, known_ids=None, child_slug=None,
                     parent_slug=None, set_by=None, path=None,
                     pending=False) -> dict | None:
    """Seeding attach — see module docstring. None (no-op) when `child`
    already has an edge; otherwise the same validation as attach().

    `pending` (GHOST NODE — LAUNCH-PENDING EDGES, module docstring): True
    marks the written edge `launchPending: true` — for a launch-time seed
    written before anything confirms the session actually booted. Leave the
    default False for every seed that already IS proof of life (the
    worker's own first report, the deliver() fallback, the migration
    pass).

    M-B fix (QA pass 4, 2026-09-26): same as `attach()` — `known_ids` is
    VALIDATION-ONLY, never forwarded to `_write_edges` as a prune roster.
    See `attach()`'s docstring for why (the migration seed's `known_ids` is
    a local-machine-only roster; QA reproduced a >24h pending Air edge
    pruned by exactly that local-only migration attach)."""
    path = path or tree_file_path()
    with _locked(path):
        edges = read_edges(path)
        if child in edges:
            return None
        _validate_attach(edges, child, parent, known_ids)
        edges[child] = _edge(parent, child_slug, parent_slug, set_by, pending=pending)
        _write_edges(path, edges)
        return dict(edges[child])


def detach(child, *, set_by=None, path=None) -> bool:
    """Explicit detach — see module docstring's DETACH TOMBSTONE (H2 fix).
    Leaves `child` tombstoned (`parent: None, detached: True`) rather than
    deleting its entry, so a still-running worker's next Stop-hook report
    can never silently re-seed the same parent (`attach_if_absent`'s no-op
    rule already treats any existing entry, tombstoned or not, as "leave it
    alone"). False (no-op) when `child` has no entry at all, or is already
    tombstoned — idempotent either way. `read_edges()`/`build_agent_tree`
    still show a tombstoned child as unassigned (no parent), and an
    explicit `attach()` clears the tombstone by overwriting the entry.

    M-B fix (QA pass 4, 2026-09-26): no `known_ids`/roster parameter at
    all — detach doesn't validate against one (no `_validate_attach` call),
    so the old parameter only ever fed `_write_edges` a prune roster, the
    same general hazard fixed across `attach`/`attach_if_absent`/`rekey_
    child`/`rekey_children_of_parent`. No production caller ever passed one
    (grepped clean)."""
    path = path or tree_file_path()
    with _locked(path):
        edges = read_edges(path)
        existing = edges.get(child)
        if existing is None or (existing or {}).get("detached"):
            return False
        edges[child] = {"parent": None, "detached": True, "setAt": time.time(), "setBy": set_by}
        _write_edges(path, edges)
        return True


def remove_child(child, *, path=None) -> bool:
    """GHOST NODE — LAUNCH-PENDING EDGES (module docstring) — HARD delete of
    `child`'s entry: unlike `detach()`, this leaves NOTHING behind, not even
    a tombstone. Only for a session that is KNOWN to have never come alive
    (a launch with a POSITIVE boot-failure signal) — there is no live
    process whose env could ever re-seed it, so `detach()`'s sticky-tombstone
    guard (DETACH TOMBSTONE, module docstring) does not apply and would be
    semantically wrong here (it would read as "a person explicitly detached
    a real worker", which never happened).

    L1 fix (QA pass 2, 2026-09-25): only ever deletes an entry that is STILL
    `launchPending` — never a real dashboard attach, and never a detach
    tombstone (which has no `launchPending` key to begin with). Without this
    guard a caller racing a launch-failure report against, say, a PO's
    dashboard attach landing moments earlier could delete a real edge purely
    because it still held the stale pre-attach `child` id. False (no-op)
    when `child` has no entry at all, or its entry is no longer pending —
    idempotent, safe to call more than once."""
    path = path or tree_file_path()
    with _locked(path):
        edges = read_edges(path)
        edge = edges.get(child)
        if not edge or not edge.get("launchPending"):
            return False
        del edges[child]
        _write_edges(path, edges)
        return True


def mark_child_live(child, *, path=None) -> bool:
    """GHOST NODE — LAUNCH-PENDING EDGES (module docstring) — clear
    `child`'s `launchPending` marker: call this the moment a caller has
    ACTUAL evidence the session is alive. `worker-report-to-chief.py`'s
    `run_hook` calls this for EVERY Stop-hook firing (before `plan_report`'s
    reportable-turn gate — a hook firing at all IS proof of life, whether or
    not this particular turn produces a report) and `deliver()` calls it too
    (only ever runs for a session that produced a real report). False
    (no-op, never an error) when `child` has no edge yet, or its edge isn't
    pending — safe to call unconditionally, same idiom as
    `attach_if_absent`'s own no-op-by-default design.

    H1 REGRESSION NOTE (QA pass 2, 2026-09-25): this alone badly under-covers
    liveness — most CHIEF_WORKER=1 shared-tree workers go long stretches
    (often a whole session) without a REPORTABLE turn, and this function
    can't observe an Air worker at all (its own machine never writes into
    the Pro's tree). `mark_children_live()` (the roster-based batch sibling,
    called from `scripts/pane-tick-writer.py`'s ~2-minute heartbeat) is the
    PRIMARY liveness signal for the ghost-node prune below; this per-call
    version is a same-turn confirmation for a LOCAL worker, not a substitute
    for it."""
    path = path or tree_file_path()
    with _locked(path):
        edges = read_edges(path)
        edge = edges.get(child)
        if not edge or not edge.get("launchPending"):
            return False
        edges[child] = {k: v for k, v in edge.items() if k != "launchPending"}
        _write_edges(path, edges)
        return True


def mark_children_live(live_ids, roster_complete, *, path=None, now=None) -> list[str]:
    """Batch `mark_child_live` — the PRIMARY ghost-node liveness signal (H1
    fix, QA pass 2, 2026-09-25; see `mark_child_live`'s own docstring for
    why the per-call version alone under-covers this). `scripts/pane-tick-
    writer.py`'s ~2-minute heartbeat already collects every LIVE
    `agent_session` id, local + every configured remote machine (the Air) —
    passing that whole roster here clears `launchPending` for every match
    (regardless of `roster_complete` — a sighting is a sighting) and, when
    the roster is trustworthy, also lets `_prune`'s roster-gated rules
    actually run on a REGULAR ~2-minute cadence, instead of only
    incidentally whenever some unrelated write happens to occur next.

    `roster_complete` (M1 REGRESSION FIX, QA pass 3, 2026-09-26): True only
    when `live_ids` reflects EVERY configured machine answering this tick
    (`pane-tick-writer._herdr_pane_info`'s own return). A caller that passed
    its roster through on ANY non-empty read — even a PARTIAL one, e.g. the
    Air machine asleep or its ssh briefly down for one tick — let `_prune`
    read "not in this roster" as "confirmed gone" for children that machine
    alone owns (QA reproduced: 11 of 15 real children are Air; one bad tick
    deleted a >24h pending Air child AND a >30d CONFIRMED Air edge). So:
    incomplete -> `known_live_ids=None` on the write (clear what we saw,
    prune nothing — the same "don't know, don't guess" contract as any other
    caller unsure whether it saw everyone). Complete -> the roster is
    authoritative even when empty (genuinely nobody alive, not a herdr
    hiccup silently returning nothing), so it's passed through as-is,
    enabling a real prune.

    `lastSeenAt` is refreshed (to `now`) for every non-pending child found in
    a COMPLETE roster only — the fact this heartbeat can also observe a
    child during a partial-roster tick (e.g. Air itself answered but some
    OTHER configured machine didn't) is still used to clear `launchPending`
    above, but is deliberately NOT treated as a fresh "seen" timestamp for
    the 30-day silence clock (`_prune`), keeping that clock's semantics tied
    to ticks where absence could also have been trusted.

    L-D correction (QA pass 4, 2026-09-26): this does NOT always perform a
    disk write any more — `_write_edges`'s own L5 no-op-write skip (QA pass
    3) means a tick that changes nothing (no pending edge to clear, no
    child due for its throttled `lastSeenAt` refresh, nothing to prune)
    leaves the file untouched. What's unconditional is the attempt: this
    function always goes through `_write_edges` on every call (so pruning
    still piggybacks on every tick, per the module docstring's design), it
    just may no-op once inside it.

    L3 correction (QA pass 3, 2026-09-26): this can raise (a genuine lock/
    disk I/O failure), same as any other locked read-modify-write in this
    module — it does NOT swallow its own errors. `pane-tick-writer.py`'s
    heartbeat wraps this call in try/except itself (best-effort from the
    CALLER's side); a docstring here once claimed "never raises", which was
    never true of this function in isolation. Returns the ids actually
    cleared (for tests/observability)."""
    live_ids = set(live_ids or ())
    now = now if now is not None else time.time()
    path = path or tree_file_path()
    with _locked(path):
        edges = read_edges(path)
        cleared = []
        for child_id in live_ids:
            edge = edges.get(child_id)
            if not edge:
                continue
            updated = dict(edge)
            changed = False
            if updated.get("launchPending"):
                del updated["launchPending"]
                cleared.append(child_id)
                changed = True
            if roster_complete:
                prior_last_seen = updated.get("lastSeenAt")
                # L5 / throttle (QA pass 3, 2026-09-26): at most once per
                # LAST_SEEN_REFRESH_MIN_INTERVAL_SECONDS per child — see that
                # constant's own comment for why finer than this is wasted
                # precision that would also defeat _write_edges's no-op skip.
                if not isinstance(prior_last_seen, (int, float)) or \
                        (now - prior_last_seen) >= LAST_SEEN_REFRESH_MIN_INTERVAL_SECONDS:
                    updated["lastSeenAt"] = now
                    changed = True
            if changed:
                edges[child_id] = updated
        known_live_ids = live_ids if roster_complete else None
        _write_edges(path, edges, known_live_ids=known_live_ids)
        return cleared


def rekey_child(old_id, new_id, *, path=None) -> bool:
    """Move `old_id`'s edge to `new_id` (see module docstring). False (no
    change) when there is nothing to move or `new_id` already has its own
    edge — never overwrites a real edge.

    M-B fix (QA pass 4, 2026-09-26): no `known_ids`/roster parameter — same
    reasoning as `detach()`'s docstring (no validation happens here either,
    so the old parameter only ever fed `_write_edges` a prune roster; `mark_
    children_live` is the one roster-pruning caller now)."""
    path = path or tree_file_path()
    with _locked(path):
        edges = read_edges(path)
        if old_id not in edges or new_id in edges:
            return False
        edge = dict(edges.pop(old_id))
        edge["setAt"] = time.time()
        edges[new_id] = edge
        _write_edges(path, edges)
        return True


def rekey_children_of_parent(old_parent_id, new_parent_id, *, set_by=None,
                             path=None) -> list[str]:
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
    and so is never touched by this.

    M-B fix (QA pass 4, 2026-09-26): no `known_ids`/roster parameter any
    more — `pane-tick-gate.py`'s `register_self` (this function's one
    production caller) has no live-agent poll on hand anyway, and forwarding
    a partial one to `_write_edges` as a prune roster is exactly the M-B
    hazard fixed across `attach`/`attach_if_absent`/`detach`/`rekey_child`
    too. A write still prunes stale TOMBSTONES unconditionally (`_prune`
    doesn't gate that branch on a roster); it just never guesses a real
    edge is gone from a partial/local-only set any more — only `mark_
    children_live` does that, and only when its roster is complete."""
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
            _write_edges(path, edges)
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
