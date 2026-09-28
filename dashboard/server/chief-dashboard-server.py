#!/usr/bin/env python3
"""
chief-dashboard-server.py — Stage 1 of the Chief Dashboard project.

A READ-ONLY live web page (http://127.0.0.1:4711/) showing what every Claude
Code agent/pane, claimed delivery run, and git branch/worktree on this Mac is
actually doing. Nothing this server does can ever touch git, Notion, or a
pane — it only reads four already-existing local data sources and renders
them. See memory/Projects/chief-dashboard/plan.md for the full design and
memory/Projects/chief-dashboard/mockup.md for the layout this follows.

SIX DATA FEEDS (all read-only; this script adds NO new hook, NO new plugin,
NO edit to .claude/settings.json):

  1. hookCache   — <TMPDIR>/delivery-ops-herdr/<sanitized-pane-id> files,
                   written by the already-installed `delivery-ops` plugin's
                   hook on every Claude Code session on this machine. Content
                   is "SEQ:STATE" (STATE in working|blocked|idle). This is
                   the "reported truth" — the thing herdr's own screen-guesser
                   throws away. Read-only file scan, polled every 2s.
  2. herdr       — `herdr agent list` / `herdr tab list` (herdr's own,
                   often-wrong, screen-guessed state). Polled every 5s.
  3. paneTick    — reads `.pane-tick-cache.json` directly (written by the
                   ~2min pane-tick-writer.py heartbeat — see
                   memory/Projects/deliver-chief-announce-for-stuck-gone-workers-stage-3-of-chief/charter.md).
                   A plain file read, not a subprocess: cheap enough to poll
                   often. Replaces this feed's PRIOR shape, which shelled out
                   to `deliver-tick.py --panes --json` every ~90s — that
                   subprocess poll is retired outright (not merely unread),
                   since it would otherwise be a THIRD concurrent contender
                   for the same shared-state file locks the heartbeat and
                   `--panes` already use (R28). Always shows the FULL current
                   picture, never the dedupe-throttled view the automatic
                   wake uses (R15) — a worker whose wake was suppressed this
                   cycle because it was already notified still shows up here.
  4. gitHealth   — `bash scripts/repo-health.sh --json`, run from the repo
                   root. Measured up to ~2min — background poll only, with a
                   generous subprocess timeout. Polled ~every 5min.
  6. paneScreen  — `herdr pane read` per live agent pane, classified by
                   scripts/lib/classify_pane.py (the same classifier
                   check-worker-panes.sh and chief-status.sh use, so the page
                   and the chief's CLI can never disagree). The only feed that
                   can tell a permission prompt from a finished turn. ~45s.
  5. board       — `python3 scripts/deliver-tick.py --json` (the delivery
                   board). A separate engineer may be fixing a crash bug in
                   this concurrently; this server treats ANY failure (crash,
                   timeout, bad JSON) as "feed broken", never as a process
                   crash of its own. Polled ~every 2.5min.

SELF-ALARM (non-negotiable, from plan.md): every feed tracks last_success_ts.
A feed whose age exceeds 3x its own refresh interval is "broken" and the page
renders a full-width, impossible-to-miss banner for it — a broken feed must
never look like "everything is fine".

THREE-WAY STATE, and no single source is trusted (corrected 2026-09-03):
plan.md's premise was "the pushed hook state is the truth, herdr's screen-guess
throws it away". Half right. herdr's guess IS wrong about `working` — it reads a
busy Claude Code as `idle` because the input box is empty the whole time it
works. But the hook feed was wrong about `blocked`: Claude Code fires one
`Notification` event both for "needs your permission" and for "waiting for your
input" (~60s AFTER a turn ends), and both were reported as `blocked`, pinning
every finished session there. Measured: 27 of 36 cached panes read `blocked`
while every live one sat at an empty prompt — a 100%-false NEEDS YOU list.
So each source is believed only where it can actually know:
  hookState   — authoritative for `working` (pushed the instant a tool runs)
  screenState — authoritative for blocked-vs-finished (feed 5; it is literally
                what the human would see if they looked at the pane)
  herdrStatus — shown for comparison only, never believed

One data layer, two consumers: GET /api/state returns the exact same JSON
object the HTML page renders from. A future "chief" consumer reads this
endpoint directly and never has to scrape rendered HTML.

ONE WRITE ACTION (everything else stays read-only): POST /api/focus
{"paneId": "<herdr pane id>"} looks the pane up in a fresh `herdr pane list`
and calls `herdr workspace focus` + `herdr tab focus` on it — moves terminal
focus only, never sends keystrokes or touches a pane's content. Wired to a
row click in the NEEDS YOU / AGENTS tables (only rows carrying a live,
herdr-confirmed pane id are clickable; stale-cache residue rows are not).

SECOND WRITE ACTION: POST /api/answer {"paneId", "choice", "question"}
sends a staged answer into an open AskUserQuestion picker in that pane
(`answer_pane_question()` below — keystroke sequences proven by a 2026-09-04
herdr spike, every step re-read and re-validated fresh, refusals instead of
guesses). Multi-question turns are sequential pickers, so a successful send
returns {"next": <queued Q2|null>} — a different question post-submit is
success-with-next, never failure. FIXED 2026-09-20 (dashboard-answer-
stray-enter brief): the "text" choice's typed-Other path used to send a
follow-up Enter WITHOUT checking whether the pane was still showing the
question just typed into — `_type_text` runs `pane run`, whose embedded
Enter can auto-submit and advance the pane on its own, so that follow-up
Enter could land on a DIFFERENT, already-open Q2 and silently record its
default option as the answer. Both the single-select fallback AND the
multi-select checkbox-confirm sub-path share this same `_type_text` call
(the first pass only fixed the single-select half; QA caught the
multi-select half sharing the identical risk with no gate at all). Both
are now gated on `_same_question(q_before, q_after)` at every read after
`_type_text`: a different question returns `{"next": q_after}` immediately
with no further key sent, exactly like the digit/select branches already
do — see `answer_pane_question`'s own docstring for the digit/select
side's independent immunity. The feed also gained an additive
`questionCursorOnExit` flag (`classify_pane.question_cursor_on_exit`)
so a picker parked on its own Submit/Next row — which
`parse_question_block` cannot see, reading it identically to "form gone" —
is distinguishable by callers; `question`'s existing shape/callers are
unchanged. Wired to the NEEDS YOU "question" row's
Confirm button only — a click stages, only Confirm sends.

THIRD WRITE ACTION: POST /api/permission {"paneId", "choice", "permission",
"index", "text"} presses key(s) into an open plain yes/no permission box OR
ExitPlanMode plan-approval box in that pane (`answer_pane_permission()`
below — same fresh-read, exact-match-or-refuse guard as /api/answer, never
a default-to-allow). `choice` is "allow" (the first "Yes…" option), "deny"
(the last "No…" option), "allow-always" (the "Yes" option that also says
"don't ask again" OR "for this session", when the prompt has one — the
latter phrasing covers an Edit-box's per-project-folder grant) — all three
plain-permission-box only — or "select" (plan-approval box only, additive):
`index` (1-based) picks the option, corroborated against the FRESHLY read
box's own `options`, never a default; `text`, valid only on the "Tell
Claude what to change" option, is feedback typed and submitted alongside
it (see `_answer_plan_select`'s docstring for the exact keystroke contract
— this box submits feedback on `enter`, the SAME shape as /api/answer's
"Other" text flow; `shift+tab` must never be sent here — it approves the
plan into auto mode instead of rejecting it with the feedback, confirmed
live 2026-09-20, dashboard-plan-feedback-approves brief). Anything else,
or a choice the live
box doesn't corroborate, refuses instead of guessing — existing "allow"/
"deny"/"allow-always" behaviour is unchanged by this addition. `permission`
is the `row.permission` object the UI rendered: {tool, detail, title,
options:[{index,label}], cursorIndex} for a plain box, additively
{kind:"plan", planPath} for a plan-approval box — `tool`/`detail` come from
the `⏺ Tool(args)` receipt line above a plain box (`parse_permission_block()`
in classify_pane.py; a plan-approval box has no such receipt, so `tool` is
always the literal "ExitPlanMode" and `detail` is always null — see
`parse_plan_approval_block()`); null on the whole `permission` object
whenever neither can be read confidently — see the module comments there.
For an Edit/Update box, `detail` is the file path plus a capped diff
excerpt (newline-joined, so `detail` can be multi-line for this shape only
— a plain Bash box's `detail` stays the bare one-line command). A
successful send returns {"next": <permission|null>} — a different box
appearing right after (another queued prompt) is success-with-next, same
spirit as /api/answer's {"next"}. Wired to the NEEDS YOU "blocked" row's
Allow/Deny buttons (and, for a plan-approval row, its select/feedback UI).

Error strings from all three write actions: "missing paneId" is checked
before any pane is looked up and is the one case that is HTTP 400, not 200
(pre-existing — see do_POST below). Everything else is
{"ok": false, "error": "..."}, HTTP 200, never a 500: "pane <id> not found
— likely closed", "question changed or gone — re-check the pane"
(/api/answer), "permission prompt changed or gone — re-check the pane" /
"no allow option on this prompt" / "no deny option on this prompt" / "no
allow-always option on this prompt" / "bad choice: must be 'allow', 'deny',
or 'allow-always'" / "press did not land — re-check the pane" / "choice
'select' only applies to a plan-approval box" / "no option <index> on this
prompt" / "option <index> requires 'text' — it does not submit on its own"
/ "'text' is only valid on the 'Tell Claude what to change' option" /
"empty answer text — nothing to send" / "plan-approval prompt changed or
gone — re-check the pane" / "typed feedback did not land — re-check the
pane" (/api/permission).

Run via herdr (not tmux — see AGENTS.md's herdr override), e.g.:
  herdr tab create --cwd /Users/trungluong/01_Project/command-bar-macos-dashboard/dashboard --label chief-dashboard-server --no-focus
  herdr pane run <pane_id> "python3 server/chief-dashboard-server.py"

Python stdlib only. No pip installs, no node_modules.

Feeds live in scripts/lib/chief_dashboard_feeds.py, computed views in
scripts/lib/chief_dashboard_views.py; this module is HTTP + the page only.
"""

import importlib.util
import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import classify_pane  # noqa: E402  (scripts/lib/classify_pane.py)
import agent_tree  # noqa: E402  (scripts/lib/agent_tree.py — the hierarchy store)
import session_transcript  # noqa: E402  (transcript latest message + plan file, P1b)
import chief_dashboard_herdr as herdr_transport  # noqa: E402
from chief_dashboard_feeds import (  # noqa: E402
    HOST, PORT, REPO_ROOT, STOP, start_pollers, run_json, MACHINES,
    sanitize_pane_id,
)
from chief_dashboard_store import (  # noqa: E402
    STORE, resolve_agent_row_id,
)
from chief_dashboard_views import (  # noqa: E402
    get_full_state, get_agent_tree_state,
    agent_tree_attach, agent_tree_detach,
)
from chief_dashboard_memory import SAMPLER  # noqa: E402
import chief_dashboard_actions as session_actions  # noqa: E402
import chief_dashboard_pass  # noqa: E402  (chief_pass restored 2026-09-25, generic)
import personas  # noqa: E402  (Jev persona registry + routing, P1)
import remote_access  # noqa: E402  (phase 1a: tailscale-fronted remote access)
import hook_permission_routes  # noqa: E402  (PermissionRequest hook bridge)
import session_inbox  # noqa: E402  (message to a Desktop/CLI session)
import agentbar_presence  # noqa: E402  (is AgentBar connected? gates the hook bridge)
import persona_start  # noqa: E402  (POST /api/persona/start, P3)
import persona_remote  # noqa: E402  (remoteStart personas on the remote listener)
import persona_registry_edit  # noqa: E402  (POST /api/personas + registry view, P4)
import persona_suggestions  # noqa: E402  (GET /api/personas/suggestions, P4)

# chief_pass (GET /api/deliver/pass): restored 2026-09-25 per PO decision —
# KEEP, made generic (see chief_dashboard_pass.py's module docstring for the
# full rationale; it replaces AptusFit's hard-coded chief-board-mcp.py
# import + CHIEF_TOOLBOX_MAP that used to sit here). Warmed at import time
# (not lazily on first request) so a busted/missing tool catalogue on any
# configured project logs immediately at boot, same as AptusFit's own copy
# used to.
chief_dashboard_pass.load_toolbox_map()

# P0 dashboard move: the worker-create flow (POST /api/worker,
# chief_dashboard_worker.py) is RETIRED here — an AptusFit chief/worktree-
# spin-up-only concern, AgentBar never calls it (confirmed in
# p0-dependency-audit.md), and it is not in the coordinator's required-
# endpoints list. See dashboard/AGENTS.md.


def _activate_terminal_app():
    """Raise the OS-level terminal window to the front (best-effort).

    herdr's own `workspace focus` / `tab focus` only update herdr's internal
    state — nothing in the herdr CLI raises its host process above whatever
    app currently has OS focus (confirmed 2026-09-04: focusing a tab left
    Ghostty backgrounded until the user cmd-tabbed manually). All herdr
    workspaces on this Mac live in ONE Ghostty window (`osascript -e 'tell
    application "System Events" to tell process "Ghostty" to get name of
    every window'` -> a single "herdr" window), so activating the app is
    enough — no per-window targeting needed. Swallow any failure (wrong OS,
    Ghostty not running, osascript denied) since the herdr-side focus above
    already succeeded and is the part worth reporting on.
    """
    if sys.platform != "darwin":
        return
    try:
        subprocess.run(
            ["osascript", "-e", 'tell application "Ghostty" to activate'],
            timeout=5, capture_output=True, text=True,
        )
    except Exception:
        pass


def focus_pane(pane_id):
    """Bring the herdr workspace+tab holding `pane_id` to the front, and (for
    a LOCAL pane only) the OS window hosting it to the top of the screen.

    Looks the pane up fresh (not from a cached feed) so a pane that moved
    tabs or a tab that closed since the last poll fails loudly instead of
    focusing the wrong thing. Raises on any failure; callers turn that into
    a JSON error, never a 500 traceback to the browser.

    `pane_id` may be namespaced (`<machine>:<rawId>`) for a remote row —
    split_pane_key resolves which machine to herdr-focus on. The OS-level
    raise (_activate_terminal_app) only ever means "bring THIS Mac's
    Ghostty forward" — calling it for a remote focus would wrongly steal
    focus on this Mac while the Air pane is what the user asked to see, so
    it is skipped whenever the resolved machine isn't local (R15).
    """
    machine, raw_pane_id = herdr_transport.split_pane_key(pane_id, MACHINES)
    try:
        data = herdr_transport.herdr_cmd_json(
            machine, ["pane", "list"], repo_root=REPO_ROOT, machines=MACHINES,
            timeout=10)
    except herdr_transport.HerdrError as e:
        raise RuntimeError(f"herdr pane list failed on {machine}: {e}")
    panes = (data.get("result") or {}).get("panes") or []
    match = next((p for p in panes if p.get("pane_id") == raw_pane_id), None)
    if not match:
        raise RuntimeError(f"pane {pane_id} not found — likely closed")
    workspace_id = match["workspace_id"]
    tab_id = match["tab_id"]
    try:
        herdr_transport.herdr_cmd_text(
            machine, ["workspace", "focus", workspace_id],
            repo_root=REPO_ROOT, machines=MACHINES, timeout=10)
        herdr_transport.herdr_cmd_text(
            machine, ["tab", "focus", tab_id],
            repo_root=REPO_ROOT, machines=MACHINES, timeout=10)
    except herdr_transport.HerdrError as e:
        raise RuntimeError(f"herdr focus failed on {machine}: {e}")
    if machine == herdr_transport.LOCAL_MACHINE:
        _activate_terminal_app()
    return {"workspaceId": workspace_id, "tabId": tab_id, "machine": machine}


def get_board_state(row_kind="session", view_id=None):
    state = get_full_state()
    agents = state.get("computed", {}).get("agents") or []
    _enrich_agents_for_actions(state, agents)
    # P0 dashboard move: the "work_item" row kind (delivery-ops/Notion board)
    # is RETIRED — only "session" rows are served now. Any other rowKind
    # (including a stray "work_item") falls through to the empty-board reply
    # below, same as any other unrecognised rowKind.
    if row_kind != "session":
        return {"rowKind": row_kind, "properties": STORE.list_properties(row_kind), "rows": []}
    board = STORE.build_session_board(agents, view_id=view_id)
    _annotate_live_rows(board, agents)
    _annotate_ended_rows(board)
    return board


def get_state_with_board():
    state = get_full_state()
    agents = state.get("computed", {}).get("agents") or []
    _enrich_agents_for_actions(state, agents)
    state["board"] = STORE.build_session_board(agents)
    _annotate_live_rows(state["board"], agents)
    _annotate_ended_rows(state["board"])
    # Agent hierarchy (scripts/lib/agent_tree.py): same object GET
    # /api/agent-tree returns, folded into every /api/state response and SSE
    # tick so AgentBar never needs a second poll loop. Best-effort: a tree
    # read must never break the rest of this payload.
    try:
        state["agentTree"] = get_agent_tree_state()
    except Exception as e:
        state["agentTree"] = {"error": str(e)}
    return state


# ── v3 reclaim (phase 5): measured Memory + the Stop → Close → Relaunch ladder ──
#
# The server decides eligibility and returns the reason string; the UI only
# renders it. A button that decides for itself when it is safe is a second
# source of truth — the exact failure phase 2's server-resolved views were
# built to prevent.
#
# Enrichment cost (this runs on every /api/state + SSE tick, so it must stay
# cheap): the memory sampler owns a background ~15s thread — here is only a
# dict copy. `uncommitted_count_fe` caches 60s. Links are one sqlite query.
# Own-pane detection (ancestor walk over ~40 process-info calls) runs once
# and is cached 5min, refreshed early only if the pane vanishes.

_OWN_PANE_CACHE = {"id": None, "ts": 0.0, "resolved": False}
_OWN_PANE_TTL_SEC = 300

#: Fresh pane-feed membership for ENDED rows (Close/Relaunch act on panes
#: that outlived their agent). One `herdr pane list` per 10s PER MACHINE (an
#: Air row must query the Air's own pane list, never local's — R2/R3) — the
#: 2s render tick reads the cache, never a subprocess.
_PANE_FEED_CACHE = {}
_PANE_FEED_TTL_SEC = 10


