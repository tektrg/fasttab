#!/usr/bin/env python3
"""Computed views for the chief dashboard: pure functions over feed snapshots.

Pure by design — /api/state and the SSE stream both render from these, so the
page and the API can never drift, and a future chief consumer reads the same
JSON instead of scraping HTML (plan.md's "one data layer, two consumers").
"""
import time

import agent_tree  # noqa: E402  (scripts/lib/agent_tree.py — the hierarchy store)
import chief_dashboard_herdr as herdr_transport
import claude_sessions  # P4: non-herdr Claude sessions as status-only rows
import desktop_sessions  # sleeping Claude Desktop sessions (no live process)
import hook_permissions  # prompts answerable via the PermissionRequest hook
import pane_screen_signals
from chief_dashboard_feeds import FEEDS, MACHINES, sanitize_pane_id  # noqa: F401
from chief_dashboard_feeds import MACHINES_CONFIG_ERROR  # noqa: F401,E402  (surfaced on every /api/state)
from chief_dashboard_feeds import read_hook_question  # noqa: E402  (phase 5: AskUserQuestion preview)
from chief_dashboard_feeds import herdr_feed_key, pane_screen_feed_key, machines_status  # noqa: E402

# ── Computed views (pure functions over feed snapshots; used by both
#    /api/state and the SSE stream, so the page and API can never drift) ──


