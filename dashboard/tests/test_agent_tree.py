#!/usr/bin/env python3
"""scripts/lib/agent_tree.py — the chief/worker hierarchy store + view model.

Covers: attach/attach_if_absent validation (self, cycle, two-level, unknown-
agent), detach, rekey_child, migrate_seed_from_chief (idempotent), project
derivation, and the build_agent_tree() CONTRACT shape (chiefs/unassigned/
parentGone, isChiefMode, isRegisteredChief, crossProject, lostParent).

Every test points AGENT_TREE_FILE at a fresh temp file — never the real
`~/.claude/agent-tree.json`.
"""
import json
import os
import shutil
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parent
TMP = Path(tempfile.mkdtemp(prefix="agent-tree-test-"))

sys.path.insert(0, str(SCRIPTS / "server" / "lib"))

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def check_raises(label, code, fn):
    try:
        fn()
    except AgentTreeError as e:  # noqa: F821 (imported below, module-level)
        ok = e.code == code
        if not ok:
            fails.append(f"{label}: raised code {e.code!r} want {code!r}")
        print(f"  {'PASS' if ok else 'FAIL'}  {label}")
        return
    fails.append(f"{label}: did not raise")
    print(f"  FAIL  {label}")


def fresh_path(name):
    return TMP / f"{name}-{time.time_ns()}.json"


# ── store basics ─────────────────────────────────────────────────────────

import agent_tree as tree  # noqa: E402
from agent_tree import AgentTreeError  # noqa: E402


def test_attach_and_read():
    p = fresh_path("attach")
    edge = tree.attach("child-1", "chief-1", known_ids={"child-1", "chief-1"},
                       child_slug="s1", set_by="test", path=p)
    check("attach returns the written edge's parent", edge["parent"], "chief-1")
    edges = tree.read_edges(p)
    check("edge persisted", edges["child-1"]["parent"], "chief-1")
    check("childSlug persisted", edges["child-1"]["childSlug"], "s1")


def test_attach_overwrites_existing_edge():
    p = fresh_path("overwrite")
    ids = {"c", "p1", "p2"}
    tree.attach("c", "p1", known_ids=ids, path=p)
    tree.attach("c", "p2", known_ids=ids, path=p)  # re-parent: a MOVE, not blocked
    check("attach() moves the edge to the new parent", tree.read_edges(p)["c"]["parent"], "p2")


def test_attach_if_absent_never_overwrites():
    p = fresh_path("seed")
    ids = {"c", "p1", "p2"}
    first = tree.attach_if_absent("c", "p1", known_ids=ids, path=p)
    check("first seed writes an edge", first["parent"], "p1")
    second = tree.attach_if_absent("c", "p2", known_ids=ids, path=p)
    check("second seed is a no-op (returns None)", second, None)
    check("edge still points at the original parent", tree.read_edges(p)["c"]["parent"], "p1")


def test_self_parent_refused():
    p = fresh_path("self")
    check_raises("self-parent refused", tree.ERROR_SELF,
                lambda: tree.attach("a", "a", known_ids={"a"}, path=p))


def test_unknown_agent_refused():
    p = fresh_path("unknown")
    check_raises("unknown child refused", tree.ERROR_UNKNOWN_AGENT,
                lambda: tree.attach("ghost", "chief", known_ids={"chief"}, path=p))
    check_raises("unknown parent refused", tree.ERROR_UNKNOWN_AGENT,
                lambda: tree.attach("child", "ghost", known_ids={"child"}, path=p))


def test_two_level_parent_cannot_have_a_parent():
    p = fresh_path("two-level-a")
    ids = {"grandparent", "parent", "child"}
    tree.attach("parent", "grandparent", known_ids=ids, path=p)
    check_raises("attaching under an already-child parent is refused", tree.ERROR_TWO_LEVEL,
                lambda: tree.attach("child", "parent", known_ids=ids, path=p))


def test_two_level_child_with_children_cannot_become_a_child():
    p = fresh_path("two-level-b")
    ids = {"chief", "worker", "grandworker"}
    tree.attach("worker", "chief", known_ids=ids, path=p)
    check_raises("an agent with children cannot become a child", tree.ERROR_TWO_LEVEL,
                lambda: tree.attach("chief", "worker", known_ids=ids, path=p))


def test_detach():
    p = fresh_path("detach")
    ids = {"c", "p"}
    tree.attach("c", "p", known_ids=ids, path=p)
    check("detach returns True", tree.detach("c", set_by="po", path=p), True)
    edge = tree.read_edges(p).get("c")
    check("tombstone left behind, not deleted (H2 fix)", edge is not None, True)
    check("tombstone has no parent", (edge or {}).get("parent"), None)
    check("tombstone marked detached", (edge or {}).get("detached"), True)
    check("detaching again is a no-op (already tombstoned)", tree.detach("c", path=p), False)
    check("detaching an id with no entry at all is a no-op",
         tree.detach("never-attached", path=p), False)


def test_detach_is_sticky_against_reseed():
    """H2 regression (converted probe_detach_not_sticky.py): a still-running
    worker's Stop hook re-runs seed_edge_if_needed on every turn end, which
    used to see "no edge" right after detach() deleted the key and silently
    re-seed the SAME parent straight back from the launch-time CHIEF_PARENT
    env (which detach cannot touch — a live process's env is immutable from
    outside). The tombstone left by detach() now makes attach_if_absent's
    own no-op rule ("child already has an edge") protect it too."""
    p = fresh_path("detach-sticky")
    ids = {"worker-abc", "chief-1"}
    tree.attach("worker-abc", "chief-1", known_ids=ids, set_by="launch", path=p)
    check("detach succeeds", tree.detach("worker-abc", path=p), True)
    check("no parent right after detach",
         (tree.read_edges(p).get("worker-abc") or {}).get("parent"), None)
    # Simulate the worker's NEXT Stop-hook report: seed_edge_if_needed's own
    # rule is "attach_if_absent, only if `child` has no edge yet".
    reseed = tree.attach_if_absent("worker-abc", "chief-1", known_ids=ids,
                                   set_by="launch-or-migration", path=p)
    check("reseed after detach is a no-op (sticky)", reseed, None)
    check("still no parent after the worker's next report",
         (tree.read_edges(p).get("worker-abc") or {}).get("parent"), None)