def _live_pane_ids_cached(machine=herdr_transport.LOCAL_MACHINE):
    """Namespaced (herdr_transport.make_pane_key) live pane-id set for one
    machine. Namespaced, not raw: every stored `paneId` (agent dicts, ended-
    row stubs) is already in that form for a remote row, so `assess_row`'s
    `pane_id in live_pane_ids` alive check must compare like-for-like —
    comparing a namespaced id against a set of bare ids from `herdr pane
    list` never matches, which is exactly how a live Air row used to read as
    'pane already gone'."""
    now = time.time()
    cached = _PANE_FEED_CACHE.get(machine)
    if cached and now - cached["ts"] < _PANE_FEED_TTL_SEC:
        return set(cached["ids"])
    try:
        panes = session_actions._live_panes(machine=machine)
        ids = {herdr_transport.make_pane_key(machine, p.get("pane_id"))
               for p in panes if p.get("pane_id")}
    except Exception:
        ids = set((cached or {}).get("ids") or set())
    _PANE_FEED_CACHE[machine] = {"ids": ids, "ts": now}
    return set(ids)


def _own_pane_cached(live_ids):
    now = time.time()
    if (_OWN_PANE_CACHE["resolved"]
            and now - _OWN_PANE_CACHE["ts"] < _OWN_PANE_TTL_SEC
            and (_OWN_PANE_CACHE["id"] is None
                 or _OWN_PANE_CACHE["id"] in live_ids)):
        return _OWN_PANE_CACHE["id"]
    try:
        own = session_actions.own_server_pane_id()
    except Exception:
        own = None
    _OWN_PANE_CACHE.update(id=own, ts=now, resolved=True)
    return own


def _enrich_agents_for_actions(state, agents):
    """Add `memoryBytes` + `actions` to each live agent dict, in place.

    `derived:memory` (numeric, sorts correctly) and the row's action buttons
    both read from here — board table, kanban cards, and any future surface
    get the same server-resolved truth with no per-surface logic."""
    if not agents:
        return
    mem_snap = {}
    try:
        mem_snap = SAMPLER.snapshot()
    except Exception:
        pass
    live_ids = {a.get("paneId") for a in agents if a.get("paneId")}
    own = _own_pane_cached(live_ids)
    try:
        uncommitted = session_actions.uncommitted_count_fe()
    except Exception:
        uncommitted = 0
    try:
        links = STORE.list_links()
    except Exception:
        links = []
    runs = (((state.get("feeds", {}).get("workItems") or {}).get("data")
             or {}).get("runs")) or {}
    # Phase 8: the context reading rides the paneScreen feed (parsed off the
    # status line by the one feeds call site). Keyed by sanitized pane id —
    # the same join build_agents_view uses. Reuse, never re-read: the sweep
    # already paid for every screen.
    try:
        screens = (((state.get("feeds", {}).get("paneScreen") or {}).get("data"))
                   or {})
    except Exception:
        screens = {}
    row_ids = [resolve_agent_row_id(a) for a in agents]
    try:
        # Ladder gates read the latest stop/close/relaunch ONLY — a later
        # archive must not hide the fact the pane was stopped (and its undo).
        ladder = STORE.last_ladder_action(row_ids)
    except Exception:
        ladder = {}
    try:
        archived_flags = STORE.archived_map("session", row_ids)
    except Exception:
        archived_flags = {}
    for agent, row_id in zip(agents, row_ids):
        agent["rowId"] = row_id
        mem_bytes = mem_snap.get(agent.get("paneId"))
        agent["memoryBytes"] = mem_bytes
        # Phase 8: context % (sorts) + the auto-compact countdown (badge,
        # not a column — it exists on only a handful of panes at a time).
        # None when unreadable: renders `—`, never 0.
        try:
            pane_id = agent.get("paneId")
            ctx = (screens.get(sanitize_pane_id(pane_id))
                   if pane_id else None) or {}
            ctx = (ctx.get("context") or {})
        except Exception:
            ctx = {}
        agent["contextPct"] = ctx.get("pct")
        agent["autocompactPct"] = ctx.get("autocompactPct")
        try:
            owners = session_actions.owners_of_session(
                row_id, agent, runs, links)
        except Exception:
            owners = []
        was_stopped = ladder.get(row_id) == "stop"
        is_archived = bool(archived_flags.get(row_id, {}).get("archived"))
        try:
            agent["actions"] = session_actions.assess_row(
                agent, row_id, live_pane_ids=live_ids,
                memory_bytes=mem_bytes, uncommitted=uncommitted,
                owners=owners, own_pane=own, was_stopped=was_stopped,
                is_archived=is_archived,
                machine=agent.get("machine") or herdr_transport.LOCAL_MACHINE)
        except Exception as e:
            agent["actions"] = {
                n: {"enabled": False, "needsConfirm": False,
                    "reason": f"refused: could not assess ({e})"}
                for n in ("stop", "close", "relaunch", "archive",
                          "unarchive")}


def _annotate_live_rows(board, agents):
    """Carry the agents feed's already-resolved `actions` + `memoryBytes` onto
    the LIVE board rows.

    `_annotate_ended_rows` below only ever touched `status == "ended"`, so the
    table view (which reads /api/board) showed buttons on the 35 rows whose
    agent was already gone and none on the 17 live ones — exactly backwards,
    since a live row is the only kind worth stopping. The agents list looked
    fine because it reads /api/state, which is enriched separately.

    Reuse, never recompute: the agent dicts have already paid for the git
    uncommitted count and the work-item owner lookup. Recomputing here would
    both cost that again per request and risk the two surfaces disagreeing
    about whether one row is safe to stop — the second-source-of-truth
    failure the whole server-resolves-actions rule exists to prevent."""
    rows = (board or {}).get("rows") or []
    by_id = {a.get("rowId"): a for a in (agents or []) if a.get("rowId")}
    for r in rows:
        if r.get("status") == "ended":
            continue
        a = by_id.get(r.get("rowId"))
        if not a:
            continue
        if a.get("actions") is not None:
            r["actions"] = a["actions"]
        if a.get("memoryBytes") is not None:
            r["memoryBytes"] = a["memoryBytes"]
        # Phase 8: the CONTEXT column sorts on this, and phase 9 renders the
        # countdown as a badge — so the live rows carry both, top-level, the
        # way Proof 2 checks. (None stays None: `—`, not 0.)
        if a.get("contextPct") is not None:
            r["contextPct"] = a["contextPct"]
        if a.get("autocompactPct") is not None:
            r["autocompactPct"] = a["autocompactPct"]


def _annotate_ended_rows(board):
    """Attach server-resolved `actions` to lingering ended rows (Close when
    the pane still exists, Relaunch when a stop was logged — the undo).
    Stop is always off there: the agent is gone, and re-stopping would walk
    the shell's tree. Memory reads None (renders —): nothing to measure."""
    rows = (board or {}).get("rows") or []
    ended = [r for r in rows if r.get("status") == "ended"]
    if not ended:
        return
    # Own-pane detection is inherently local (comment on _own_pane_cached),
    # so it always checks against the LOCAL live set regardless of which
    # machine any given ended row turns out to be on.
    local_live_pane_ids = _live_pane_ids_cached(herdr_transport.LOCAL_MACHINE)
    try:
        annotations = STORE.session_action_annotations(
            [r.get("rowId") for r in ended])
    except Exception:
        annotations = {}
    try:
        ladder = STORE.last_ladder_action([r.get("rowId") for r in ended])
    except Exception:
        ladder = {}
    try:
        archived_flags = STORE.archived_map(
            "session", [r.get("rowId") for r in ended])
    except Exception:
        archived_flags = {}
    try:
        own = _own_pane_cached(local_live_pane_ids)
    except Exception:
        own = None
    for r in ended:
        row_id = r.get("rowId")
        pane = ((r.get("derived") or {}).get("paneId")
                or (r.get("values") or {}).get("derived:pane") or None)
        # Same resolution _resolve_stopped_pane uses below: a namespaced pane
        # id names its own machine, so an ended Air row's liveness must query
        # the Air's own pane list, not local's (the bug this replaces always
        # defaulted to "local" and so read a still-live Air pane as "gone").
        # An unresolvable prefix (machine removed from config) must never be
        # guessed as local — `machine` stays None and is handled below.
        machine = herdr_transport.LOCAL_MACHINE
        if pane:
            try:
                machine, _raw = herdr_transport.split_pane_key(pane, MACHINES)
            except herdr_transport.UnknownMachine:
                machine = None
        stub = {
            "paneId": pane,
            "paneIdSanitized": None,
            "tabId": None,
            "label": ((r.get("derived") or {}).get("label")
                      or (r.get("values") or {}).get("derived:label")
                      or row_id),
            "cwd": None,
            "focused": False,
            "hookState": None,
            "hookSinceSec": None,
            "herdrStatus": None,
            "disagree": False,
            "hasHookData": False,
            "agentSession": None if (row_id or "").startswith("pane:")
            else row_id,
            "screenState": None,
            "machine": machine if machine is not None else "unknown",
            "rowId": row_id,
        }
        was_stopped = ladder.get(row_id) == "stop"
        is_archived = bool(archived_flags.get(row_id, {}).get("archived"))
        if machine is None:
            # Can't tell which machine's pane list to check — must read as
            # unknown, never a false-certain "gone". Same catch-all shape
            # _enrich_agents_for_actions uses when assess_row itself raises.
            r["actions"] = {
                n: {"enabled": False, "needsConfirm": False,
                    "reason": "refused: could not assess (pane's machine "
                              "prefix is not configured — liveness unknown)"}
                for n in ("stop", "close", "relaunch", "archive",
                          "unarchive")}
            continue
        row_live_pane_ids = (local_live_pane_ids
                              if machine == herdr_transport.LOCAL_MACHINE
                              else _live_pane_ids_cached(machine))
        try:
            r["actions"] = session_actions.assess_row(
                stub, row_id, live_pane_ids=row_live_pane_ids,
                memory_bytes=None, uncommitted=0, owners=[],
                own_pane=own, was_stopped=was_stopped,
                is_archived=is_archived,
                machine=machine)
        except Exception:
            pass


def _resolve_stopped_pane(row_id):
    """Rebuild a minimal agent dict for a row that left the agent feed but
    whose pane still exists (the stopped-pane case). Returns None when the
    pane is gone too. The pane feed — read FRESH, never cached — is the
    truth for existence; session_seen supplies the last label.

    The row id doubles as the resume token when it is a real session id
    (`pane:`-prefixed ids are pane-derived and carry no session to resume).
    """
    try:
        seen = STORE.get_seen_row("session", row_id)
    except Exception:
        seen = None
    if not seen or not seen.get("last_pane"):
        return None
    pane_id = seen["last_pane"]
    try:
        machine, raw_pane_id = herdr_transport.split_pane_key(
            pane_id, MACHINES)
    except herdr_transport.HerdrError:
        return None
    try:
        panes = session_actions._live_panes(machine=machine)
    except Exception:
        return None
    match = next((p for p in panes if p.get("pane_id") == raw_pane_id), None)
    if not match:
        return None
    return {
        "paneId": pane_id,
        "paneIdSanitized": None,
        "tabId": match.get("tab_id"),
        "workspaceId": match.get("workspace_id"),
        "label": seen.get("last_label") or row_id,
        "cwd": None,
        "focused": False,
        "hookState": None,
        "hookSinceSec": None,
        "herdrStatus": None,
        "disagree": False,
        "hasHookData": False,
        "agentSession": None if row_id.startswith("pane:") else row_id,
        "screenState": None,
        "screenSignal": None,
        "rowId": row_id,
    }


def _log_failed_attempt(row_id, action, actor, error, text=None):
    """Record a send that TOUCHED the pane and did not land.

    Only the send path calls this — the pre-send refusals (no live agent, a
    picker open, a dev-server pane, needsConfirm) never typed anything, so
    logging them would fill the timeline with rows that describe no event.
    A failed row is invisible to session_action_annotations() and
    last_ladder_action() by construction (they filter status='failed'), so it
    can never caption a row or move a button gate — it exists so
    /api/session/history can show the PO that the send was tried and failed,
    instead of the failure vanishing the moment the toast does.
    """
    try:
        STORE.log_session_action(row_id, action, actor, error,
                                 text=text, status="failed")
    except Exception:
        pass


def _picker_or_permission_open(lines, question):
    """Fresh-read verdict: is a question picker or permission prompt open
    on the pane RIGHT NOW? `lines`/`question` must come from a read taken
    at the moment of the check, never a cached one — a stray Enter hitting
    a live picker has caused real damage before (project history), so
    every caller that is about to send a key re-reads and re-runs this.

    Returns (blocker, live_state): blocker is "picker", "permission", or
    None (clear); live_state is the fresh classify_pane verdict (or None on
    a classify failure) — the initial call's caller also needs live_state
    for the busy/confirm check right after, so it is returned rather than
    thrown away. Shared by the initial free-text guard in
    _handle_reach_action and its stuck-slash-command retry guard below —
    the retry reuses this exact function, never a laxer check.
    """
    if question is not None:
        return "picker", None
    try:
        live_state, _signal = classify_pane.classify("\n".join(lines[-40:]))
    except Exception:
        live_state = None
    if live_state == "NEEDS_HUMAN":
        return "permission", live_state
    return None, live_state


def _refused_before_typing(error):
    """A refusal that provably typed nothing into any pane: {ok:false,
    error, typed:false}. `typed: false` is the ONLY signal the board's
    Composer uses to put the text back in the box — any other failure
    (mid-sequence error, dropped connection, NOT SUBMITTED) may already
    have delivered the text, and restoring it invites a double-send on the
    next Enter. So mark ONLY returns that happen before the first
    keystroke; never add it after `_type_text`."""
    return {"ok": False, "error": error, "typed": False}


def _handle_inbox_message(agent, body, row_id, actor, text):
    """The Send-message path for a Claude Desktop / plain CLI row (no pane):
    delivered through the session's own peer inbox (session_inbox.py), with
    the pane path's rules (one line, no slash command, refused while a
    prompt is pending, confirm when busy) and the same audit rows."""
    result = session_inbox.deliver_row_message(
        agent, text, bool((body or {}).get("confirm")))
    if result.get("ok"):
        # Same frozen `reason` shape as the pane path (the history reader
        # parses it); the full body rides in `text`.
        queued = result.get("state") == "queued"
        try:
            STORE.log_session_action(
                row_id, "message", actor,
                (STORE.QUEUED_REASON_PREFIX if queued else "") + text[:80],
                text=text, status="queued" if queued else "sent")
        except Exception:
            pass
    elif result.get("error") and result.get("typed") is not False:
        _log_failed_attempt(row_id, "message", actor, result["error"], text)
    return result


def _handle_reach_action(action, body, row_id, actor):
    """POST /api/session/message {rowId, actor, text?, confirm?}.

    v4 reach: the board keeps a session GOING (look at it, top up its
    context, tell it what to do next) — the opposite direction from v3's
    ladder, which ends sessions. Same response shape: {ok, state, reason},
    or {ok:false, needsConfirm:true, reason} when a confirm is required and
    absent (the second-click state, not an error).

    Resolution reuses the ladder's live-agent lookup and nothing else: a
    message needs a LIVE agent to read it, so there is deliberately NO
    stopped-pane fallback — typing into a stopped pane's shell would EXECUTE
    as a shell command. Dev-server and own-pane guards mirror the ladder;
    the chief's pane is the deliberate exception (the v3 guard is about
    STOPPING it; messaging it is how the PO steers it — do not "fix" this
    back into a refusal, see Proof 8).

    The picker/prompt refusal is checked against a FRESH read at send time,
    never a cached state: free text would route into an open picker and
    mis-answer real work.
    """
    ok, cleaned = session_actions.validate_message_text(
        (body or {}).get("text"))
    if not ok:
        return _refused_before_typing(cleaned)
    text = cleaned

    state = get_full_state()
    agents = state.get("computed", {}).get("agents") or []
    _enrich_agents_for_actions(state, agents)
    agent = next((a for a in agents
                  if resolve_agent_row_id(a) == row_id), None)
    if agent is None:
        return _refused_before_typing(
            f"row {row_id} is not live — no agent there to read it")
    pane_id = agent.get("paneId")
    if not pane_id and session_inbox.message_via(agent) == "inbox":
        return _handle_inbox_message(agent, body, row_id, actor, text)
    if not pane_id:
        return _refused_before_typing(
            f"row {row_id} has no pane — nothing to type into")
    try:
        machine, raw_pane_id = herdr_transport.split_pane_key(
            pane_id, MACHINES)
    except herdr_transport.HerdrError as e:
        return _refused_before_typing(f"could not resolve pane machine: {e}")
    label = agent.get("label") or ""
    # No chief refusal here — deliberate (see docstring). The guards below
    # (own pane, dev-servers) still apply to every row including the chief's.
    try:
        own = _own_pane_cached(
            {a.get("paneId") for a in agents if a.get("paneId")})
    except Exception:
        own = None
    if own and pane_id == own:
        return _refused_before_typing(
            "refused: this is the dashboard server's own pane "
            "— there is no agent there to read it")
    if label in session_actions.DEV_SERVER_LABELS:
        return _refused_before_typing(
            "refused: dev-server panes are out of scope here — "
            "no agent there to read it, and the keystrokes "
            "would land in Metro")

    try:
        lines, question = _read_pane_now(raw_pane_id, machine=machine)
    except Exception as e:
        return _refused_before_typing(
            f"could not read pane {pane_id} fresh — {e}")
    blocked, live_state = _picker_or_permission_open(lines, question)
    if blocked == "picker":
        return _refused_before_typing(
            "refused: a question picker is open on that pane — "
            "free text would route into it and mis-answer real "
            "work. Answer it in the answer panel instead")
    if blocked == "permission":
        return _refused_before_typing(
            "refused: a permission prompt is open on that "
            "pane — free text would land in it. Answer it in "
            "the terminal instead")

    # Busy is evaluated ONCE, up front: it drives the confirm rule below
    # AND the queued verdict after sending. A mid-turn pane queues input —
    # it cannot drain the box until the turn ends — so "our text not stuck"
    # on a busy pane means queued, not instantly landed.
    was_busy = session_actions.resolve_busy(
        live_state, session_actions.state_word(agent))
    if was_busy:
        if not (body or {}).get("confirm"):
            return {"ok": False, "needsConfirm": True,
                    "reason": "that pane is mid-turn — the message queues "
                              "and lands when the turn ends. Confirm to "
                              "queue it"}

    try:
        _type_text(raw_pane_id, text, machine=machine)
        _send_keys(raw_pane_id, "enter", machine=machine)
        time.sleep(2)
        lines_after, _q = _read_pane_now(raw_pane_id, machine=machine)
    except Exception as e:
        err = f"message send failed mid-sequence — {e}"
        _log_failed_attempt(row_id, "message", actor, err, text)
        return {"ok": False, "error": err}
    if session_actions.input_box_still_holds(lines_after, text):
        if session_actions.is_allowed_slash_command(text):
            # Defensive fallback, scoped ONLY to /compact and /clear (the
            # two commands proven to submit on a single Enter — see
            # validate_message_text's allowlist docstring, 2026-09-22
            # probe). If the input still reads stuck, try ONE corrective
            # esc+enter — but first re-prove, on a FRESH read, that the
            # pane hasn't grown a live question picker or permission
            # prompt in the meantime, using the exact same guard as the
            # pre-send check above (_picker_or_permission_open). Do not
            # skip this: a stray Enter hitting a live picker has caused
            # real damage before. If that guard now blocks, skip the
            # retry and fall through to the normal STUCK failure below —
            # no looping past this one attempt.
            try:
                retry_lines, retry_question = _read_pane_now(
                    raw_pane_id, machine=machine)
            except Exception as e:
                err = f"message send failed mid-sequence (retry read) — {e}"
                _log_failed_attempt(row_id, "message", actor, err, text)
                return {"ok": False, "error": err}
            retry_blocked, _retry_live_state = _picker_or_permission_open(
                retry_lines, retry_question)
            if retry_blocked is None:
                try:
                    _send_keys(raw_pane_id, "esc", machine=machine)
                    _send_keys(raw_pane_id, "enter", machine=machine)
                    time.sleep(2)
                    lines_after, _q = _read_pane_now(
                        raw_pane_id, machine=machine)
                except Exception as e:
                    err = f"message send failed mid-sequence (retry) — {e}"
                    _log_failed_attempt(row_id, "message", actor, err, text)
                    return {"ok": False, "error": err}
        if session_actions.input_box_still_holds(lines_after, text):
            _log_failed_attempt(
                row_id, "message", actor,
                "NOT SUBMITTED — text stuck in the input box", text)
            return {"ok": False,
                    "error": "NOT SUBMITTED — the text is stuck in the "
                             "input box"}
    if session_actions.pane_reports_queued(lines_after) or was_busy:
        # The worker confirmed acceptance (or was mid-turn when we sent,
        # which queues by design): SUCCESS with state queued, and LOGGED —
        # the log is what makes a retry visible instead of a blind double.
        reason = ("queued — lands when the current turn ends. Do not "
                  "re-send — this send is logged")
        try:
            # `reason` keeps its exact 80-char legacy shape (the annotation
            # reader renders off it); the untruncated body rides in `text`.
            STORE.log_session_action(
                row_id, "message", actor, "queued: " + text[:80],
                text=text, status="queued")
        except Exception:
            pass
        return {"ok": True, "state": "queued", "reason": reason}
    try:
        STORE.log_session_action(row_id, "message", actor, text[:80],
                                 text=text, status="sent")
    except Exception:
        pass
    return {"ok": True, "state": "message sent",
            "reason": "verified — the input box drained after enter"}


