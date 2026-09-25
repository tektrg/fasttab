#!/usr/bin/env python3
"""Data feeds for the chief dashboard — every source it reads, and the
staleness bookkeeping that makes a dead feed impossible to mistake for a calm
one. Pure collection: nothing here decides what the human should look at (that
is chief_dashboard_views), and nothing here writes anywhere.

Split out of chief-dashboard-server.py when that file crossed the 700-LOC
refactor trigger; the server module now owns only HTTP + the page.
"""
import sys
import concurrent.futures
import importlib.util
import json
import os
import re
import subprocess
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import classify_pane  # noqa: E402  (scripts/lib/classify_pane.py)
import chief_dashboard_context  # noqa: E402  (phase 8: context parser)
import chief_dashboard_herdr as herdr_transport  # noqa: E402  (R2/R3: the one door)
import pane_live_work  # noqa: E402  (sub-agent status lines: live-work evidence)
import pane_screen_signals  # noqa: E402  (screen fingerprint + motion stamp)

#: Env-overridable so a SECOND instance can run from a worktree on a spare
#: port for live verification without ever touching the real :4711 one
#: (watch-worker-events.py already reads CHIEF_DASHBOARD_PORT on the client
#: side; this is the matching server-side read). Defaults are byte-identical
#: to before this existed.
HOST = os.environ.get("CHIEF_DASHBOARD_HOST", "127.0.0.1")
PORT = int(os.environ.get("CHIEF_DASHBOARD_PORT", "4711"))

LIB_DIR = os.path.dirname(os.path.abspath(__file__))
SCRIPT_DIR = os.path.dirname(LIB_DIR)
REPO_ROOT = os.path.dirname(SCRIPT_DIR)  # /Users/trungluong/01_Project/AptusFit
TMPDIR = os.environ.get("TMPDIR", "/tmp")
HOOK_CACHE_DIR = os.path.join(TMPDIR, "delivery-ops-herdr")

SANITIZE_RE = re.compile(r"[^A-Za-z0-9]")

#: Loaded once at import (same lifecycle as REPO_ROOT above — a machine
#: added/removed/edited takes effect on the next server restart, same as
#: every other config-shaped global in this module). Missing file ->
#: ({}, None): today's exact behaviour, no ssh ever attempted (R18).
MACHINES, MACHINES_CONFIG_ERROR = herdr_transport.load_machines_config(REPO_ROOT)


def sanitize_pane_id(pane_id):
    """Mirror the plugin hook's sanitization: every non-alphanumeric char -> '-'."""
    return SANITIZE_RE.sub("-", pane_id)


def run_json(cmd, cwd, timeout):
    """Run a subprocess, return parsed JSON stdout. Raises on any failure —
    caller is responsible for catching and recording it as a feed error.
    Never let a raised exception here escape a poll loop and kill the thread
    silently; each poll loop wraps its body in try/except.

    Kept for callers that still pass a bare `["herdr", ...]` / other argv
    directly (git-health, board, ps — never herdr calls after the R2 wrapper
    swap below). Herdr calls go through herdr_transport.herdr_cmd_json
    instead so local vs remote is never decided ad hoc at a call site."""
    proc = subprocess.run(
        cmd, cwd=cwd, timeout=timeout, capture_output=True, text=True
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"{' '.join(cmd)} exited {proc.returncode}: {proc.stderr.strip()[:500]}"
        )
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        raise RuntimeError(
            f"{' '.join(cmd)} produced non-JSON stdout: {e} "
            f"(first 200 chars: {proc.stdout[:200]!r})"
        )