def test_detach_shows_child_as_unassigned_in_view_model():
    p = fresh_path("detach-view")
    ids = {"worker-1", "chief-1"}
    tree.attach("worker-1", "chief-1", known_ids=ids, path=p)
    tree.detach("worker-1", path=p)
    agents = [
        _agent("chief-1", "chief", "/Users/trungluong/01_Project/AptusFit"),
        _agent("worker-1", "worker", "/Users/trungluong/01_Project/AptusFit"),
    ]
    out = tree.build_agent_tree(agents, tree.read_edges(p), chief_mode_roots=[])
    # chief-1 has zero children after the detach, so it's no longer a
    # "chief" in the view model either (known_parent_ids requires >=1 child
    # edge) — both ids land in unassigned, which is correct: nothing lost.
    check("no chiefs row left (zero children)", out["chiefs"], [])
    check("detached worker shows as unassigned, not vanished",
         "worker-1" in [a["id"] for a in out["unassigned"]], True)
    check("detached worker not in parentGone either",
         [a["id"] for a in out["parentGone"]], [])


def test_attach_after_detach_clears_the_tombstone():
    p = fresh_path("reattach")
    ids = {"c", "p1", "p2"}
    tree.attach("c", "p1", known_ids=ids, path=p)
    tree.detach("c", path=p)
    edge = tree.attach("c", "p2", known_ids=ids, path=p)
    check("explicit re-attach after detach succeeds", edge["parent"], "p2")
    check("detached flag cleared", tree.read_edges(p)["c"].get("detached"), None)


def test_rekey_child():
    p = fresh_path("rekey")
    ids = {"old-uuid", "chief"}
    tree.attach("old-uuid", "chief", known_ids=ids, child_slug="s", path=p)
    check("rekey moves the edge", tree.rekey_child("old-uuid", "new-uuid", path=p), True)
    edges = tree.read_edges(p)
    check("old id gone", "old-uuid" in edges, False)
    check("new id carries the parent", edges["new-uuid"]["parent"], "chief")
    check("new id carries the slug", edges["new-uuid"]["childSlug"], "s")
    check("rekey again is a no-op (nothing left to move)",
         tree.rekey_child("old-uuid", "another-uuid", path=p), False)


def test_rekey_never_overwrites_a_real_edge():
    p = fresh_path("rekey-guard")
    ids = {"old-uuid", "new-uuid", "chief-a", "chief-b"}
    tree.attach("old-uuid", "chief-a", known_ids=ids, path=p)
    tree.attach("new-uuid", "chief-b", known_ids=ids, path=p)
    check("rekey refuses when the target id already has its own edge",
         tree.rekey_child("old-uuid", "new-uuid", path=p), False)
    check("target's own edge is untouched", tree.read_edges(p)["new-uuid"]["parent"], "chief-b")


# ── rekey_children_of_parent (CHIEF RESTART REKEY, 2026-09-25) ─────────────

def test_rekey_children_of_parent_moves_every_matching_edge():
    """The probe_chief_restart.py regression, at the store level: a chief
    restart keeps the same pane but gets a NEW session id — every worker
    still parented to the OLD session id must move to the NEW one so its
    DONE/BLOCKED report keeps routing to the (same) chief."""
    p = fresh_path("rekey-parent")
    ids = {"chief-OLD", "chief-NEW", "worker-a", "worker-b", "unrelated-worker", "other-chief"}
    tree.attach("worker-a", "chief-OLD", known_ids=ids, set_by="launch", path=p)
    tree.attach("worker-b", "chief-OLD", known_ids=ids, set_by="launch", path=p)
    tree.attach("unrelated-worker", "other-chief", known_ids=ids, set_by="launch", path=p)

    rekeyed = tree.rekey_children_of_parent("chief-OLD", "chief-NEW", set_by="chief-reregister", path=p)
    check("both chief-OLD children rekeyed", sorted(rekeyed), ["worker-a", "worker-b"])

    edges = tree.read_edges(p)
    check("worker-a now parents to chief-NEW", edges["worker-a"]["parent"], "chief-NEW")
    check("worker-b now parents to chief-NEW", edges["worker-b"]["parent"], "chief-NEW")
    check("setBy stamped for the rekey", edges["worker-a"]["setBy"], "chief-reregister")
    check("unrelated worker under a different chief is untouched",
         edges["unrelated-worker"]["parent"], "other-chief")


# P0 dashboard move: test_rekey_children_of_parent_resolves_parent_pane_after_
# restart is RETIRED — it exercised agent_tree_routing.resolve_parent_pane
# end to end, and agent_tree_routing.py is NOT-CARRIED (pane-tick-writer.py-
# only fired-problem routing, stays in AptusFit; the dashboard server never
# imports it). rekey_children_of_parent itself (the MOVE-set function this
# test also covered) keeps full coverage from the other rekey_* tests below.


def test_rekey_children_of_parent_idempotent():
    p = fresh_path("rekey-idempotent")
    ids = {"chief-OLD", "chief-NEW", "worker-a"}
    tree.attach("worker-a", "chief-OLD", known_ids=ids, path=p)
    first = tree.rekey_children_of_parent("chief-OLD", "chief-NEW", path=p)
    check("first call rekeys the one edge", first, ["worker-a"])
    second = tree.rekey_children_of_parent("chief-OLD", "chief-NEW", path=p)
    check("repeat call with the same old id finds nothing left to move", second, [])
    check("edge still correctly parented after the no-op repeat",
         tree.read_edges(p)["worker-a"]["parent"], "chief-NEW")


def test_rekey_children_of_parent_no_previous_session_id_is_a_safe_noop():
    """register_self's own guard mirrors this: a legacy/first-ever
    registration has no previous sessionId to rekey FROM — must never
    crash, must never touch the store."""
    p = fresh_path("rekey-no-old")
    ids = {"chief-1", "worker-a"}
    tree.attach("worker-a", "chief-1", known_ids=ids, path=p)
    before = tree.read_edges(p)
    check("falsy old_parent_id -> no-op", tree.rekey_children_of_parent(None, "chief-1", path=p), [])
    check("falsy new_parent_id -> no-op", tree.rekey_children_of_parent("chief-1", None, path=p), [])
    check("old == new -> no-op", tree.rekey_children_of_parent("chief-1", "chief-1", path=p), [])
    check("store untouched by any of the no-ops", tree.read_edges(p), before)


def test_rekey_children_of_parent_never_touches_tombstones():
    p = fresh_path("rekey-tombstone")
    ids = {"chief-OLD", "chief-NEW", "worker-a", "worker-b"}
    tree.attach("worker-a", "chief-OLD", known_ids=ids, path=p)
    tree.attach("worker-b", "chief-OLD", known_ids=ids, path=p)
    tree.detach("worker-b", path=p)  # tombstoned: parent -> None
    rekeyed = tree.rekey_children_of_parent("chief-OLD", "chief-NEW", path=p)
    check("only the still-attached child is rekeyed", rekeyed, ["worker-a"])
    edge_b = tree.read_edges(p)["worker-b"]
    check("tombstone's parent stays None, never rewritten to chief-NEW",
         edge_b.get("parent"), None)
    check("tombstone flag preserved", edge_b.get("detached"), True)


