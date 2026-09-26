#!/usr/bin/env python3
"""GET /api/deliver/pass — the merged per-pass status read a chief needs
(feed health, both pane-liveness classifiers with disagreement named, the
delivery tick, and the tool catalogue), restored 2026-09-25 per PO decision:
`chief_pass` was dropped in the P0 move's first pass (no MOVE-set caller
needed it — AptusFit's own `chief-board-mcp.py` `chief_pass` MCP tool calls
it, and that tool stays in AptusFit, not the MOVE set) but the PO ruled it
should be KEPT, made generic, because AptusFit's chief calls it at the start
of every supervision round (27 sessions/3 days) and cutover would otherwise
break every one of them.

Split into its own module rather than grown into chief_dashboard_views.py or
chief-dashboard-server.py (both already over this repo's ~800-line split
trigger) — this feature's only unusual concerns (locating an optional
per-project script, dynamically loading another project's own module by
path) don't belong with either file's existing job.

GENERIC, PER PO RULING
-----------------------
- feedHealth, panes (both raw liveness readings + disagree flags),
  paneDisagreementCount: unconditional — the same computation AptusFit's
  version always did, over whichever agents/feeds THIS dashboard is already
  polling. Nothing AptusFit-specific left in this part.
- tick: AptusFit's `deliver-tick.py --json` output, pulled from the "board"
  feed chief_dashboard_feeds.py already polls — but that feed's poller
  (poll_board) now runs the script ONLY when some configured projectRoot
  actually has `scripts/deliver-tick.py` (resolved by scanning
  dashboard_config.PROJECT_ROOTS, never hard-coded to projectRoots[0]/
  AptusFit). No project has it -> the feed reports a clean, non-broken
  success with `data: None` -> `tick: null` here, not an error: most
  projects won't have a delivery tick, and that is not a chief_pass failure.
- toolboxMap: `chief-board-mcp.py`'s TOOLS catalogue (name+description only),
  loaded the same way AptusFit's server did — import the module by file
  path, no package dependency — but from the first configured projectRoot
  that HAS a `scripts/chief-board-mcp.py`, not a hard-coded AptusFit path.
  None found -> `[]` (matches AptusFit's own defensive fallback: a busted or
  absent catalogue must never take the rest of chief_pass down with it).

NOT PORTED: AptusFit's `_load_plugin_module`/`_delivery_ops_shim` (a
"review-mode" plugin loader living unused in its chief_dashboard_feeds.py).
Confirmed dead code even upstream: AptusFit's own `build_chief_pass` never
calls it, the desk/remote review-mode switch it would have served was
removed 2026-09-22 (AptusFit `.claude/chief.local.md`), and a live
`GET /api/deliver/pass` on AptusFit's :4711 has no `mode` key today despite
the `chief_pass` MCP tool's description text still mentioning one (stale
docs, not a live code path) — verified 2026-09-25 by diffing this module's
JSON keys against a live 4711 response.
"""
import importlib.util
import os
import sys

import dashboard_config

DELIVER_TICK_RELPATH = os.path.join("scripts", "deliver-tick.py")
CHIEF_BOARD_MCP_RELPATH = os.path.join("scripts", "chief-board-mcp.py")


def find_project_root_with(relpath, project_roots=None):
    """First entry in `project_roots` (default: dashboard_config.PROJECT_ROOTS)
    whose <root>/<relpath> exists, else None. The one place this module
    "resolves per projectRoots" instead of hard-coding projectRoots[0]."""
    roots = (project_roots if project_roots is not None
             else dashboard_config.PROJECT_ROOTS)
    for root in roots:
        if os.path.isfile(os.path.join(root, relpath)):
            return root
    return None


_TOOLBOX_CACHE = {"loaded": False, "map": []}