class Feed:
    """One data source. Tracks its own last-success timestamp so the page can
    self-alarm on staleness rather than silently going quiet (plan.md's
    "a broken checker and a calm board look identical" problem)."""

    def __init__(self, name, refresh_interval_sec):
        self.name = name
        self.refresh_interval_sec = refresh_interval_sec
        self.created_ts = time.time()
        self._lock = threading.Lock()
        self.data = None
        self.error = None
        self.last_success_ts = None
        self.last_attempt_ts = None
        self.last_duration_sec = None

    def set_success(self, data, duration_sec=None):
        with self._lock:
            self.data = data
            self.error = None
            now = time.time()
            self.last_success_ts = now
            self.last_attempt_ts = now
            self.last_duration_sec = duration_sec

    def set_error(self, err, duration_sec=None):
        with self._lock:
            self.error = str(err)
            self.last_attempt_ts = time.time()
            self.last_duration_sec = duration_sec

    def snapshot(self):
        with self._lock:
            now = time.time()
            age = (now - self.last_success_ts) if self.last_success_ts else None
            stale_after = self.refresh_interval_sec * 3
            if age is not None:
                broken, warming = age > stale_after, False
            else:
                # A feed that has never succeeded is only BROKEN once it has had
                # long enough to succeed. gitHealth's own poll takes up to ~2min
                # and board up to ~1min, so on a cold start both used to raise a
                # FEED BROKEN alarm — and an alarm that cries wolf every restart
                # is how a real one gets ignored. The self-alarm is untouched:
                # past this window, never-succeeded is still broken.
                warming = (now - self.created_ts) <= stale_after
                broken = not warming
            return {
                "name": self.name,
                "refreshIntervalSec": self.refresh_interval_sec,
                "warming": warming,
                "lastSuccessTs": self.last_success_ts,
                "lastAttemptTs": self.last_attempt_ts,
                "lastDurationSec": self.last_duration_sec,
                "ageSec": age,
                "broken": broken,
                "error": self.error,
                "data": self.data,
            }


def herdr_feed_key(machine):
    """Legacy-preserving feed name: "herdr" for local (unchanged, R16), else
    "herdr:<machine>" — a brand new key, so nothing that reads FEEDS["herdr"]
    today has to change or can be confused by a remote machine's data."""
    return "herdr" if machine == herdr_transport.LOCAL_MACHINE else f"herdr:{machine}"


def pane_screen_feed_key(machine):
    return ("paneScreen" if machine == herdr_transport.LOCAL_MACHINE
            else f"paneScreen:{machine}")


# P0 dashboard move: "gitHealth" (git worktree/branch health sweep — the
# retired git view) and "workItems" (delivery-ops/Notion board mirror — the
# retired work_item board) are RETIRED feeds. "paneTick" is KEPT — it is
# still read by get_agent_tree_state (AgentBar's agent hierarchy view), not
# just by the retired build_chief_pass.
FEEDS = {
    "hookCache": Feed("hookCache", refresh_interval_sec=2),
    "herdr": Feed("herdr", refresh_interval_sec=5),
    # 90s here is the STALENESS budget (3x -> "broken" past 270s / 4.5min),
    # sized to pane-tick-writer.py's own ~2min heartbeat cadence — not the
    # 10s this server actually re-reads the file at (see poll_pane_tick).
    "paneTick": Feed("paneTick", refresh_interval_sec=90),
    "board": Feed("board", refresh_interval_sec=150),
    # The ONLY feed that can tell "sitting at a permission prompt" from
    # "sitting at an empty prompt, turn finished" — see poll_pane_screen.
    # Phase 5: the sweep runs parallel (~3s for 17 panes), so 15s is plenty.
    # Staleness budget is 3x -> FEED BROKEN past 45s; proven flap-free over a
    # 5-minute watch 2026-09-05 before settling here.
    "paneScreen": Feed("paneScreen", refresh_interval_sec=15),
}

# R7/R9: one herdr feed + one paneScreen feed PER CONFIGURED MACHINE, so an
# Air outage or blip spends only that machine's own staleness budget and can
# never borrow or spend local's (own Feed object, own consecutive-failure
# counter via .error/.broken — see Feed.snapshot above).
for _machine_name in MACHINES:
    FEEDS[herdr_feed_key(_machine_name)] = Feed(
        herdr_feed_key(_machine_name), refresh_interval_sec=5)
    FEEDS[pane_screen_feed_key(_machine_name)] = Feed(
        pane_screen_feed_key(_machine_name), refresh_interval_sec=15)