def handle_session_action(action, body):
    """POST /api/session/{stop,close,relaunch,archive,unarchive,message}
    {rowId, actor, confirm?, text?} -> {ok, state, reason}. When confirm is required
    and absent: {ok:false, needsConfirm:true, reason} — NOT an error; the UI
    turns that into the second-click state.

    Resolution order (the ladder acts on PANES, not agents): a live agent
    row first; else the row's last live sighting (session_seen) verified
    against a FRESH pane list — a stopped pane still exists, and Close /
    Relaunch must reach it. Stop needs a live agent row: stopping a pane
    whose agent already left the feed is either a no-op (stopped) or a race
    (agent list lagging a newborn) — both refuse loudly rather than guess.

    Archive/unarchive are board-only (hide the row, free nothing, touch no
    process): they resolve any known row — live or merely seen — need no
    confirm, and accept `chief` as well as `po`. Archive is the only action
    the chief will ever hold.

    Message (v4 reach) keeps a session going instead of ending it: it
    resolves a LIVE agent row only (no stopped-pane fallback — typing into
    a shell would execute), refuses `chief` as actor, and verifies every
    send by re-reading the pane. The verify has three verdicts: STUCK (our
    literal text still in the box — NOT SUBMITTED, no log) vs QUEUED (the
    worker's queued-messages indicator, or a pane known mid-turn at send
    time — SUCCESS with state queued, LOGGED) vs drained (submitted).
    See _handle_reach_action.
    """
    row_id = (body or {}).get("rowId")
    actor = (body or {}).get("actor")
    if not row_id:
        return _refused_before_typing("missing rowId")
    if action not in ("stop", "close", "relaunch", "archive", "unarchive",
                      "message"):
        return _refused_before_typing("bad action")
    if action in ("archive", "unarchive"):
        ok, why = session_actions.check_actor(
            actor, allowed=session_actions.ARCHIVE_ACTORS)
    else:
        ok, why = session_actions.check_actor(actor)
    if not ok:
        return _refused_before_typing(why)

    if action in ("archive", "unarchive"):
        # Board-only, and resolved BEFORE any agent lookup on purpose.
        #
        # Archive shares nothing with the ladder: it frees no memory, touches
        # no process, and its whole point is tidying rows whose pane is
        # already gone. Routing it through the liveness path refused exactly
        # those rows ("pane already closed") — the chief's one power, useless
        # on everything it was meant for. It also fell through to the `else`
        # branch below, which calls do_relaunch.
        want = (action == "archive")
        try:
            STORE.set_archived("session", row_id, want, actor)
        except Exception as e:
            return {"ok": False, "error": str(e)}
        try:
            STORE.log_session_action(row_id, action, actor, "board-only")
        except Exception:
            pass
        return {"ok": True,
                "state": "archived" if want else "unarchived",
                "reason": "board-only — no process touched"}

    if action == "message":
        # Reach needs no ladder resolution (it refuses non-live rows
        # outright) and must never fall through to do_relaunch below.
        return _handle_reach_action(action, body, row_id, actor)

    state = get_full_state()
    agents = state.get("computed", {}).get("agents") or []
    _enrich_agents_for_actions(state, agents)
    agent = next((a for a in agents
                  if resolve_agent_row_id(a) == row_id), None)
    if agent is None:
        if action == "stop":
            return {"ok": False,
                    "error": f"row {row_id} is not live — nothing to stop"}
        agent = _resolve_stopped_pane(row_id)
        if agent is None:
            return {"ok": False,
                    "error": f"row {row_id} is gone — pane already closed"}
        # Re-assess the stopped pane: stale hook state is gone with the
        # agent, so the reason is rebuilt from the sighting (the stake died
        # with the stop — Close is one click, Relaunch is offered).
        _enrich_agents_for_actions(state, [agent])
    entry = (agent.get("actions") or {}).get(action) or {}
    if not entry.get("enabled"):
        return {"ok": False, "error": entry.get("reason") or "refused"}
    if entry.get("needsConfirm") and not (body or {}).get("confirm"):
        return {"ok": False, "needsConfirm": True,
                "reason": entry.get("reason") or ""}
    # agent["paneId"] is namespaced (`<machine>:<rawId>`) for a remote row
    # (R1) — split once here so every executor below gets the RAW id plus
    # the machine to route it at, never a namespaced string handed to herdr.
    try:
        machine, raw_pane_id = herdr_transport.split_pane_key(
            agent["paneId"], MACHINES)
    except herdr_transport.HerdrError as e:
        return {"ok": False, "error": f"could not resolve pane machine: {e}"}
    try:
        if action == "stop":
            result = session_actions.do_stop(raw_pane_id, machine=machine)
            note = (f"stopped ({result.get('freed', 0)} procs; "
                    f"{result.get('sigkilled', 0)} sigkilled)")
        elif action == "close":
            result = session_actions.do_close(
                raw_pane_id, agent.get("tabId"), machine=machine)
            note = f"closed tab {result.get('tabId')}"
        elif action == "relaunch":
            result = session_actions.do_relaunch(
                raw_pane_id, agent.get("agentSession"), machine=machine)
            note = f"resumed {result.get('resumed')}"
        else:
            # Explicit, so a verb added later cannot silently inherit
            # relaunch's behaviour the way archive just did.
            return {"ok": False, "error": f"unhandled action {action}"}
    except Exception as e:
        return {"ok": False, "error": str(e)}
    try:
        STORE.log_session_action(row_id, action, actor,
                                 entry.get("reason") or "")
    except Exception:
        pass
    return {"ok": True, "state": note,
            "reason": entry.get("reason") or ""}


# ── Answering an AskUserQuestion picker from the dashboard (2nd write action) ──
#
# THE SHAPE, as of Claude Code v2.1.263 (re-measured 2026-09-06 on a throwaway
# claude-aptus tab, spike-submitstuck, since closed). A whole AskUserQuestion
# turn is ONE TABBED FORM, not a run of separate pickers:
#
#     ←  ☐ Fruit  ☐ Colour  ✔ Submit  →      <- one tab per question, then Submit
#     Which fruit?
#     ❯ 1. Apple  /  2. Banana  /  3. Type something.
#
#   * Single-select: the option's DIGIT selects and advances to the next tab.
#   * Multi-select: a digit TOGGLES that option's checkbox without moving the
#     cursor or advancing; the box is left by its own exit row, labelled
#     `Next` on every question but the last and `Submit` on the last.
#   * Answering the LAST question always lands on the REVIEW screen
#     ("Review your answers … ❯ 1. Submit answers / 2. Cancel") — whatever the
#     question's type. `enter` submits it. The digit `1` does NOT: three
#     seconds after `1` the screen was unchanged, and `enter` released the turn
#     immediately.
#   * Digits are position-dependent: with the cursor on the free-text row after
#     text was typed, "1" APPENDS to the text ("spike-ship-raft" ->
#     "spike-ship-raft1") instead of toggling option 1. So always park on
#     option row 1 (verified by re-read) before sending any digit.
#   * "Other" is an explicit row ("N. Type something.", always last). Typing via
#     `herdr pane run` auto-routes into it and REPLACES the placeholder.
#     Multi-select needs `enter` AFTER typing to check the row on; enter-BEFORE-
#     typing leaves it unchecked and the text is silently dropped, so the order
#     is type-then-enter.
#   * Every navigation step is closed-loop (send one key, re-read, confirm the
#     cursor line) because up/down wrap-around behaviour is UNPROVEN — an
#     overshoot that lands on the wrong row and eats an `enter` could answer a
#     different option, or hit the review screen's `Cancel`.
#
# WHAT THE OLD SHAPE WAS, and what believing it cost. Until 2026-09-06 this
# path assumed the pre-v2.1.263 model: sequential pickers, a single-select
# digit auto-submitting the whole turn, a review screen only ever after a
# multi-select, dismissed with the digit `1`, and an exit row only ever called
# `Submit`. Every one of those is now false, and the failures were silent:
# answering the last question parked the worker on `Submit answers` forever
# while the dashboard said "answer may not have landed", and a multi-select on
# any question but the last could not be left at all (twelve blind `down`
# presses, then a refusal, with the boxes already ticked). Re-measure this
# block against a live pane whenever the picker's drawing changes — the
# fixtures in scripts/tests are captures, and a capture cannot notice that the
# product moved.
#
# RISK POSTURE (this dashboard is otherwise read-only): a wrong keystroke lands
# in a live agent sharing a tree with other sessions. So the send path (1)
# re-reads the pane FRESH (never the 45s-old feed), (2) refuses unless the live
# question still matches what the UI rendered, (3) verifies every toggle, check
# and submit by re-reading, and (4) refuses — never guesses — on any mismatch.
# A refusal costs the human a glance; a wrong answer costs a worker its turn.

import re as _re

# `Next` is the same exit row under another name — see SUBMIT_ROW_RE in
# classify_pane.py. A tabbed form labels it for where it goes.
_CURSOR_SUBMIT_RE = _re.compile(r'^\s*❯\s*(?:Submit|Next)\s*$')
_CURSOR_OPT_RE = _re.compile(r'^\s*❯\s*(\d+)\.\s+')
#: The composer's mode footer when the pane has left plan mode for auto-accept
#: ("⏵⏵ auto mode on (shift+tab to cycle) · ..."). Used only by the ask-#2
#: post-send guard below — never to decide what to press, only to notice
#: what actually happened after.
_AUTO_MODE_FOOTER_RE = _re.compile(r'⏵⏵\s*auto mode on')
# 100, not 40: measured 2026-09-04 that `herdr pane read --lines 40` on a
# live picker returns only the last ~12 lines (title cut off, unparsable)
# while --lines 100 returns the whole box. Same lesson as
# PANE_SCREEN_READ_LINES in chief_dashboard_feeds.py.
_ANSWER_READ_LINES = 100
_NAV_MAX_STEPS = 12


def _pane_run_raw(args, machine=herdr_transport.LOCAL_MACHINE, timeout=15):
    try:
        return herdr_transport.herdr_cmd_text(
            machine, args, repo_root=REPO_ROOT, machines=MACHINES,
            timeout=timeout)
    except herdr_transport.HerdrError as e:
        raise RuntimeError(f"{' '.join(args[:3])} on {machine}: {e}")


def _read_pane_now(pane_id, read_lines=_ANSWER_READ_LINES, parser=None,
                   machine=herdr_transport.LOCAL_MACHINE):
    """Fresh screen text + parsed block (None if none open).

    `read_lines` exists for /api/pane/screen, which shows the PO the raw
    screen and may want more scrollback than the picker parser needs; every
    send-path caller keeps the measured 100-line default. `parser` defaults
    to the AskUserQuestion picker parser — every pre-existing call site is
    unchanged — and the permission-box send path passes
    `classify_pane.parse_permission_block` instead. `pane_id` here is
    always the RAW id (never namespaced) — callers split machine out first.
    """
    out = _pane_run_raw(["pane", "read", pane_id,
                         "--source", "recent-unwrapped",
                         "--lines", str(read_lines)], machine=machine)
    if not out.strip():
        raise RuntimeError(f"pane {pane_id} read back empty — likely closed")
    lines = out.splitlines()
    parse = parser or classify_pane.parse_question_block
    return lines, parse(lines[-_ANSWER_READ_LINES:])


def _send_keys(pane_id, *keys, machine=herdr_transport.LOCAL_MACHINE):
    # Logged (2026-09-27, air-m1:w2:p2M brief): every prior failure on this
    # path left NO trace — `log_message` below drops every 200-status
    # request, and `/api/answer` always answers 200 (`ok:false` on a
    # refusal), so nothing about a failed send ever reached the console.
    # This is the one choke point every key send goes through (digits,
    # arrows, enter), so one line here covers the whole picker-answer path.
    # Real capture: this call reported exit 0 (no HerdrError raised) on a
    # pane where the digit provably never reached the pty — a real
    # keystroke typed directly into the same pane, moments later, worked
    # immediately. So "no exception" is NOT proof of delivery; logging the
    # attempt is what makes the NEXT one diagnosable, since herdr's own
    # send-keys has no stronger confirmation to give us.
    print(f"chief-dashboard-server: send-keys pane={pane_id!r} "
          f"machine={machine!r} keys={keys!r}", file=sys.stderr)
    try:
        _pane_run_raw(["pane", "send-keys", pane_id, *keys],
                      machine=machine)
    except Exception as e:
        print(f"chief-dashboard-server: send-keys pane={pane_id!r} "
              f"machine={machine!r} keys={keys!r} FAILED: {e}",
              file=sys.stderr)
        raise


def _type_text(pane_id, text, machine=herdr_transport.LOCAL_MACHINE):
    # argv, not a shell string — no quoting layer to escape through.
    _pane_run_raw(["pane", "run", pane_id, text], machine=machine)


def _cursor_line(lines):
    for l in lines:
        if _CURSOR_SUBMIT_RE.match(l):
            return "submit"
        m = _CURSOR_OPT_RE.match(l)
        if m:
            return int(m.group(1))
    return None


def _park_on_row(pane_id, want, machine=herdr_transport.LOCAL_MACHINE):
    """Move the picker cursor to option row 1 / `want` / submit, verified.

    `want` is 1 (top option), an option index, or "submit". Closed-loop: one
    key per iteration, re-read, stop only when the cursor line confirms. Any
    unconfirmed navigation refuses — see the module comment for why.

    Submit-row subtlety: once the cursor sits on `❯ Submit`, the block parser
    returns None (its cursor detector needs `❯` + a digit, and the Submit row
    has none) — but the Submit row existing IS the proof the picker is still
    open, so that is the success return, not a refusal. A missing cursor with
    no parse is the genuinely-gone case.
    Returns the fresh (lines, question) once parked.
    """
    for _ in range(_NAV_MAX_STEPS):
        lines, q = _read_pane_now(pane_id, machine=machine)
        cur = _cursor_line(lines)
        if cur == want:
            if want == "submit" or q is not None:
                return lines, q
            raise RuntimeError(
                "question changed or gone — re-check the pane")
        if q is None and cur != "submit":
            raise RuntimeError(
                "question changed or gone — re-check the pane")
        _send_keys(pane_id, "up" if (want == 1 or (
            isinstance(want, int) and isinstance(cur, int)
            and cur > want)) else "down", machine=machine)
        time.sleep(0.5)
    raise RuntimeError(
        "could not park the picker cursor — re-check the pane")


def _same_question(a, b):
    return (a is not None and b is not None
            and a.get("title") == b.get("title")
            and a.get("question") == b.get("question"))


def _wait_for_next(pane_id, old, timeout_sec=8,
                   machine=herdr_transport.LOCAL_MACHINE):
    """After a successful send, wait briefly for a QUEUED next question.

    Sequential multi-question turns present Q2 seconds after Q1 is answered —
    faster than the 45s feed. Returns the fresh parsed question if one opens
    that differs from `old`, else None. Bounded at 8s (spike: Q2 was up
    within ~8s): a small hold on every answer that saves ~40s whenever a
    second question is queued.
    """
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        time.sleep(2)
        try:
            _, q = _read_pane_now(pane_id, machine=machine)
        except Exception:
            return None
        if q is None:
            continue  # turn over, or Q2 not presented yet — keep waiting
        return None if _same_question(q, old) else q
    return None


def _submit_review(pane_id, machine=herdr_transport.LOCAL_MACHINE):
    """Press an open review screen's `Submit answers` row. Verified, closed-loop.

    `enter` submits; the digit does NOT — measured 2026-09-06 on v2.1.263: the
    screen sat unchanged three seconds after `1`, and `enter` released the turn
    at once. (The digit did work when this path was written, which is exactly
    why nothing noticed: the key silently stopped doing anything.)

    The cursor is confirmed to be standing ON the Submit row first, because the
    row under it is `Cancel` — an unverified `enter` would discard answers the
    human has already staged. Returns True once the review is gone.
    """
    for _ in range(_NAV_MAX_STEPS):
        lines, _q = _read_pane_now(pane_id, machine=machine)
        if not classify_pane.review_screen_open(lines):
            return True
        if not classify_pane.cursor_on_review_submit(lines):
            _send_keys(pane_id, "up", machine=machine)
            time.sleep(0.5)
            continue
        _send_keys(pane_id, "enter", machine=machine)
        for _ in range(3):
            time.sleep(2)
            lines, _q = _read_pane_now(pane_id, machine=machine)
            if not classify_pane.review_screen_open(lines):
                return True
        return False
    return False


