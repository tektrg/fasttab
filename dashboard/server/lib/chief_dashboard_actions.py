#!/usr/bin/env python3
"""The v3-reclaim destructive ladder: Stop agent → Close pane → Relaunch here.

Lives beside (not inside) chief_dashboard_views.py / chief_dashboard_feeds.py
— HARD RULE: the pure layer four phases depend on is untouched. The server
calls `assess_row()` per live agent to fill `actions:[{name, enabled,
needsConfirm, reason}]` (the UI renders, never decides), and the three
`do_*()` executors behind POST /api/session/{stop,close,relaunch}.

Guard posture, from the brief:
  - The dashboard server's own pane and the chief's pane can NEVER be
    stopped/closed/relaunched. Enforced HERE, server-side — a hidden button
    is not a guard.
  - Agent-session panes ONLY. Dev-server panes (`aptusfit-metro`,
    `aptusfit-backend`) are refused with the "later pass" reason.
  - `actor` must be `po`. Honest comment: this guards against ACCIDENT, not
    attack — anything can claim to be the PO. The real barrier is that no
    stop tool will ever exist in MCP (phase 7).
"""

import os
import re
import signal
import subprocess
import time

import chief_dashboard_herdr as herdr_transport
import claude_sessions  # P4: status-only (paneless) rows

try:
    from chief_dashboard_feeds import REPO_ROOT, MACHINES
except Exception:  # pragma: no cover
    REPO_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "..", "..")
    MACHINES = {}

#: Actions this module refuses on a remote row outright — never routed to
#: the wrapper at all (D1/D3/R14). Stop kills LOCAL process ids (this Mac's
#: `ps`/`kill`), Relaunch is remote-launch scope (phase 2 by the ask).
REMOTE_REFUSED_ACTIONS = ("stop", "relaunch")

try:
    from chief_dashboard_memory import (
        parse_ps, sum_tree, _pane_foreground_pids, format_bytes,
    )
except Exception:  # pragma: no cover
    from chief_dashboard_memory import parse_ps, sum_tree  # type: ignore
    _pane_foreground_pids = None
    format_bytes = None

#: Tab labels that are dev servers, not agent sessions. PO ruling: the ladder
#: targets agent-session panes only; dev-server control belongs to a later
#: health-plus-control pass, not bolted onto a memory button.
DEV_SERVER_LABELS = frozenset({"aptusfit-metro", "aptusfit-backend"})

#: The chief's tab label. The dashboard server's OWN pane is detected
#: dynamically (ancestor walk) — a label match would be spoofable by renaming.
CHIEF_TAB_LABEL = "chief"

#: Only the PO destroys. The browser sends `po`; anything else is refused.
PO_ACTOR = "po"

#: Archive is board-only tidying (hides the row, frees nothing) — the only
#: action the chief will ever hold (phase 7). Both may archive/unarchive.
ARCHIVE_ACTORS = ("po", "chief")

#: Grace period between SIGTERM and SIGKILL when stopping an agent tree.
STOP_GRACE_SEC = 3

#: `git status --porcelain` in fe/ is the "real stake" behind the confirm
#: (several sessions share ONE checkout). Refreshed at most this often — the
#: 2s render tick must stay cheap.
UNCOMMITTED_TTL_SEC = 60

_FE_ROOT = os.path.join(REPO_ROOT, "fe")

_uncommitted_cache = {"ts": 0.0, "count": 0}


def check_actor(actor, allowed=(PO_ACTOR,)):
    """Refuse anyone outside `allowed`. Accident guard, not security (see
    module docstring) — the real barrier is no MCP stop tool, ever. The
    ladder allows only `po`; archive/unarchive also allow `chief`."""
    if actor not in allowed:
        want = " or ".join(f"'{a}'" for a in allowed)
        return (False,
                f"refused: this action needs actor {want} (got "
                f"'{actor}') — accident guard, not attack-proof")
    return True, ""