def load_toolbox_map(project_roots=None, force=False):
    """[{"name", "description"}] from the first configured project's own
    `scripts/chief-board-mcp.py` TOOLS list, if any project has one — same
    "import by path" trick AptusFit's server used for its own hard-coded
    copy, generalized to any project root. Cached for the server's
    lifetime (module-level cache, like AptusFit's CHIEF_TOOLBOX_MAP): a
    TOOLS change needs a dashboard restart to show up here, same as before
    this move. Never raises — a busted or absent catalogue reports `[]`."""
    if _TOOLBOX_CACHE["loaded"] and not force:
        return _TOOLBOX_CACHE["map"]
    toolbox = []
    root = find_project_root_with(CHIEF_BOARD_MCP_RELPATH, project_roots)
    if root:
        path = os.path.join(root, CHIEF_BOARD_MCP_RELPATH)
        try:
            spec = importlib.util.spec_from_file_location(
                "_chief_dashboard_pass_toolbox", path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            toolbox = [{"name": t["name"], "description": t["description"]}
                       for t in getattr(mod, "TOOLS", [])]
        except Exception as e:
            print(f"chief_dashboard_pass: could not load {path}'s tool "
                  f"catalogue ({type(e).__name__}: {e}) — chief_pass will "
                  f"report an empty toolboxMap instead of failing",
                  file=sys.stderr)
            toolbox = []
    _TOOLBOX_CACHE["loaded"] = True
    _TOOLBOX_CACHE["map"] = toolbox
    return toolbox


def _pane_tick_by_pane_id(feeds_snap):
    """Index the pane-tick-writer LaunchAgent's cached per-agent verdicts
    (refreshed ~every 2min) by paneId, so build_chief_pass can cross-check
    them against this dashboard's own live classify_pane reading (paneScreen,
    refreshed every 15s) for the same pane. A small, deliberate duplicate of
    chief_dashboard_views._pane_tick_by_pane_id (which get_agent_tree_state
    uses for a different projection) rather than a cross-module import of a
    "private" name — keeps this module's only coupling to the rest of the
    server an explicit one (feeds_snap/agents passed in, nothing pulled)."""
    data = feeds_snap["paneTick"]["data"] or {}
    by_pane = {}
    for a in data.get("agents") or []:
        pane_id = a.get("paneId")
        if pane_id:
            by_pane[pane_id] = a
    return by_pane


def build_chief_pass(feeds_snap, agents, toolbox=None):
    """The one merged status read a chief pass needs — feed health + tick
    pacing + both pane-liveness classifiers with disagreement named + the
    tool catalogue. Pure function over already-fetched snapshots: no new
    subprocess, no new network call — `feeds_snap["board"]` is whatever
    poll_board last cached (deliver-tick.py's own output, or None when no
    configured project has that script).

    KILLS THE "RUN BOTH" TRAP, MECHANICALLY
    ----------------------------------------
    A pane's liveness is graded two different, independently-cadenced ways:
    this dashboard's own live screen classify (paneScreen, ~15s) and the
    pane-tick heartbeat's cached verdict (paneTick, ~2min). They CAN
    disagree (the exact incident on record: a pane measured actively
    working while its cached reading said idle) — this reports BOTH raw
    readings rather than picking a winner, same as the separate hookState-
    vs-herdrStatus disagreement build_agents_view already computes. The
    chief decides.

    `toolbox` defaults to `load_toolbox_map()` (cached); tests pass an
    explicit list to stay independent of any project root on disk.
    """
    if toolbox is None:
        toolbox = load_toolbox_map()

    feed_health = {"broken": [], "warming": []}
    for name, snap in feeds_snap.items():
        if not isinstance(snap, dict) or "broken" not in snap:
            continue  # not a Feed snapshot — e.g. the "machines" per-machine
            # health rollup get_full_state() adds to its OWN feeds dict, and
            # "machinesConfigError" (always present, None when there's no
            # error) — same guard as chief_dashboard_views.build_needs_you.
        if snap["broken"] and not snap.get("warming"):
            feed_health["broken"].append({"feed": name, "error": snap.get("error")})
        elif snap.get("warming"):
            feed_health["warming"].append(name)

    tick_feed = feeds_snap["board"]
    if tick_feed.get("data") is None:
        # Either no configured projectRoot has scripts/deliver-tick.py (the
        # generic, expected case for most projects), or the feed genuinely
        # has nothing yet — either way there is no tick to report, and that
        # is not itself a chief_pass failure (feedHealth above already
        # covers a *broken* board feed, e.g. deliver-tick.py crashing on a
        # project that DOES have it).
        tick = None
    else:
        tick = dict(tick_feed["data"])
        tick["feedAgeSec"] = tick_feed["ageSec"]
        tick["feedBroken"] = bool(tick_feed["broken"] and not tick_feed.get("warming"))

    pane_tick_by_pane = _pane_tick_by_pane_id(feeds_snap)
    pane_tick_age_sec = feeds_snap["paneTick"]["ageSec"]

    panes = []
    for a in agents:
        # Residue and orphaned hook files are inventory, not a live pane to
        # grade — same exclusion build_needs_you and the board apply.
        if a.get("orphanHook") or a.get("residue"):
            continue
        pane_id = a.get("paneId")
        cached = pane_tick_by_pane.get(pane_id) if pane_id else None
        cached_screen_state = cached.get("screenState") if cached else None
        live_screen_state = a.get("screenState")
        disagree_screen_vs_cached = bool(
            cached_screen_state and live_screen_state
            and cached_screen_state != live_screen_state)
        panes.append({
            "paneId": pane_id,
            "label": a.get("label"),
            # Full Claude session UUID — the one identifier that survives a
            # pane/tab restart, unlike paneId.
            "agentSession": a.get("agentSession"),
            "hookState": a.get("hookState"),
            "herdrStatus": a.get("herdrStatus"),
            "disagreeHookVsHerdr": bool(a.get("disagree")),
            "hookSinceSec": a.get("hookSinceSec"),
            "screenUnchangedSec": a.get("screenUnchangedSec"),
            "subagentsRunning": a.get("subagentsRunning"),
            "herdrTurnReported": a.get("herdrTurnReported"),
            "liveScreenState": live_screen_state,
            "liveScreenSignal": a.get("screenSignal"),
            "cachedScreenState": cached_screen_state,
            "cachedTickStatus": cached.get("status") if cached else None,
            "cachedAgeSec": pane_tick_age_sec,
            "disagreeScreenVsCachedTick": disagree_screen_vs_cached,
        })

    disagreement_count = sum(
        1 for p in panes
        if p["disagreeHookVsHerdr"] or p["disagreeScreenVsCachedTick"])

    return {
        "feedHealth": feed_health,
        "tick": tick,
        "panes": panes,
        "paneDisagreementCount": disagreement_count,
        "toolboxMap": toolbox,
    }


def get_chief_pass(get_full_state):
    """GET /api/deliver/pass's thin handler — all logic above. `get_full_state`
    is chief_dashboard_views.get_full_state, passed in rather than imported
    to avoid this module depending on that one for anything but the one call
    (views.py already imports FEEDS etc.; this keeps the dependency one-way:
    server -> views AND server -> this module, never this module -> views)."""
    state = get_full_state()
    feeds_snap = state["feeds"]
    agents = state["computed"]["agents"]
    return build_chief_pass(feeds_snap, agents)