def build_agents_view(feeds_snap):
    hook = (feeds_snap["hookCache"]["data"] or {})
    herdr = (feeds_snap["herdr"]["data"] or {"agents": [], "tabs": []})
    agents_raw = herdr.get("agents", [])
    tabs_raw = herdr.get("tabs", [])
    tabs_by_id = {t.get("tab_id"): t for t in tabs_raw}
    screens = (feeds_snap["paneScreen"]["data"] or {})
    now = time.time()

    seen_sanitized = set()
    rows = []
    for a in agents_raw:
        pane_id = a.get("pane_id")
        sid = sanitize_pane_id(pane_id) if pane_id else None
        hook_entry = hook.get(sid) if sid else None
        if sid:
            seen_sanitized.add(sid)
        herdr_status = a.get("agent_status")
        screen = screens.get(sid) or {}
        hook_state = hook_entry["state"] if hook_entry else None
        hook_seq = hook_entry["seq"] if hook_entry else None
        since_sec = (now - hook_seq) if hook_seq is not None else None
        # herdr's agent_status is a default, not a measurement: a split is news
        # only when nothing shows the pane working (one rule, with its evidence:
        # pane_screen_signals.live_work_evidence).
        unchanged_sec = pane_screen_signals.screen_unchanged_sec(screen, now)
        subagents = screen.get("subagents") or 0
        disagree = pane_screen_signals.hook_vs_herdr_disagree(
            hook_state, herdr_status, screen.get("state"), since_sec,
            screen_unchanged_sec=unchanged_sec, subagents=subagents)
        tab = tabs_by_id.get(a.get("tab_id"), {})
        # P5: a non-Claude pane (OpenCode, …) the screen can't classify falls
        # back to herdr's own agent_status; screenStateSource says which won.
        screen_state, screen_state_source = (
            pane_screen_signals.screen_state_with_herdr_fallback(
                a.get("agent"), screen.get("state"), herdr_status))
        rows.append({
            "paneId": pane_id,
            "tabId": a.get("tab_id"),
            "workspaceId": a.get("workspace_id"),
            "label": tab.get("label") or a.get("terminal_title_stripped") or a.get("terminal_title") or "",
            "cwd": a.get("cwd"),
            "focused": bool(a.get("focused")),
            "hookState": hook_state,
            "hookSinceSec": since_sec,
            "herdrStatus": herdr_status,
            "disagree": disagree,
            # Evidence a firing `disagree` alert carries (chief_wake_fingerprint):
            # how long the screen has read identically, sub-agent lines on it,
            # and whether herdr ever reported a completed turn (null = its
            # `agent_status` is a default, not a measurement).
            "screenUnchangedSec": unchanged_sec,
            "subagentsRunning": subagents,
            "herdrTurnReported": a.get("last_completed_turn") is not None,
            "hasHookData": hook_entry is not None,
            # Parked on a monitor/agent past the 2h ceiling: the UI stops
            # painting the row as working (same rule as resolve_state).
            "backgroundWaitExpired": pane_screen_signals.background_wait_expired(
                screen_state, since_sec),
            "residue": False,
            "agentSession": (a.get("agent_session") or {}).get("value"),
            "hookReason": (hook_entry or {}).get("reason"),
            # What the pane actually shows right now — the corroborating truth.
            "screenState": screen_state,
            "screenStateSource": screen_state_source,
            "screenSignal": screen.get("signal"),
            # The open AskUserQuestion picker, if any (parsed block, or None).
            "screenQuestion": screen.get("question"),
            # The open plain yes/no permission box, if any (parsed block, or
            # None) — mutually exclusive with screenQuestion above.
            "screenPermission": screen.get("permission"),
            # The hook's display-only preview of a just-opened picker (raw
            # tool input, never screen-parsed). Attached here; build_needs_you
            # decides whether it outranks the stale screen. Live rows only —
            # an orphaned sidecar with no pane is residue, never a row.
            "hookQuestion": read_hook_question(sid) if sid else None,
            "machine": herdr_transport.LOCAL_MACHINE,
            "source": claude_sessions.HERDR_SOURCE,
        })

    # Remote rows (R1/R4/R7): one machine at a time, from that machine's OWN
    # herdr + paneScreen feeds — never mixed into the local loop above, so a
    # remote outage can only ever cost that machine's rows, never local's.
    for machine in MACHINES:
        herdr_feed = feeds_snap.get(herdr_feed_key(machine)) or {}
        remote_herdr = herdr_feed.get("data") or {"agents": [], "tabs": []}
        remote_agents_raw = remote_herdr.get("agents", [])
        remote_tabs_by_id = {t.get("tab_id"): t
                             for t in remote_herdr.get("tabs", [])}
        remote_screens = (feeds_snap.get(pane_screen_feed_key(machine)) or {}).get("data") or {}
        for a in remote_agents_raw:
            raw_pane_id = a.get("pane_id")
            if not raw_pane_id:
                continue
            pane_key = herdr_transport.make_pane_key(machine, raw_pane_id)
            sid = sanitize_pane_id(pane_key)
            screen = remote_screens.get(sid) or {}
            tab = remote_tabs_by_id.get(a.get("tab_id"), {})
            rows.append({
                "paneId": pane_key,
                "tabId": a.get("tab_id"),
                "workspaceId": a.get("workspace_id"),
                "label": tab.get("label") or a.get("terminal_title_stripped")
                        or a.get("terminal_title") or "",
                "cwd": a.get("cwd"),
                "focused": bool(a.get("focused")),
                # R4: NEVER hookState/herdrStatus here — no hook can push to
                # this Mac from the Air, and the Air's own agent_status is
                # exactly the signal this whole feature exists to stop
                # trusting for state. Kept, renamed, for anyone auditing what
                # the Air itself claimed — never read by derived:state.
                "hookState": None,
                "hookSinceSec": None,
                "herdrStatus": None,
                "herdrStatusUnverified": a.get("agent_status"),
                "disagree": False,
                "hasHookData": False,
                "residue": False,
                "agentSession": (a.get("agent_session") or {}).get("value"),
                "hookReason": None,
                "screenState": screen.get("state"),
                "screenSignal": screen.get("signal"),
                "screenQuestion": screen.get("question"),
                "screenPermission": screen.get("permission"),
                "hookQuestion": None,
                "machine": machine,
                "source": claude_sessions.HERDR_SOURCE,
                # Local-only facts (R16) degrade to null on a remote row,
                # never a guessed/borrowed local value.
                "memoryBytes": None,
            })

    # P4: Claude sessions outside herdr (Claude Desktop, a plain terminal),
    # status-only. A session herdr already shows (same agentSession) is skipped
    # — the pane row is the richer one. Local sessions folder only.
    herdr_session_ids = {r["agentSession"] for r in rows if r.get("agentSession")}
    claude_sessions_data = (feeds_snap.get("claudeSessions") or {}).get("data")
    rows.extend(claude_sessions.build_status_only_rows(
        claude_sessions_data, herdr_session_ids, now,
        machine=herdr_transport.LOCAL_MACHINE,
        hook_requests=hook_permissions.STORE.exposed_by_session(claude_sessions_data)))

    # Hook files with no matching herdr pane. The hook only deletes one on a
    # graceful SessionEnd, so a closed tab or a killed session leaves it behind
    # forever — measured 2026-09-03: 17 of them, the oldest 5 days dead, filling
    # this table with "(no matching herdr pane)" rows the PO could do nothing
    # with. They are still returned (a mid-`working` one means a worker died
    # with work in flight, which build_needs_you does surface), but each is
    # flagged `residue` so the page can keep them out of the main table.
    # If herdr itself has never answered, `agents_raw` is empty and every hook
    # entry below would look orphaned — which would drop every genuinely
    # blocked live worker as "residue". Withhold that judgement instead; the
    # herdr feed raises its own FEED BROKEN row, so nothing is silently lost.
    herdr_usable = feeds_snap["herdr"]["lastSuccessTs"] is not None
    for sid, hook_entry in hook.items():
        if sid in seen_sanitized:
            continue
        rows.append({
            "paneId": None,
            "paneIdSanitized": sid,
            "tabId": None,
            "workspaceId": None,
            "label": "(no matching herdr pane)",
            "cwd": None,
            "focused": False,
            "hookState": hook_entry["state"],
            "hookSinceSec": now - hook_entry["seq"],
            "herdrStatus": None,
            "disagree": False,
            "hasHookData": True,
            "orphanHook": True,
            # Residue unless it died mid-turn — that one is a real event.
            "residue": herdr_usable and hook_entry["state"] != "working",
            "agentSession": None,
            "hookReason": hook_entry.get("reason"),
            "screenState": None,
            "screenSignal": None,
            "screenQuestion": None,
            "screenPermission": None,
            "machine": herdr_transport.LOCAL_MACHINE,
        })

    # R6: the SAME agentSession UUID can legitimately show up twice (a
    # session resumed on a different machine than where it started, or a
    # stale sighting on one side). Both rows stay — dedup means "know which
    # is which," never "drop one." First occurrence (by scan order: local
    # rows first, then remote machines in config order) keeps the real
    # session id as its identity; every later occurrence of the same UUID
    # is flagged and its own identity falls back to its (namespaced, so
    # already unique) pane id instead — resolve_agent_row_id() prefers
    # agentSession, so clearing it here is what actually prevents the
    # second row from silently overwriting the first wherever a caller
    # keys a dict by row id.
    seen_sessions = set()
    for r in rows:
        sess = r.get("agentSession")
        if not sess:
            continue
        if sess in seen_sessions:
            r["duplicateOfSession"] = sess
            r["agentSession"] = None
        else:
            seen_sessions.add(sess)

    order = {"blocked": 0, None: 1, "working": 2, "idle": 3}
    rows.sort(key=lambda r: (order.get(r["hookState"], 1), -(r["hookSinceSec"] or 0)))
    return rows