def _settle_after_submit(pane_id, old, machine=herdr_transport.LOCAL_MACHINE):
    """Confirm a send landed, finish the form, and pick up any next question.

    Returns {"next": <question|null>}.

    THE FORM'S LAST STEP IS OURS TO PRESS. v2.1.263 renders an AskUserQuestion
    turn as one tabbed form whose final tab is a review screen; answering the
    last question parks there whatever the question's type. Nothing else will
    press it — the human never touched this pane — so a landed answer used to
    leave the worker frozen on `Submit answers` while this function reported
    the answer lost. Detecting the review and calling it failure WAS the bug.

    A freshly-opened DIFFERENT question is the next tab of the same form —
    success, not failure, and checked FIRST because a spent review screen can
    still linger above it in scrollback. Only the SAME question still open, or
    a review that refuses to close, counts as a failed send.

    Slow-dismiss tolerance: a landed send can take seconds to clear the picker
    (measured 2026-09-05 on a snapshotting pane), so the same question is
    re-read a few times before it counts. Nothing is ever re-sent while
    waiting — a blind resend could toggle a landed answer back off.
    """
    lines, q = _read_pane_now(pane_id, machine=machine)
    presses_left = 2  # bounded: a review that survives two verified `enter`s
    for _ in range(4):                     # is stuck, and waiting longer only
        if q is not None and not _same_question(q, old):   # holds the request
            return {"next": q}
        if classify_pane.review_screen_open(lines) and presses_left:
            presses_left -= 1
            _submit_review(pane_id, machine=machine)
        elif q is None and not classify_pane.review_screen_open(lines):
            break
        else:
            time.sleep(3)
        lines, q = _read_pane_now(pane_id, machine=machine)
    if ((q is not None and _same_question(q, old))
            or classify_pane.review_screen_open(lines)):
        # Logged for the same reason as `_send_keys` above: 2026-09-27's
        # air-m1:w2:p2M brief hit this exact refusal twice, post-fix, on a
        # pane where every `send-keys` call reported success — yet a real
        # keystroke typed directly into that pane worked immediately after.
        # Nothing else on this path leaves a trace (see `_send_keys`), so
        # without this line a repeat is exactly as undiagnosable as this
        # one was.
        print(f"chief-dashboard-server: settle refused pane={pane_id!r} "
              f"machine={machine!r} old_title={old.get('title')!r} "
              f"still_same_question={q is not None and _same_question(q, old)!r} "
              f"review_open={classify_pane.review_screen_open(lines)!r}",
              file=sys.stderr)
        raise RuntimeError(
            "answer may not have landed over the dashboard — try answering "
            "directly in the pane's own terminal instead")
    return {"next": _wait_for_next(pane_id, old, machine=machine)}


def _submit_multi(pane_id, old, machine=herdr_transport.LOCAL_MACHINE):
    """Leave a multi-select's box by its own exit row, then settle.

    That row is `Submit` on the form's last question and `Next` on every other
    one, so where the `enter` lands differs: the review screen, or the next
    question's tab. `_settle_after_submit` handles both — and presses the
    review when it is the one that appears.
    """
    _park_on_row(pane_id, "submit", machine=machine)
    _send_keys(pane_id, "enter", machine=machine)
    time.sleep(2)
    return _settle_after_submit(pane_id, old, machine=machine)


def _clean_free_text(value):
    """Free text fit to type into the picker's Other row: single line (the
    row is one line — a newline would submit mid-text), capped (a paste the
    size of a file is never an answer), never empty."""
    s = _re.sub(r'\s+', ' ', (value or '')).strip()
    if not s:
        raise RuntimeError("empty answer text — nothing to send")
    return s[:500]


def _check_targets(q, indices):
    """Validate select targets against the FRESHLY parsed question."""
    by_index = {o["index"]: o for o in q["options"]}
    if not indices:
        raise RuntimeError("no option picked — nothing to send")
    for i in indices:
        o = by_index.get(i)
        if o is None:
            raise RuntimeError(
                "question changed or gone — re-check the pane")
        if o["other"]:
            raise RuntimeError(
                "that row is the free-text row — type an answer instead")
    return sorted(set(indices))


def answer_pane_question(pane_id, choice, question):
    """Send a staged dashboard answer into a live AskUserQuestion picker.

    Same shape as focus_pane(): the pane is looked up FRESH, everything is
    re-read fresh, and any failure is raised for the caller to turn into a
    JSON {ok:false} response — never a 500, never a blind keystroke.
    `choice` is {"type":"select","indices":[...]} or {"type":"text","value"}.
    `question` is {"title":...,"question":...} as the UI rendered it.

    `pane_id` may be namespaced (R1) — resolved once here into (machine,
    raw pane_id), then every nested helper below takes machine= and never
    re-derives it, so a remote Answer sends its keys to the Air, not here.

    AUDITED 2026-09-20 (dashboard-answer-stray-enter brief) for the class
    of bug this function used to have: a key sent on the assumption "the
    question under us hasn't changed" without actually re-checking that.
    `_type_text` is the risky primitive — it runs `pane run`, which embeds
    an Enter that CAN auto-submit and advance the pane on its own, so a
    screen read right after it can legitimately be a different,
    already-open question. It is called from BOTH halves of the "text"
    branch (single-select and multi-select share the same `_type_text`
    call; only the handling after it differs) — both halves now gate every
    follow-up key on `_same_question` before sending it (the multi-select
    half was missed in the first pass and only caught by QA). The `select`
    (digit) branches never call `_type_text`: a digit press is the ONE key
    sent per turn there, and every read after it is treated reactively
    (`_settle_after_submit`'s own `_same_question` check, or the
    multi-select toggle loop's explicit re-verify before each further
    digit) — none of them assumes "still open" and blindly sends a second
    key. Structurally immune, not merely untested.
    """
    machine, pane_id = herdr_transport.split_pane_key(pane_id, MACHINES)
    try:
        data = herdr_transport.herdr_cmd_json(
            machine, ["pane", "list"], repo_root=REPO_ROOT, machines=MACHINES,
            timeout=10)
    except herdr_transport.HerdrError as e:
        raise RuntimeError(f"herdr pane list failed on {machine}: {e}")
    panes = (data.get("result") or {}).get("panes") or []
    if not any(p.get("pane_id") == pane_id for p in panes):
        raise RuntimeError(f"pane {pane_id} not found — likely closed")

    lines, q = _read_pane_now(pane_id, machine=machine)
    if q is None:
        raise RuntimeError("question changed or gone — re-check the pane")
    want = question or {}
    if (q["title"] != want.get("title")
            or q["question"] != want.get("question")):
        # The feed copy is up to 45s old: the pane may have moved on or been
        # answered from the terminal since. Answering the NEW question with
        # the OLD choice would silently mis-answer real work. This refusal
        # also fires whenever the CLIENT posted a title/question that was
        # never screen-parsed in the first place (e.g. the transcript's raw
        # AskUserQuestion copy, a different representation of the same
        # question — see FormCard.tsx's fix note) — logged here, not just
        # raised, because that class of bug otherwise looks identical to
        # genuine staleness and is undiagnosable from the client's generic
        # "question changed or gone" toast alone.
        print(f"chief-dashboard-server: answer_pane_question mismatch "
              f"pane={pane_id!r} machine={machine!r} "
              f"posted_title={want.get('title')!r} fresh_title={q['title']!r} "
              f"posted_question={want.get('question')!r} "
              f"fresh_question={q['question']!r}", file=sys.stderr)
        raise RuntimeError("question changed or gone — re-check the pane")

    ctype = (choice or {}).get("type")
    if ctype == "select":
        indices = _check_targets(q, (choice or {}).get("indices") or [])
        if not q["multi"]:
            if len(indices) != 1:
                raise RuntimeError(
                    "single-select takes exactly one option")
            # Digit = instant select+submit (spike) — CONFIRMED still true
            # regardless of where the cursor already sits: live-tested
            # 2026-09-27 on both the Pro AND the Air (throwaway local
            # panes, plain tmux keys AND `herdr pane send-keys` itself —
            # the identical primitive this function calls, over the exact
            # ssh options this function uses), with the digit already
            # under the cursor, a background subagent actively churning,
            # the target pane's TAB not the active one in its workspace,
            # and the pane's real macOS window not frontmost — every case
            # submitted instantly. So the picker's own key handling is not
            # the cause of the 2026-09-27 air-m1:w2:p2M failure (a first
            # pass at this fix wrongly assumed a same-row no-op, and a
            # second pass wrongly assumed a resendable network hiccup;
            # neither survived testing against the real picker and the
            # real pane, and both were reverted — see the delivery note).
            #
            # NO resend: the real capture answered this SAME pane through
            # this SAME code path TWICE MORE after the resend shipped, and
            # both attempts still refused identically — resending the
            # identical digit through the identical delivery mechanism
            # provably does not help THIS failure, so keeping it was dead
            # weight (extra latency, false confidence) rather than a fix.
            # What's actually true, confirmed the same day: a real
            # keystroke typed directly into that pane's own terminal
            # landed immediately. So `_send_keys` and `_settle_after_submit`
            # below are now logged (their own docstrings/comments explain
            # why) so the NEXT occurrence is diagnosable instead of a
            # repeat of this investigation, and the refusal below tells the
            # PO the one thing that is actually known to work.
            _send_keys(pane_id, str(indices[0]), machine=machine)
            time.sleep(3)
            return _settle_after_submit(pane_id, q, machine=machine)
        # Multi: park on row 1 first (digits typed from the free-text row
        # APPEND to its text instead of toggling — spike), toggle remotely,
        # verify every check landed, then the Submit+review sequence. Digits
        # TOGGLE, so only send the ones not already checked in the FRESH
        # read — re-sending a checked one would UNCHECK it.
        _park_on_row(pane_id, 1, machine=machine)
        _, q2 = _read_pane_now(pane_id, machine=machine)
        if q2 is None:
            raise RuntimeError(
                "question changed or gone — re-check the pane")
        if (q2["title"] != q["title"]
                or q2["question"] != q["question"]):
            raise RuntimeError(
                "question changed or gone — re-check the pane")
        by_index = {o["index"]: o for o in q2["options"]}
        for i in indices:
            _check_targets(q2, [i])
            if not (by_index.get(i) or {}).get("checked"):
                _send_keys(pane_id, str(i), machine=machine)
                time.sleep(0.7)
        # Toggles can render slowly on a busy pane (measured 2026-09-05: a
        # checked box still read unchecked 0.7s after the digit) — wait for
        # every check to show before proceeding. Never RESEND while waiting:
        # a blind resend could flip a landed toggle back off. Worst case is
        # a refusal, never a wrong answer.
        missing = indices
        for _ in range(6):
            _, q2 = _read_pane_now(pane_id, machine=machine)
            if q2 is None or not _same_question(q2, q):
                raise RuntimeError(
                    "question changed or gone — re-check the pane")
            by_index = {o["index"]: o for o in q2["options"]}
            missing = [i for i in indices
                       if not (by_index.get(i) or {}).get("checked")]
            if not missing:
                break
            time.sleep(1.0)
        if missing:
            raise RuntimeError(
                "toggle did not land — re-check the pane")
        return _submit_multi(pane_id, q, machine=machine)
    elif ctype == "text":
        value = _clean_free_text((choice or {}).get("value"))
        if q["otherIndex"] is None:
            raise RuntimeError(
                "question changed or gone — re-check the pane")
        # Cursor onto the Other row, type (auto-routes into the row,
        # replacing its placeholder), then:
        # single-select auto-submits on type alone; multi-select needs an
        # `enter` AFTER typing to check the row on — enter-before-typing
        # leaves it unchecked and the text is silently dropped (spike).
        _park_on_row(pane_id, 1, machine=machine)
        _park_on_row(pane_id, q["otherIndex"], machine=machine)
        _type_text(pane_id, value, machine=machine)
        time.sleep(3)
        _, q2 = _read_pane_now(pane_id, machine=machine)
        if q2 is None:
            # Single-select auto-submit carried it. No picker now means Q2
            # is queued, the turn is over, or — on the form's LAST question —
            # the REVIEW screen is up and only we can press `Submit answers`
            # (2026-09-21: waiting here left the worker frozen on it).
            # `_settle_after_submit` covers all three.
            return {"next": _settle_after_submit(
                pane_id, q, machine=machine)["next"]}
        if q["multi"]:
            # Same risk as the single-select tail below, same fix: `_type_text`
            # already ran `pane run` (embeds an Enter) before we ever get here,
            # so q2 being non-None does NOT mean "Q1 still open" — it can be a
            # DIFFERENT question the embedded Enter already advanced to. The
            # label/checked-state checks just below are proxies for "did the
            # text land", not for "is this still Q1" — a coincidentally
            # matching different question would sail through them and get the
            # next `enter` (then `_submit_multi`) aimed at IT instead (same bug
            # class QA-caught 2026-09-20, session c7db27d6; this multi-select
            # sub-path was missed in the first pass and only caught by QA).
            if not _same_question(q2, q):
                return {"next": q2}
            other = next((o for o in q2["options"] if o["other"]), None)
            if other is None or value[:20] not in other["label"]:
                raise RuntimeError(
                    "typed text did not land — re-check the pane")
            _send_keys(pane_id, "enter", machine=machine)
            time.sleep(1)
            _, q3 = _read_pane_now(pane_id, machine=machine)
            if q3 is None:
                # Same last-question review screen as the q2 case above.
                return {"next": _settle_after_submit(
                    pane_id, q, machine=machine)["next"]}
            # Same guard again: the checkbox-confirm Enter just sent could
            # itself have advanced the pane (multi-select "Type something"
            # rows can auto-check-and-submit on some terminals) — never let
            # `_submit_multi` run against a stale `q` without re-verifying q3
            # is still that same question first.
            if not _same_question(q3, q):
                return {"next": q3}
            other3 = next((o for o in q3["options"] if o["other"]), None)
            if other3 is None or not other3["checked"]:
                raise RuntimeError(
                    "free-text row did not check on — re-check the pane")
            return _submit_multi(pane_id, q, machine=machine)
        # Single-select: q2 being non-None does NOT mean "Q1 still open" —
        # `_type_text` runs `pane run` (embeds an Enter), which CAN
        # auto-submit Q1 on its own and advance the pane straight to Q2.
        # Sending another blind `enter` here used to land on WHATEVER q2
        # now shows (its own default-selected option), silently
        # mis-answering a question AgentBar never asked about (QA-caught
        # 2026-09-20, session c7db27d6, pane wB:p6 — Q2 "Versioning" was
        # recorded as its default option despite never being shown in
        # AgentBar). Only send the follow-up Enter when q2 is PROVABLY the
        # same question — otherwise the type already landed AND submitted,
        # and q2 is the very next-question success case, same as the
        # multi-select and digit-select branches already return it: no
        # further key, ever, once the question under us has changed.
        if not _same_question(q2, q):
            return {"next": q2}
        _send_keys(pane_id, "enter", machine=machine)
        time.sleep(3)
        return _settle_after_submit(pane_id, q, machine=machine)
    raise RuntimeError("bad choice: type must be 'select' or 'text'")


def _same_permission(a, b):
    """Same title+tool+detail+planPath+option layout — the exact-match half
    of the stale-race guard `answer_pane_permission` runs before sending a
    key.

    `planPath` is compared too: a plan-approval box's title/tool/options are
    a FIXED sentence (unlike a Bash/Edit box, whose `detail` is the actual
    command/diff), so two DIFFERENT plans read identically on every other
    field. Without this, a stale echoed plan box could pass the race guard
    against a live box for a completely different plan file. A no-op for
    every non-plan box — neither side ever carries a `planPath` key, so both
    `.get()` calls return None."""
    if a is None or b is None:
        return False
    layout = lambda p: [(o["index"], o["label"]) for o in p.get("options") or []]
    return (a.get("title") == b.get("title")
            and a.get("tool") == b.get("tool")
            and a.get("detail") == b.get("detail")
            and a.get("planPath") == b.get("planPath")
            and layout(a) == layout(b))


def _permission_target_index(perm, choice):
    """Resolve `choice` to the option index to press, or raise.

    Never defaults to allow: every branch requires the FRESHLY read option's
    own label to corroborate the choice, and "allow-always" raises outright
    when the prompt has no such option — there is nothing safe to press.
    """
    options = perm.get("options") or []
    if choice == "allow":
        first = options[0] if options else None
        if not first or not first["label"].startswith("Yes"):
            raise RuntimeError("no allow option on this prompt")
        return first["index"]
    if choice == "deny":
        last = options[-1] if options else None
        if not last or not last["label"].startswith("No"):
            raise RuntimeError("no deny option on this prompt")
        return last["index"]
    if choice == "allow-always":
        # Two corroborating phrasings seen so far: a Bash prompt's "don't ask
        # again" and an Edit-box's "... for this session" (real capture,
        # 2026-09-19: "Yes, and allow Claude to edit files in this project's
        # .claude folder for this session"). `startswith("Yes")` still guards
        # against ever matching a "No, and don't ask again"-shaped label.
        for o in options:
            label = o["label"]
            if label.startswith("Yes") and (
                    "don't ask again" in label or "for this session" in label):
                return o["index"]
        raise RuntimeError("no allow-always option on this prompt")
    raise RuntimeError(
        "bad choice: must be 'allow', 'deny', or 'allow-always'")