STOP = threading.Event()


# ── Poll loops (each is defensive: one bad iteration never kills the thread,
#    and a dead thread just means that one feed goes stale -> self-alarms) ──


def poll_hook_cache():
    feed = FEEDS["hookCache"]
    while not STOP.is_set():
        t0 = time.time()
        try:
            entries = {}
            if os.path.isdir(HOOK_CACHE_DIR):
                for fname in os.listdir(HOOK_CACHE_DIR):
                    # "<pane>.why" is the hook's reason sidecar for a `blocked`
                    # state (the actual question the human has to answer), and
                    # "<pane>.question.json" the AskUserQuestion preview — not
                    # panes of their own.
                    if not is_pane_cache_file(fname):
                        continue
                    fpath = os.path.join(HOOK_CACHE_DIR, fname)
                    try:
                        with open(fpath, "r") as f:
                            content = f.read().strip()
                        seq_str, state = content.split(":", 1)
                        entries[fname] = {
                            "seq": int(seq_str),
                            "state": state,
                            "reason": read_hook_reason(fname),
                        }
                    except Exception:
                        # one malformed/racing file must not blank the whole feed
                        continue
                feed.set_success(entries, time.time() - t0)
            else:
                feed.set_error(f"cache dir does not exist: {HOOK_CACHE_DIR}", time.time() - t0)
        except Exception as e:
            feed.set_error(e, time.time() - t0)
        STOP.wait(feed.refresh_interval_sec)


def poll_herdr(machine=herdr_transport.LOCAL_MACHINE):
    """Agent + tab list for one machine (local, or one configured remote
    machine). Every herdr call goes through herdr_transport.herdr_cmd_json —
    R2's one door — so a bad ssh reply (garbage, an error envelope, exit
    255) raises HerdrError/SshUnreachable and this machine's feed reads
    FEED BROKEN with that reason, never an empty-but-healthy agent list
    (R7)."""
    feed = FEEDS[herdr_feed_key(machine)]
    while not STOP.is_set():
        t0 = time.time()
        try:
            agents_resp = herdr_transport.herdr_cmd_json(
                machine, ["agent", "list"], repo_root=REPO_ROOT,
                machines=MACHINES, timeout=15)
            tabs_resp = herdr_transport.herdr_cmd_json(
                machine, ["tab", "list"], repo_root=REPO_ROOT,
                machines=MACHINES, timeout=15)
            agents = agents_resp.get("result", {}).get("agents", [])
            tabs = tabs_resp.get("result", {}).get("tabs", [])
            feed.set_success({"agents": agents, "tabs": tabs}, time.time() - t0)
        except Exception as e:
            feed.set_error(e, time.time() - t0)
        STOP.wait(feed.refresh_interval_sec)


def machines_status():
    """{"air-m1": {"status": "ok"|"broken", "error": ..., "ageSec": ...}}
    for every configured machine — R7's per-machine health surface. Absent
    entirely when no machines are configured (today's exact shape)."""
    out = {}
    for name in MACHINES:
        snap = FEEDS[herdr_feed_key(name)].snapshot()
        broken = bool(snap["broken"] and not snap.get("warming"))
        out[name] = {
            "status": "broken" if broken else ("warming" if snap.get("warming") else "ok"),
            "error": snap.get("error"),
            "ageSec": snap.get("ageSec"),
            "agentCount": len((snap.get("data") or {}).get("agents") or []),
        }
    return out


#: Mirrors pane-tick-gate.py's own MAX_CACHE_AGE — the writer runs ~every
#: 2 min, so 6 min is roughly 3 missed cycles before the FILE'S OWN `ts` (not
#: just "did the read succeed") is treated as too old to call fresh.
PANE_TICK_MAX_AGE_SEC = 6 * 60