# ── stale-entry pruning (2026-09-25) ────────────────────────────────────

def _seed_raw(path, edges):
    """Write `edges` to `path` verbatim, bypassing `_write_edges`'s own
    pruning — so a test can plant an aged entry and then observe the NEXT
    real write (through the public API) prune it, rather than having the
    seeding write itself already do the pruning."""
    Path(path).write_text(json.dumps(edges, indent=2, sort_keys=True) + "\n")


def test_prune_drops_old_tombstone_on_next_write():
    p = fresh_path("prune-tombstone")
    ids = {"c", "chief", "other"}
    tree.attach("c", "chief", known_ids=ids, path=p)
    tree.detach("c", path=p)
    # Backdate the tombstone past the 7-day threshold directly in the file
    # (simulating time passing), then trigger any other write on the store.
    edges = tree.read_edges(p)
    edges["c"]["setAt"] = time.time() - tree.TOMBSTONE_MAX_AGE_SECONDS - 3600
    _seed_raw(p, edges)
    check("backdated tombstone still on disk before the next write",
         "c" in tree.read_edges(p), True)
    tree.attach("other", "chief", known_ids=ids, path=p)  # any write re-runs pruning
    check("stale tombstone pruned away", "c" in tree.read_edges(p), False)
    check("fresh edge from the triggering write is kept", "other" in tree.read_edges(p), True)


def test_prune_keeps_fresh_tombstone():
    p = fresh_path("prune-tombstone-fresh")
    ids = {"c", "chief", "other"}
    tree.attach("c", "chief", known_ids=ids, path=p)
    tree.detach("c", path=p)
    tree.attach("other", "chief", known_ids=ids, path=p)
    check("a fresh (just-detached) tombstone survives a write", "c" in tree.read_edges(p), True)


def test_prune_never_drops_a_live_edge_without_a_known_live_set():
    """No known_ids on hand (e.g. register_self's rekey call) must prune
    tombstones only — never guess a real edge is stale from age alone."""
    p = fresh_path("prune-no-known-ids")
    ids = {"c", "chief"}
    tree.attach("c", "chief", known_ids=ids, path=p, set_by="launch")
    edges = tree.read_edges(p)
    edges["c"]["setAt"] = time.time() - tree.EDGE_MAX_AGE_SECONDS - 3600
    _seed_raw(p, edges)
    # No known_ids passed here at all — mirrors register_self's real
    # rekey_children_of_parent call, which has no live-agent poll on hand.
    # _write_edges's known_live_ids stays None -> prune tombstones only.
    tree.attach_if_absent("new-child", "chief", path=p)
    check("old real edge for 'c' survives with no known_ids given",
         "c" in tree.read_edges(p), True)


def test_attach_known_ids_is_validation_only_never_prunes_M_B_fix():
    """M-B FIX (QA pass 4, 2026-09-26): `attach()`'s `known_ids` is for
    `_validate_attach` ONLY now — it must NEVER be forwarded to
    `_write_edges` as a prune roster. Before this fix, a stale real edge
    excluded from a later `known_ids` set got pruned by a PLAIN attach()
    call — this test used to assert exactly that (the old, buggy contract);
    it now asserts the opposite, because an attach()/attach_if_absent()
    caller's `known_ids` is very often PARTIAL (see the migration test
    below), and treating it as prune-authoritative is precisely what QA
    reproduced deleting real Air edges."""
    p = fresh_path("attach-known-ids-validation-only")
    ids = {"c", "chief"}
    tree.attach("c", "chief", known_ids=ids, path=p)
    edges = tree.read_edges(p)
    edges["c"]["setAt"] = time.time() - tree.EDGE_MAX_AGE_SECONDS - 3600
    _seed_raw(p, edges)
    # A later attach() whose known_ids set does NOT include "c" must NOT
    # prune it — known_ids here is validation-only.
    tree.attach("new-child", "chief", known_ids={"new-child", "chief"}, path=p)
    check("a stale real edge survives even when a later attach()'s "
         "known_ids excludes it — known_ids is validation-only, never a "
         "prune roster (M-B fix)",
         "c" in tree.read_edges(p), True)


def test_attach_if_absent_local_only_known_ids_never_prunes_the_migration_bug():
    """M-B REGRESSION (QA pass 4, 2026-09-26): the exact bug QA reproduced.
    `chief-dashboard-server.py`'s one-time migration (`_run_agent_tree_
    migration_once`) queries `herdr agent list` on the LOCAL machine only,
    then calls `migrate_seed_from_chief(repo_root, known_ids, chief_id)` ->
    `attach_if_absent(child, chief_id, known_ids=known_ids, ...)` for every
    worker that reported for this repo. That `known_ids` set structurally
    can never contain an Air session id — before this fix, `_write_edges`
    read "Air session not in this (local-only) known_ids" as "confirmed
    gone", pruning a >24h pending Air child AND a >30-day CONFIRMED Air
    edge off a single local-only migration attach."""
    p = fresh_path("attach-if-absent-local-only-migration")
    tree.attach_if_absent("air-pending", "chief", set_by="launch", path=p, pending=True)
    tree.attach("air-confirmed", "chief", known_ids={"air-confirmed", "chief"}, path=p)
    edges = tree.read_edges(p)
    edges["air-pending"]["setAt"] = time.time() - 25 * 3600  # >24h
    edges["air-confirmed"]["setAt"] = time.time() - 31 * 24 * 3600  # >30d
    _seed_raw(p, edges)
    # A LOCAL-ONLY known_ids set (mirrors the migration's local `herdr agent
    # list`) — neither Air child is in it, and "chief"/"local-worker" are
    # the only ids a local-only poll could ever see.
    LOCAL_ONLY_IDS = {"chief", "local-worker"}
    tree.attach_if_absent("local-worker", "chief", known_ids=LOCAL_ONLY_IDS, path=p)
    check("a >24h pending Air child survives a local-only migration attach",
         "air-pending" in tree.read_edges(p), True)
    check("...still pending", tree.read_edges(p).get("air-pending", {}).get("launchPending"), True)
    check("a >30-day CONFIRMED Air child survives the same local-only attach",
         "air-confirmed" in tree.read_edges(p), True)


def test_prune_keeps_stale_real_edge_when_known_live_set_includes_it():
    p = fresh_path("prune-known-ids-keeps")
    ids = {"c", "chief", "new-child"}
    tree.attach("c", "chief", known_ids=ids, path=p)
    edges = tree.read_edges(p)
    edges["c"]["setAt"] = time.time() - tree.EDGE_MAX_AGE_SECONDS - 3600
    _seed_raw(p, edges)
    tree.attach_if_absent("new-child", "chief", known_ids=ids, path=p)
    check("stale-but-still-known-live edge for 'c' is kept "
         "(now true unconditionally post-M-B-fix, not because of inclusion)",
         "c" in tree.read_edges(p), True)