#: One ranked list, most urgent first. Lower sorts first. A broken feed
#: outranks everything because it makes every row below it untrustworthy —
#: the list cannot claim "nothing needs you" while blind.
URGENCY = {
    "feed-broken": 0,
    "blocked": 1,
    "question": 1,
}

#: classify_pane states that positively establish a pane is NOT waiting on the
#: human. Anything else (incl. UNKNOWN, or no reading at all) leaves a pushed
#: `blocked` standing — fail toward showing a row, never toward hiding one.
SCREEN_NOT_BLOCKED = ("WAITING", "ACTIVE", "WAITING_ON_BACKGROUND")


def _hook_preview_outranks(hook_question, screen_read_age, now):
    """May the hook's question preview overrule the stale screen? Exactly the
    screen_outranks_hook rule, mirrored: only a hook event NEWER than the
    newest possible screen reading wins. A newer screen read had its chance
    and said nothing — the preview drops (this is also what retires a dead
    session's orphaned sidecar within one sweep). No time-based expiry on top:
    the screen is the authority. A screen feed that never succeeded has no
    reading to outrank anything, so the preview shows (fail toward showing)."""
    if not isinstance(hook_question, dict) or not hook_question.get("ts"):
        return False
    if screen_read_age is None:
        return True
    return (now - hook_question["ts"]) < screen_read_age