def poll_pane_tick():
    """Plain file read of the pane-tick heartbeat's cache — no subprocess, no
    lock needed on the read side (the writer's atomic rename already
    guarantees this never sees a half-written file). Polled often (cheap),
    but a successful READ is not the same fact as FRESH DATA: if the writer's
    LaunchAgent dies, the file stays on disk and every read keeps succeeding
    forever — so staleness has to be judged against the payload's own `ts`,
    not against whether this loop's last file-open worked (R39)."""
    feed = FEEDS["paneTick"]
    cache_path = os.path.join(REPO_ROOT, "scripts", ".pane-tick-cache.json")
    while not STOP.is_set():
        t0 = time.time()
        try:
            with open(cache_path) as f:
                payload = json.load(f)
            age = time.time() - float(payload.get("ts", 0))
            if age > PANE_TICK_MAX_AGE_SEC:
                feed.set_error(
                    f"pane-tick-cache.json is {int(age // 60)}m old — the "
                    "pane-tick-writer LaunchAgent may have died", time.time() - t0)
            else:
                feed.set_success(payload.get("data") or {}, time.time() - t0)
        except FileNotFoundError:
            # R26: before the heartbeat has ever run, this is a normal cold
            # start, not a crash — surfaces as an ordinary broken/stale feed,
            # same as any other feed with no successful poll yet.
            feed.set_error("no .pane-tick-cache.json yet — has the "
                           "pane-tick-writer LaunchAgent run?", time.time() - t0)
        except Exception as e:
            feed.set_error(e, time.time() - t0)
        STOP.wait(10)


# P0 dashboard move: poll_git_health (scripts/repo-health.sh) is RETIRED along
# with its feed — an AptusFit-repo-specific sweep with no MOVE-set consumer
# left after build_git_view was dropped.


def poll_board():
    feed = FEEDS["board"]
    while not STOP.is_set():
        t0 = time.time()
        try:
            data = run_json(
                ["python3", "scripts/deliver-tick.py", "--json"],
                cwd=REPO_ROOT,
                timeout=120,
            )
            feed.set_success(data, time.time() - t0)
        except Exception as e:
            # This is exactly the failure mode plan.md problem #2 describes:
            # the board poller crashing/erroring must surface as FEED BROKEN,
            # never crash this server process.
            feed.set_error(e, time.time() - t0)
        elapsed = time.time() - t0
        STOP.wait(max(feed.refresh_interval_sec - elapsed, 20))




REASON_SUFFIX = ".why"
#: Phase 5: sidecar written by chief-question-hook.sh (PreToolUse on
#: AskUserQuestion) the instant a picker opens — display-only preview until
#: the sweep parses the real screen block.
QUESTION_SUFFIX = ".question.json"


def is_pane_cache_file(fname):
    """True for one file per pane; sidecars (.why, .question.json) are not
    panes of their own — enumerating one as a pane invents a phantom row."""
    return not (fname.endswith(REASON_SUFFIX)
                or fname.endswith(QUESTION_SUFFIX))
#: How much of a pane's scrollback the classifier needs. Mirrors
#: check-worker-panes.sh's own window — classify_pane only ever looks at the
#: last 40 lines, so reading more is wasted bytes.
PANE_SCREEN_LINES = 40
#: The QUESTION parser needs more. Measured 2026-09-04: `herdr pane read
#: --lines 40` on a live AskUserQuestion picker returned only the last ~12
#: lines (options + footer) and cut the title/question off the top, while
#: --lines 100 returned the whole box — so a 40-line read parses no question
#: at all. The extra bytes (~2KB × panes per 45s) are negligible; classify()
#: still gets exactly its last-40 window, unchanged. With `--source visible`
#: (below) this is now also a viewport cap, not just a scrollback depth: a
#: picker taller than the pane's visible rows can still get cut at the top,
#: same failure mode as the old --lines 40, just triggered by pane height
#: instead of line count — accepted 2026-09-10 to stop the scroll-reset.
PANE_SCREEN_READ_LINES = 100
#: Cost ceiling. One `herdr pane read` per agent per cycle, fanned out over
#: PANE_SCREEN_WORKERS threads — each read is ~2.5s of pure waiting on the
#: herdr socket, not work, so 17 panes finish in ~3s instead of ~35s.
#: Measured 2026-09-05: 4 panes sequential 10.06s, parallel 2.60s.
PANE_SCREEN_MAX_PANES = 40
#: ThreadPoolExecutor bound for the sweep. 10 is plenty for the 40-pane cap;
#: more would only contend on the herdr socket.
PANE_SCREEN_WORKERS = 10