def test_detach_and_rekey_never_prune_a_stale_real_edge_M_B_fix():
    """M-B fix (QA pass 4, 2026-09-26): `detach()`, `rekey_child()` and
    `rekey_children_of_parent()` no longer accept a `known_ids`/roster
    parameter at all — they never validated against one, so it only ever
    fed `_write_edges` a prune roster. A stale, unrelated real edge must
    survive an ordinary detach/rekey write untouched."""
    p = fresh_path("detach-rekey-never-prune")
    ids = {"stale-child", "chief", "other-child", "movable-child",
          "old-parent", "new-parent"}
    tree.attach("stale-child", "chief", known_ids=ids, path=p)
    tree.attach("other-child", "old-parent", known_ids=ids, path=p)
    tree.attach("movable-child", "old-parent", known_ids=ids, path=p)
    edges = tree.read_edges(p)
    edges["stale-child"]["setAt"] = time.time() - tree.EDGE_MAX_AGE_SECONDS - 3600
    _seed_raw(p, edges)
    tree.detach("other-child", path=p)
    check("a stale real edge survives an unrelated detach()",
         "stale-child" in tree.read_edges(p), True)
    # movable-child is still attached to old-parent, so this actually
    # performs a write (rekeyed is non-empty) — unlike a no-op rekey, which
    # would trivially leave everything untouched either way.
    rekeyed = tree.rekey_children_of_parent("old-parent", "new-parent", path=p)
    check("the rekey actually moved something (so this write is a real test)",
         rekeyed, ["movable-child"])
    check("...and an unrelated stale edge survives that real write",
         "stale-child" in tree.read_edges(p), True)


# ── GHOST NODE — LAUNCH-PENDING EDGES (QA fix, 2026-09-25) ─────────────────

def test_attach_if_absent_pending_marks_launch_pending():
    p = fresh_path("pending-marks")
    edge = tree.attach_if_absent("c", "chief", set_by="launch", path=p, pending=True)
    check("pending seed returns an edge", edge is not None, True)
    check("launchPending set true", tree.read_edges(p)["c"].get("launchPending"), True)


def test_attach_if_absent_default_not_pending():
    p = fresh_path("pending-default")
    tree.attach_if_absent("c", "chief", set_by="deliver-fallback", path=p)
    check("no pending kwarg -> no launchPending key",
         "launchPending" in tree.read_edges(p)["c"], False)


def test_mark_child_live_clears_pending():
    p = fresh_path("mark-live")
    tree.attach_if_absent("c", "chief", set_by="launch", path=p, pending=True)
    changed = tree.mark_child_live("c", path=p)
    check("mark_child_live reports a change", changed, True)
    check("launchPending cleared", "launchPending" in tree.read_edges(p)["c"], False)
    check("parent untouched", tree.read_edges(p)["c"]["parent"], "chief")


def test_mark_child_live_noop_when_not_pending():
    p = fresh_path("mark-live-noop")
    tree.attach("c", "chief", known_ids={"c", "chief"}, path=p)
    changed = tree.mark_child_live("c", path=p)
    check("no-op on an already-confirmed edge", changed, False)


def test_mark_child_live_noop_when_absent():
    p = fresh_path("mark-live-absent")
    changed = tree.mark_child_live("nobody", path=p)
    check("no-op when there is no edge at all", changed, False)


def test_remove_child_hard_deletes():
    p = fresh_path("remove-child")
    tree.attach_if_absent("c", "chief", set_by="launch", path=p, pending=True)
    removed = tree.remove_child("c", path=p)
    check("remove_child reports a removal", removed, True)
    check("edge is gone entirely (not a tombstone)", "c" in tree.read_edges(p), False)


def test_remove_child_noop_when_absent():
    p = fresh_path("remove-child-noop")
    check("no-op when there is no entry", tree.remove_child("nobody", path=p), False)


def test_remove_child_is_not_a_tombstone():
    """A hard-removed child re-seeds cleanly (unlike a detach()ed one, whose
    tombstone deliberately blocks re-seeding) — proves this is a real
    delete, not detach() under another name."""
    p = fresh_path("remove-not-tombstone")
    tree.attach_if_absent("c", "chief", set_by="launch", path=p, pending=True)
    tree.remove_child("c", path=p)
    reseeded = tree.attach_if_absent("c", "chief-2", set_by="launch", path=p, pending=True)
    check("a hard-removed child can be freshly re-seeded", reseeded is not None, True)
    check("re-seeded under the new parent", tree.read_edges(p)["c"]["parent"], "chief-2")


def test_remove_child_refuses_a_confirmed_edge():
    """L1 fix (QA pass 2, 2026-09-25): remove_child must never delete an
    entry that is no longer launchPending — a real dashboard attach, or an
    edge already confirmed live, must never be hard-deletable by a caller
    that only knows a stale child id."""
    p = fresh_path("remove-refuses-confirmed")
    tree.attach("c", "chief", known_ids={"c", "chief"}, path=p)  # a REAL, non-pending attach
    check("refuses to delete a non-pending (real) edge", tree.remove_child("c", path=p), False)
    check("edge is untouched", tree.read_edges(p)["c"]["parent"], "chief")


def test_remove_child_refuses_a_tombstone():
    p = fresh_path("remove-refuses-tombstone")
    tree.attach("c", "chief", known_ids={"c", "chief"}, path=p)
    tree.detach("c", path=p)
    check("refuses to delete a detach tombstone", tree.remove_child("c", path=p), False)
    check("tombstone still present", tree.read_edges(p)["c"]["detached"], True)


def test_remove_child_refuses_once_confirmed_live():
    p = fresh_path("remove-refuses-confirmed-live")
    tree.attach_if_absent("c", "chief", set_by="launch", path=p, pending=True)
    tree.mark_child_live("c", path=p)  # confirmed — no longer a ghost node candidate
    check("refuses to delete once launchPending is cleared", tree.remove_child("c", path=p), False)
    check("edge survives", "c" in tree.read_edges(p), True)


# H1 REGRESSION (QA pass 2, 2026-09-25): a launch-pending edge used to age
# out UNCONDITIONALLY at LAUNCH_PENDING_MAX_AGE_SECONDS — no known_live_ids
# needed — which pruned perfectly healthy CHIEF_WORKER=1 workers (most never
# produce a reportable Stop-hook turn) and never re-seeded them, silently
# reintroducing the "worker not nested" bug this whole feature exists to
# fix. Confirmed live via QA reproduction. Fixed: SAME gating as the
# known_live_ids-gated 30-day rule for an ordinary real edge — see the three
# tests immediately below, mirroring test_prune_never_drops_a_live_edge_
# without_a_known_live_set / _drops_stale_real_edge_when_known_live_set_
# excludes_it / _keeps_stale_real_edge_when_known_live_set_includes_it above.