def _row(kind, label, pane_id, detail, since_sec, identity=None):
    return {
        "kind": kind,
        "urgency": URGENCY.get(kind, 9),
        "label": label,
        "paneId": pane_id,
        "detail": detail,
        "sinceSec": since_sec,
        # A stable per-worker id (a session id) when the source has one, used
        # ONLY for dedupe. Labels are human-chosen and DO collide — two live
        # workers on this machine share one today — so collapsing by label
        # would silently drop one of two rows the human has to act on.
        "identity": identity,
    }


def build_needs_you(feeds_snap, agents):
    """The one list the dashboard exists for — narrowed to ONE question (PO
    ruling 2026-09-06): WHICH PANE IS STOPPED, WAITING FOR ME TO TYPE?

    Exactly two things put a worker here, and both are a prompt drawn on its
    screen right now with the cursor parked on it:

      * `question` — an AskUserQuestion picker is open. Answerable inline.
      * `blocked`  — a permission request ("Claude needs your permission to
                     use Bash"). Terminal-only; the human must go and press.

    Plus `feed-broken`, which is not a worker at all: it is the list saying it
    cannot see. Without it an empty page would read "nothing needs you" while
    blind, and that is the one lie this list must never tell.

    WHAT WAS REMOVED, AND WHY IT WAS NOT A LOSS
    -------------------------------------------
    The earlier version also ranked `done`, `asked`, `gone`, `stalled`,
    `crashed` and `needs-human` — a worker that FINISHED, a worker that died,
    a worker that went quiet. All real, none of them a prompt: nothing is
    stopped waiting for a keystroke, so nothing is lost by not putting them at
    the top of the page. They stay in the BOARD section, which is the
    inventory (every session, live and ended, with its last line and its
    controls). The split is now clean: NEEDS YOU is a keyboard queue, BOARD is
    everything else.

    In practice this was also where the noise lived: measured on this machine
    the same afternoon, 10 of 12 rows were `done` — finished workers with
    nothing owed — which is exactly the pile that trains a human to stop
    reading the list.

    WHAT DID NOT CHANGE
    -------------------
      * Residue is still never a row. The hook only deletes its cache file on
        a graceful SessionEnd, so a closed tab leaves one behind forever; a
        cache file whose pane no longer exists is dropped outright.
      * Sessions from other projects are still inventory, not action. They
        have no state hook and their screens do not classify, so the only
        signal is herdr's own guess — the guess this dashboard exists because
        it is wrong. They live in the BOARD.
      * Fail-open is still the rule. Where the screen cannot confirm or deny a
        pushed `blocked`, the row SHOWS. A false positive costs a glance; a
        false negative leaves a worker stopped forever.
    """
    rows = []
    # A pushed `blocked` with no screen reading is shown rather than hidden —
    # a false positive costs a glance, a false negative means the human never
    # learns a worker is waiting. But that fail-open must not fire when the
    # screen feed has NEVER succeeded: then EVERY pane is unreadable, and the
    # rule turns the whole list back into the noise it was built to remove.
    # The feed itself raises a FEED BROKEN row in that case, so nothing is lost.
    screen_feed_usable = feeds_snap["paneScreen"]["lastSuccessTs"] is not None
    # How old the newest screen reading is. The permission notifier fires ~6s
    # after a prompt appears but the screen feed only refreshes every 45s, so a
    # reading taken BEFORE the block began would otherwise veto the row for up
    # to 45s — at exactly the moment a worker is stuck (QA, 2026-09-03).
    # Feed-level, so it is the age of the pass, not of one pane's reading. That
    # pass is a sequential loop with a 15s timeout PER PANE: healthy it takes
    # ~0.2s for 18 panes, but a degraded herdr can make the first pane read far
    # older than `ageSec` claims, and a stale WAITING would then veto a fresh
    # hook `blocked` — a genuinely blocked worker with no row, the worst failure
    # this list has. So charge the whole pass duration against the reading. The
    # comparison is deliberately one-directional: a hook event newer than the
    # newest possible reading wins, which is correct, not a missing case.
    screen_read_age = feeds_snap["paneScreen"]["ageSec"]
    if screen_read_age is not None:
        screen_read_age += feeds_snap["paneScreen"].get("lastDurationSec") or 0
    now = time.time()

    for a in agents:
        # Residue: a hook cache file whose pane is gone. Never a row — and now
        # not even when it died mid-`working`, because a dead pane has no
        # prompt on it and no keystroke can reach it.
        if a.get("orphanHook"):
            continue

        pane_id = a.get("paneId") or a.get("paneIdSanitized")
        label = a["label"]
        age = a["hookSinceSec"]
        if claude_sessions.is_status_only_row(a):
            # P4: no pane, no screen — the session's own `waiting` status is
            # the whole signal. Answered in its own app, or — when the
            # PermissionRequest hook sent it — via `hookRequest`.
            if a["hookState"] == "blocked":
                row = _row("blocked", label, None, a.get("hookReason")
                           or claude_sessions.DEFAULT_WAITING_REASON, age,
                           identity=a.get("agentSession"))
                row["permission"] = None
                row["source"] = a["source"]
                row["agentSession"] = a.get("agentSession")
                row["openUrl"] = a.get("openUrl")
                row["hookRequest"] = a.get("hookRequest")
                row["transcriptQuestion"] = a.get("transcriptQuestion")
                rows.append(row)
            continue
        screen = a.get("screenState")
        signal = a.get("screenSignal")
        # Only a reading at least as new as the hook event may overrule it.
        screen_outranks_hook = (
            screen_read_age is not None and age is not None
            and age >= screen_read_age)

        if screen == "NEEDS_HUMAN":
            # Screen signal FIRST here: `hookReason` is the vendor's generic
            # notification copy ("Claude needs your permission to use Bash")
            # and never names the actual command or question, while the screen
            # line is the prompt the human has to answer.
            #
            # An open AskUserQuestion picker is a NEEDS_HUMAN with a parsed
            # block attached — it outranks a bare permission prompt as its own
            # kind ("question") so the page can render the full question with
            # answer buttons instead of one truncated line. Plain permission
            # prompts have no parsed block and stay "blocked", terminal-only.
            question = a.get("screenQuestion")
            kind = "question" if question else "blocked"
            row = _row(kind, label, pane_id,
                       signal or a.get("hookReason")
                       or "a prompt is waiting for your answer", age)
            row["question"] = question
            if kind == "blocked":
                # A plain permission box's parsed detail (tool/command/file),
                # or None when it can't be read confidently — see
                # parse_permission_block's module comment. `question`-kind
                # rows never carry this; the two stay mutually exclusive.
                row["permission"] = a.get("screenPermission")
            rows.append(row)
        elif screen == "NEEDS_LOGIN":
            # The session is logged out: nothing sent to it is ever answered
            # until a person runs /login in its pane. That is a stopped pane
            # only the human can unstick, so it belongs in this keyboard queue
            # (it read as an ordinary idle worker before, and nobody was told).
            row = _row("blocked", label, pane_id,
                       "not logged in — run /login in this pane", age)
            row["permission"] = None
            rows.append(row)
        elif _hook_preview_outranks(a.get("hookQuestion"), screen_read_age, now):
            # Phase 5: the hook saw a picker open AFTER the last sweep read
            # this pane, so the stale screen (ACTIVE/WAITING) has not caught
            # up yet. Emit the question row NOW with the display-only preview
            # — no `question` key, so no Confirm button anywhere, and the
            # sweep's parsed copy replaces it within one interval. Gating this
            # on the screen already agreeing would build nothing; dropping it
            # the moment a NEWER screen read says not-NEEDS_HUMAN is what
            # retires a SIGKILLed session's preview within one sweep.
            hq = a["hookQuestion"]
            opts = " · ".join(f"{o['index']}. {o['label']}" for o in hq["options"])
            head = f"{hq['title']}: {hq['question']}" if hq["title"] else hq["question"]
            row = _row("question", label, pane_id,
                       f"{head} [{opts}]"
                       " (options loading — answerable picker lands at next sweep)"
                       if opts else f"{head} (options loading — answerable picker lands at next sweep)",
                       now - hq["ts"] if hq["ts"] else age)
            row["questionPreview"] = {
                "title": hq["title"], "question": hq["question"],
                "multi": hq["multi"], "options": hq["options"],
            }
            rows.append(row)
        elif (a["hookState"] == "blocked" and screen_feed_usable
              and not (screen in SCREEN_NOT_BLOCKED and screen_outranks_hook)):
            # The hook says a prompt is up but the screen has not confirmed it.
            # Shown, per fail-open — a permission prompt the human never sees
            # stops that worker until they happen to look at the pane.
            row = _row(
                "blocked", label, pane_id,
                (a.get("hookReason") or "the worker reported it is waiting on a human")
                + (" (unconfirmed — its screen could not be read)"
                   if screen is None else f" (screen reads {screen})"), age)
            # Always present on a "blocked" row, even when unparsable — a
            # client checking row.permission should never have to special-
            # case a missing key vs. an explicit null.
            row["permission"] = a.get("screenPermission")
            rows.append(row)

    for feed_name, f in feeds_snap.items():
        if "broken" not in f:
            continue  # not a Feed snapshot — e.g. the "machines" per-machine
            # health rollup get_full_state() adds to its own feeds dict (R7).
        if f["broken"] and not f.get("warming"):
            rows.append(_row("feed-broken", f"{feed_name} feed", None,
                             f["error"] or "no successful poll yet", f["ageSec"]))

    # One pane, one row: keep only its most urgent reason, so a worker whose
    # picker is both parsed and previewed is not listed twice.
    best = {}
    unkeyed = {}
    for r in rows:
        if not r["paneId"]:
            # No pane id to correlate on, so fall back to the row's own
            # identity: same kind about the same worker is one row. Prefer the
            # session id over the label — see _row().
            key = (r["kind"], r["identity"] or f"label:{r['label']}")
            if key not in unkeyed or r["urgency"] < unkeyed[key]["urgency"]:
                unkeyed[key] = r
            continue
        prev = best.get(r["paneId"])
        if prev is None or r["urgency"] < prev["urgency"]:
            best[r["paneId"]] = r

    merged = list(best.values()) + list(unkeyed.values())
    merged.sort(key=lambda r: (r["urgency"], -(r["sinceSec"] or 0)))
    return merged