def read_hook_reason(fname):
    """The `blocked` reason the hook recorded alongside the state, or None."""
    try:
        with open(os.path.join(HOOK_CACHE_DIR, fname + REASON_SUFFIX)) as f:
            return f.read().strip() or None
    except Exception:
        return None


def read_hook_question(sanitized_sid):
    """The AskUserQuestion preview the hook recorded for one pane, or None.

    Display-only: raw tool-input strings, never screen-parsed, so this copy
    can never satisfy answer_pane_question()'s exact-match refusal gate. Any
    malformed sidecar reads as no preview — fail toward the sweep's copy.
    """
    try:
        with open(os.path.join(HOOK_CACHE_DIR, sanitized_sid + QUESTION_SUFFIX),
                  encoding="utf-8") as f:
            payload = json.load(f)
        if not isinstance(payload, dict):
            return None
        question = str(payload.get("question") or "")
        title = str(payload.get("title") or "")
        if not question and not title:
            return None
        try:
            ts = float(payload.get("ts") or 0)
        except (TypeError, ValueError):
            ts = 0
        options = []
        for o in payload.get("options") or []:
            if not isinstance(o, dict) or not str(o.get("label") or ""):
                continue
            try:
                index = int(o.get("index"))
            except (TypeError, ValueError):
                continue
            options.append({"index": index, "label": str(o["label"])[:200],
                            "description": str(o.get("description") or "")[:300]})
        return {"ts": ts, "title": title[:200], "question": question[:500],
                "multi": bool(payload.get("multi")), "options": options[:12]}
    except Exception:
        return None


#: Extra cost of the `_recompute_permission_unwrapped` call below: ONE more
#: `herdr pane read` subprocess (same ~15s timeout budget as the main read),
#: but ONLY for panes already classified NEEDS_HUMAN this sweep — a small,
#: already-blocked minority of the fleet, not every polled pane. A busy
#: fleet of e.g. 40 panes with 3 blocked pays 3 extra reads/sweep, not 40.
def _recompute_permission_unwrapped(pane_id, wrapped_perm,
                                     machine=herdr_transport.LOCAL_MACHINE):
    """Re-derive `permission` from an UNWRAPPED read, for a NEEDS_HUMAN pane
    only. `--source visible` above renders long lines WRAPPED across
    multiple visual rows, so `PERMISSION_RECEIPT_RE`'s single-line match
    misses a long/wrapped Bash command and `parse_permission_block` reads
    None even though a real box is open. `recent-unwrapped` is the same
    source `_read_pane_now`'s send path already reads, so a permission
    object built from it is guaranteed to match what `/api/permission`'s
    own fresh re-read will see. Falls back to the wrapped-tail result
    (`wrapped_perm`, possibly still None) on any failure — never raises,
    same contract as the caller.

    Routed through herdr_transport (R2's one door) with the same `machine`
    the caller read the wrapped tail from, not a bare local `subprocess.run`
    — a hardcoded local call would read nothing (or the wrong pane) for a
    NEEDS_HUMAN pane on a configured remote machine and always fall back to
    the possibly-None wrapped tail for it.
    """
    try:
        out = herdr_transport.herdr_cmd_text(
            machine,
            ["pane", "read", pane_id, "--source", "recent-unwrapped",
             "--lines", str(PANE_SCREEN_READ_LINES)],
            repo_root=REPO_ROOT, machines=MACHINES, timeout=15)
        if not out.strip():
            return wrapped_perm
        unwrapped_tail = out.splitlines()[-PANE_SCREEN_READ_LINES:]
        perm = classify_pane.parse_permission_or_plan_block(unwrapped_tail)
        return perm if perm is not None else wrapped_perm
    except Exception:
        return wrapped_perm