def test_prune_never_drops_a_pending_edge_without_a_known_live_set():
    p = fresh_path("prune-pending-no-known-ids")
    tree.attach_if_absent("c", "chief", set_by="launch", path=p, pending=True)
    edges = tree.read_edges(p)
    edges["c"]["setAt"] = time.time() - tree.LAUNCH_PENDING_MAX_AGE_SECONDS - 3600
    _seed_raw(p, edges)
    # No known_live_ids passed — mirrors a write with no roster on hand.
    tree.attach_if_absent("other", "chief", path=p)
    check("stale pending edge survives with no known_ids given (H1 fix)",
         "c" in tree.read_edges(p), True)


def test_attach_if_absent_known_ids_never_prunes_a_stale_pending_edge_M_B_fix():
    """M-B FIX (QA pass 4, 2026-09-26): this used to assert the OLD (buggy)
    behavior — a plain `attach_if_absent()` call pruning a stale pending
    edge purely because its OWN `known_ids` (validation-only) excluded it.
    That is now `mark_children_live`'s job alone, and only when its roster
    is complete — see `test_attach_if_absent_local_only_known_ids_never_
    prunes_the_migration_bug` above for the exact QA-reproduced scenario
    with a real pending Air edge."""
    p = fresh_path("prune-pending-known-ids-no-longer-drops")
    tree.attach_if_absent("c", "chief", set_by="launch", path=p, pending=True)
    edges = tree.read_edges(p)
    edges["c"]["setAt"] = time.time() - tree.LAUNCH_PENDING_MAX_AGE_SECONDS - 3600
    _seed_raw(p, edges)
    tree.attach_if_absent("other", "chief", known_ids={"other", "chief"}, path=p)
    check("a stale pending edge survives a later attach_if_absent() whose "
         "known_ids excludes it — known_ids is validation-only (M-B fix)",
         "c" in tree.read_edges(p), True)


def test_prune_keeps_stale_pending_edge_when_known_live_set_includes_it():
    p = fresh_path("prune-pending-known-ids-keeps")
    tree.attach_if_absent("c", "chief", set_by="launch", path=p, pending=True)
    edges = tree.read_edges(p)
    edges["c"]["setAt"] = time.time() - tree.LAUNCH_PENDING_MAX_AGE_SECONDS - 3600
    _seed_raw(p, edges)
    tree.attach_if_absent("other", "chief", known_ids={"other", "chief", "c"}, path=p)
    check("stale-but-still-in-roster pending edge is kept",
         "c" in tree.read_edges(p), True)


def test_prune_keeps_fresh_pending_edge():
    p = fresh_path("prune-pending-fresh")
    tree.attach_if_absent("c", "chief", set_by="launch", path=p, pending=True)
    tree.attach_if_absent("other", "chief", path=p)
    check("a fresh (just-seeded) pending edge survives a write",
         "c" in tree.read_edges(p), True)


def test_prune_keeps_stale_pending_edge_once_confirmed_live():
    """mark_child_live must actually protect the edge from the 24h rule —
    not just cosmetically clear the flag."""
    p = fresh_path("prune-pending-confirmed")
    tree.attach_if_absent("c", "chief", set_by="launch", path=p, pending=True)
    tree.mark_child_live("c", path=p)
    edges = tree.read_edges(p)
    edges["c"]["setAt"] = time.time() - tree.LAUNCH_PENDING_MAX_AGE_SECONDS - 3600
    _seed_raw(p, edges)
    tree.attach_if_absent("other", "chief", path=p)
    check("confirmed-live edge survives past the pending window",
         "c" in tree.read_edges(p), True)


def test_mark_children_live_clears_every_match_in_the_roster():
    p = fresh_path("mark-children-live")
    tree.attach_if_absent("w1", "chief", set_by="launch", path=p, pending=True)
    tree.attach_if_absent("w2", "chief", set_by="launch", path=p, pending=True)
    tree.attach_if_absent("w3", "chief", set_by="launch", path=p, pending=True)
    cleared = tree.mark_children_live(["w1", "w3", "not-in-tree"], True, path=p)
    check("clears every id in the roster that was pending", sorted(cleared), ["w1", "w3"])
    check("w1 confirmed", "launchPending" in tree.read_edges(p)["w1"], False)
    check("w2 still pending — not in the roster passed", tree.read_edges(p)["w2"].get("launchPending"), True)
    check("w3 confirmed", "launchPending" in tree.read_edges(p)["w3"], False)
    check("a COMPLETE roster also stamps lastSeenAt for the child it saw",
         isinstance(tree.read_edges(p)["w1"].get("lastSeenAt"), (int, float)), True)


def test_mark_children_live_gated_prune_runs_with_that_same_roster():
    """The whole point of the batch version over calling mark_child_live in
    a loop: it also feeds the SAME roster through to the write as
    known_live_ids (when the roster is COMPLETE), so the ordinary gated 24h
    prune actually executes with it — a stale pending edge for a child NOT
    in the roster is dropped by the very same call that confirms everyone
    else."""
    p = fresh_path("mark-children-live-prune")
    tree.attach_if_absent("live-one", "chief", set_by="launch", path=p, pending=True)
    tree.attach_if_absent("ghost", "chief", set_by="launch", path=p, pending=True)
    edges = tree.read_edges(p)
    edges["ghost"]["setAt"] = time.time() - tree.LAUNCH_PENDING_MAX_AGE_SECONDS - 3600
    _seed_raw(p, edges)
    tree.mark_children_live(["live-one"], True, path=p)
    check("the roster member is confirmed", "launchPending" in tree.read_edges(p)["live-one"], False)
    check("the stale non-roster ghost is pruned by the SAME call", "ghost" in tree.read_edges(p), False)