# P0 dashboard move: build_git_view (gitHealth feed) is RETIRED — no
# MOVE-set caller. build_chief_pass moved OUT of this file entirely — it now
# lives in chief_dashboard_pass.py (restored 2026-09-25, generic — see that
# module's docstring), split out rather than grown here since its own
# concerns (locating an optional per-project script, loading another
# project's module by path) don't belong with this file's "pure functions
# over feed snapshots" job. _pane_tick_by_pane_id / the paneTick feed are
# KEPT below — get_agent_tree_state (AgentBar's agent hierarchy view) still
# reads them for each row's status_by_pane.


def _pane_tick_by_pane_id(feeds_snap):
    """Index the pane-tick-writer LaunchAgent's cached per-agent verdicts
    (supervise_panes(), refreshed ~every 2min) by paneId — get_agent_tree_state
    uses this to label each agent-tree row's status."""
    data = feeds_snap["paneTick"]["data"] or {}
    by_pane = {}
    for a in data.get("agents") or []:
        pane_id = a.get("paneId")
        if pane_id:
            by_pane[pane_id] = a
    return by_pane


def get_full_state():
    feeds_snap = {name: f.snapshot() for name, f in FEEDS.items()}
    agents = build_agents_view(feeds_snap)
    disagreements = [a for a in agents if a["disagree"]]
    residue_count = sum(1 for a in agents if a.get("residue"))
    # build_needs_you walks feeds_snap.items() assuming every value is a Feed
    # snapshot ({"broken", "warming", "error", ...}). machines_status()'s
    # per-machine summary below is NOT that shape ({name: {"status", "error",
    # "ageSec", "agentCount"}}) — computed here, BEFORE it's added, so it
    # never iterates over it and KeyErrors on "broken" (measured live: every
    # /api/state request 500'd the instant .claude/dashboard-machines.json
    # existed).
    needs_you = build_needs_you(feeds_snap, agents)
    # R7: a compact per-machine health summary alongside the raw per-machine
    # feed entries already in feeds_snap (herdr:<m>, paneScreen:<m>) — one
    # place the SPA badge reads instead of re-deriving broken/warming/ok
    # from two feed keys per machine. Absent entirely when no machine is
    # configured (today's exact shape — no new key for zero machines).
    feeds_snap = dict(feeds_snap)
    sleeping = _sleeping_sessions(feeds_snap, agents)
    if MACHINES:
        feeds_snap["machines"] = machines_status()
    # A parse error must survive even though it always makes MACHINES falsy
    # (parse_machines_config's all-or-nothing contract) — otherwise a single
    # typo in dashboard-machines.json is indistinguishable, from /api/state,
    # from "no config file at all", and the whole machines feature goes dark
    # with no diagnostic. Always present (null when there's no error) so the
    # UI can tell "no config" from "broken config" without guessing.
    feeds_snap["machinesConfigError"] = MACHINES_CONFIG_ERROR
    return {
        "serverTimeTs": time.time(),
        "feeds": feeds_snap,
        "computed": {
            "agents": [a for a in agents if not a.get("residue")],
            "residueCount": residue_count,
            "disagreementCount": len(disagreements),
            "needsYou": needs_you,
            # Claude Desktop sessions with no running process (AgentBar's
            # "sleeping" rows) — kept out of `agents`: not live, no status.
            "sleepingSessions": sleeping,
        },
    }