def read_one_pane_screen(pane_id, machine=herdr_transport.LOCAL_MACHINE,
                          screen_key=None):
    """Read + classify ONE pane. Returns (key, entry) or None when this pane
    is unreadable. Never raises — one bad pane must never blank the feed,
    and with threads that means catching per-pane, not around the batch.

    `screen_key` is what the returned entry is keyed by in the paneScreen
    feed — sanitize_pane_id(pane_id) for local (unchanged), or the
    NAMESPACED sanitized key for a remote pane (so a remote and a local pane
    sharing the same raw id can never collide — R1/E3)."""
    key = screen_key if screen_key is not None else sanitize_pane_id(pane_id)
    try:
        # `--source visible` (not recent-unwrapped): a scrollback read was
        # snapping every polled pane's live view back to the bottom every
        # 15s, so a human scrolled up to read something got yanked back down
        # mid-read. `visible` only snapshots the current viewport — no
        # scrollback touch, no scroll-reset. PO-confirmed trade-off
        # 2026-09-10: classify() and the question parser only ever see what
        # fits on screen now (see PANE_SCREEN_READ_LINES comment above).
        out = herdr_transport.herdr_cmd_text(
            machine,
            ["pane", "read", pane_id, "--source", "visible",
             "--lines", str(PANE_SCREEN_READ_LINES)],
            repo_root=REPO_ROOT, machines=MACHINES, timeout=15)
        if not out.strip():
            return None
        tail_all = out.splitlines()
        state, signal = classify_pane.classify(
            "\n".join(tail_all[-PANE_SCREEN_LINES:]))
        tail = tail_all[-PANE_SCREEN_READ_LINES:]
        classified_text = "\n".join(tail_all[-PANE_SCREEN_LINES:])
        permission = classify_pane.parse_permission_or_plan_block(tail)
        # NEEDS_HUMAN only: the `visible` tail above WRAPS long lines, so a
        # long/wrapped Bash command's receipt line never matches on the
        # wrapped tail and `permission` above reads None even with a real
        # box open. One extra unwrapped read recovers it — see
        # `_recompute_permission_unwrapped`'s docstring for the exact cost
        # and why this is scoped to already-blocked panes only.
        if state == "NEEDS_HUMAN":
            permission = _recompute_permission_unwrapped(pane_id, permission,
                                                          machine=machine)
        return (key, {
            "state": state, "signal": signal,
            "ts": time.time(),
            # Live-work evidence for the hook-vs-herdr disagree rule: a
            # fingerprint of what is drawn (poll_pane_screen turns it into
            # "unchanged for N s" across sweeps) and how many sub-agent status
            # lines are on screen (pane_screen_signals.live_work_evidence).
            "digest": pane_screen_signals.screen_digest(classified_text),
            "subagents": pane_live_work.count_subagents(tail_all[-PANE_SCREEN_LINES:]),
            # The open AskUserQuestion picker, if any — parsed
            # from the same tail so state and question can never
            # disagree. None for every other shape (plain
            # permission prompts stay terminal-only).
            "question": classify_pane.parse_question_block(tail),
            # dashboard-answer-stray-enter brief: `question` above reads
            # None both when the form is genuinely gone AND when it's
            # still open with the cursor parked on its own Submit/Next
            # exit row (parse_question_block's cursor search needs a
            # numbered row, which the exit row never has). This additive
            # sibling flag lets AgentBar tell the two apart instead of
            # reading both as "no picker".
            "questionCursorOnExit": classify_pane.question_cursor_on_exit(tail),
            # The open plain yes/no permission box OR ExitPlanMode
            # plan-approval box, if any (parse_permission_or_plan_block —
            # the two are mutually exclusive, see its docstring). None
            # whenever neither can be read confidently (see
            # parse_permission_block's/parse_plan_approval_block's own
            # module comments); used to give a "blocked" needsYou row the
            # actual command/file/plan being approved instead of just the
            # vendor's generic "Claude needs your permission" reason.
            "permission": permission,
            # Phase 8: the context-window reading off the status line
            # (free — already inside this tail). THE one permitted
            # addition to this module: the parser lives in
            # chief_dashboard_context, this is only the call site.
            "context": chief_dashboard_context.parse_context(
                "\n".join(tail))})
    except Exception:
        # One unreadable pane must never blank the whole feed —
        # that would turn a single closed tab into a FEED BROKEN
        # banner and hide every other pane's real state.
        return None