def test_mark_children_live_incomplete_roster_clears_but_never_prunes():
    """M1 REGRESSION FIX (QA pass 3, 2026-09-26): a PARTIAL roster (one
    configured machine down/unreachable this tick, e.g. the Air asleep) must
    still clear launchPending for whoever it DID see, but must NEVER be
    treated as known_live_ids for pruning — an incomplete roster excluding a
    child proves nothing about that child, only that this tick couldn't
    reach wherever it lives. QA reproduced this exact bug: 11 of 15 real
    children are Air; one tick where Air's ssh failed deleted BOTH a >24h
    pending Air child AND a >30-day CONFIRMED Air edge, because the (partial)
    roster was passed straight through as known_live_ids."""
    p = fresh_path("mark-children-live-incomplete")
    tree.attach_if_absent("seen-pending", "chief", set_by="launch", path=p, pending=True)
    tree.attach_if_absent("air-pending", "chief", set_by="launch", path=p, pending=True)
    tree.attach("air-confirmed", "chief", known_ids={"air-confirmed", "chief"}, path=p)
    edges = tree.read_edges(p)
    edges["air-pending"]["setAt"] = time.time() - 25 * 3600  # >24h
    edges["air-confirmed"]["setAt"] = time.time() - 31 * 24 * 3600  # >30d, no lastSeenAt yet
    _seed_raw(p, edges)
    # Only "seen-pending" is in this tick's roster (Air's machine failed to
    # answer, so its children are simply absent) — and the roster is marked
    # INCOMPLETE.
    cleared = tree.mark_children_live(["seen-pending"], False, path=p)
    check("still clears the one child actually seen, even on an incomplete tick",
         cleared, ["seen-pending"])
    check("...and it's really cleared", "launchPending" in tree.read_edges(p)["seen-pending"], False)
    check("a >24h pending Air child NOT in the (incomplete) roster survives",
         "air-pending" in tree.read_edges(p), True)
    check("...still pending — an incomplete roster clears nothing it didn't see",
         tree.read_edges(p)["air-pending"].get("launchPending"), True)
    check("a >30-day CONFIRMED Air edge NOT in the (incomplete) roster survives",
         "air-confirmed" in tree.read_edges(p), True)


def test_mark_children_live_empty_incomplete_roster_does_not_mass_prune():
    """An EMPTY roster that is also INCOMPLETE (herdr itself unreachable this
    tick) must not be read as positive proof nobody is alive."""
    p = fresh_path("mark-children-live-empty-incomplete")
    tree.attach_if_absent("c", "chief", set_by="launch", path=p, pending=True)
    edges = tree.read_edges(p)
    edges["c"]["setAt"] = time.time() - tree.LAUNCH_PENDING_MAX_AGE_SECONDS - 3600
    _seed_raw(p, edges)
    cleared = tree.mark_children_live([], False, path=p)
    check("nothing to clear", cleared, [])
    check("an empty INCOMPLETE roster must NOT mass-prune a stale pending edge",
         "c" in tree.read_edges(p), True)


def test_mark_children_live_empty_complete_roster_does_prune():
    """An EMPTY roster that IS complete (every machine answered, genuinely
    nobody alive anywhere) is now trustworthy — unlike an incomplete one,
    this is positive proof, so the ordinary gated prune runs for real."""
    p = fresh_path("mark-children-live-empty-complete")
    tree.attach_if_absent("c", "chief", set_by="launch", path=p, pending=True)
    edges = tree.read_edges(p)
    edges["c"]["setAt"] = time.time() - tree.LAUNCH_PENDING_MAX_AGE_SECONDS - 3600
    _seed_raw(p, edges)
    cleared = tree.mark_children_live([], True, path=p)
    check("nothing to clear", cleared, [])
    check("a genuinely COMPLETE empty roster DOES prune the stale pending edge",
         "c" in tree.read_edges(p), False)


def test_mark_children_live_throttles_last_seen_refresh():
    """L5 fix (QA pass 3, 2026-09-26): lastSeenAt is refreshed at most once
    per LAST_SEEN_REFRESH_MIN_INTERVAL_SECONDS per child — a 30-day silence
    clock does not need per-tick precision, and per-tick precision would
    defeat _write_edges's no-op-write skip for any tree with a live child."""
    p = fresh_path("mark-children-live-throttle")
    tree.attach("w1", "chief", known_ids={"w1", "chief"}, path=p)
    now = time.time()
    tree.mark_children_live(["w1"], True, path=p, now=now)
    first_seen = tree.read_edges(p)["w1"]["lastSeenAt"]
    check("lastSeenAt stamped on first complete sighting", first_seen, now)
    # A second sighting 60s later — well under the throttle interval — must
    # NOT bump the timestamp (and, per L5, must not even rewrite the file).
    mtime_before = Path(p).stat().st_mtime_ns
    tree.mark_children_live(["w1"], True, path=p, now=now + 60)
    check("a sighting inside the throttle window doesn't bump lastSeenAt",
         tree.read_edges(p)["w1"]["lastSeenAt"], now)
    check("...and the file wasn't rewritten at all (L5)",
         Path(p).stat().st_mtime_ns, mtime_before)
    # A sighting past the throttle interval DOES bump it.
    later = now + tree.LAST_SEEN_REFRESH_MIN_INTERVAL_SECONDS + 1
    tree.mark_children_live(["w1"], True, path=p, now=later)
    check("a sighting past the throttle window bumps lastSeenAt",
         tree.read_edges(p)["w1"]["lastSeenAt"], later)


def test_prune_measures_silence_since_last_seen_not_setat():
    """M1 fix (QA pass 3, 2026-09-26): the 30-day rule for a CONFIRMED edge
    must measure time since it was last actually SEEN (lastSeenAt), not just
    how old the edge is (setAt) — an edge set 40 days ago but seen 2 days ago
    is not stale; the old age-only rule would have pruned it the instant a
    roster excluded it, even though it was seen recently."""
    p = fresh_path("prune-silence-not-age")
    tree.attach("c", "chief", known_ids={"c", "chief"}, path=p)
    edges = tree.read_edges(p)
    edges["c"]["setAt"] = time.time() - 40 * 24 * 3600  # old edge...
    edges["c"]["lastSeenAt"] = time.time() - 2 * 24 * 3600  # ...but seen 2 days ago
    _seed_raw(p, edges)
    # known_live_ids excludes "c" -> the OLD age-only rule would prune it;
    # the silence-based rule must not, since it was seen well within 30 days.
    tree.attach_if_absent("other", "chief", known_ids={"c", "chief", "other"}, path=p)
    check("an old edge seen recently survives a known_live_ids exclusion",
         "c" in tree.read_edges(p), True)


def test_write_edges_skips_a_truly_unchanged_write():
    """L5 fix (QA pass 3, 2026-09-26): a write whose post-prune content is
    byte-identical to what's on disk must not touch the file at all — the
    ~2-minute heartbeat calls mark_children_live on every tick, most of
    which (once lastSeenAt is throttled) change nothing."""
    p = fresh_path("write-edges-noop")
    tree.attach_if_absent("w1", "chief", set_by="launch", path=p, pending=True)
    mtime_before = Path(p).stat().st_mtime_ns
    # Nothing in this roster matches "w1" (still pending) and the roster is
    # complete but empty relative to it — no launchPending clear, no
    # lastSeenAt stamp (w1 isn't in the roster at all) -> content unchanged.
    tree.mark_children_live(["someone-else-entirely"], True, path=p)
    check("a write that changes nothing doesn't touch the file's mtime",
         Path(p).stat().st_mtime_ns, mtime_before)