def _sleeping_sessions(feeds_snap, agents):
    """computed.sleepingSessions from the desktopSessions feed. `feeds_snap`
    (a per-request copy) then carries only the feed's health + a count, so the
    rows are not sent twice on every push."""
    desktop_feed = feeds_snap.get("desktopSessions")
    if not desktop_feed:
        return []
    live_sessions = (feeds_snap.get("claudeSessions") or {}).get("data")
    # Until the live-session feed has read once (startup), every RUNNING
    # Desktop session would pass the live-wins dedup and show as sleeping.
    sleeping = ([] if live_sessions is None else
                desktop_sessions.build_sleeping_sessions(desktop_feed.get("data"), live_sessions, agents))
    feeds_snap["desktopSessions"] = dict(desktop_feed, data={"sleepingCount": len(sleeping)})
    return sleeping


# ── agent hierarchy (scripts/lib/agent_tree.py): GET /api/agent-tree,
#    POST /api/agent-tree/attach|detach — thin handlers in the server, all
#    logic here ──

def get_agent_tree_state():
    """GET /api/agent-tree's payload — agent_tree.build_agent_tree's CONTRACT
    (see that module's docstring; AgentBar is built against these exact field
    names). Fed by this dashboard's own already-polled roster
    (build_agents_view: local herdr `agent list` + every configured remote
    machine) — that call is system-wide, not scoped to this project, so
    other projects' chiefs/workers on this Mac and every Air agent are
    already in it with zero extra herdr calls. `status` per row comes from
    the pane-tick heartbeat's cached verdict (`_pane_tick_by_pane_id`)."""
    feeds_snap = {name: f.snapshot() for name, f in FEEDS.items()}
    agents = build_agents_view(feeds_snap)
    status_by_pane = {pane_id: (cached.get("verdict"))
                      for pane_id, cached in _pane_tick_by_pane_id(feeds_snap).items()}
    return agent_tree.build_agent_tree(agents, agent_tree.read_edges(),
                                       status_by_pane=status_by_pane)