def _answer_plan_select(pane_id, perm, index, text,
                         machine=herdr_transport.LOCAL_MACHINE):
    """Send `choice: "select"` into an open plan-approval box.

    `index` (1-based) is corroborated against the FRESHLY read `perm`'s own
    options — never a default, never a guess, same discipline as
    `_permission_target_index`. `text`, present only for the "Tell Claude
    what to change" option, is the feedback to submit alongside it. Never
    routed through `_permission_target_index`/its "allow"/"deny"/
    "allow-always" branches — this box's semantics (auto-mode / manual-
    approve / feedback) and its keystroke contract are genuinely different,
    per real-pane findings (throwaway panes wB:p3X/wB:p3Y, 2026-09-20;
    wB:p48, 2026-09-20 — see the dashboard-plan-feedback-approves brief):

    1. Options 1/2 ("Yes, and use auto mode" / "Yes, manually approve
       edits") are an INSTANT submit+dismiss on a bare digit press — same
       one-key shape as a plain allow/deny box, just gated by a different
       validity check (any live option index, not a "Yes"/"No" wording
       test — this box's options aren't allow/deny).
    2. Option 3 ("Tell Claude what to change") is NOT instant: a digit press
       only moves the cursor onto that row and the box stays open. Typing
       must go through `pane send-text` (LITERAL text, no embedded Enter) —
       never `_type_text`'s `pane run`, which embeds one. **`shift+tab` —
       the box's own footer hint — must NEVER be sent here: it does not
       "submit feedback and stay in plan mode" as the hint reads; it
       APPROVES the plan and flips the pane into auto-accept ("auto mode
       on"), confirmed live by AgentBar QA (2026-09-20, reproduced twice)
       and the exact reason this function existed with a `shift+tab` send
       until this fix.** The safe submit is plain `enter`, live-verified on
       throwaway pane wB:p48 (2026-09-20): after digit `3` + `pane
       send-text` + `enter`, the transcript showed "User rejected Claude's
       plan" quoting the ORIGINAL plan, the agent revised it to incorporate
       the typed feedback verbatim, produced a fresh plan-approval box, and
       the pane's footer read "plan mode on" throughout — never "auto mode
       on". This is the same shape as `/api/answer`'s "Other" row (type,
       then Enter) rather than anything box-specific.
    """
    if perm.get("kind") != "plan":
        raise RuntimeError(
            "choice 'select' only applies to a plan-approval box")
    options = perm.get("options") or []
    if not isinstance(index, int) or not any(o["index"] == index for o in options):
        raise RuntimeError(f"no option {index!r} on this prompt")
    is_feedback_option = any(
        o["index"] == index and "Tell Claude what to change" in o["label"]
        for o in options)

    if text is None:
        if is_feedback_option:
            # QA-caught 2026-09-20: the feedback option's digit press only
            # MOVES THE CURSOR, it never submits on its own (see this
            # function's docstring, finding 2) — falling through to the
            # instant-press branch below would send the digit, then poll
            # `_settle_after_permission` for up to 8s against a box that
            # never changes (cursorIndex isn't part of `_same_permission`),
            # finally raising the generic "press did not land", which
            # reads as a keystroke-delivery failure rather than what it
            # actually is: a required field missing from the request.
            raise RuntimeError(
                f"option {index} requires 'text' — it does not submit on "
                "its own")
        _send_keys(pane_id, str(index), machine=machine)
        time.sleep(2)
        result = _settle_after_permission(pane_id, perm, machine=machine)
        return _warn_if_unexpected_auto_mode(pane_id, index, result, machine=machine)

    if not is_feedback_option:
        raise RuntimeError(
            "'text' is only valid on the 'Tell Claude what to change' option")
    clean = _clean_free_text(text)
    _send_keys(pane_id, str(index), machine=machine)
    time.sleep(0.5)
    _pane_run_raw(["pane", "send-text", pane_id, clean], machine=machine)
    time.sleep(1)
    _, perm2 = _read_pane_now(
        pane_id, parser=classify_pane.parse_permission_or_plan_block,
        machine=machine)
    if (perm2 is None or perm2.get("kind") != "plan"
            or perm2.get("title") != perm.get("title")
            or perm2.get("planPath") != perm.get("planPath")):
        raise RuntimeError(
            "plan-approval prompt changed or gone — re-check the pane")
    landed = next((o for o in perm2["options"] if o["index"] == index), None)
    if landed is None or clean[:20] not in landed["label"]:
        raise RuntimeError("typed feedback did not land — re-check the pane")
    # dashboard-plan-feedback-approves brief (2026-09-20): the box's own
    # footer hint ("shift+tab to approve with this feedback") is NOT a safe
    # submit — see this function's docstring. `enter` is the live-verified
    # safe one: it rejects the plan WITH the typed feedback attached and the
    # agent revises while staying in plan mode, exactly like `/api/answer`'s
    # "Other" row. Never send `shift+tab` here again.
    _send_keys(pane_id, "enter", machine=machine)
    time.sleep(2)
    # Settle against perm2 (the VERIFIED post-typing state, option's label
    # already holding the typed text), never the original pre-typing `perm`.
    # QA-caught 2026-09-20: settling against `perm` meant a submit that
    # silently failed to land (box still open, unchanged since perm2) read
    # as "layout differs from perm" — since perm's option label is the
    # ORIGINAL "Tell Claude what to change", not the typed text — and
    # `_same_permission` reported the still-open box as a NEW `next` prompt
    # instead of raising "press did not land". Settling against perm2 makes
    # an unsubmitted box compare EQUAL (raise), matching every other choice.
    result = _settle_after_permission(pane_id, perm2, machine=machine)
    return _warn_if_unexpected_auto_mode(pane_id, index, result, machine=machine)


def _warn_if_unexpected_auto_mode(pane_id, chosen_index, result,
                                   machine=herdr_transport.LOCAL_MACHINE):
    """Ask #2 (dashboard-plan-feedback-approves brief): after ANY plan
    `select`, notice — never silently swallow — a pane that ends up in
    "auto mode on" despite the chosen option NOT being option 1.

    Never re-presses, never raises: this only annotates an already-{ok:true}
    result with a `warning` key, since by this point the keystroke has
    already been sent and settled — there is nothing left to undo, only
    something the caller must be told rather than read as a clean, expected
    "not auto mode" outcome. A read failure here is swallowed (returns
    `result` unchanged) rather than turning a successful send into an
    error — the guard is a bonus signal, not a new way for a good send to
    fail.

    Known gap, disclosed rather than hidden: this only catches the
    IMMEDIATE window `_settle_after_permission` already re-read (a few
    seconds). A plan-approval box that appears LATER — e.g. a revised plan
    Claude writes after this feedback is accepted — can still land in auto
    mode on its own with no further `select` call at all (reproduced live,
    throwaway pane wB:p48, 2026-09-20); no post-send guard on THIS call can
    see that, because it happens after this function has already returned.
    """
    if chosen_index == 1:
        return result
    try:
        lines, _ = _read_pane_now(
            pane_id, parser=classify_pane.parse_permission_or_plan_block,
            machine=machine)
    except RuntimeError:
        return result
    if any(_AUTO_MODE_FOOTER_RE.search(l) for l in lines[-6:]):
        result = dict(result)
        result["warning"] = (
            f"option {chosen_index} was chosen (not auto mode), but the "
            "pane now shows \"auto mode on\" — the plan may have been "
            "approved into auto mode anyway; check the pane before "
            "trusting this as a safe non-auto choice")
    return result


def _settle_after_permission(pane_id, old, machine=herdr_transport.LOCAL_MACHINE):
    """Confirm a single yes/no press landed. Returns {"next": <permission|null>}.

    Simpler than `_settle_after_submit`: a permission box has no review step
    and no multi-question chain to hold for — gone, or a genuinely different
    box, are both success. Re-reads a few times before giving up; never
    re-presses, since a blind resend could act on whatever prompt appears
    next while this one is still settling.
    """
    _, perm = _read_pane_now(
        pane_id, parser=classify_pane.parse_permission_or_plan_block,
        machine=machine)
    for _ in range(4):
        if perm is None or not _same_permission(perm, old):
            return {"next": perm}
        time.sleep(2)
        _, perm = _read_pane_now(
            pane_id, parser=classify_pane.parse_permission_or_plan_block,
            machine=machine)
    # The loop's LAST re-read (done at the tail of its final iteration) is
    # never checked by the loop itself — it only checks the read from the
    # PREVIOUS pass before sleeping again. Re-check it here before giving
    # up, or a press that lands on exactly that final poll reports as failed
    # (QA-caught 2026-09-19: reproduced by a fake pane whose screen only
    # clears on the discarded read). Same fix `_settle_after_submit` already
    # has via its own post-loop check.
    if perm is None or not _same_permission(perm, old):
        return {"next": perm}
    raise RuntimeError("press did not land — re-check the pane")


def answer_pane_permission(pane_id, choice, permission, index=None, text=None):
    """Send a staged allow/deny/allow-always/select into a live permission
    or plan-approval box.

    Same shape as answer_pane_question(): the pane is looked up FRESH,
    everything is re-read fresh, and any failure is raised for the caller to
    turn into a JSON {ok:false} response — never a 500, never a blind
    keystroke. `permission` is the `row.permission` object the UI rendered
    — {title,tool,detail,options,cursorIndex} for a plain permission box,
    additively {kind:"plan",planPath} for a plan-approval box; the live box
    must match it exactly before a key is sent — the dashboard's own feed
    copy can be up to 45s stale, and the human may already have answered
    from the terminal.

    `choice` is "allow"/"deny"/"allow-always" (unchanged — routed through
    `_permission_target_index`, plain permission boxes only) or "select"
    (plan-approval boxes only, routed through `_answer_plan_select`):
    `index` (1-based) picks the option, and `text` — valid only on the
    "Tell Claude what to change" option — is the feedback to submit
    alongside it. `index`/`text` are ignored for every other `choice`.

    `pane_id` may be namespaced (R1) — resolved once here, same as
    answer_pane_question().
    """
    machine, pane_id = herdr_transport.split_pane_key(pane_id, MACHINES)
    try:
        data = herdr_transport.herdr_cmd_json(
            machine, ["pane", "list"], repo_root=REPO_ROOT, machines=MACHINES,
            timeout=10)
    except herdr_transport.HerdrError as e:
        raise RuntimeError(f"herdr pane list failed on {machine}: {e}")
    panes = (data.get("result") or {}).get("panes") or []
    if not any(p.get("pane_id") == pane_id for p in panes):
        raise RuntimeError(f"pane {pane_id} not found — likely closed")

    _, perm = _read_pane_now(
        pane_id, parser=classify_pane.parse_permission_or_plan_block,
        machine=machine)
    if perm is None or not _same_permission(perm, permission or {}):
        raise RuntimeError(
            "permission prompt changed or gone — re-check the pane")

    if choice == "select":
        return _answer_plan_select(pane_id, perm, index, text, machine=machine)

    target = _permission_target_index(perm, choice)
    _send_keys(pane_id, str(target), machine=machine)
    time.sleep(2)
    return _settle_after_permission(pane_id, perm, machine=machine)


# ── v4 reach, read side: the history panel and the raw screen ──
#
# Both are ON-DEMAND reads for one row the PO opened, and they are the only
# GETs in this server that are not free.
#
# /api/pane/screen shells out to `herdr pane read` SYNCHRONOUSLY (~2.5s,
# 15s timeout) on the request thread. It must NEVER be called from the 2s SSE
# tick, from the state cache, or from any polling loop: at N live panes a
# polled version costs N blocking subprocesses per interval, and the existing
# background paneScreen feed (chief_dashboard_feeds.py, 15s, classification
# only) already covers the always-on case. If the UI ever wants live screen
# text, the answer is a longer interval on an explicit user action — not
# moving this call into the tick.
#
# Refusal convention matches the rest of the API: a malformed request is a
# 400, an operational failure (pane gone, herdr angry, timeout) is a 200 with
# ok:false and a plain reason the UI renders verbatim — the PO needs to read
# WHY the screen is blank, and a 500 would only show a status code.

#: Screen-read bounds. 100 = the measured default (see _ANSWER_READ_LINES);
#: 400 caps how much a single blocking read can cost.
PANE_SCREEN_DEFAULT_LINES = _ANSWER_READ_LINES
PANE_SCREEN_MAX_LINES = 400

#: History bounds, mirrored from BoardStore.session_action_history.
HISTORY_DEFAULT_LIMIT = 50
HISTORY_MAX_LIMIT = 200


def _qs_int(qs, name, default, low, high):
    """One query-string integer, clamped. A junk value falls back to the
    default rather than 400ing: these are display bounds, not the request's
    subject, and refusing the whole read over `lines=abc` would leave the
    panel empty for no reason the PO could act on."""
    raw = (qs.get(name) or [None])[0]
    if raw is None or str(raw).strip() == "":
        return default
    try:
        return max(low, min(int(str(raw).strip()), high))
    except (TypeError, ValueError):
        return default


def handle_session_history(qs):
    """GET /api/session/history?rowId=&limit= -> (payload, http_status).

    Every logged action for one row, newest first, FAILED attempts included —
    the panel's job is an honest timeline, and it gates nothing.
    """
    row_id = (qs.get("rowId") or [None])[0]
    if not row_id or not row_id.strip():
        return {"ok": False, "error": "missing rowId"}, 400
    row_id = row_id.strip()
    limit = _qs_int(qs, "limit", HISTORY_DEFAULT_LIMIT, 1, HISTORY_MAX_LIMIT)
    try:
        entries = STORE.session_action_history(row_id, limit)
    except Exception as e:
        return {"ok": False, "error": str(e)}, 200
    return {"ok": True, "rowId": row_id, "entries": entries}, 200


# ── Phase 1b (agentbar-mobile-web plan): transcript latest message + plan
# file, machine-aware ──
#
# AgentBar's own SessionTranscriptReader/PlanFileReader
# (Sources/AgentBar/Answer/Transcript/, Sources/AgentBar/Permission/Plan/)
# read straight off THIS Mac's local disk — they cannot see a session
# running on a configured remote machine (the Air), and a phone has no
# local disk at all (AGENTS.md gotchas 9 and 13). These two endpoints port
# the same read logic (session_transcript.py) and route it through
# chief_dashboard_herdr's one ssh door for a remote row, so the web/phone
# UI (and eventually Mac AgentBar) can ask the dashboard instead of reading
# a file directly.

_CLAUDE_PROJECTS_ROOT = os.path.expanduser("~/.claude/projects")
_REMOTE_TAIL_TIMEOUT_SEC = 20
_REMOTE_PLAN_READ_TIMEOUT_SEC = 15


def _agent_for_row(row_id):
    """The live `computed.agents[]` entry for one board row id, or None —
    same resolution `_handle_reach_action` uses (resolve_agent_row_id)."""
    state = get_full_state()
    agents = state.get("computed", {}).get("agents") or []
    return next((a for a in agents if resolve_agent_row_id(a) == row_id), None)


def _local_tail_reader(session_id):
    """A `read_window` callback (see session_transcript.latest_message_from_tail
    / .pending_question_form_from_tail) backed by this Mac's own disk."""
    def read_window(window_bytes):
        path = session_transcript.find_local_transcript(
            session_id, _CLAUDE_PROJECTS_ROOT)
        if path is None:
            return None
        result = session_transcript.read_local_tail(path, window_bytes)
        if result is None:
            return None
        data, starts_at_file_start, _size = result
        return data, starts_at_file_start
    return read_window


def _remote_tail_reader(machine, session_id, errors):
    """Same `read_window` shape, over ssh (chief_dashboard_herdr's one
    door). Memoized per window size: the message scan and the pending-
    question scan each walk the same growing window list, and without this
    a single request could cost up to 6 ssh round trips instead of at most
    3. Any ssh failure is recorded into `errors` (the caller's list) and
    read as "nothing at this window" rather than raised — a transient ssh
    hiccup on the FIRST (smallest) window must not stop a wider retry."""
    cache = {}

    def read_window(window_bytes):
        if window_bytes in cache:
            return cache[window_bytes]
        script = session_transcript.remote_tail_script(session_id, window_bytes)
        try:
            out = herdr_transport.remote_shell_text(
                machine, script, repo_root=REPO_ROOT, machines=MACHINES,
                timeout=_REMOTE_TAIL_TIMEOUT_SEC)
        except herdr_transport.HerdrError as e:
            errors.append(str(e))
            cache[window_bytes] = None
            return None
        result = session_transcript.parse_remote_tail_reply(out)
        cache[window_bytes] = result
        return result
    return read_window


def handle_session_latest(qs):
    """GET /api/session/latest?rowId= -> (payload, http_status).

    {ok, rowId, machine, latestMessage, pendingQuestion} — the same two
    things AgentBar's Answer card reads from local disk: the last assistant
    text, and (when the agent is sitting on an unanswered multi-question
    AskUserQuestion form) the pending form's questions/options, ported from
    SessionTranscriptReader/AskUserQuestionExtractor (see session_transcript.py's
    module docstring for exact, documented differences from the Swift
    originals). `machine` is "local" or a configured remote machine name;
    reads for a remote row go over the same ssh door every other machine
    call in this server uses (chief_dashboard_herdr), not a new one.

    A row with no live agent, or a live agent with no Claude session
    (opencode/codex/gemini, or a status-only Claude Desktop/CLI row that
    has since ended) reads `ok:false` with a plain reason — never a 400,
    since "not live right now" is an operational fact, not a bad request.
    """
    row_id = (qs.get("rowId") or [None])[0]
    if not row_id or not row_id.strip():
        return {"ok": False, "error": "missing rowId"}, 400
    row_id = row_id.strip()
    agent = _agent_for_row(row_id)
    if agent is None:
        return {"ok": False, "error": f"row {row_id} is not live"}, 200
    session_id = agent.get("agentSession")
    if not session_id:
        return {"ok": False,
                "error": f"row {row_id} has no Claude session transcript"}, 200
    if not session_transcript.is_safe_session_id(session_id):
        return {"ok": False, "error": "bad session id"}, 400
    machine = agent.get("machine") or herdr_transport.LOCAL_MACHINE

    errors = []
    read_window = (_local_tail_reader(session_id) if machine == herdr_transport.LOCAL_MACHINE
                   else _remote_tail_reader(machine, session_id, errors))
    scan = session_transcript.latest_message_from_tail(read_window)
    pending = session_transcript.pending_question_form_from_tail(read_window)
    if scan["latestMessage"] is None and pending is None and errors:
        # Nothing at all came back AND at least one window attempt failed
        # over ssh — report the ssh failure rather than a silent "no
        # message", so a dead Air reads as "unreachable", not "quiet".
        return {"ok": False, "error": errors[0]}, 200
    return {"ok": True, "rowId": row_id, "machine": machine,
            "latestMessage": scan["latestMessage"],
            "pendingQuestion": pending}, 200


def _current_plan_path(pane_id, row_id):
    """Reads the pane FRESH (same `_read_pane_now` door every send-path
    handler uses) and returns (planPath, resolvedMachine, error). error is
    a plain-English reason for the UI when the row has nothing to show —
    no pane, unreachable, or not currently sitting on a plan-approval box."""
    if not pane_id:
        return None, None, f"row {row_id} has no pane — nothing to read"
    try:
        machine, raw_pane_id = herdr_transport.split_pane_key(pane_id, MACHINES)
    except herdr_transport.HerdrError as e:
        return None, None, f"could not resolve pane machine: {e}"
    try:
        _lines, prompt = _read_pane_now(
            raw_pane_id, parser=classify_pane.parse_permission_or_plan_block,
            machine=machine)
    except Exception as e:
        return None, machine, f"could not read pane {pane_id} fresh — {e}"
    if not prompt or prompt.get("kind") != "plan":
        return None, machine, (f"row {row_id} is not showing a plan approval "
                               "box right now")
    return prompt.get("planPath"), machine, None