# ── migration ────────────────────────────────────────────────────────────

def test_migrate_seed_from_chief():
    repo = TMP / f"repo-{time.time_ns()}"
    reports = repo / ".claude" / "worker-reports"
    reports.mkdir(parents=True)
    (reports / "worker-a.json").write_text("{}")
    (reports / "worker-b.json").write_text("{}")
    (reports / "outbox").mkdir()  # not a session marker — must be ignored... actually a dir glob("*.json") skips it; nothing to assert beyond no crash
    p = fresh_path("migrate")
    known = {"worker-a", "worker-b", "chief-x", "not-live"}
    seeded = tree.migrate_seed_from_chief(str(repo), known, "chief-x", path=p)
    check("migration seeds both live workers", sorted(seeded), ["worker-a", "worker-b"])
    edges = tree.read_edges(p)
    check("worker-a parented to the chief", edges["worker-a"]["parent"], "chief-x")
    check("worker-b parented to the chief", edges["worker-b"]["parent"], "chief-x")

    # idempotent: re-running the migration seeds nothing new (both already
    # have edges, including one an operator may since have re-parented).
    reseed = tree.migrate_seed_from_chief(str(repo), known, "chief-x", path=p)
    check("re-running migration seeds nothing new (already has edges)", reseed, [])


def test_migrate_seed_skips_unknown_chief():
    repo = TMP / f"repo2-{time.time_ns()}"
    (repo / ".claude" / "worker-reports").mkdir(parents=True)
    (repo / ".claude" / "worker-reports" / "w.json").write_text("{}")
    p = fresh_path("migrate-unknown-chief")
    check("no chief_id -> nothing seeded",
         tree.migrate_seed_from_chief(str(repo), {"w"}, None, path=p), [])
    check("chief_id not itself known -> nothing seeded",
         tree.migrate_seed_from_chief(str(repo), {"w"}, "ghost-chief", path=p), [])


# ── project derivation ───────────────────────────────────────────────────

def test_project_for_cwd():
    check("meta repo root", tree.project_for_cwd("/Users/trungluong/01_Project/AptusFit"),
         ("AptusFit", "/Users/trungluong/01_Project/AptusFit"))
    check("nested product repo maps to the meta project",
         tree.project_for_cwd("/Users/trungluong/01_Project/AptusFit/fe/apps/mobile"),
         ("AptusFit", "/Users/trungluong/01_Project/AptusFit"))
    check("a worktree maps back to the owning project",
         tree.project_for_cwd(
             "/Users/trungluong/01_Project/AptusFit/.claude/worktrees/fe-my-slug"),
         ("AptusFit", "/Users/trungluong/01_Project/AptusFit"))
    check("Air mirror path maps the same way",
         tree.project_for_cwd("/Users/wifey/01_Project/AptusFit/fe"),
         ("AptusFit", "/Users/wifey/01_Project/AptusFit"))
    check("outside the convention degrades to a bare basename",
         tree.project_for_cwd("/opt/somewhere/else"), ("else", "/opt/somewhere/else"))
    check("empty cwd", tree.project_for_cwd(None), (None, None))


# ── build_agent_tree() contract ─────────────────────────────────────────

def _agent(sid, label, cwd, machine="local", pane_id=None):
    return {"agentSession": sid, "label": label, "cwd": cwd,
           "machine": machine, "paneId": pane_id or f"p-{sid}"}


def test_build_agent_tree_basic_shape():
    p = fresh_path("view-basic")
    ids = {"chief-1", "worker-1", "worker-2"}
    tree.attach("worker-1", "chief-1", known_ids=ids, path=p)
    tree.attach("worker-2", "chief-1", known_ids=ids, path=p)
    agents = [
        _agent("chief-1", "chief pane", "/Users/trungluong/01_Project/AptusFit"),
        _agent("worker-1", "worker one", "/Users/trungluong/01_Project/AptusFit/fe"),
        _agent("worker-2", "worker two", "/Users/trungluong/01_Project/AptusFit/fe"),
    ]
    out = tree.build_agent_tree(agents, tree.read_edges(p), chief_mode_roots=[])
    check("top-level keys", sorted(out.keys()),
         sorted(["generatedAt", "chiefs", "unassigned", "parentGone"]))
    check("one chief row", len(out["chiefs"]), 1)
    chief = out["chiefs"][0]
    check("chief id", chief["id"], "chief-1")
    check("chief has two children", sorted(c["id"] for c in chief["children"]),
         ["worker-1", "worker-2"])
    check("chief alive", chief["alive"], True)
    check("chief not chief-mode (no chief-mode file given)", chief["isChiefMode"], False)
    for child in chief["children"]:
        check(f"{child['id']} alive", child["alive"], True)
        check(f"{child['id']} not cross-project (same project as parent)",
             child["crossProject"], False)
    check("nothing unassigned", out["unassigned"], [])
    check("nothing parentGone", out["parentGone"], [])


def test_build_agent_tree_unassigned_and_cross_project():
    p = fresh_path("view-unassigned")
    ids = {"chief-1", "worker-1", "lonely-1"}
    tree.attach("worker-1", "chief-1", known_ids=ids, path=p)
    agents = [
        _agent("chief-1", "chief", "/Users/trungluong/01_Project/AptusFit"),
        _agent("worker-1", "worker", "/Users/trungluong/01_Project/ssv-bi-platform"),
        _agent("lonely-1", "lonely", "/Users/trungluong/01_Project/AptusFit"),
    ]
    out = tree.build_agent_tree(agents, tree.read_edges(p), chief_mode_roots=[])
    check("lonely-1 has no parent -> unassigned",
         [a["id"] for a in out["unassigned"]], ["lonely-1"])
    child = out["chiefs"][0]["children"][0]
    check("worker-1 flagged cross-project (ssv-bi-platform child of AptusFit chief)",
         child["crossProject"], True)


def test_build_agent_tree_parent_gone():
    p = fresh_path("view-parent-gone")
    ids = {"dead-chief", "worker-1"}
    tree.attach("worker-1", "dead-chief", known_ids=ids, parent_slug="old-chief", path=p)
    # dead-chief never appears in `agents` (not live) and no chief-mode file
    # names it -> its child must surface as parentGone, not silently nested.
    agents = [_agent("worker-1", "worker", "/Users/trungluong/01_Project/AptusFit")]
    out = tree.build_agent_tree(agents, tree.read_edges(p), chief_mode_roots=[])
    check("no chiefs row for an unknown dead parent", out["chiefs"], [])
    check("worker-1 lands in parentGone", [a["id"] for a in out["parentGone"]], ["worker-1"])
    lost = out["parentGone"][0]["lostParent"]
    check("lostParent carries the id", lost["id"], "dead-chief")
    check("lostParent falls back to the stored parentSlug", lost["label"], "old-chief")