def own_server_pane_id(pane_ids_fn=None, proc_info_fn=None, ps_fn=None):
    """Which pane hosts THIS server process, via an ancestor walk.

    `ps` gives pid->ppid; walk up from os.getpid() and find the pane whose
    shell_pid is an ancestor. Returns None when it cannot be proven (fail
    closed: callers treat unknown as unguardable and refuse? No — callers
    treat a None own-pane as "no self-match", because refusing EVERYTHING on
    a measurement failure would brick the feature. The walk failing only
    matters if the target IS our pane, and then the pane's own shell_pid
    lookup fails too. Documented, not silent.)
    """
    try:
        out = (ps_fn or _default_ps)()
        ppid_of, _ = parse_ps(out)
    except Exception:
        return None
    ancestors = set()
    pid = os.getpid()
    for _ in range(64):
        ppid = ppid_of.get(pid)
        if not ppid:
            break
        ancestors.add(ppid)
        pid = ppid
    try:
        ids = list((pane_ids_fn or _default_pane_ids)() or [])
    except Exception:
        return None
    for pane_id in ids:
        try:
            shell = (proc_info_fn or _default_shell_pid)(pane_id)
        except Exception:
            continue
        if shell is not None and shell in ancestors:
            return pane_id
    return None


def _default_ps():
    proc = subprocess.run(["ps", "-eo", "pid=,ppid=,rss="],
                          timeout=15, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError("ps failed")
    return proc.stdout


def _default_pane_ids():
    """own_server_pane_id() is inherently local-only — this server process
    can only ever run on this Mac — so this stays a bare local call, never
    machine-parameterized."""
    data = herdr_transport.herdr_cmd_json(
        "local", ["pane", "list"], repo_root=REPO_ROOT, timeout=10)
    return [p.get("pane_id") for p in
            (data.get("result") or {}).get("panes") or [] if p.get("pane_id")]


def _default_shell_pid(pane_id):
    try:
        data = herdr_transport.herdr_cmd_json(
            "local", ["pane", "process-info", "--pane", pane_id],
            repo_root=REPO_ROOT, timeout=10)
    except herdr_transport.HerdrError:
        return None
    shell = ((data.get("result") or {}).get("process_info") or {}).get(
        "shell_pid")
    try:
        return int(shell)
    except (TypeError, ValueError):
        return None


def uncommitted_count_fe(force=False, _now=None):
    """Uncommitted working-tree files in fe/ (the shared checkout). Cached
    ~60s; failures read 0 with the count simply omitted from the reason."""
    now = _now if _now is not None else time.time()
    if not force and now - _uncommitted_cache["ts"] < UNCOMMITTED_TTL_SEC:
        return _uncommitted_cache["count"]
    count = 0
    try:
        proc = subprocess.run(
            ["git", "status", "--porcelain"], cwd=_FE_ROOT,
            timeout=15, capture_output=True, text=True,
        )
        if proc.returncode == 0:
            count = sum(1 for line in proc.stdout.splitlines() if line.strip())
    except Exception:
        count = 0
    _uncommitted_cache.update(ts=now, count=count)
    return count


def owners_of_session(row_id, agent, runs, manual_links):
    """Work-item refs (itemIds) this session owns, for the confirm string.

    Three sources, strongest last-wins per item: the record's own fields
    (absent in practice — session/pane are null on every record today), the
    item number in the tab label (heuristic), manual board links (certain).
    Returns ["1867 (claimed)", ...] sorted. Empty = owns nothing.
    """
    try:
        from chief_dashboard_store import item_numbers_in_label
    except Exception:  # pragma: no cover
        import re
        def item_numbers_in_label(label):
            return set(re.compile(r"\d{3,5}").findall(label or ""))

    agent_session = (agent or {}).get("agentSession")
    pane_id = (agent or {}).get("paneId")
    label = (agent or {}).get("label") or ""
    label_nums = item_numbers_in_label(label)
    by_item = {}  # itemId -> "claimed ..." marker
    for run_key, record in (runs or {}).items():
        record = record or {}
        item_id = str(record.get("itemId") or "")
        if not item_id:
            continue
        hit = False
        # Guard every side: null must never equal null. A null record
        # session equalled a null agent session, and `None in (pane, None)`
        # matched a null record pane — either "match" claimed every work
        # item for every session-less row (caught live 2026-09-05).
        rec_session = record.get("session")
        rec_pane = record.get("pane")
        if agent_session and rec_session and rec_session == agent_session:
            hit = True
        elif pane_id and rec_pane and rec_pane in (
                pane_id, (agent or {}).get("paneIdSanitized")):
            hit = True
        elif item_id in label_nums:
            hit = True
        if hit:
            by_item[item_id] = ("claimed" if record.get("by") else
                                str(record.get("stage") or "open"))
    for link in manual_links or []:
        if (link.get("targetKind") == "session"
                and link.get("targetId") == row_id):
            work = str(link.get("workRowId") or "")
            item_id = work.split(":", 1)[-1] if ":" in work else work
            # Notion page ids are not item numbers — only keep numeric ones.
            if item_id.isdigit():
                by_item[item_id] = "claimed"
    return [f"{i} ({by_item[i]})" for i in sorted(by_item)]


def state_word(agent):
    """The state the confirm names: hookState where the worker reports,
    else herdr's guess, else the screen class. `idle` only when SAID idle —
    no hook data reads `unknown`, never idle (one click must be earned)."""
    if (agent or {}).get("hasHookData") and (agent or {}).get("hookState"):
        return (agent or {})["hookState"]
    if (agent or {}).get("herdrStatus"):
        return (agent or {})["herdrStatus"]
    return (agent or {}).get("screenState") or "unknown"


def build_reason(agent, memory_bytes, uncommitted, owners):
    """`working · 3 uncommitted files in fe/ · owns 1867 (claimed) · 2.1 GB`.
    Absent stakes are omitted (no uncommitted files = no clause), but the
    state word is always first."""
    parts = [state_word(agent)]
    if uncommitted:
        parts.append(
            f"{uncommitted} uncommitted file{'s' if uncommitted != 1 else ''} "
            "in fe/")
    for o in owners or []:
        parts.append(f"owns work item {o}")
    if memory_bytes:
        parts.append(format_bytes(memory_bytes) if format_bytes else
                     f"{memory_bytes} B")
    return " · ".join(parts)


def _guarded_refusal(why, is_archived=False):
    """ stop/close/relaunch off with the guard's reason; archive stays on —
    hiding a row is tidying, not destruction, and the chief tidies."""
    out = {n: {"enabled": False, "needsConfirm": False, "reason": why}
           for n in ("stop", "close", "relaunch")}
    out["archive"] = {"enabled": not is_archived, "needsConfirm": False,
                      "reason": ("board-only: hides the row, frees nothing"
                                 if not is_archived
                                 else "already archived")}
    out["unarchive"] = {"enabled": bool(is_archived), "needsConfirm": False,
                        "reason": ("restore to the default view"
                                   if is_archived
                                   else "not archived — nothing to restore")}
    return out


def assess_row(agent, row_id, *, live_pane_ids, memory_bytes=None,
               uncommitted=0, owners=(), own_pane=None, was_stopped=False,
               is_archived=False, machine=herdr_transport.LOCAL_MACHINE):
    """Server-side availability for one row. Returns
    `{name: {enabled, needsConfirm, reason}}` for stop/close/relaunch/
    archive/unarchive — the UI renders these and computes nothing itself.

    `live_pane_ids` is the pane feed (the truth for availability, never a
    stored flag) — for a remote row this must already be that machine's own
    pane-id set, never this Mac's, or a live remote pane misreads as gone.
    `own_pane` is this server's pane (ancestor walk, cached by the caller;
    inherently local — a remote pane can never be this server's own pane).
    `was_stopped` marks a pane the ladder already stopped: its hook state is
    stale, and the stake died with the agent — Close drops to one click and
    Relaunch (the undo) is offered.

    `machine` gates Stop/Relaunch outright (D1/D3/R14): both operate on a
    LOCAL process tree via this Mac's ps/kill, so routing either at a remote
    row would be silently wrong, not just unsupported. That refusal is
    applied last and wins over every other stop/relaunch branch above.
    """
    pane_id = (agent or {}).get("paneId")
    label = (agent or {}).get("label") or ""
    session = (agent or {}).get("agentSession")
    alive = bool(pane_id) and pane_id in (live_pane_ids or set())

    if claude_sessions.is_status_only_row(agent):
        why = (f"refused: {agent['source']} session, not a herdr pane — "
               "status only, act on it in its own app")
        return _guarded_refusal(why, is_archived)
    if pane_id and pane_id == own_pane:
        why = ("refused: this is the dashboard server's own pane — "
               "self-destruct is structurally impossible")
        return _guarded_refusal(why, is_archived)
    if label == CHIEF_TAB_LABEL:
        why = ("refused: the chief's pane can never be stopped from the "
               "board")
        return _guarded_refusal(why, is_archived)
    if label in DEV_SERVER_LABELS:
        why = ("refused: dev-server panes are out of scope here — "
               "server/repo/simulator health and their controls come in a "
               "later pass")
        return _guarded_refusal(why, is_archived)

    reason = build_reason(agent, memory_bytes, uncommitted, owners)
    idle = state_word(agent) == "idle"
    out = {}
    # Stop: needs the live pane AND a live agent. Re-stopping an already
    # stopped pane would walk the shell's tree and SIGTERM the pane itself
    # — refuse instead. Idle acts on one click; anything else needs the
    # second click naming the stake.
    if was_stopped:
        out["stop"] = {"enabled": False, "needsConfirm": False,
                       "reason": "refused: already stopped — the pane is "
                                 "empty, Close it or Relaunch here"}
    elif alive:
        out["stop"] = {"enabled": True, "needsConfirm": not idle,
                       "reason": reason}
    else:
        out["stop"] = {"enabled": False, "needsConfirm": False,
                       "reason": "refused: pane is gone — nothing to stop"}
    # Close: only when the pane still exists. Each stage carries the confirm
    # rule — a busy pane names its stake twice. After a logged stop the
    # agent is already dead, so the stake died with it: one click.
    if alive:
        out["close"] = {"enabled": True,
                        "needsConfirm": (not idle) and (not was_stopped),
                        "reason": reason}
    else:
        out["close"] = {"enabled": False, "needsConfirm": False,
                        "reason": "refused: pane is already gone"}
    # Relaunch: the undo for Stop, back into the SAME (now empty) pane.
    # Offered only there: typing a resume into a live agent's pane would
    # hijack real work, and a gone pane has nowhere to relaunch into.
    # (`was_stopped` is the display gate; the executor re-verifies the
    # foreground is actually empty before typing anything.)
    out["relaunch"] = {
        "enabled": bool(alive and session and was_stopped),
        "needsConfirm": False,
        "reason": (reason if (alive and session and was_stopped) else
                   ("refused: relaunch is the undo for Stop — "
                    + ("stop this pane first" if alive and session
                       else ("pane is gone" if not alive
                             else "no session id on this row")))),
    }
    # Archive is board-only tidying: it hides the row, frees nothing, touches
    # no process — so it is always one click, needs no confirm, and stays
    # available on ended rows too. Unarchive mirrors it. The guards above
    # (own pane, chief, dev-servers) do NOT apply: hiding is not destruction,
    # and the chief tidies.
    if is_archived:
        out["archive"] = {"enabled": False, "needsConfirm": False,
                          "reason": "already archived — unarchive to restore"}
        out["unarchive"] = {"enabled": True, "needsConfirm": False,
                            "reason": "restore to the default view"}
    else:
        out["archive"] = {"enabled": True, "needsConfirm": False,
                          "reason": ("board-only: hides the row, frees "
                                     "nothing, touches no process")}
        out["unarchive"] = {"enabled": False, "needsConfirm": False,
                            "reason": "not archived — nothing to restore"}
    if machine != herdr_transport.LOCAL_MACHINE:
        for name in REMOTE_REFUSED_ACTIONS:
            out[name] = {
                "enabled": False, "needsConfirm": False,
                "reason": (f"n/a on remote — {name} operates on this Mac's "
                           f"own process tree, not {machine}'s (phase 1)"),
            }
    return out


# ── Executors (each looks its target up fresh, refuses loudly, never assumes:
#    the house style of POST /api/focus and POST /api/answer) ──

def _live_panes(machine=herdr_transport.LOCAL_MACHINE):
    try:
        data = herdr_transport.herdr_cmd_json(
            machine, ["pane", "list"], repo_root=REPO_ROOT, machines=MACHINES,
            timeout=10)
    except herdr_transport.HerdrError as e:
        raise RuntimeError(f"herdr pane list failed on {machine} — {e}")
    return (data.get("result") or {}).get("panes") or []


def _tabs_by_id(machine=herdr_transport.LOCAL_MACHINE):
    try:
        data = herdr_transport.herdr_cmd_json(
            machine, ["tab", "list"], repo_root=REPO_ROOT, machines=MACHINES,
            timeout=10)
    except herdr_transport.HerdrError as e:
        raise RuntimeError(f"herdr tab list failed on {machine} — {e}")
    tabs = (data.get("result") or {}).get("tabs") or []
    return {t.get("tab_id"): t for t in tabs if t.get("tab_id")}


def _pane_fg_and_shell(pane_id, machine=herdr_transport.LOCAL_MACHINE, timeout=10):
    """(foreground pids, shell pid) for one pane. A pane sitting at a shell
    prompt lists the shell itself as foreground — callers deciding "is an
    agent running here" must exclude shell_pid, or every stopped pane reads
    busy and Relaunch can never fire.

    Foreground pids only ever mean something on the machine that owns them
    — a remote pane's "shell_pid" is a pid on the Air, never comparable to
    this Mac's process tree (R9/R12: callers must not treat it as local)."""
    try:
        data = herdr_transport.herdr_cmd_json(
            machine, ["pane", "process-info", "--pane", pane_id],
            repo_root=REPO_ROOT, machines=MACHINES, timeout=timeout)
    except herdr_transport.HerdrError:
        raise RuntimeError(f"pane {pane_id} not found — likely closed")
    info = (data.get("result") or {}).get("process_info") or {}
    fg = []
    for fp in info.get("foreground_processes") or []:
        try:
            fg.append(int(fp.get("pid")))
        except (TypeError, ValueError):
            continue
    try:
        shell = int(info.get("shell_pid"))
    except (TypeError, ValueError):
        shell = None
    return fg, shell


def agent_pids_in_pane(pane_id, machine=herdr_transport.LOCAL_MACHINE):
    """Foreground pids that are NOT the pane's own shell. Empty = the pane
    is stopped/at-prompt — stoppable nothing, relaunchable. Remote pids
    (see _pane_fg_and_shell) are only ever used for the "is busy" check
    here, never handed to a local os.kill."""
    fg, shell = _pane_fg_and_shell(pane_id, machine=machine)
    return [p for p in fg if p != shell]


def _tree_pids(roots):
    """roots + all descendants from ONE ps snapshot."""
    """roots + all descendants from ONE ps snapshot."""
    proc = subprocess.run(["ps", "-eo", "pid=,ppid=,rss="],
                          timeout=15, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError("ps failed — cannot map the process tree")
    ppid_of, _ = parse_ps(proc.stdout)
    children = {}
    for pid, ppid in ppid_of.items():
        children.setdefault(ppid, []).append(pid)
    seen, stack = set(), list(roots or [])
    while stack:
        pid = stack.pop()
        if pid in seen:
            continue
        seen.add(pid)
        stack.extend(children.get(pid, ()))
    return seen


def _refuse_if_remote(action_name, machine):
    """Stop and Relaunch both act on a LOCAL process tree (this Mac's own
    ps/kill/pane-run) — never route either at a remote machine, not even to
    let the wrapper's ssh call fail loudly. Raise before any subprocess."""
    if machine != herdr_transport.LOCAL_MACHINE:
        raise RuntimeError(
            f"{action_name} is n/a on remote machine '{machine}' (phase 1) "
            "— it operates on this Mac's own process tree")


def do_stop(pane_id, kill_fn=None, sleep_fn=None, roots_fn=None,
            machine=herdr_transport.LOCAL_MACHINE):
    """SIGTERM the pane's foreground process tree, wait 3s, SIGKILL
    survivors. Frees essentially all the session's RAM; the pane stays."""
    _refuse_if_remote("stop", machine)
    panes = _live_panes()
    if not any(p.get("pane_id") == pane_id for p in panes):
        raise RuntimeError(f"pane {pane_id} not found — likely closed")
    roots = (roots_fn(pane_id) if roots_fn is not None
             else ((_pane_foreground_pids(pane_id)
                    if _pane_foreground_pids else [])))
    if not roots:
        raise RuntimeError(
            f"pane {pane_id} has no foreground process — nothing to stop")
    me = os.getpid()
    victims = sorted(p for p in _tree_pids(roots)
                     if p != me and p > 1)
    if not victims:
        raise RuntimeError("nothing stoppable in that pane's tree")
    kill = kill_fn or os.kill
    for pid in victims:
        try:
            kill(pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            continue
    (sleep_fn or time.sleep)(STOP_GRACE_SEC)
    survivors = sorted(p for p in _tree_pids(roots) if p != me and p > 1)
    for pid in survivors:
        try:
            kill(pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            continue
    return {"freed": len(victims), "sigkilled": len(survivors)}


def do_close(pane_id, tab_id=None, machine=herdr_transport.LOCAL_MACHINE):
    """`herdr tab close <tabId>`. The pane must still exist — the feed is the
    truth, never a stored flag. Close IS allowed on a remote row (D1/D3) —
    it only tells the Air's own herdr to close a tab, no local process
    touched."""
    panes = _live_panes(machine=machine)
    match = next((p for p in panes if p.get("pane_id") == pane_id), None)
    if not match:
        raise RuntimeError(f"pane {pane_id} not found — already gone")
    tab = tab_id or match.get("tab_id")
    if not tab:
        raise RuntimeError(f"pane {pane_id} has no tab — re-check herdr")
    try:
        herdr_transport.herdr_cmd_json(
            machine, ["tab", "close", tab], repo_root=REPO_ROOT,
            machines=MACHINES, timeout=15)
    except herdr_transport.HerdrError as e:
        raise RuntimeError(f"herdr tab close failed on {machine}: {e}")
    return {"tabId": tab}


def transcript_exists(agent_session, projects_dir=None):
    """A resume needs the session's transcript on disk. The brief's rule:
    never ship a button that promises history it cannot deliver — a session
    id with no transcript (never ran a turn, or a foreign id) is refused
    here, not after typing into the pane. Cwd-slug varies, so every project
    dir is searched."""
    if not agent_session or "/" in agent_session or agent_session.startswith("."):
        return False
    base = projects_dir or os.path.join(os.path.expanduser("~"), ".claude",
                                        "projects")
    try:
        for entry in os.listdir(base):
            cand = os.path.join(base, entry, agent_session + ".jsonl")
            if os.path.isfile(cand):
                return True
    except OSError:
        return False
    return False


def do_relaunch(pane_id, agent_session, machine=herdr_transport.LOCAL_MACHINE):
    """`herdr pane run <paneId> 'claude-aptus --resume <session>'` then
    enter. `pane run` types but does NOT submit — the enter is mandatory.
    `claude-aptus` is a zsh alias: it resolves only when typed into a live
    interactive prompt, which is exactly what `pane run` does. Never bash -c.
    Refuses unless the pane's foreground is empty OF AGENTS — resuming INTO
    a live agent would hijack real work. A bare shell prompt counts as
    empty (the shell is the pane, not the agent). Remote is refused outright
    (phase 1 scope, D1/D3) — never even reaches _live_panes."""
    _refuse_if_remote("relaunch", machine)
    if not agent_session:
        raise RuntimeError("no session id on this row — cannot resume")
    panes = _live_panes()
    if not any(p.get("pane_id") == pane_id for p in panes):
        raise RuntimeError(f"pane {pane_id} not found — likely closed")
    if not transcript_exists(agent_session):
        raise RuntimeError(
            f"no transcript on disk for session {agent_session} — resume "
            "would open an empty session, not your history")
    busy = agent_pids_in_pane(pane_id)
    if busy:
        raise RuntimeError(
            f"pane {pane_id} still runs {len(busy)} agent process(es) — "
            "relaunch is the undo for Stop, not a second agent alongside")
    # machine is guaranteed "local" here (_refuse_if_remote above), but this
    # still routes through the wrapper rather than a bare subprocess call —
    # R2's "one door" holds with no carve-out for "always local anyway".
    cmd = f"claude-aptus --resume {agent_session}"
    try:
        herdr_transport.herdr_cmd_text(
            machine, ["pane", "run", pane_id, cmd], repo_root=REPO_ROOT,
            machines=MACHINES, timeout=15)
    except herdr_transport.HerdrError as e:
        raise RuntimeError(f"herdr pane run failed: {e}")
    try:
        herdr_transport.herdr_cmd_text(
            machine, ["pane", "send-keys", pane_id, "enter"],
            repo_root=REPO_ROOT, machines=MACHINES, timeout=15)
    except herdr_transport.HerdrError:
        raise RuntimeError(
            "resume was typed but enter may not have sent — re-check the pane")
    return {"resumed": agent_session}


# ── Phase 8 (v4 reach): pure helpers for Send message ──

#: Free text over 8000 chars is a paste, not a message — refuse it.
MESSAGE_MAX_CHARS = 8000

#: A prompt line holding typed-but-unsubmitted text. Claude renders the live
#: input as `❯ <text>`; opencode's prompt markers vary, hence the set.
_INPUT_PROMPT_MARKS = ("❯", "›", ">")


#: The only two slash commands allowed through `validate_message_text`.
#: 2026-09-02 blocked ALL leading-`/` text because slash commands open an
#: autocomplete dropdown that was measured eating the first Enter. A live
#: re-probe on 2026-09-22 proved that premise FALSE for these two specific
#: commands in the current Claude Code version: typing the command then
#: sending Enter ONCE submits immediately (dropdown-open frame byte-identical
#: to typed text -> one Enter -> input line empty, command executed). Escape
#: reliably dismisses the dropdown without mutating/submitting as a fallback.
#: Every OTHER leading-`/` command stays refused — this is an allowlist, not
#: a loosened prefix check, on purpose (`/compact2`, `/clearfoo` etc. must
#: still be refused).
_ALLOWED_SLASH_BARE = frozenset({"/clear", "/compact"})
_ALLOWED_SLASH_PREFIX = "/compact "  # "/compact" + a space + trailing args


def is_allowed_slash_command(cleaned):
    """Is `cleaned` exactly `/clear`, exactly `/compact`, or `/compact `
    followed by trailing instructions text? See _ALLOWED_SLASH_BARE.

    Public (not `_`-prefixed): the server's stuck-retry fallback also needs
    to know "is this one of the two allowlisted commands" to scope its
    esc+enter retry to only these two (see _handle_reach_action)."""
    return (cleaned in _ALLOWED_SLASH_BARE
            or cleaned.startswith(_ALLOWED_SLASH_PREFIX))


#: Characters a terminal ACTS on instead of displaying: C0 controls
#: (0x00-0x1F: ctrl-C = 0x03, ctrl-U = 0x15, ESC = 0x1B, ...), DEL (0x7F)
#: and C1 controls (0x80-0x9F, which some terminals treat like ESC-prefixed
#: sequences). Shell quoting (`shlex.quote`) does NOT neutralise them: text
#: typed into a live pane reaches the terminal's line discipline / the
#: agent's key handler byte by byte before any shell parses a quote, so a
#: `\x03` interrupts and a `\x15` erases the line no matter how it's quoted.
_TERMINAL_CONTROL_CHARS_RE = re.compile(r"[\x00-\x1f\x7f-\x9f]")


def find_terminal_control_char(text, allowed=""):
    """The first terminal control character in `text` that isn't in
    `allowed` (e.g. `"\n\t"` for multi-line instructions), or None.
    Shared by every path that types text into a pane (Send message here,
    `persona_start.py`'s claude command) — one definition of "unsafe to
    type"."""
    for match in _TERMINAL_CONTROL_CHARS_RE.finditer(text or ""):
        if match.group() not in allowed:
            return match.group()
    return None


def validate_message_text(text):
    """Refuse text that must never be typed into a pane. Returns
    (ok, cleaned_or_reason): cleaned text on ok, the refusal reason if not.

    Guards, each with its mechanism (the plan's table):
      - empty: nothing to send.
      - newline: a newline in a terminal IS the submit key — a two-line
        message sends half a thought.
      - leading `/`: slash commands open an autocomplete that eats the
        first enter (measured 2026-09-02) — they stay in the terminal,
        never typed via message. EXCEPTION: `/compact` (bare, or with
        trailing instructions after a space) and bare `/clear` are
        allowlisted through — re-probed live 2026-09-22, a single Enter
        submits both in the current Claude Code version (see
        is_allowed_slash_command / _ALLOWED_SLASH_BARE for the proof and
        why this stays a narrow allowlist, not a loosened prefix check).
      - over MESSAGE_MAX_CHARS: a paste, not a message.
      - any other terminal control character (`find_terminal_control_char`):
        typed into a live pane it is a keystroke (ctrl-C, ctrl-U, ESC...),
        not text — quoting can't neutralise it.

    Tabs are the one control character NORMALIZED instead of refused: each
    becomes a space (a pasted tab is almost always spacing, and a refusal
    would cost the PO the whole message). Same rule as AgentBar's
    `TerminalSafeText`, so every client sends the same text. Every caller
    (Send message, persona start) gets this through here.
    """
    cleaned = (text or "").replace("\t", " ").strip()
    if not cleaned:
        return False, "refused: empty message — nothing to send"
    if "\n" in cleaned or "\r" in cleaned:
        return False, ("refused: newlines are the submit key in a terminal "
                        "— send one line at a time")
    control_char = find_terminal_control_char(cleaned)
    if control_char is not None:
        return False, (f"refused: control character {control_char!r} — it "
                       "would act as a keystroke in the pane, not as text")
    if cleaned.startswith("/") and not is_allowed_slash_command(cleaned):
        return False, ("refused: slash commands need the two-enter dance — "
                        "they stay in the terminal")
    if len(cleaned) > MESSAGE_MAX_CHARS:
        return False, (f"refused: {len(cleaned)} chars is a paste, not a "
                       f"message (limit {MESSAGE_MAX_CHARS})")
    return True, cleaned


def pane_reports_queued(lines):
    """Does the tail show Claude's queued-messages indicator?

    `❯ Press up to edit queued messages` is the worker CONFIRMING the input
    was accepted and will be delivered after the turn — AGENTS.md states it
    outright ("a worker mid-turn queues the input and compacts when its
    turn ends"). It is the opposite of stuck: retrying here DOUBLE-sends
    into the queue, which is exactly the hazard the verify exists to
    prevent. Pure text check over the recent tail; the server treats it as
    SUCCESS-with-state-queued (and logs it, so a retry is visible).
    """
    if not lines:
        return False
    return any("queued messages" in (l or "")
               for l in (lines or [])[-12:])


def input_box_still_holds(lines, text):
    """Did our typed text fail to leave the input box?

    The live input box is bottom-anchored: the LAST prompt-prefixed line in
    the tail IS the box. A submitted message clears it (the text moves into
    the transcript ABOVE — Claude renders the echo as `❯ <text>`, which is
    what the old any-match rule tripped on: a fast submit reported
    NOT SUBMITTED and skipped its log entry, inviting a retry that would
    DOUBLE-send. Measured live 2026-09-06 on a compact that submitted
    fine while the endpoint cried stuck).

    So: only the last prompt line holding OUR EXACT text counts as stuck.
    The queued-messages indicator is explicitly NOT stuck — see
    pane_reports_queued: the worker confirmed acceptance, and calling it a
    failure double-sends down the one path the endpoint tells the PO to
    confirm (measured live 2026-09-06: busy-pane sends reported NOT
    SUBMITTED with no audit entry). Fail-closed only where genuinely
    ambiguous: our literal text still sitting in the box.
    """
    if not text:
        return False
    last_prompt = None
    for line in (lines or [])[-12:]:
        stripped = (line or "").strip()
        if stripped[:1] in _INPUT_PROMPT_MARKS:
            last_prompt = stripped
    if last_prompt is None:
        return False
    return text in last_prompt


def resolve_busy(live_state, cached_word):
    """Is the pane mid-turn RIGHT NOW? The fresh screen decides.

    `cached_word` is the hook/herdr state the agents feed carries, and it
    LAGS. Measured 2026-09-06: a pane demonstrably mid-turn (running a 55s
    shell command) reported `idle`, so the busy confirm was skipped and the
    endpoint answered "message sent — the input box drained" for a message
    that had in fact queued. Both outcomes deliver, so nothing was lost —
    but the reason line described the wrong one, and the confirm the PO was
    promised ("mid-turn asks first") never fired.

    `live_state` comes from classify_pane on the SAME fresh read the picker
    guard just used, and the dashboard's own rule (see poll_pane_screen) is
    that the screen is authoritative for busy-vs-finished. So believe it
    where it can know, and fall back to the cached word only when it cannot
    (UNKNOWN, or the classifier failed).
    """
    if live_state == "ACTIVE":
        return True
    # A pane parked on its own monitor/agent has ENDED its turn and its composer
    # is live (classify_pane says WAITING_ON_BACKGROUND only with the live
    # composer box drawn), so a message submits at once - it does not queue.
    if live_state in ("WAITING", "WAITING_ON_BACKGROUND", "CRASHED"):
        return False
    return cached_word != "idle"