def handle_session_plan(qs):
    """GET /api/session/plan?rowId= -> (payload, http_status).

    {ok, rowId, machine, planPath, plan:{status, text?, truncated?, reason?}}
    — ports PlanFileReader (Sources/AgentBar/Permission/Plan/PlanFileReader.swift)
    for a row currently blocked on a plan-approval box, reading the plan
    file from whichever machine the row's pane actually lives on instead of
    only this Mac's disk (AGENTS.md gotcha 13's deferred item). `plan.status`
    is one of "noPath" (box names no file), "unreadable" (reason given,
    never blocks approval), or "text" (plan.text, plan.truncated at 200KB —
    same cap as the Swift reader).
    """
    row_id = (qs.get("rowId") or [None])[0]
    if not row_id or not row_id.strip():
        return {"ok": False, "error": "missing rowId"}, 400
    row_id = row_id.strip()
    agent = _agent_for_row(row_id)
    if agent is None:
        return {"ok": False, "error": f"row {row_id} is not live"}, 200
    plan_path, machine, err = _current_plan_path(agent.get("paneId"), row_id)
    machine = machine or agent.get("machine") or herdr_transport.LOCAL_MACHINE
    if err:
        return {"ok": False, "error": err}, 200
    if not plan_path:
        return {"ok": True, "rowId": row_id, "machine": machine,
                "planPath": None, "plan": {"status": "noPath"}}, 200

    if machine == herdr_transport.LOCAL_MACHINE:
        plan = session_transcript.read_local_plan_file(plan_path)
    else:
        script = session_transcript.remote_plan_file_script(plan_path)
        try:
            out = herdr_transport.remote_shell_text(
                machine, script, repo_root=REPO_ROOT, machines=MACHINES,
                timeout=_REMOTE_PLAN_READ_TIMEOUT_SEC)
        except herdr_transport.HerdrError as e:
            return {"ok": False, "error": str(e)}, 200
        plan = session_transcript.parse_remote_plan_file_reply(out, plan_path)
    return {"ok": True, "rowId": row_id, "machine": machine,
            "planPath": plan_path, "plan": plan}, 200


def _plain_herdr_error(exc):
    """A herdr failure as one sentence the PO can read.

    _pane_run_raw surfaces herdr's stderr verbatim, and herdr reports errors
    as JSON (`{"error":{"code":"pane_not_found","message":"pane w9:pZ not
    found"},...}`). This panel renders the reason as-is, so the blob would be
    what the human sees; unwrap it to the message and keep the raw string
    whenever it is not that shape (a timeout, a crash, a future format).
    """
    raw = str(exc)
    start = raw.find("{")
    if start != -1:
        try:
            blob = json.loads(raw[start:])
            msg = ((blob or {}).get("error") or {}).get("message")
            if msg:
                return msg
        except (ValueError, AttributeError):
            pass
    return raw


def handle_pane_screen(qs):
    """GET /api/pane/screen?paneId=&lines= -> (payload, http_status).

    BLOCKING (~2.5s) — see the section comment above: on demand only.

    `readTs` is on EVERY response, failures included: the panel labels the
    screen with its age, and an error with no timestamp cannot be aged — the
    PO would not know whether a `pane not found` is from this click or from a
    stale render. On a failure it is the moment the attempt STARTED, which is
    the only timestamp a timeout has; on success it is the moment the text
    came back.
    """
    attempted = time.time()
    pane_id = (qs.get("paneId") or [None])[0]
    if not pane_id or not pane_id.strip():
        return {"ok": False, "error": "missing paneId",
                "readTs": attempted}, 400
    pane_id = pane_id.strip()
    read_lines = _qs_int(qs, "lines", PANE_SCREEN_DEFAULT_LINES,
                         1, PANE_SCREEN_MAX_LINES)
    try:
        machine, raw_pane_id = herdr_transport.split_pane_key(pane_id, MACHINES)
    except herdr_transport.HerdrError as e:
        return {"ok": False, "paneId": pane_id,
                "error": _plain_herdr_error(e),
                "readTs": attempted}, 200
    try:
        # Reuses the send path's reader on purpose — one herdr invocation in
        # this file, so a flag or source change cannot fix one caller and
        # leave the other reading a different screen. Must split the pane
        # key first (same as every other handler in this file) — a
        # namespaced id passed whole to _read_pane_now's "local" default
        # silently reads the WRONG pane (or none) on the local machine
        # instead of the real remote one.
        lines, _question = _read_pane_now(raw_pane_id, read_lines=read_lines,
                                          machine=machine)
    except subprocess.TimeoutExpired:
        return {"ok": False,
                "paneId": pane_id,
                "error": f"pane {pane_id} did not answer within 15s — it may "
                         "be wedged",
                "readTs": attempted}, 200
    except Exception as e:
        return {"ok": False, "paneId": pane_id,
                "error": _plain_herdr_error(e),
                "readTs": attempted}, 200
    return {"ok": True, "paneId": pane_id,
            "lines": lines[-read_lines:], "readTs": time.time()}, 200


# ── HTML page (self-contained, no build step, polls /api/state + subscribes
#    to /api/events for push updates) ──