def test_build_agent_tree_chief_mode_empty_chief_is_a_drop_target():
    p = fresh_path("view-chief-mode")
    root = TMP / f"proj-{time.time_ns()}"
    (root / ".claude").mkdir(parents=True)
    now_iso = datetime.now(timezone.utc).isoformat(timespec="seconds")
    (root / ".claude" / "chief-mode").write_text(f"on {now_iso} idle-chief-1\n")
    out = tree.build_agent_tree([], {}, chief_mode_roots=[str(root)])
    check("one chief row from chief-mode alone, zero children",
         [(c["id"], c["isChiefMode"], c["alive"], c["children"]) for c in out["chiefs"]],
         [("idle-chief-1", True, False, [])])


def test_build_agent_tree_registered_chief_pane_survives_stale_chief_mode():
    # Red-first case for the 2026-09-24 bug: a live chief pane registered in
    # .claude/chief-pane.json (scripts/chief-register-pane.sh) must count as
    # a chief even when its .claude/chief-mode TTL line is stale AND it has
    # zero child edges — before the fix this fell into unassigned[] instead,
    # leaving the AgentBar tree with no drop target for that project's chief.
    p = fresh_path("view-registered-chief-pane")
    root = TMP / f"proj-{time.time_ns()}"
    (root / ".claude").mkdir(parents=True)
    stale_iso = (datetime.now(timezone.utc) - timedelta(hours=tree.CHIEF_MODE_TTL_HOURS + 1)) \
        .isoformat(timespec="seconds")
    # names a DIFFERENT (unrelated, not-live) session — proves the live
    # registered-pane agent is promoted on its own, not via this line.
    (root / ".claude" / "chief-mode").write_text(f"on {stale_iso} some-other-stale-id\n")
    # sessionId (H1 fix) matches the live agent below — a VERIFIED registration.
    (root / ".claude" / "chief-pane.json").write_text(json.dumps(
        {"paneId": "wB:p55", "sessionId": "chief-live-1", "generation": 16,
         "registeredAt": 1790179314}))
    agents = [_agent("chief-live-1", "chief pane", str(root), pane_id="wB:p55")]
    out = tree.build_agent_tree(agents, {}, chief_mode_roots=[str(root)])
    check("registered chief pane counts as chief despite stale chief-mode + zero children",
         [c["id"] for c in out["chiefs"]], ["chief-live-1"])
    chief = out["chiefs"][0]
    check("flagged isRegisteredChief", chief["isRegisteredChief"], True)
    check("not isChiefMode (stale line names an unrelated id)", chief["isChiefMode"], False)
    check("zero children", chief["children"], [])
    check("not in unassigned", [a["id"] for a in out["unassigned"]], [])


def test_build_agent_tree_registered_chief_pane_ignores_non_matching_pane_id():
    p = fresh_path("view-registered-chief-pane-mismatch")
    root = TMP / f"proj-{time.time_ns()}"
    (root / ".claude").mkdir(parents=True)
    (root / ".claude" / "chief-pane.json").write_text(json.dumps(
        {"paneId": "wB:p99", "sessionId": "lonely-2"}))
    agents = [_agent("lonely-2", "not the chief", str(root), pane_id="wB:p55")]
    out = tree.build_agent_tree(agents, {}, chief_mode_roots=[str(root)])
    check("no chiefs row when the live agent's paneId doesn't match", out["chiefs"], [])
    check("agent stays unassigned", [a["id"] for a in out["unassigned"]], ["lonely-2"])


def test_build_agent_tree_stale_pane_reused_by_stranger_not_flagged_chief():
    """H1 regression (converted probe_stale_chief_pane.py): chief-pane.json
    names paneId wB:p55, written long ago by a chief that has since exited.
    A totally unrelated, ordinary (non-chief) session now occupies that pane
    slot (herdr reuses slots — own_pane_id()'s docstring documents this as
    measured behaviour). Before the H1 fix, "whoever is live at that pane"
    alone made this stranger read as isRegisteredChief."""
    root = TMP / f"proj-{time.time_ns()}"
    (root / ".claude").mkdir(parents=True)
    # Legacy registration: no sessionId (written before the H1 fix shipped).
    (root / ".claude" / "chief-pane.json").write_text(json.dumps(
        {"paneId": "wB:p55", "generation": 3, "registeredAt": 1700000000}))
    agents = [_agent("random-dev-session", "ordinary session", str(root), pane_id="wB:p55")]
    out = tree.build_agent_tree(agents, {}, chief_mode_roots=[str(root)])
    check("a legacy (no sessionId) registration never flags a chief",
         out["chiefs"], [])
    check("the stranger stays unassigned, not promoted to chief",
         [a["id"] for a in out["unassigned"]], ["random-dev-session"])


def test_build_agent_tree_stale_pane_reused_by_different_recorded_session():
    """Same scenario, but the registration DOES carry a sessionId — for a
    DIFFERENT session than whoever now occupies the pane (the real chief
    exited, an unrelated session reused the slot). Must still not verify."""
    root = TMP / f"proj-{time.time_ns()}"
    (root / ".claude").mkdir(parents=True)
    (root / ".claude" / "chief-pane.json").write_text(json.dumps(
        {"paneId": "wB:p55", "sessionId": "the-real-chief-now-gone"}))
    agents = [_agent("random-dev-session", "ordinary session", str(root), pane_id="wB:p55")]
    out = tree.build_agent_tree(agents, {}, chief_mode_roots=[str(root)])
    check("recorded session id mismatch -> not flagged chief", out["chiefs"], [])
    check("stranger stays unassigned",
         [a["id"] for a in out["unassigned"]], ["random-dev-session"])


def test_verified_chief_session_id():
    check("matches -> verified", tree.verified_chief_session_id("p1", "s1", "s1"), "s1")
    check("mismatch -> None", tree.verified_chief_session_id("p1", "s1", "s2"), None)
    check("no live occupant -> None", tree.verified_chief_session_id("p1", "s1", None), None)
    check("no recorded session (legacy file) -> None",
         tree.verified_chief_session_id("p1", None, "s1"), None)
    check("no pane id -> None", tree.verified_chief_session_id(None, "s1", "s1"), None)


def run_all():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for t in tests:
        print(f"-- {t.__name__} --")
        t()
    print()
    if fails:
        print(f"FAILED ({len(fails)}):")
        for f in fails:
            print(f"  - {f}")
        shutil.rmtree(TMP, ignore_errors=True)
        sys.exit(1)
    print(f"All {len(tests)} agent_tree test groups passed.")
    shutil.rmtree(TMP, ignore_errors=True)


if __name__ == "__main__":
    run_all()