def _known_agent_ids_and_projects():
    """(known_ids, {agentId: project}) from this dashboard's own live roster
    — the "live id set it already has" agent_tree.attach()'s `known_ids`
    param asks the caller to pass (module docstring). Cheap: same snapshot
    reads get_agent_tree_state() already does, no extra herdr calls."""
    feeds_snap = {name: f.snapshot() for name, f in FEEDS.items()}
    agents = build_agents_view(feeds_snap)
    known_ids, projects = set(), {}
    for a in agents:
        sid = a.get("agentSession")
        if not sid:
            continue
        known_ids.add(sid)
        projects[sid] = agent_tree.project_for_cwd(a.get("cwd"))[0]
    return known_ids, projects


def agent_tree_attach(child, parent, confirm_cross_project=False):
    """POST /api/agent-tree/attach's logic. Returns (payload, status):
    200 {"ok": True, "warning": str|None}; 409 {"error": "cross-project",
    "needsConfirm": True, "message": ...} when the two agents are in
    different projects and the caller hasn't confirmed yet; 400 for
    self/cycle/two-level/unknown-agent (agent_tree.AgentTreeError's own
    `code`/message, passed straight through as the contract's `error`).

    The 409 confirm gate is a UI convenience layered on TOP of
    agent_tree.attach() — that function itself never refuses on
    crossProject alone (its own docstring), so a caller that already knows
    to pass confirm_cross_project=True (a retried request) skips this
    check entirely and only agent_tree's own validation can still reject."""
    if not child or not parent:
        return {"error": agent_tree.ERROR_UNKNOWN_AGENT,
                "message": "both child and parent session ids are required"}, 400
    known_ids, projects = _known_agent_ids_and_projects()
    child_project, parent_project = projects.get(child), projects.get(parent)
    cross_project = bool(child_project and parent_project and child_project != parent_project)
    if cross_project and not confirm_cross_project:
        return {"error": "cross-project", "needsConfirm": True,
                "message": f"{child} ({child_project}) and {parent} ({parent_project}) "
                           "are in different projects — attach anyway?"}, 409
    try:
        agent_tree.attach(child, parent, known_ids=known_ids, set_by="dashboard")
    except agent_tree.AgentTreeError as e:
        return {"error": e.code, "message": str(e)}, 400
    return {"ok": True,
            "warning": (f"cross-project: {child_project} -> {parent_project}"
                       if cross_project else None)}, 200


def agent_tree_detach(child):
    """POST /api/agent-tree/detach's logic. Always 200 {"ok": True} — a
    detach of an id with no edge is a no-op, not an error (agent_tree.detach's
    own contract), so there is nothing for the caller to retry differently."""
    if not child:
        return {"error": agent_tree.ERROR_UNKNOWN_AGENT, "message": "child session id is required"}, 400
    agent_tree.detach(child)
    return {"ok": True}, 200