PAGE_HTML = r"""<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>Chief Dashboard</title>
<style>
  :root {
    --bg: #0b0e14; --panel: #121620; --border: #262b38; --text: #d8dee9;
    --dim: #6b7280; --red: #ef4444; --amber: #f59e0b; --green: #22c55e;
    --blue: #3b82f6; --mono: 'Avenir', 'Avenir Next', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--text); font-family: var(--mono); font-size: 13px; }
  header { display:flex; justify-content:space-between; align-items:center; padding:10px 16px;
    border-bottom:1px solid var(--border); position:sticky; top:0; background:var(--bg); z-index:10; }
  header h1 { font-size:14px; margin:0; letter-spacing:0.5px; }
  header .meta { color:var(--dim); }
  .banner { background:#3a0d0d; border:2px solid var(--red); color:#ffb4b4; padding:10px 16px;
    margin:10px 16px; border-radius:4px; font-weight:bold; }
  .banner .sub { font-weight:normal; color:#ffcccc; font-size:12px; display:block; margin-top:4px; }
  .feedstrip { display:flex; gap:16px; padding:4px 16px; color:var(--dim); flex-wrap:wrap; }
  .feedstrip span.ok { color:var(--green); }
  .feedstrip span.bad { color:var(--red); font-weight:bold; }
  section { margin:12px 16px; border:1px solid var(--border); border-radius:6px; background:var(--panel); }
  section > h2 { font-size:12px; text-transform:uppercase; letter-spacing:1px; margin:0; padding:8px 12px;
    border-bottom:1px solid var(--border); color:#9aa4b2; display:flex; justify-content:space-between; }
  table { width:100%; border-collapse:collapse; }
  th, td { text-align:left; padding:5px 12px; border-bottom:1px solid #1b2030; white-space:nowrap; }
  th { color:var(--dim); font-weight:normal; font-size:11px; text-transform:uppercase; }
  tr:hover td { background:#171c28; }
  td.wrap, th.wrap { white-space:normal; }
  .badge { padding:1px 6px; border-radius:3px; font-size:11px; }
  .st-blocked { color:var(--red); font-weight:bold; }
  .st-working { color:var(--green); }
  .st-idle { color:var(--dim); }
  .st-parked { color:var(--blue); }
  .st-unknown { color:var(--amber); }
  .disagree { background:#3a2a0d; color:var(--amber); font-weight:bold; padding:1px 5px; border-radius:3px;}
  .agree { color:var(--dim); }
  .empty { color:var(--dim); padding:12px; font-style:italic; }
  .small { color:var(--dim); font-size:11px; }
  a.link { color: var(--blue); text-decoration:none; }
  .needsyou-row td { background:#1a1210; }
  /* Three kinds, all urgent by construction: a pane stopped at a prompt.
     Red = go and press (permission, or the list is blind); blue = answerable
     here (a picker). The amber gone/stalled and dim done vocabularies went
     with the ranks that used them (2026-09-06). */
  .kind-blocked, .kind-feed-broken { color: var(--red); font-weight:bold; }
  .kind-question { color: var(--blue); font-weight:bold; }
  footer { padding:16px; color:var(--dim); text-align:center; font-size:11px; }
  tr[data-pane] { cursor:pointer; }
  tr[data-pane]:hover td { background:#1c2436; }
  #toast { position:fixed; bottom:16px; right:16px; padding:8px 14px; border-radius:4px;
    font-family:var(--mono); font-size:12px; z-index:100; border:1px solid; }
  .qbox { background:#101827; border-top:1px dashed var(--border); padding:8px 12px; }
  .qbox .qq { color:var(--text); margin-bottom:6px; white-space:normal; }
  .qbox .qq .qt { color:var(--dim); font-size:11px; }
  .qopt { display:block; margin:2px 0; padding:3px 10px; border:1px solid var(--border);
    border-radius:4px; background:#0b0e14; color:var(--text); font-family:var(--mono); font-size:12px; cursor:pointer; }
  .qopt:hover { border-color:var(--blue); }
  .qopt.staged { border-color:var(--green); background:#123a1d; color:#fff; }
  .qopt .tick { color:var(--green); }
  .qopt .qdesc { display:block; font-weight:normal; color:var(--dim); font-size:11px; white-space:normal; max-width:280px; }
  .qbox .qctx { color:var(--dim); font-size:11px; font-style:italic; }
  .qother { margin:6px 0; }
  .qother input { width:60%; padding:4px 8px; background:#0b0e14; color:var(--text);
    border:1px solid var(--border); border-radius:4px; font-family:var(--mono); font-size:12px; }
  .qsend { margin-left:8px; padding:4px 14px; border:1px solid var(--green); border-radius:4px;
    background:#123a1d; color:#fff; font-family:var(--mono); font-size:12px; cursor:pointer; }
  .qsend:disabled { opacity:.4; cursor:default; }
  .qhint { color:var(--dim); font-size:11px; margin-top:4px; }
  .qexpand { color:var(--blue); cursor:pointer; text-decoration:underline; }
</style>
</head>
<body>
<header>
  <h1>CHIEF DASHBOARD &middot; Stage 1</h1>
  <div class="meta" id="clock">connecting&hellip;</div>
</header>

<div id="banners"></div>
<div class="feedstrip" id="feedstrip"></div>

<section>
  <h2><span>NEEDS YOU</span><span id="needsyou-count" class="small"></span></h2>
  <div class="small" style="padding:6px 12px; color:var(--dim);">
    Only panes STOPPED, waiting for you to type.
    <span class="kind-question">QUESTION</span> a picker you can answer right here (expand, stage, Confirm) &mdash;
    a just-opened one first shows as a preview with no buttons until the sweep parses it &middot;
    <span class="kind-blocked">BLOCKED</span> a permission request; go to the pane and press &middot;
    <span class="kind-feed-broken">FEED BROKEN</span> this list cannot see, so an empty page below it proves nothing.
    Finished, quiet, crashed and vanished workers are NOT here &mdash; nothing is stopped waiting for a keystroke,
    so they live in BOARD with their last line. Click a row to focus its pane in herdr.
  </div>
  <div id="needsyou-body"></div>
</section>

<section>
  <h2><span>AGENTS</span><span id="agents-count" class="small"></span></h2>
  <div class="small" style="padding:6px 12px; color:var(--dim);">
    Three views of one pane. STATE = what the worker pushed (right about <em>working</em>, and it was the
    source of the old false-<em>blocked</em> flood). SCREEN = what the pane actually shows, classified the same
    way the chief's own CLI does &mdash; believed over the other two for blocked-vs-finished.
    HERDR = the terminal manager's screen guess, shown for comparison only, never believed.
    Click a row to focus its pane in herdr.
  </div>
  <div id="agents-body"></div>
</section>

<section>
  <h2><span>GIT / BRANCHES</span><span id="git-count" class="small"></span></h2>
  <div id="git-body"></div>
</section>

<section>
  <h2><span>WORKTREES</span><span id="worktrees-count" class="small"></span></h2>
  <div id="worktrees-body"></div>
</section>

<footer>
  Read-only except two buttons: row click focuses a pane, and a QUESTION row's
  Confirm sends one staged answer into that pane. Nothing here can push, tag, deploy, merge, or delete anything.
  Raw JSON: <a class="link" href="/api/state">/api/state</a>
</footer>

<script>
function esc(s) { return (s === null || s === undefined) ? '' : String(s).replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])); }
function escAttr(s) { return esc(s).replace(/["']/g, c => ({'"':'&quot;',"'":'&#39;'}[c])); }
function fmtAge(sec) {
  if (sec === null || sec === undefined) return '—';
  sec = Math.round(sec);
  if (sec < 60) return sec + 's';
  if (sec < 3600) return Math.round(sec/60) + 'm';
  if (sec < 86400) return Math.round(sec/3600) + 'h';
  return Math.round(sec/86400) + 'd';
}
function screenClass(s) {
  if (s === 'NEEDS_HUMAN' || s === 'CRASHED' || s === 'NEEDS_LOGIN') return 'st-blocked';
  if (s === 'ACTIVE') return 'st-working';
  if (s === 'WAITING_ON_BACKGROUND') return 'st-parked';
  if (s === 'WAITING') return 'st-idle';
  return 'st-unknown';
}
function stClass(s) {
  if (s === 'blocked') return 'st-blocked';
  if (s === 'working') return 'st-working';
  if (s === 'idle') return 'st-idle';
  return 'st-unknown';
}
// Top-level (was nested inside render() until 2026-09-04, which made
// connect() throw before the first fetch and left the page permanently at
// "connecting…"). Notification needs a user gesture before the browser
// grants it — requested on load and on every click until decided.
function ensureNotiPerm() {
  try {
    if (window.Notification && Notification.permission === 'default') {
      Notification.requestPermission().catch(() => {});
    }
  } catch (e) {}
}

function render(state) {
  _lastState = state;
  document.getElementById('clock').textContent =
    new Date(state.serverTimeTs * 1000).toLocaleTimeString() + ' · live';

  // Broken-feed banners
  const banners = document.getElementById('banners');
  banners.innerHTML = '';
  const strip = document.getElementById('feedstrip');
  strip.innerHTML = '';
  const order = ['hookCache','herdr','paneScreen','paneTick','gitHealth','board'];
  order.forEach(name => {
    const f = state.feeds[name];
    const span = document.createElement('span');
    span.className = f.broken ? 'bad' : 'ok';
    span.textContent = name + ' ' +
      (f.warming ? '◌ warming up' : (f.broken ? '✖ BROKEN ' : '●') + ' ' + fmtAge(f.ageSec) + ' ago');
    strip.appendChild(span);
    if (f.broken && !f.warming) {
      const b = document.createElement('div');
      b.className = 'banner';
      b.innerHTML = '⛔ FEED BROKEN — ' + esc(name) +
        '<span class="sub">' + (f.lastSuccessTs ? ('last good ' + fmtAge(f.ageSec) + ' ago') : 'never succeeded') +
        (f.error ? (' — ' + esc(f.error)) : '') + '</span>';
      banners.appendChild(b);
    }
  });

  // NEEDS YOU — question-row staging lives in qstate (keyed by paneId) so
  // the 2s re-render can rebuild the table without losing staged picks.
  // Typing into an Other input skips that tick's rebuild (focus preservation).
  const qdata = window._qdata || (window._qdata = {});
  const qstate = window._qstate || (window._qstate = {});
  // Panes the user already advanced past the feed on (Confirm returned a
  // queued Q2): the feed still carries stale Q1 for up to 45s — never let it
  // overwrite the fresher box until it catches up to the same question.
  const qadv = window._qadv || (window._qadv = {});
  function qst(paneId) {
    if (!qstate[paneId]) qstate[paneId] = {expanded: true, selected: [], text: ''};
    if (qstate[paneId].expanded === undefined) qstate[paneId].expanded = true;
    return qstate[paneId];
  }
  // Desktop + sound alert for NEW questions only (keyed by pane+question, so
  // the 2s re-render never re-fires). Notification needs a user gesture
  // before the browser grants it — requested on load and on every click
  // until decided. Sound is a self-contained WebAudio two-tone (no files).
  const notiSeen = window._notiSeen || (window._notiSeen = {});
  function playAlert() {
    try {
      const AC = window.AudioContext || window.webkitAudioContext;
      if (!AC) return;
      const ctx = playAlert._ctx || (playAlert._ctx = new AC());
      if (ctx.state === 'suspended') ctx.resume().catch(() => {});
      [660, 880].forEach((f, k) => {
        const o = ctx.createOscillator(), g = ctx.createGain();
        o.connect(g); g.connect(ctx.destination);
        o.frequency.value = f;
        const t = ctx.currentTime + k * 0.22;
        g.gain.setValueAtTime(0.0001, t);
        g.gain.exponentialRampToValueAtTime(0.3, t + 0.03);
        g.gain.exponentialRampToValueAtTime(0.0001, t + 0.2);
        o.start(t); o.stop(t + 0.22);
      });
    } catch (e) {}
  }
  function alertNewQuestions(ny) {
    let fired = false;
    ny.forEach(i => {
      if (i.kind !== 'question' || !i.question || !i.paneId) return;
      const key = i.paneId + ' :: ' + i.question.title + ' :: ' + i.question.question;
      if (notiSeen[i.paneId] === key) return;
      notiSeen[i.paneId] = key;
      fired = true;
      playAlert();
      try {
        if (window.Notification && Notification.permission === 'granted') {
          new Notification('QUESTION needs you: ' + i.label, {
            body: i.question.question + ' (' + i.question.options.filter(o => !o.other).length + ' options)',
            tag: i.paneId,
          });
        }
      } catch (e) {}
    });
    return fired;
  }
  function qoptDesc(o) { return o.desc || o.description || ''; }
  function qboxHtml(i) {
    const q = i.question;
    if (!q) return '';
    const st = qst(i.paneId);
    if (st.expanded === false) {
      return '<div class="qbox"><span class="qexpand" data-qact="expand">answer here &#9656;</span></div>';
    }
    let h = '<div class="qbox"><div class="qq"><span class="qt">' + esc(q.title) + ' &middot; ' +
      (q.multi ? 'pick any' : 'pick one') + '</span> <span class="qexpand" data-qact="collapse" title="collapse">&#9652;</span><br>' +
      (q.context ? '<span class="qctx">&ldquo;' + esc(q.context) + '&rdquo;</span><br>' : '') + esc(q.question) + '</div><div>';
    q.options.forEach(o => {
      if (o.other) return;  // the free-text row is the input below, not a button
      const cls = st.selected.indexOf(o.index) >= 0 ? 'qopt staged' : 'qopt';
      h += '<button class="' + cls + '" data-qact="opt" data-idx="' + o.index + '"'
        + (qoptDesc(o) ? ' title="' + escAttr(qoptDesc(o)) + '"' : '') + '>' +
        esc(o.index + '. ' + o.label) + (o.checked ? ' <span class="tick">&#10003;</span>' : '') +
        (qoptDesc(o) ? ' <span class="qdesc">' + esc(qoptDesc(o)) + '</span>' : '') + '</button>';
    });
    h += '</div><div class="qother">Other: <input data-qtext="1" placeholder="type free text instead" value="' +
      escAttr(st.text) + '"> <button class="qsend" data-qact="send" data-multi="' + (q.multi ? '1' : '0') + '"' +
      ((st.selected.length || st.text.trim()) ? '' : ' disabled') + '>Confirm &amp; Send</button></div>';
    h += '<div class="qhint">Clicking stages only — nothing is sent until Confirm. ' +
      'Free text replaces option picks. The server re-reads the pane fresh and refuses if the question moved on.</div></div>';
    return h;
  }
  const ny = state.computed.needsYou;
  document.getElementById('needsyou-count').textContent = ny.length;
  alertNewQuestions(ny);
  const nyBody = document.getElementById('needsyou-body');
  const typingNow = nyBody.contains(document.activeElement) &&
    document.activeElement && document.activeElement.tagName === 'INPUT';
  if (ny.length === 0) {
    Object.keys(qdata).forEach(k => delete qdata[k]);
    nyBody.innerHTML = '<div class="empty">nothing needs you right now</div>';
  } else if (!typingNow) {
    let html = '<table><tbody>';
    ny.forEach(i => {
      const paneAttr = i.paneId ? (' data-pane="' + esc(i.paneId) + '" data-label="' + esc(i.label) + '"') : '';
      html += '<tr class="needsyou-row"' + paneAttr + '><td class="kind-' + esc(i.kind) + '">' + esc(i.kind.toUpperCase()) + '</td>' +
        '<td class="small">' + fmtAge(i.sinceSec) + '</td>' +
        '<td>' + esc(i.label) + '</td>' +
        '<td class="small">' + esc(i.paneId || '') + '</td>' +
        '<td class="wrap">' + esc(i.detail) + '</td></tr>';
      if (i.kind === 'question' && i.question && i.paneId) {
        if (qadv[i.paneId] && qdata[i.paneId] &&
            i.question.title === qdata[i.paneId].title &&
            i.question.question === qdata[i.paneId].question) {
          delete qadv[i.paneId];  // feed caught up to the advanced box
        }
        if (!qadv[i.paneId]) qdata[i.paneId] = i.question;
        // data-pane on the qbox row too: the box's own buttons need the pane
        // id, and the qbox click handler returns before focus can fire, so a
        // stray click here still cannot focus the pane.
        html += '<tr class="needsyou-row"' + paneAttr + '><td></td><td colspan="4" style="padding:0">' + qboxHtml(i) + '</td></tr>';
      }
    });
    html += '</tbody></table>';
    nyBody.innerHTML = html;
  }

  // AGENTS
  const agents = state.computed.agents;
  document.getElementById('agents-count').textContent =
    agents.length + ' panes · ' + state.computed.disagreementCount + ' hook/herdr disagreements' +
    (state.computed.residueCount ? (' · ' + state.computed.residueCount + ' stale cache files hidden') : '');
  const agBody = document.getElementById('agents-body');
  let ah = '<table><thead><tr><th>STATE</th><th>SCREEN</th><th>LABEL</th><th>PANE</th><th>SINCE</th><th class="wrap">CWD</th><th>HERDR</th></tr></thead><tbody>';
  agents.forEach(a => {
    const paneAttr = a.paneId ? (' data-pane="' + esc(a.paneId) + '" data-label="' + esc(a.label) + '"') : '';
    ah += '<tr' + paneAttr + '>' +
      '<td class="' + stClass(a.hookState) + '">' + esc(a.hookState || (a.hasHookData ? '?' : 'no data')) + '</td>' +
      '<td class="' + screenClass(a.screenState) + '">' + esc(a.screenState || '—') + '</td>' +
      '<td>' + esc(a.label) + (a.focused ? ' •' : '') + '</td>' +
      '<td class="small">' + esc(a.paneId || a.paneIdSanitized || '') + '</td>' +
      '<td class="small">' + fmtAge(a.hookSinceSec) + '</td>' +
      '<td class="wrap small">' + esc(a.cwd || '') + '</td>' +
      '<td class="' + (a.disagree ? 'disagree' : 'agree') + '">' + esc(a.herdrStatus || '—') + (a.disagree ? ' ⚠' : '') + '</td>' +
      '</tr>';
  });
  ah += '</tbody></table>';
  agBody.innerHTML = agents.length ? ah : '<div class="empty">no agent data yet</div>';

  // GIT
  const git = state.computed.git;
  const gitBody = document.getElementById('git-body');
  if (!git) {
    gitBody.innerHTML = '<div class="empty">git feed has no data yet</div>';
    document.getElementById('git-count').textContent = '';
  } else {
    document.getElementById('git-count').textContent =
      git.repos.length + ' repos · ' + git.snapshotsCount + ' snapshots';
    let gh = '<table><thead><tr><th>REPO</th><th>BRANCHES</th><th class="wrap">BY STATUS</th></tr></thead><tbody>';
    git.repos.forEach(r => {
      const statusStr = Object.entries(r.byStatus).map(([k,v]) => k + ':' + v).join('  ');
      gh += '<tr><td>' + esc(r.canon) + '</td><td>' + r.branchCount + '</td><td class="wrap small">' + esc(statusStr) + '</td></tr>';
    });
    gh += '</tbody></table>';
    gh += '<div class="small" style="padding:8px 12px;">SAFE TO DELETE: ' + git.safeToDelete.length +
      ' &nbsp; WIP STALE: ' + git.wipStale.length + ' &nbsp; REVIEW OLD (14d+): ' + git.reviewOld.length + '</div>';
    if (git.safeToDelete.length) {
      gh += '<table><tbody>';
      git.safeToDelete.slice(0, 15).forEach(b => {
        gh += '<tr><td class="small">' + esc(b.rel) + '</td><td class="small">' + esc(b.branch) + '</td></tr>';
      });
      gh += '</tbody></table>';
      if (git.safeToDelete.length > 15) gh += '<div class="small" style="padding:4px 12px;">+' + (git.safeToDelete.length-15) + ' more</div>';
    }
    gh += '<div class="small" style="padding:8px 12px; color:var(--amber);">⚑ "merged" is ancestry, not shipped — fe squash-merges via PR, so a shipped branch can read UNMERGED. Cross-check before deleting anything.</div>';
    gitBody.innerHTML = gh;
  }

  // WORKTREES
  const wts = git ? git.worktrees : [];
  document.getElementById('worktrees-count').textContent = wts ? wts.length : '';
  const wtBody = document.getElementById('worktrees-body');
  if (!wts || wts.length === 0) {
    wtBody.innerHTML = '<div class="empty">no worktree data yet</div>';
  } else {
    let wh = '<table><thead><tr><th>BRANCH</th><th>REPO</th><th>AGE</th><th>AHEAD</th><th>DIRTY</th><th>OWNER STATE</th></tr></thead><tbody>';
    wts.forEach(w => {
      wh += '<tr' + (w.stale ? ' style="color:var(--amber)"' : '') + '>' +
        '<td>' + esc(w.branch) + (w.stale ? ' ⚠ stale' : '') + (w.foreignLocation ? ' ⚠ foreign' : '') + '</td>' +
        '<td class="small">' + esc(w.repo) + '</td>' +
        '<td class="small">' + esc(w.ageDays) + 'd</td>' +
        '<td class="small">' + esc(w.ahead) + '</td>' +
        '<td class="small">' + (w.dirty ? esc(w.dirty) : '0') + '</td>' +
        '<td class="small ' + stClass(w.ownerAgentStatus) + '">' + esc(w.ownerAgentStatus || (w.owner ? 'no live agent' : '—')) + '</td>' +
        '</tr>';
    });
    wh += '</tbody></table>';
    wtBody.innerHTML = wh;
  }
}

function showToast(msg, ok) {
  let t = document.getElementById('toast');
  if (!t) { t = document.createElement('div'); t.id = 'toast'; document.body.appendChild(t); }
  t.textContent = msg;
  t.style.background = ok ? '#123a1d' : '#3a0d0d';
  t.style.color = ok ? 'var(--green)' : 'var(--red)';
  t.style.borderColor = ok ? 'var(--green)' : 'var(--red)';
  clearTimeout(t._hideTimer);
  t._hideTimer = setTimeout(() => t.remove(), 2500);
}
function focusPane(paneId, label) {
  fetch('/api/focus', {
    method: 'POST', headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({paneId}),
  }).then(r => r.json()).then(res => {
    showToast(res.ok ? ('focused: ' + (label || paneId)) : ('focus failed: ' + (res.error || '?')), !!res.ok);
  }).catch(e => showToast('focus failed: ' + e, false));
}
document.addEventListener('input', (ev) => {
  const inp = ev.target.closest ? ev.target.closest('[data-qtext]') : null;
  if (!inp) return;
  const row = ev.target.closest('[data-pane]');
  if (!row) return;
  const st = (window._qstate || {})[row.getAttribute('data-pane')];
  if (!st) return;
  st.text = inp.value;
  const qrow = inp.closest('tr');
  const btn = qrow ? qrow.querySelector('[data-qact="send"]') : null;
  if (btn) btn.disabled = !(st.selected.length || st.text.trim());
});
document.addEventListener('click', (ev) => {
  ensureNotiPerm();  // user gesture: the moment the browser may grant it
  const qb = ev.target.closest ? ev.target.closest('.qbox') : null;
  if (qb) {
    // Inside a question box: stage/expand/confirm — NEVER focus the pane.
    const row = ev.target.closest('[data-pane]');
    const paneId = row ? row.getAttribute('data-pane') : null;
    const q = (window._qdata || {})[paneId];
    const st = (window._qstate || {})[paneId];
    if (!q || !st || !paneId) return;
    const actEl = ev.target.closest('[data-qact]');
    const act = actEl ? actEl.getAttribute('data-qact') : null;
    if (act === 'expand') { st.expanded = true; renderSoon(); }
    else if (act === 'collapse') { st.expanded = false; renderSoon(); }
    else if (act === 'opt') {
      const idx = parseInt(actEl.getAttribute('data-idx'), 10);
      if (q.multi) {
        const at = st.selected.indexOf(idx);
        if (at >= 0) st.selected.splice(at, 1); else st.selected.push(idx);
      } else { st.selected = [idx]; }
      renderSoon();
    } else if (act === 'send') {
      let choice = null;
      if (st.text.trim()) choice = {type: 'text', value: st.text.trim()};
      else if (st.selected.length) choice = {type: 'select', indices: st.selected.slice().sort((a,b)=>a-b)};
      if (!choice) return;
      actEl.disabled = true;
      fetch('/api/answer', {
        method: 'POST', headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({paneId, choice, question: {title: q.title, question: q.question}}),
      }).then(r => r.json()).then(res => {
        if (res.ok) {
          st.selected = []; st.text = '';
          if (res.next) {
            // Multi-question turn: Q2 queued right behind Q1 — advance the
            // box immediately instead of waiting up to 45s for the feed.
            // qdata is keyed per pane and re-render reads it fresh.
            qdata[paneId] = res.next;
            qadv[paneId] = true;
            st.expanded = true;
          } else { st.expanded = false; }
        }
        showToast(res.ok ? (res.next ? 'answer sent — next question below' : 'answer sent') : ('answer refused: ' + (res.error || '?')), !!res.ok);
        renderSoon();
      }).catch(e => { showToast('answer failed: ' + e, false); renderSoon(); });
    }
    return;
  }
  const row = ev.target.closest('[data-pane]');
  if (row) focusPane(row.getAttribute('data-pane'), row.getAttribute('data-label'));
});
let _lastState = null;
function renderSoon() {
  // Re-render from the last pushed state so staging feedback is instant
  // instead of waiting for the next 2s tick.
  if (_lastState) render(_lastState);
}

let es;
function connect() {
  ensureNotiPerm();
  fetch('/api/state').then(r => r.json()).then(render).catch(()=>{});
  es = new EventSource('/api/events');
  es.onmessage = (ev) => { try { render(JSON.parse(ev.data)); } catch(e) {} };
  es.onerror = () => { /* EventSource auto-reconnects */ };
}
connect();
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    # The built React app in dashboard/ui/dist/ is served statically at /. The
    # hand-written PAGE_HTML stays at /legacy, and is also what / falls back
    # to when dist/ is missing. dist/ is NOT committed here (gitignored): build
    # it with `cd dashboard/ui && bun install && bun run build`.
    UI_DIST = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "ui", "dist")
    UI_MIME = {".html": "text/html; charset=utf-8",
               ".js": "text/javascript; charset=utf-8",
               ".css": "text/css; charset=utf-8",
               ".json": "application/json",
               ".webmanifest": "application/manifest+json",
               ".svg": "image/svg+xml",
               ".png": "image/png",
               ".ico": "image/x-icon"}

    #: Phone 2a (docs/plans/2026-09-26-agentbar-mobile-web.md phase 2): the
    #: PWA shell assets. iOS fetches manifest/icons/sw.js itself (not
    #: through the page's own fetch/cookie jar in every install flow), so on
    #: the remote listener these specific paths are reachable WITHOUT the
    #: session cookie/token — same as /remote/login. Nothing else on the
    #: remote listener gets this treatment: nothing sensitive is servable at
    #: these five paths (static, content-free assets), and every other
    #: route (including /assets/* and the SPA shell) still requires auth.
    PWA_PUBLIC_PATHS = {
        "/manifest.webmanifest": "manifest.webmanifest",
        "/sw.js": "sw.js",
        "/icons/icon-192.png": "icons/icon-192.png",
        "/icons/icon-512.png": "icons/icon-512.png",
        "/apple-touch-icon.png": "apple-touch-icon.png",
    }

    def log_message(self, fmt, *args):
        # Keep the pane readable; only log non-200s and startup, not every poll.
        try:
            if not (len(args) >= 2 and str(args[1]).startswith("2")):
                super().log_message(fmt, *args)
        except Exception:
            pass

    def _send_json(self, obj, status=200):
        body = json.dumps(obj, default=str).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)
        # Remote access: flush the audit line for this write once its real
        # outcome (this status) is known — see _reject_foreign_write.
        pending = getattr(self, "_pending_remote_audit", None)
        if pending is not None:
            self._pending_remote_audit = None
            remote_access.append_audit(
                pending["route"], pending["method"],
                status, row_id=pending.get("row_id"))

    # ---- Unread-body desync guard (found live-testing P3, 2026-09-26) ----
    # HTTP/1.1 keep-alive reads the next request off the same socket. A
    # response sent BEFORE the body was read (every early refusal: foreign
    # Origin, remote-listener 403, wrong Content-Type, 404) left that body
    # in the socket, and it was then parsed as a second request — with
    # headers the sender wrote. So a cross-site page's refused text/plain
    # POST could carry a guard-clean `POST /api/persona/start` (no Origin,
    # JSON Content-Type) that ran. Fix: any response to a request whose
    # body wasn't read closes the connection instead.

    def parse_request(self):
        # One Handler instance serves every request on a keep-alive
        # connection, so the flag is reset per request.
        self._request_body_read = False
        self._response_status = None
        return super().parse_request()

    def send_response_only(self, code, message=None):
        # Every status line goes through here — send_response AND
        # handle_expect_100's interim `100 Continue` — so end_headers knows
        # which reply it is finishing.
        self._response_status = code
        super().send_response_only(code, message)

    def _read_request_body(self):
        """The raw request body (b"" when none), marked as read."""
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        self._request_body_read = True
        return raw

    def _request_body_left_unread(self):
        headers = getattr(self, "headers", None)
        if headers is None:
            return False
        if headers.get("Transfer-Encoding"):
            return True  # never read here (no chunked support): always close
        if getattr(self, "_request_body_read", False):
            return False
        try:
            return int(headers.get("Content-Length") or 0) != 0
        except ValueError:
            return True

    def end_headers(self):
        # A 1xx reply is interim: it goes out before the client sends the
        # body (`Expect: 100-continue`), so the body is unread by design and
        # closing there would drop keep-alive for a legitimate POST. The
        # final reply still runs the check below.
        status = getattr(self, "_response_status", None)
        is_interim_reply = status is not None and status < 200
        if not is_interim_reply and self._request_body_left_unread():
            # http.server sets close_connection when it sees this header.
            self.send_header("Connection", "close")
        super().end_headers()

    def _read_json_body(self):
        return json.loads(self._read_request_body() or b"{}") or {}

    #: Loopback-only: this server has no auth of its own, so every write
    #: route's real protection is "nothing outside this Mac can reach it."
    #: A foreign Origin or Host header means something other than that
    #: assumption is true — a browser tab on another site, or a request
    #: proxied in from elsewhere — and R20 says refuse before the handler
    #: runs, for local AND remote-machine rows alike (this check has
    #: nothing to do with which pane a request targets).
    _LOOPBACK_HOSTNAMES = ("127.0.0.1", "localhost", "::1")

    @classmethod
    def _is_loopback_netloc(cls, netloc):
        netloc = (netloc or "").strip()
        # IPv6 literals are bracketed and contain colons themselves
        # ("[::1]:4711") — strip the bracketed part first, or a naive
        # split(":")[0] truncates to "[" and never matches.
        if netloc.startswith("["):
            host = netloc[1:].split("]")[0]
        else:
            host = netloc.split(":")[0]
        return host.strip("[]").lower() in cls._LOOPBACK_HOSTNAMES

    # ---- Remote access (tailscale serve) --------------------------------
    # QA pass 2 REDESIGN: remote access no longer shares this listener with
    # loopback callers at all. A SEPARATE socket is bound (see main()) only
    # when `remote.enabled` is true, and `self.server.remote_listener` is
    # True on that socket's server instance, False on the main one — that
    # flag, not any header, decides which branch below runs. Every request
    # that arrives on the remote listener is remote by construction (it is
    # a different port that `tailscale serve` fronts and 4711 never is), so
    # there is nothing left to spoof: no Host-header classification, no
    # Tailscale-identity-header heuristic, no "unrecognized host" sentinel.
    # See server/lib/remote_access.py's module docstring for why pass 1's
    # header-based approach was replaced.

    def _is_remote_listener(self):
        return bool(getattr(getattr(self, "server", None), "remote_listener", False))

    def _note_agentbar_seen(self):
        """True (and AgentBar marked connected) for AgentBar's own request on
        the local listener. The hook bridge holds prompts only while it is."""
        if not agentbar_presence.is_agentbar_request(
                getattr(self, "headers", None), self._is_remote_listener()):
            return False
        agentbar_presence.PRESENCE.note_seen()
        return True

    def _remote_authenticated(self):
        auth = self.headers.get("Authorization") or ""
        if auth.startswith("Bearer "):
            if remote_access.verify_token(auth[len("Bearer "):].strip()):
                return True
        cookies = remote_access.parse_cookies(self.headers.get("Cookie"))
        session_id = cookies.get(remote_access.SESSION_COOKIE_NAME)
        return remote_access.session_valid(session_id)

    def _note_remote_audit_row(self, row_id):
        pending = getattr(self, "_pending_remote_audit", None)
        if pending is not None and row_id is not None:
            pending["row_id"] = row_id

    def _handle_remote_login(self):
        """Verify the token BEFORE consulting the failure-rate limiter.

        `client_address` is 127.0.0.1 for EVERY remote request (tailscale
        serve always proxies in over loopback), so `is_login_blocked` is
        keyed on the same bucket for every remote caller, not per real
        attacker — it is checked first, so an attacker sending one
        wrong-token guess roughly once a minute could keep the shared 60s
        window perpetually full and lock the real owner's own phone out of
        ever logging in. A request carrying the actual token proves its
        sender isn't the guesser being rate-limited, so it must always be
        allowed through regardless of recent failures from whoever else is
        hitting this endpoint; only a WRONG guess is subject to the limiter
        (unchanged otherwise)."""
        raw = self._read_request_body()
        token = remote_access.parse_login_form(raw)
        if not remote_access.verify_token(token):
            if remote_access.is_login_blocked(self.client_address):
                self._send_page(remote_access.render_login_page(
                    "Too many attempts — wait a minute and try again."))
                return
            remote_access.record_login_failure(self.client_address)
            remote_access.append_audit("/remote/login", "POST", 401)
            self._send_page(remote_access.render_login_page("Invalid token."))
            return
        remote_access.clear_login_failures(self.client_address)
        session_id = remote_access.create_session()
        remote_access.append_audit("/remote/login", "POST", 200)
        self.send_response(302)
        self.send_header("Location", "/")
        self.send_header("Set-Cookie", remote_access.session_cookie_header(session_id))
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _reject_foreign_write(self):
        """True (and a response already sent) when this write must be
        refused. Called once at the top of every write method, before any
        path routing or handler runs.

        Remote listener: auth is required first — an unauthenticated
        remote request is refused with 401 before Origin is even
        inspected, since Origin can't be trusted to identify a legitimate
        caller until one is known. Once authenticated, an Origin the
        browser sends must name one of `remote.hosts` over https — a
        same-page fetch from the phone PWA satisfies that; anything else
        is CSRF and gets 403.

        Main (loopback) listener: unchanged from before phase 1a — no
        Origin header at all (a curl call, or a same-page fetch that never
        sends one) is NOT foreign; only an explicit cross-origin Origin, or
        a Host naming something other than this loopback server, counts.
        """
        origin = self.headers.get("Origin")
        if self._is_remote_listener():
            # self.path is only read on this branch — the loopback-only
            # unit tests for this method construct a bare Handler with no
            # real request/socket behind it, so nothing below this point
            # may assume self.path exists.
            path = urlparse(self.path).path
            if path == "/remote/login":
                self._handle_remote_login()
                return True
            if not self._remote_authenticated():
                remote_access.append_audit(path, self.command, 401)
                self._send_json({"ok": False, "error": "unauthenticated"}, status=401)
                return True
            _enabled, hosts, _port = remote_access.load_remote_settings()
            if origin and not remote_access.origin_allowed(origin, hosts):
                remote_access.append_audit(path, self.command, 403)
                self._send_json(
                    {"ok": False, "error": "refused: foreign Origin"},
                    status=403)
                return True
            # Authenticated + CSRF-clean: allow through, and remember what
            # to audit once the real handler's response status is known
            # (flushed from _send_json).
            self._pending_remote_audit = {"route": path, "method": self.command}
            return False

        if origin:
            try:
                ok = self._is_loopback_netloc(urlparse(origin).netloc)
            except Exception:
                ok = False
            if not ok:
                self._send_json(
                    {"ok": False, "error": "refused: foreign Origin"},
                    status=403)
                return True
        host = self.headers.get("Host")
        if host and not self._is_loopback_netloc(host):
            self._send_json(
                {"ok": False, "error": "refused: non-loopback Host"},
                status=403)
            return True
        return False

    def _serve_file(self, rel):
        # Static asset out of UI_DIST. `rel` comes from the /assets/ prefix
        # only (never a raw URL path), so no traversal is possible.
        path = os.path.join(self.UI_DIST, rel)
        if not os.path.isfile(path):
            self._send_json({"error": "not found"}, status=404)
            return
        _, ext = os.path.splitext(path)
        mime = self.UI_MIME.get(ext, "application/octet-stream")
        try:
            with open(path, "rb") as f:
                body = f.read()
        except OSError:
            self._send_json({"error": "not found"}, status=404)
            return
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_page(self, body):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_spa(self):
        # / serves the React build's index.html; missing dist/ falls back to
        # the legacy page so the board never goes dark on a fresh checkout.
        index = os.path.join(self.UI_DIST, "index.html")
        try:
            with open(index, "rb") as f:
                self._send_page(f.read())
        except OSError:
            self._send_page(PAGE_HTML.encode("utf-8"))

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        # Remote access: on the remote listener, EVERY route (including the
        # SPA shell, static /assets/, and the /api/events SSE stream)
        # requires auth — unlike the main loopback listener, where GET has
        # never needed any. /remote/login itself must stay reachable
        # unauthed, or there would be no way to ever get a session.
        if self._is_remote_listener():
            if path == "/remote/login":
                self._send_page(remote_access.render_login_page())
                return
            if path in self.PWA_PUBLIC_PATHS:
                self._serve_file(self.PWA_PUBLIC_PATHS[path])
                return
            if not self._remote_authenticated():
                if path.startswith("/api/"):
                    self._send_json({"ok": False, "error": "unauthenticated"}, status=401)
                else:
                    self.send_response(302)
                    self.send_header("Location", "/remote/login")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                return
        self._note_agentbar_seen()
        if hook_permission_routes.is_hook_path(path):
            self._send_json(*hook_permission_routes.handle_get(
                path, parse_qs(parsed.query), self._is_remote_listener()))
            return
        if path == "/" or path == "/index.html":
            self._serve_spa()
        elif path == "/legacy":
            self._send_page(PAGE_HTML.encode("utf-8"))
        elif path.startswith("/assets/"):
            self._serve_file(path.lstrip("/"))
        elif path in self.PWA_PUBLIC_PATHS:
            self._serve_file(self.PWA_PUBLIC_PATHS[path])
        elif path == "/favicon.ico":
            self.send_response(204)
            self.end_headers()
        elif path == "/api/state":
            self._send_json(get_state_with_board())
        elif path == "/api/agent-tree":
            try:
                self._send_json(get_agent_tree_state())
            except Exception as e:
                self._send_json({"error": str(e)}, status=400)
        elif path == "/api/board":
            qs = parse_qs(parsed.query)
            row_kind = qs.get("rowKind", ["session"])[0]
            view_id = qs.get("view", [None])[0]
            try:
                self._send_json(get_board_state(row_kind, view_id))
            except Exception as e:
                self._send_json({"error": str(e)}, status=400)
        elif path == "/api/views":
            qs = parse_qs(parsed.query)
            row_kind = qs.get("rowKind", ["session"])[0]
            self._send_json({"views": STORE.list_views(row_kind)})
        elif path.startswith("/api/views/"):
            try:
                self._send_json({"view": STORE.get_view(path[len("/api/views/"):])})
            except Exception as e:
                self._send_json({"error": str(e)}, status=404)
        elif path == "/api/properties":
            row_kind = parse_qs(parsed.query).get("rowKind", ["session"])[0]
            self._send_json({"properties": STORE.list_properties(row_kind)})
        elif path == "/api/events":
            self._serve_sse(parse_qs(parsed.query))
        elif path == "/api/links":
            qs = parse_qs(parsed.query)
            work_row_id = qs.get("workRowId", [None])[0]
            self._send_json({"links": STORE.list_links(work_row_id)})
        elif path == "/api/session/history":
            payload, status = handle_session_history(parse_qs(parsed.query))
            self._send_json(payload, status=status)
        elif path == "/api/session/latest":
            payload, status = handle_session_latest(parse_qs(parsed.query))
            self._send_json(payload, status=status)
        elif path == "/api/session/plan":
            payload, status = handle_session_plan(parse_qs(parsed.query))
            self._send_json(payload, status=status)
        elif path == "/api/pane/screen":
            # BLOCKING ~2.5s on this request thread. ThreadingHTTPServer keeps
            # it off the SSE stream and the rest of the board; a polling
            # caller would still serialize herdr, so: on demand only.
            payload, status = handle_pane_screen(parse_qs(parsed.query))
            self._send_json(payload, status=status)
        elif path == "/api/deliver/pass":
            # Restored 2026-09-25, generic — see chief_dashboard_pass.py.
            self._send_json(chief_dashboard_pass.get_chief_pass(get_full_state))
        elif path == "/api/personas":
            # Jev persona routing P1 — see server/lib/personas.py. The
            # remote listener gets only opted-in (remoteStart) personas,
            # without folder paths — see server/lib/persona_remote.py.
            try:
                if self._is_remote_listener():
                    self._send_json(persona_remote.remote_personas())
                else:
                    self._send_json(personas.get_personas_state())
            except Exception as e:
                self._send_json({"error": str(e)}, status=400)
        elif path in ("/api/personas/suggestions", "/api/personas/registry"):
            # Jev persona routing P4 (Settings > Personas): folder paths and
            # instructions, so localhost only like every persona write.
            if self._is_remote_listener():
                self._send_json({"ok": False, "error": "refused: localhost-only"}, status=403)
                return
            try:
                if path.endswith("/suggestions"):
                    self._send_json(persona_suggestions.get_suggestions())
                else:
                    self._send_json(persona_registry_edit.registry_view())
            except Exception as e:
                self._send_json({"ok": False, "error": str(e)}, status=500)
        else:
            self._send_json({"error": "not found"}, status=404)

    def _handle_local_json_post(self, path, handle_body, remote_handle_body=None):
        """Persona writes: POST /api/persona/start (P3, persona_start.py)
        and POST /api/personas (P4, persona_registry_edit.py). Localhost
        only (brief: "Dashboard endpoints"): refused on the remote listener
        even when authenticated — these are local-desk actions. Then the
        Content-Type gate, before the body is parsed: a browser page can't
        send application/json cross-site without a preflight this
        dashboard never answers. `remote_handle_body`, when given, serves
        the remote listener instead of the 403 (it arrives there already
        authenticated and CSRF-checked by `_reject_foreign_write`)."""
        if self._is_remote_listener() and remote_handle_body is not None:
            handle_body = remote_handle_body
        elif self._is_remote_listener():
            self._send_json(
                {"ok": False, "error": f"refused: {path} is localhost-only"},
                status=403)
            return
        if not persona_start.is_json_content_type(self.headers.get("Content-Type")):
            self._send_json(
                {"ok": False, "error": "Content-Type must be application/json"},
                status=400)
            return
        try:
            body = self._read_json_body()
        except Exception as e:
            self._send_json({"ok": False, "error": str(e)}, status=200)
            return
        self._send_json(handle_body(body))

    def do_POST(self):
        if self._reject_foreign_write():
            return
        self._note_agentbar_seen()
        path = urlparse(self.path).path
        if hook_permission_routes.is_hook_path(path):
            self._note_remote_audit_row(hook_permission_routes.request_id_of(path))
            self._send_json(*hook_permission_routes.handle_post(
                path, self._read_json_body, self._is_remote_listener()))
            return
        if path.startswith("/api/session/"):
            action = path[len("/api/session/"):]
            self._note_remote_audit_row(action)
            try:
                body = self._read_json_body()
                # Audit the row acted on, not just the verb.
                row_id = body.get("rowId") if isinstance(body, dict) else None
                self._note_remote_audit_row(row_id if isinstance(row_id, str) else None)
                self._send_json(handle_session_action(action, body))
            except Exception as e:
                self._send_json({"ok": False, "error": str(e)}, status=200)
            return
        if path == "/api/links":
            try:
                self._send_json({"ok": True, "link": STORE.create_link(self._read_json_body())})
            except Exception as e:
                self._send_json({"ok": False, "error": str(e)}, status=400)
            return
        if path == "/api/views":
            try:
                self._send_json({"ok": True, "view": STORE.create_view(self._read_json_body())})
            except Exception as e:
                self._send_json({"ok": False, "error": str(e)}, status=400)
            return
        if path == "/api/properties":
            try:
                self._send_json({"ok": True, "property": STORE.create_property(self._read_json_body())})
            except Exception as e:
                self._send_json({"ok": False, "error": str(e)}, status=400)
            return
        if path == "/api/agent-tree/attach":
            try:
                body = self._read_json_body()
            except Exception as e:
                self._send_json({"ok": False, "error": str(e)}, status=200)
                return
            payload, status = agent_tree_attach(
                body.get("child"), body.get("parent"),
                confirm_cross_project=bool(body.get("confirmCrossProject")))
            self._send_json(payload, status=status)
            return
        if path == "/api/agent-tree/detach":
            try:
                body = self._read_json_body()
            except Exception as e:
                self._send_json({"ok": False, "error": str(e)}, status=200)
                return
            payload, status = agent_tree_detach(body.get("child"))
            self._send_json(payload, status=status)
            return
        if path == "/api/persona/start":
            self._handle_local_json_post(path, persona_start.start_persona,
                                         persona_remote.start_persona_remote)
            return
        if path == "/api/personas":
            self._handle_local_json_post(path, persona_registry_edit.apply_registry_action)
            return
        # P0 dashboard move: POST /api/worker (chief_dashboard_worker.py —
        # worktree/session spin-up for AptusFit's not-yet-built "Jev
        # create-new-agent" flow) is RETIRED — AgentBar never called it.
        if path not in ("/api/focus", "/api/answer", "/api/permission"):
            self._send_json({"error": "not found"}, status=404)
            return
        try:
            body = self._read_json_body()
            pane_id = body.get("paneId")
            if not pane_id:
                self._send_json({"ok": False, "error": "missing paneId"}, status=400)
                return
            self._note_remote_audit_row(pane_id)
            if path == "/api/focus":
                result = focus_pane(pane_id)
            elif path == "/api/answer":
                result = answer_pane_question(
                    pane_id, body.get("choice"), body.get("question"))
            else:
                result = answer_pane_permission(
                    pane_id, body.get("choice"), body.get("permission"),
                    index=body.get("index"), text=body.get("text"))
            self._send_json({"ok": True, **result})
        except Exception as e:
            self._send_json({"ok": False, "error": str(e)}, status=200)

    def do_PATCH(self):
        if self._reject_foreign_write():
            return
        path = urlparse(self.path).path
        vprefix = "/api/views/"
        if path.startswith(vprefix):
            try:
                self._send_json({"ok": True, "view": STORE.update_view(path[len(vprefix):], self._read_json_body())})
            except Exception as e:
                self._send_json({"ok": False, "error": str(e)}, status=400)
            return
        prefix = "/api/properties/"
        if not path.startswith(prefix):
            self._send_json({"error": "not found"}, status=404)
            return
        try:
            prop_id = path[len(prefix):]
            self._send_json({"ok": True, "property": STORE.update_property(prop_id, self._read_json_body())})
        except Exception as e:
            self._send_json({"ok": False, "error": str(e)}, status=400)

    def do_DELETE(self):
        if self._reject_foreign_write():
            return
        path = urlparse(self.path).path
        if path == "/api/links":
            try:
                body = self._read_json_body()
                self._send_json(STORE.delete_link(body))
            except Exception as e:
                self._send_json({"ok": False, "error": str(e)}, status=400)
            return
        vprefix = "/api/views/"
        if path.startswith(vprefix):
            try:
                self._send_json(STORE.delete_view(path[len(vprefix):]))
            except Exception as e:
                self._send_json({"ok": False, "error": str(e)}, status=400)
            return
        prefix = "/api/properties/"
        if not path.startswith(prefix):
            self._send_json({"error": "not found"}, status=404)
            return
        try:
            self._send_json(STORE.delete_property(path[len(prefix):]))
        except Exception as e:
            self._send_json({"ok": False, "error": str(e)}, status=400)

    def do_PUT(self):
        if self._reject_foreign_write():
            return
        path = urlparse(self.path).path
        if path != "/api/values":
            self._send_json({"error": "not found"}, status=404)
            return
        try:
            self._send_json(STORE.set_value(self._read_json_body()))
        except Exception as e:
            self._send_json({"ok": False, "error": str(e)}, status=400)

    def _serve_sse(self, query=None):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        # AgentBar, or the web UI that answers hook prompts (phone included):
        # the hook bridge holds prompts while either one is connected.
        is_answer_surface = (self._note_agentbar_seen()
                             or agentbar_presence.is_web_answer_stream(query))
        try:
            while not STOP.is_set():
                # Remote: auth was checked once at connect; re-check every
                # push so a token rotation (or session expiry) also ends a
                # stream that is already open — it would otherwise keep
                # streaming state and counting as an answer surface. The
                # phone's EventSource then reconnects, gets 401, logs in.
                if self._is_remote_listener() and not self._remote_authenticated():
                    self.close_connection = True  # no Content-Length: only a close ends it
                    return
                payload = json.dumps(get_state_with_board(), default=str)
                chunk = f"data: {payload}\n\n".encode("utf-8")
                self.wfile.write(chunk)
                self.wfile.flush()
                if is_answer_surface:  # each delivered push = still connected
                    agentbar_presence.PRESENCE.note_seen()
                time.sleep(2)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception:
            pass


class QuietThreadingHTTPServer(ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        exc = sys.exc_info()[1]
        if isinstance(exc, (BrokenPipeError, ConnectionResetError)):
            return
        super().handle_error(request, client_address)


# P0 dashboard move: _run_agent_tree_migration_once (one-time catch-up that
# seeded chief_dashboard_worker's registered-chief session as parent for any
# pre-agent-tree AptusFit worker) is RETIRED along with chief_dashboard_worker
# itself — it only ever mattered for sessions that predate a feature this
# repo never shipped independently of AptusFit's chief. agent_tree.py's own
# per-project seeding (unchanged, still MOVE-set) still runs via the normal
# attach/detach + hook-cache paths.


def _start_remote_listener():
    """Binds the separate remote-access listener (127.0.0.1:<remote.port>,
    default 4712) when `remote.enabled` is true in config.json, and returns
    the running server (already serve_forever-ing on a background thread),
    or None when remote access is off or the port could not be bound.

    A bind failure here (port already in use, e.g. two dashboard instances,
    or a stale process still holding it) must never take down the main
    dashboard — it's logged and the server keeps running local-only, same
    as if `remote.enabled` were false."""
    enabled, _hosts, port = remote_access.load_remote_settings()
    if not enabled:
        return None
    try:
        server = QuietThreadingHTTPServer(("127.0.0.1", port), Handler)
    except OSError as e:
        print(f"chief-dashboard-server: remote listener could not bind "
              f"127.0.0.1:{port} ({e}) — continuing WITHOUT remote access", file=sys.stderr)
        return None
    server.remote_listener = True
    thread = threading.Thread(target=server.serve_forever, daemon=True,
                               name="remote-listener")
    thread.start()
    print(f"chief-dashboard-server: remote listener on http://127.0.0.1:{port}/ "
          f"(tailscale serve should target this port, never {PORT})")
    return server


def main():
    start_pollers()
    SAMPLER.start()

    server = QuietThreadingHTTPServer((HOST, PORT), Handler)
    server.remote_listener = False
    remote_server = _start_remote_listener()
    print(f"chief-dashboard-server listening on http://{HOST}:{PORT}/  (repo root: {REPO_ROOT})")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        STOP.set()
        server.shutdown()
        if remote_server is not None:
            remote_server.shutdown()


if __name__ == "__main__":
    main()