def poll_pane_screen():
    """Classify what each live agent pane ACTUALLY shows on screen.

    WHY THIS FEED EXISTS (measured 2026-09-03)
    ------------------------------------------
    The pushed hook state cannot answer the one question this dashboard is for.
    Claude Code fires a single `Notification` event both for "needs your
    permission" and for "waiting for your input" (~60s after an ordinary turn
    END), and the plugin hook mapped both to `blocked` — so 27 of 36 cached
    panes read `blocked` while every live one sat at an empty prompt, turn
    finished. The hook is fixed now, but a state that is pushed at a moment and
    never re-asserted can always drift from what is on the glass; the screen
    cannot. So: the hook feed is the FAST signal, this is the CORROBORATING one,
    and build_needs_you trusts the screen where they disagree.

    Deliberately reuses scripts/lib/classify_pane.py — the same classifier
    check-worker-panes.sh and chief-status.sh drive — so the dashboard can never
    disagree with the chief's own CLI about what a pane is doing. Its states:
    NEEDS_HUMAN (a permission prompt is up), CRASHED (an API error killed the
    turn), ACTIVE (a live spinner), WAITING (turn finished), UNKNOWN.
    """
    feed = FEEDS["paneScreen"]
    motion_history = {}
    while not STOP.is_set():
        t0 = time.time()
        try:
            agents = (FEEDS["herdr"].snapshot()["data"] or {}).get("agents") or []
            pane_ids = [a["pane_id"] for a in agents if a.get("pane_id")]
            pane_ids_sanitized = [sanitize_pane_id(pid) for pid in pane_ids]
            if not pane_ids:
                # On a cold start the herdr feed has not answered yet, so there
                # is nothing to read. Publishing an empty SUCCESS here is the
                # trap: it is indistinguishable from "every pane read fine and
                # none needs a human", which let stale hook `blocked` entries
                # fail open into rows for the first 45s after every restart.
                # Stay unsuccessful (the feed reads `warming`) and retry soon.
                feed.set_error("waiting for the herdr feed to list panes",
                               time.time() - t0)
                STOP.wait(5)
                continue
            screens = {}
            # Parallel: each read is socket-wait, not work. Per-future catch
            # (read_one_pane_screen already never raises) so one dead pane
            # still cannot blank the feed.
            with concurrent.futures.ThreadPoolExecutor(
                    max_workers=PANE_SCREEN_WORKERS,
                    thread_name_prefix="pane-screen") as pool:
                futures = {pool.submit(read_one_pane_screen, pid): pid
                           for pid in pane_ids[:PANE_SCREEN_MAX_PANES]}
                for fut in concurrent.futures.as_completed(futures):
                    try:
                        got = fut.result()
                    except Exception:
                        continue
                    if got is not None:
                        screens[got[0]] = got[1]
            # "Has this screen changed since the last sweep?" - the evidence the
            # hook-vs-herdr disagree rule needs to tell a worker that is drawing
            # from a frozen frame. History outlives a failed read of one pane.
            pane_screen_signals.stamp_sweep_motion(
                screens, motion_history, time.time(), live_keys=set(pane_ids_sanitized))
            if not screens:
                # Panes existed but not one could be read — herdr is sick.
                # Recording that as a SUCCESS is the "broken feed looks calm"
                # failure: `lastSuccessTs` would stay set forever, this feed
                # would never self-alarm, and build_needs_you's fail-open would
                # trust a reading that does not exist.
                feed.set_error(
                    f"none of {len(pane_ids)} panes could be read",
                    time.time() - t0)
            else:
                feed.set_success(screens, time.time() - t0)
        except Exception as e:
            feed.set_error(e, time.time() - t0)
        STOP.wait(max(feed.refresh_interval_sec - (time.time() - t0), 10))


def poll_pane_screen_remote(machine):
    """Same job as poll_pane_screen, for one configured remote machine —
    own Feed object (pane_screen_feed_key(machine)), own worker cap
    (machines[machine]["maxParallel"], R8's per-machine semaphore), own
    namespaced screen keys (R1/E3: sanitize_pane_id(make_pane_key(machine,
    raw)), never the bare local-shaped key) so a remote and a local pane
    sharing the same raw id can never collide in this feed's dict."""
    feed = FEEDS[pane_screen_feed_key(machine)]
    herdr_feed = FEEDS[herdr_feed_key(machine)]
    max_workers = (MACHINES.get(machine) or {}).get("maxParallel", 4)
    cap = min(max_workers, PANE_SCREEN_MAX_PANES)
    while not STOP.is_set():
        t0 = time.time()
        try:
            agents = (herdr_feed.snapshot()["data"] or {}).get("agents") or []
            pane_ids = [a["pane_id"] for a in agents if a.get("pane_id")]
            if not pane_ids:
                feed.set_error(
                    f"waiting for the herdr:{machine} feed to list panes",
                    time.time() - t0)
                STOP.wait(5)
                continue
            screens = {}
            with concurrent.futures.ThreadPoolExecutor(
                    max_workers=cap,
                    thread_name_prefix=f"pane-screen-{machine}") as pool:
                futures = {
                    pool.submit(
                        read_one_pane_screen, pid, machine=machine,
                        screen_key=sanitize_pane_id(
                            herdr_transport.make_pane_key(machine, pid))
                    ): pid
                    for pid in pane_ids[:PANE_SCREEN_MAX_PANES]
                }
                for fut in concurrent.futures.as_completed(futures):
                    try:
                        got = fut.result()
                    except Exception:
                        continue
                    if got is not None:
                        screens[got[0]] = got[1]
            if not screens:
                feed.set_error(
                    f"none of {len(pane_ids)} panes on {machine} could be read",
                    time.time() - t0)
            else:
                feed.set_success(screens, time.time() - t0)
        except Exception as e:
            feed.set_error(e, time.time() - t0)
        STOP.wait(max(feed.refresh_interval_sec - (time.time() - t0), 10))


# P0 dashboard move: the "work items" feed (delivery-ops/Notion state mirror)
# and the chief_pass review-mode plugin loader (_load_plugin_module,
# _delivery_ops_shim) are both RETIRED — the former backed the retired
# work_item board, the latter backed the retired chief_pass/toolbox map only.
# Neither has a MOVE-set caller left.


POLLERS = {
    "hookCache": poll_hook_cache,
    "herdr": poll_herdr,
    "paneTick": poll_pane_tick,
    "board": poll_board,
    "paneScreen": poll_pane_screen,
}


def start_pollers():
    """One daemon thread per feed. A thread that dies takes only its own feed
    stale, which self-alarms — it can never take the server down.

    Plus, per configured remote machine: one herdr-list thread and one
    pane-screen thread, each its own Feed object — a hung or dead machine
    can only ever spend its own thread's staleness budget, never local's
    (R8/R9). With no machines configured this loop body never runs, so
    nothing new starts and no ssh is ever attempted (R18)."""
    for name, target in POLLERS.items():
        threading.Thread(target=target, name=f"poll-{name}", daemon=True).start()
    for machine in MACHINES:
        threading.Thread(target=poll_herdr, args=(machine,),
                          name=f"poll-herdr-{machine}", daemon=True).start()
        threading.Thread(target=poll_pane_screen_remote, args=(machine,),
                          name=f"poll-paneScreen-{machine}", daemon=True).start()


def snapshot_all():
    return {name: f.snapshot() for name, f in FEEDS.items()}
