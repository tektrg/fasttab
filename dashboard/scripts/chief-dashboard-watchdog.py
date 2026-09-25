#!/usr/bin/env python3
"""Chief-dashboard watchdog: a 60-second PROBE, not a daemon takeover.

Answers exactly one question — *is anything answering on port 4711?* — and
restarts the dashboard server only when the answer is no. Scheduled by
`scripts/launchd/com.aptusfit.chief-dashboard-watchdog.plist` (StartInterval
60, RunAtLoad true), same shape as the two cache writers already on this Mac:
short-lived python, no long-running process of its own, logs under `logs/`.

WHY THIS EXISTS
---------------
The dashboard used to be one `python3 scripts/chief-dashboard-server.py`
inside a herdr pane with NO keep-alive: pane dies -> board dies -> a human has
to notice. chief-dashboard v5 turns the board into the chief's toolbox (its
tools are served by this server), so "the dashboard is down" stops costing one
supervision pass and starts halting the chief's whole loop. Hence a probe.

P0 DASHBOARD MOVE NOTE: in AptusFit (where this file was written), a failure
recorded here also fed a loud escalation in `chief-tick-gate.py` (via
`dashboard_down_reason`) — that gate is AptusFit's own chief-supervision-loop
code and stays there; it is NOT part of this move and this copy has no such
consumer yet. The state this file keeps (`first_failed_at` / `trouble_since` /
`outage_starts` / …, see below) is left fully intact regardless — it is the
honest probe/restart-cap ledger on its own merits, and a future local
consumer could read it the same way — but every comment below that used to
say "so `chief-tick-gate.py` can escalate this" is describing AptusFit's
behavior, not this copy's.

WHY A PROBE AND NOT `KeepAlive` ON THE SERVER
---------------------------------------------
The dashboard lives in a herdr pane on purpose — the PO watches it there. A
`KeepAlive` LaunchAgent owning the process would race that pane for port 4711
and take the window away. The pane stays the home; this only intervenes when
the home is empty.

THE THREE TRAPS THIS FILE IS SHAPED AROUND
------------------------------------------
1. **A warming server is ALIVE.** A cold start reads `warming` on every feed
   for ~45s (the pane-screen feed is on a 45s cycle). A watchdog that read
   `warming` as dead would restart a perfectly healthy booting server every
   60 seconds, forever. So does `broken: true` on a feed — that is the board's
   own alarm, with its own owner. HTTP 200 + parseable JSON is ALIVE, full
   stop (`classify_response`).
2. **An unmeasurable probe is not a death — but it is not nothing either.**
   Only the known network failures (refused, timeout, non-200) and an
   unparseable body license a RESTART. An exception this file did not
   anticipate never kills anything. It is still RECORDED as a failure
   (`main`), because the streak file is also the alarm rail: a dead dashboard
   plus a repeating probe bug used to freeze `last_failed_at`, trip the gate's
   6-minute freshness guard, and go silent in both directions at once.
3. **A SLOW server is alive too — one dead probe is not proof.** Trap 1 covers
   a server that is warming; this is the other axis, and it was missed at first.
   `/api/state` computes 7 feeds, so it is latency-spiky under machine load:
   measured on this Mac 2026-09-09 it normally answers in **0.19–0.54s**, but it
   was caught answering in **3.0s** once and taking **over 5s** once — curl
   returned `000` at `--max-time 5`, then the very same (healthy, never
   restarted) process answered `200` in 3.0s at `--max-time 15`. With a 5s
   budget, one such outlier would have killed a perfectly healthy server that
   the whole chief supervision loop depends on. Two guards, not one:
     - a restart requires `DEAD_PROBES_BEFORE_RESTART` (2) CONSECUTIVE dead
       probes; the first only records the streak;
     - immediately before anything is killed, ONE confirmation read on the
       much longer `CONFIRM_PROBE_TIMEOUT_SECONDS` budget must ALSO come back
       dead (`main`). Two 5s probes 60s apart are strongly correlated when the
       cause is a machine-load spike that lasts minutes, so they buy less
       margin than they look like; a slower read taken only on the verge of a
       destructive action is what actually distinguishes slow from dead.
   Note what this trap does NOT license: raising `PROBE_TIMEOUT_SECONDS` (the
   routine probe must stay fast or it misses its own tick — the confirmation
   read is a separate, rarer call) or probing a cheaper endpoint (there is
   none — `/api/state` is the honest liveness question on this server).

RESTART CAP AND FLAP ESCALATION (rewritten AGAIN 2026-09-09 — QA D1/D2/D3)
--------------------------------------------------------------------------
At most `RESTART_CAP` restarts in a rolling `RESTART_CAP_WINDOW_SECONDS`.
Uncapped, a server that cannot bind (port held by a zombie, a syntax error in
a feed module) turns this into a fork bomb on a 60-second timer. The cap
PAUSES rather than latching: only restarts inside the current window count, so
as the oldest ages out a fresh attempt is allowed — a slow retry for a blocker
that may clear on its own. **The cap counts across recoveries**, which is what
finding F1 was about: `clear_failure` used to delete the whole file on the
first good probe, so a FLAPPING dashboard reset the ledger every cycle and took
6 restarts per 15 minutes against a cap of 3.

TWO SIGNALS, NOT ONE FIELD — and F1's first fix conflated them
--------------------------------------------------------------
F1 kept a residue across a recovery and let the NEXT streak inherit
`trouble_since` as its `first_failed_at`. That made one number answer two
different questions, and it was wrong in both directions at once:

  * **D1 — a fully recovered board fired a FALSE alarm on one slow probe.**
    The gate escalates on `first_failed_at` AGE plus a FRESH `last_failed_at`,
    and a single dead probe supplies a fresh `last_failed_at`. Measured: a
    20-minute outage the watchdog FIXED, then 5 minutes of perfect health,
    then ONE slow-but-alive probe (the >5s latency outlier of trap 3 — nothing
    killed, no restart issued) produced `{"fire": true, "source":
    "dashboard-down", "reason": "chief dashboard has been unreachable for 25m
    (1 failed probes)"}`. The window was 15 minutes wide and the duration
    unbounded: a 200-minute outage fixed 3 minutes earlier plus one blip
    reported `unreachable for 203m (1 failed probes)`.
  * **D2 — a short-outage flapper was completely invisible.** 60 ticks with the
    board dead 60s every 3 minutes (33% unavailability): 0 restarts, 0 alarms,
    empty state file. The outage never occupied two consecutive probes, so no
    restart; and it left two consecutive GOOD probes, which expired the residue
    (D3, below), so no anchor either. The 2026-08-31 silent outage at a shorter
    timescale.

So the two questions now have two fields, and neither answers the other's:

  * **"How long has it been unreachable RIGHT NOW"** — `first_failed_at`, the
    start of the CURRENT streak and nothing else. A recovery resets this clock
    (`clear_failure` drops the field), so a blip after a recovery is one minute
    old, not twenty-five. This is the only field the gate's continuous-outage
    escalation reads, which is what kills D1.
  * **"How often has this EPISODE gone down"** — `outage_starts`, a rolling
    ledger holding one timestamp per dead probe that BEGAN a streak, pruned to
    `RESTART_CAP_WINDOW_SECONDS` exactly like `restarts`. Counting dead probes
    rather than restarts is what makes D2's flapper visible at all — it never
    earns a restart — and counting only the ONSET of each streak, rather than
    every dead probe, is what keeps it from re-inventing D1: a fixed 20-minute
    outage leaves 20 dead probes but only ONE onset, so it plus a later blip is
    two isolated outages, not a flap. `chief-tick-gate.py` escalates this as
    its own, separately-named `flapping` alarm (see
    `FLAP_OUTAGE_STARTS_IN_WINDOW` there); the reason string says flapping,
    with the counts, never an episode age dressed up as continuous
    unreachability.

`clear_failure` therefore rewrites the file down to a residue of:

  * `restarts` — the rolling cap ledger, so 3-per-15-minutes holds whether the
    server dies once or twenty times (F1, unchanged and still tested).
  * `outage_starts` — the rolling flap ledger the gate escalates from.
  * `dead_probes` — every dead probe in the window. Not the escalation signal;
    it is what the episode's own lifetime is measured from (D3, below) and the
    honest denominator in the flap message.
  * `trouble_since` — when this episode's trouble began. Reported in the flap
    message and used to hold the flap alarm behind the same 15-minute
    threshold as everything else. It is NOT inherited as `first_failed_at`.
  * `recoveries` — times this episode came back from a CONFIRMED death, i.e.
    from a streak that reached `DEAD_PROBES_BEFORE_RESTART`. A single slow
    probe followed by a good one is a blip, not a recovery (D7: six such blips
    with the board never down reported `recoveries: 6` and five `FLAPPING:`
    log lines boasting about a restart ledger that was empty).
  * `cleared_at` — when the streak ended, for the log.

The residue carries NO `first_failed_at`, `last_failed_at`, `count` or
`error`, so the gate reads it as "no streak" and the continuous alarm stays
quiet: a restart that WORKED and HELD still wakes nobody.

EPISODE LIFETIME IS DRIVEN BY THE LAST SYMPTOM (D3)
---------------------------------------------------
The episode is forgotten — file deleted — once the `dead_probes` and `restarts`
ledgers both prune to empty, i.e. once no dead probe and no restart has
happened for `EPISODE_MEMORY_SECONDS`. That is one rule, not two, because the
window that prunes them IS `EPISODE_MEMORY_SECONDS`. It used to be computed from
`last_failed_at`, which the residue drops, so `symptoms` was `[0]`, `now - 0 >
900` was always true, and a restart-free episode's residue was deleted after
**2 ticks (~120s)** rather than the 900s its own constant claims. Measured
before the fix: 2 good ticks. That is the mechanism that made D2 invisible.

A RESTART IS JUDGED ON THE HTTP ANSWER, NEVER ON A RETURN CODE OR A SOCKET
--------------------------------------------------------------------------
`herdr pane run` exits 0 when the PANE accepted the text — including when a
foreground process in that pane eats the line as stdin and nothing runs (see
`wait_for_dashboard`). Judged on the return code alone, that restart logged
`restarted via pane`, and the detached fallback — written for exactly this
case — could never fire, because it only runs when the pane call FAILS.

F3's fix re-probed the PORT, and a socket is not proof either (D4). Two
confirmed shapes: a foreign process holding :4711 accepts the connection, and
an unresolvable `lsof` makes `port_owner_pids()` return `[]`, which
`kill_stale_server` reads as "a free port needs no kill" — leaving the old
process holding the port so the new one dies on bind. Both ended with
`restart_dashboard()` returning `"pane"` and the log saying *"restarted via
pane, listener confirmed"*, with the detached fallback disabled in exactly the
case it exists for. The honest verdict was already in this file: `probe()` /
`classify_response`, the same HTTP-200-and-parseable-JSON question every tick
asks. `wait_for_dashboard` now asks that, so an accepted socket that is not the
dashboard reads as a restart that did NOT take.
"""
from __future__ import annotations

import json
import os
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from shutil import which

# P0 dashboard move: REPO_ROOT was a literal AptusFit path (not derived, not
# env-overridable — flagged in p0-move-map.md). Derived from __file__ instead,
# same pattern chief_dashboard_feeds.py uses, so this runs correctly from
# whichever checkout it lives in. DASHBOARD_HOME is this dashboard/ folder;
# SERVER_SCRIPT is now an absolute path (the server lives in server/, not
# scripts/, in this layout) so it does not depend on the herdr pane's own cwd.
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DASHBOARD_HOME = os.path.dirname(SCRIPT_DIR)
sys.path.insert(0, os.path.join(DASHBOARD_HOME, "server", "lib"))
import dashboard_config  # noqa: E402  (P0 move: shared config/state-dir split)

SERVER_SCRIPT = os.path.join(DASHBOARD_HOME, "server", "chief-dashboard-server.py")
#: What a process holding the port must look like before this file will signal
#: it — see `kill_stale_server`.
SERVER_BASENAME = os.path.basename(SERVER_SCRIPT)
#: Design call #1 (state dir): the failure ledger and fallback log are runtime
#: state, not source — they now live in the shared state dir alongside the
#: board db, not inside this checkout.
FAILURE_FILE = os.path.join(dashboard_config.STATE_HOME, "chief-dashboard-failure.json")
FALLBACK_LOG = os.path.join(dashboard_config.STATE_HOME, "logs", "chief-dashboard-fallback.log")

#: Same 5s fast-failure budget the MCP layer contracts for. Never raise it —
#: a probe that hangs is a probe that misses its own tick. The pre-kill
#: confirmation read below is the place for a longer budget.
PROBE_TIMEOUT_SECONDS = 5
#: Budget for the ONE confirmation read taken immediately before a kill (trap
#: 3). Deliberately far past the worst latency ever measured on `/api/state`
#: (>5s on 2026-09-09): this call happens at most once per restart decision, so
#: it can afford to wait, and a slow-but-healthy server must never be killed.
CONFIRM_PROBE_TIMEOUT_SECONDS = 15
DASHBOARD_PORT = int(os.environ.get("CHIEF_DASHBOARD_PORT", "4711"))
#: Same env var `chief-dashboard-restart.sh` honours, same default. A herdr
#: workspace reset invalidates every pane id under it (found 2026-09-14: the
#: original `w2:p1A` workspace was gone entirely, and — since this LaunchAgent
#: was never actually installed, see the plist's own comment — nothing had
#: been restarting the server against the dead pane for however long it sat
#: down). This hardcoded default WILL go stale again the next time herdr
#: resets; there is no live discovery-by-label here yet.
DASHBOARD_PANE = os.environ.get("CHIEF_DASHBOARD_PANE", "wB:p1P")

#: Consecutive dead probes required before a restart — see trap 3. One dead
#: probe is not proof of death on a latency-spiky endpoint; it only starts the
#: streak (which `clear_failure` ends on the next successful probe).
DEAD_PROBES_BEFORE_RESTART = 2

RESTART_CAP = 3
RESTART_CAP_WINDOW_SECONDS = 15 * 60
#: NOT a production guard, despite reading like one: the plist's `StartInterval`
#: is 60, so 60 > 45 and this can never block a launchd tick. What it does
#: block is a manual or back-to-back invocation (a hand-run `python3
#: scripts/chief-dashboard-watchdog.py` seconds after another one, or a
#: RunAtLoad tick landing on top of a scheduled one) restarting into a server
#: that is still warming. The real production spacing comes from
#: `StartInterval` and from `RESTART_CAP`.
RESTART_COOLDOWN_SECONDS = 45
#: How long to wait for a killed server to actually stop holding the port. Hit
#: by hand on 2026-09-08: ctrl+c then relaunch left the OLD pid still answering.
PORT_RELEASE_TIMEOUT_SECONDS = 10
#: How long to wait for a restart to produce a DASHBOARD (not merely a socket
#: — D4). Each read inside the wait uses the fast `PROBE_TIMEOUT_SECONDS`
#: budget, so this is room for two full reads plus slack. Sized against the
#: 60s `StartInterval`, worst case on a restart tick: 5s routine probe + 15s
#: confirmation read + 10s port release + 10s pane verify + 10s detached
#: verify = 50s. Raising it eats that margin and lets two ticks overlap.
RESTART_VERIFY_TIMEOUT_SECONDS = 10
#: How long an outage EPISODE outlives its last symptom. The same 15 minutes as
#: the cap window on purpose, not a second tunable: BOTH rolling ledgers
#: (`restarts`, `dead_probes`) are pruned to that window, and an episode lives
#: exactly as long as one of them is non-empty. One rule, so a symptom the cap
#: has already forgotten cannot keep an episode alive either — and, per D3, so
#: the residue's real lifetime is the one this constant claims.
EPISODE_MEMORY_SECONDS = RESTART_CAP_WINDOW_SECONDS
#: Log the flap loudly from this recovery onward. One recovery is an ordinary
#: fixed outage; two inside one episode is a pattern the PO should see in
#: `logs/` even while the gate is still under its 15-minute threshold.
FLAP_RECOVERIES_TO_REPORT = 2
#: ...and from this many SEPARATE outages in the rolling window onward, which
#: is the half D2 needed: a 33%-duty flapper never earns a second consecutive
#: dead probe, so it never restarts and never recovers — its only trace is that
#: it keeps starting new streaks. `chief-tick-gate.py`'s
#: `FLAP_OUTAGE_STARTS_IN_WINDOW` escalates on the same count and defends the
#: number against the measured shapes; keep the two in step.
FLAP_OUTAGE_STARTS_TO_REPORT = 3
#: Hard ceiling on each rolling ledger's length. Only the window is ever read,
#: and at one 60s tick per entry the window holds at most 15 — so this is slack
#: for a hand-run pile-up, not a second window.
LEDGER_ENTRIES_KEPT = 20

# P0 dashboard move: was a literal "/Users/trungluong/..." path (move-map
# line 260) — not an AptusFit path (agent-skills is a separate, shared repo),
# but still hardcoded to one user's home. `expanduser` keeps identical
# behavior on this Mac while dropping the literal username.
PLUGIN_SCRIPTS = os.path.expanduser(
    "~/01_Project/agent-skills/plugins/delivery-ops/scripts")


class _UnlockedJsonStore:
    """Last-resort stand-in for `delivery_ops.filelock` (see `_load_state_store`).

    Same two calls and the same atomic `.tmp<pid>` + `os.replace` write, WITHOUT
    the cross-process lock — so two watchdog processes racing a read-modify-write
    could lose one side's update. Only one process writes this file (a 60s
    LaunchAgent tick that finishes in well under a second), so that race is
    nearly unreachable, and it is in any case the smaller loss of the two on
    offer.
    """

    @staticmethod
    def read_json(path, default=None):
        try:
            with open(path) as handle:
                return json.load(handle)
        except Exception:
            return {} if default is None else default

    @classmethod
    def update_json(cls, path, mutate):
        value = mutate(cls.read_json(path, {}))
        directory = os.path.dirname(path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        tmp = f"{path}.tmp{os.getpid()}"
        with open(tmp, "w") as handle:
            json.dump(value, handle, indent=2)
            handle.write("\n")
        os.replace(tmp, path)
        return value


def _load_state_store():
    """`delivery_ops.filelock` if it imports, else the unlocked stand-in.

    -> (store, is_locked).

    This used to be a bare module-level `from delivery_ops import filelock`
    after a `sys.path.insert`, which made a moved plugin path fatal at IMPORT:
    no probe, no streak, no alarm, and the LaunchAgent log filling with the
    same traceback. `chief-tick-gate.py` forbids exactly that posture for
    itself — "a gate that raises is a gate that answers 'nothing needs you'" —
    and this file is the same rail, so it takes the same stance: degrade the
    locking, never lose the probe. `main` logs the degradation on every tick,
    because running unlocked is abnormal and should be visible.
    """
    sys.path.insert(0, PLUGIN_SCRIPTS)
    try:
        from delivery_ops import filelock
        return filelock, True
    except Exception:
        return _UnlockedJsonStore(), False


STATE_STORE, STATE_STORE_IS_LOCKED = _load_state_store()


def log(message: str) -> None:
    """One timestamped line into the LaunchAgent's log (it accumulates, so an
    untimestamped line is unreadable a day later)."""
    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')} chief-dashboard-watchdog: {message}",
          flush=True)


# ---------------------------------------------------------------- probing

def classify_response(status, body):
    """Is this HTTP response proof the server is alive? -> (alive, reason).

    HTTP 200 with a parseable JSON object is ALIVE even when every feed reads
    `warming` and even when a feed reads `broken` — see trap 1 in the module
    docstring. The only questions asked here are "did something answer" and
    "was the answer JSON".
    """
    if status != 200:
        return False, f"HTTP {status} from /api/state"
    try:
        payload = json.loads(body)
    except Exception:
        return False, "unparseable body from /api/state (not JSON)"
    if not isinstance(payload, dict):
        return False, "unparseable body from /api/state (JSON, but not an object)"
    return True, ""


def probe(timeout=None):
    """GET /api/state -> (alive, reason). Only the known network failures are
    read as dead; anything unexpected propagates to `main`, which logs and
    records it WITHOUT restarting.

    `timeout` defaults to the fast `PROBE_TIMEOUT_SECONDS` budget every routine
    tick uses. `main` passes `CONFIRM_PROBE_TIMEOUT_SECONDS` for the single
    pre-kill confirmation read (trap 3).
    """
    budget = PROBE_TIMEOUT_SECONDS if timeout is None else timeout
    url = f"http://127.0.0.1:{DASHBOARD_PORT}/api/state"
    try:
        with urllib.request.urlopen(url, timeout=budget) as resp:
            status = getattr(resp, "status", None) or resp.getcode()
            body = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        return False, f"HTTP {exc.code} from /api/state"
    except (urllib.error.URLError, socket.timeout, OSError) as exc:
        return False, f"no answer on :{DASHBOARD_PORT} ({exc})"
    return classify_response(status, body)


def port_is_held(port=None, timeout=1.0) -> bool:
    """True while something still accepts connections on the port. Used to
    confirm a killed server actually let go.

    NOT a restart verdict — see `wait_for_dashboard` (D4): an accepted socket
    can belong to a foreign process, or to the OLD server that never let go."""
    port = DASHBOARD_PORT if port is None else port
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=timeout):
            return True
    except OSError:
        return False


# ------------------------------------------------------ failure-file state

def read_state() -> dict:
    """Current streak/episode state, or `{}`. Unlocked on purpose — every write
    is an atomic rename, so a reader never sees a half-written file."""
    state = STATE_STORE.read_json(FAILURE_FILE, {})
    return state if isinstance(state, dict) else {}


def _recent_stamps(state: dict, key: str, now: float) -> list:
    """The timestamps under `key` still inside the rolling window, oldest first.

    One implementation for all three rolling ledgers — `restarts` (the cap),
    `outage_starts` (the gate's flap signal) and `dead_probes` (the episode's
    lifetime) — and for the cap decision, for what survives a successful probe,
    and for when the episode expires. Many readers of one rule, so they can
    never drift into disagreeing about which symptoms still count.

    `0 <= now - t` is D6, and it is not paranoia about hand-edited files: a
    backwards NTP step makes every stored stamp look like the FUTURE, and
    `now - t <= WINDOW` is true for all of them. `restart_decision` then
    answered "a restart issued -7200s ago is still warming" and auto-restart
    stayed off until real time caught up — an outage the watchdog watches and
    refuses to fix. A stamp from the future is not a symptom; drop it.
    """
    stamps = [float(t) for t in (state.get(key) or [])
              if isinstance(t, (int, float))]
    return sorted(t for t in stamps if 0 <= now - t <= RESTART_CAP_WINDOW_SECONDS)


def _episode_residue(state: dict, now: float) -> dict:
    """What survives a successful probe: the two rolling ledgers and the
    trouble anchor, and deliberately none of the fields the gate's
    continuous-outage escalation reads.

    `{}` once the episode is over. "Over" is one rule — `dead_probes` AND
    `restarts` both pruned to empty, i.e. no symptom of either kind inside
    `EPISODE_MEMORY_SECONDS` (D3: this used to be computed from
    `last_failed_at`, which the residue itself drops, so a restart-free episode
    expired after two ticks). `outage_starts` is not consulted because every
    onset is also a dead probe, so it can never outlive `dead_probes`. That is
    what deletes the file and returns a healthy machine to carrying no state.
    """
    state = state if isinstance(state, dict) else {}
    restarts = _recent_stamps(state, "restarts", now)
    dead_probes = _recent_stamps(state, "dead_probes", now)
    outage_starts = _recent_stamps(state, "outage_starts", now)
    if not restarts and not dead_probes:
        return {}
    anchor = int(state.get("trouble_since")
                 or state.get("first_failed_at")
                 or min(dead_probes or restarts))
    # A CONFIRMED death recovered — the streak had reached the point where this
    # file calls it dead (and restarts it, unless the cap or the cooldown said
    # no). D7: a single slow probe followed by a good one is a blip, and
    # counting it as a recovery had the log boasting about a restart ledger
    # that was empty. Ticks that merely find an existing residue count nothing.
    recovered = int(state.get("count") or 0) >= DEAD_PROBES_BEFORE_RESTART
    return {
        "trouble_since": anchor,
        "recoveries": int(state.get("recoveries") or 0) + (1 if recovered else 0),
        "restarts": [int(t) for t in restarts[-LEDGER_ENTRIES_KEPT:]],
        "dead_probes": [int(t) for t in dead_probes[-LEDGER_ENTRIES_KEPT:]],
        "outage_starts": [int(t) for t in outage_starts[-LEDGER_ENTRIES_KEPT:]],
        "cleared_at": int(now),
    }


def record_failure(error: str, restarted: bool, now: float | None = None) -> dict:
    """Extend the streak (or start one), optionally logging a restart attempt.

    TWO anchors, and the difference is the whole of D1:

      * `first_failed_at` — the start of THIS streak. Carried forward across
        later failed cycles of the same streak (or an outage hours old would
        look brand-new on every tick) but NEVER inherited from the episode
        residue. `chief-tick-gate.py` measures continuous unreachability from
        it, and a recovery must reset that clock: inheriting `trouble_since`
        here is what made one slow probe five minutes after a FIXED 20-minute
        outage fire `"unreachable for 25m (1 failed probes)"`.
      * `trouble_since` — the start of the EPISODE, which does survive a
        recovery. It is reported in the gate's `flapping` message and holds
        that alarm behind the shared 15-minute threshold. It is never read as a
        streak age.

    Same discipline (and normally the same `delivery_ops.filelock`) as
    `chief-tick-writer.py:_record_failure`.
    """
    stamp = int(now if now is not None else time.time())

    def mutate(current):
        current = current if isinstance(current, dict) else {}
        restarts = _recent_stamps(current, "restarts", stamp)
        if restarted:
            restarts.append(float(stamp))
        # Every dead probe is recorded, restart or not — that is the only trace
        # D2's 33%-duty flapper leaves, since it never earns a second
        # consecutive dead probe and so never earns a restart.
        dead_probes = _recent_stamps(current, "dead_probes", stamp) + [float(stamp)]
        # ...but the FLAP signal is the ONSET of each streak, not every dead
        # probe. A fixed 20-minute outage leaves 20 dead probes and 1 onset, so
        # counting probes would have made that outage plus one later blip look
        # like a flap — D1 again, wearing the flap branch's clothes.
        outage_starts = _recent_stamps(current, "outage_starts", stamp)
        if not current.get("count"):
            outage_starts.append(float(stamp))
        return {
            "first_failed_at": int(current.get("first_failed_at") or stamp),
            "trouble_since": int(current.get("trouble_since")
                                 or current.get("first_failed_at")
                                 or stamp),
            "last_failed_at": stamp,
            "count": int(current.get("count") or 0) + 1,
            "recoveries": int(current.get("recoveries") or 0),
            "error": str(error)[:300],
            # Bounded: only the rolling window is ever read, and an unbounded
            # list would grow for as long as an outage lasts.
            "restarts": [int(t) for t in restarts[-LEDGER_ENTRIES_KEPT:]],
            "dead_probes": [int(t) for t in dead_probes[-LEDGER_ENTRIES_KEPT:]],
            "outage_starts": [int(t)
                              for t in outage_starts[-LEDGER_ENTRIES_KEPT:]],
        }

    return STATE_STORE.update_json(FAILURE_FILE, mutate)


def clear_failure(now: float | None = None) -> dict:
    """Self-heal: one successful probe ends the STREAK. -> the episode residue.

    It does NOT end the episode, which is QA finding F1: deleting the whole
    file threw away the restart ledger and the trouble anchor with it, so a
    flapping dashboard beat the 3-per-15-minutes cap and never escalated. The
    residue keeps both ledgers plus the anchor (see the module docstring) and
    carries none of the fields the gate's CONTINUOUS-outage escalation reads —
    `first_failed_at` above all — so trap 2's false-alarm guard is stronger
    than it was: a restart that worked and HELD wakes nobody, and neither does
    one slow probe afterwards (D1). Once the episode goes quiet for
    `EPISODE_MEMORY_SECONDS` the file is deleted outright.
    """
    now_stamp = float(now if now is not None else time.time())
    if not read_state():
        # A healthy machine calls this on every tick, forever — never create a
        # file just to say there is nothing wrong.
        return {}
    residue = STATE_STORE.update_json(
        FAILURE_FILE, lambda current: _episode_residue(current, now_stamp))
    if not residue:
        try:
            os.unlink(FAILURE_FILE)
        except (FileNotFoundError, OSError):
            pass
    return residue


def restart_decision(state: dict, now: float | None = None):
    """May we restart right now? -> (allowed, why_not).

    The ledger this reads survives a successful probe (`clear_failure`), so the
    cap applies to a flapping server exactly as it does to a dead one.
    """
    now = now if now is not None else time.time()
    recent = _recent_stamps(state, "restarts", now)
    if recent and (now - recent[-1]) < RESTART_COOLDOWN_SECONDS:
        settling = int(now - recent[-1])
        return False, (f"a restart issued {settling}s ago is still warming "
                       f"(<{RESTART_COOLDOWN_SECONDS}s) — not restarting again")
    if len(recent) >= RESTART_CAP:
        return False, (f"restart cap reached ({len(recent)} in the last "
                       f"{RESTART_CAP_WINDOW_SECONDS // 60}m) — not restarting "
                       f"again; this ledger is left in {FAILURE_FILE} for a "
                       f"human or a future local escalation to read")
    return True, ""


# ------------------------------------------------------------- restarting

def herdr_bin() -> str:
    """`herdr` resolved for a LaunchAgent, which gets the plist's PATH and not
    a login shell's. The plist puts ~/.local/bin on PATH; this keeps a literal
    fallback so a PATH regression degrades to the fallback launcher instead of
    silently never restarting."""
    return (os.environ.get("HERDR_BIN")
            or which("herdr")
            or os.path.expanduser("~/.local/bin/herdr"))


def _run(argv, timeout=15) -> bool:
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except Exception as exc:
        log(f"command failed: {' '.join(argv[:3])}… ({exc})")
        return False
    if done.returncode != 0:
        log(f"command exit {done.returncode}: {' '.join(argv[:3])}… "
            f"{(done.stderr or done.stdout or '').strip()[:200]}")
        return False
    return True


def _command_output(argv, timeout=10) -> str:
    """stdout of a short read-only command, or `""` if it could not be run."""
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except Exception as exc:
        log(f"command failed: {' '.join(argv[:2])}… ({exc})")
        return ""
    return done.stdout or ""


def port_owner_pids(port=None) -> list:
    """pids LISTENING on the port, via `lsof`. The only honest answer to "who
    holds this port"; a command-line pattern is not (see `kill_stale_server`)."""
    port = DASHBOARD_PORT if port is None else port
    pids = []
    for token in _command_output(
            ["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"]).split():
        try:
            pids.append(int(token))
        except ValueError:
            continue
    return pids


def pid_command(pid) -> str:
    """The argv of one pid, or `""` — the safety check before signalling it."""
    return _command_output(["ps", "-o", "command=", "-p", str(pid)]).strip()


def signal_pid(pid, sig=signal.SIGTERM) -> bool:
    """The ONE place this file kills anything. Kept as its own named seam so
    that "who would be signalled" is a question the suite can answer without
    signalling anybody."""
    try:
        os.kill(pid, sig)
        return True
    except OSError as exc:
        log(f"could not signal pid {pid} on :{DASHBOARD_PORT} ({exc})")
        return False


def kill_stale_server() -> None:
    """Kill THE PROCESS HOLDING THE TARGET PORT — nothing else — and WAIT for it
    to let go. Relaunching before the old pid is reaped leaves it answering and
    makes the new process die on bind.

    This was `pkill -f chief-dashboard-server.py`, which is port-blind and
    checkout-blind (QA finding F5): `DASHBOARD_PORT` is env-overridable but the
    pattern was not, so pointing `CHIEF_DASHBOARD_PORT` at a test instance still
    killed the real :4711 board — plus any other worktree's board, plus any
    process whose argv merely mentions the filename. That bit for real on
    2026-09-09: a scratchpad copy of this watchdog killed the live dashboard and
    it stayed down until a human noticed. So: ask the PORT who owns it, check
    the owner looks like this server before signalling, and never signal
    anything else.
    """
    owners = port_owner_pids()
    if not owners:
        return  # a free port needs no kill
    ours = [pid for pid in owners if SERVER_BASENAME in pid_command(pid)]
    strangers = [pid for pid in owners if pid not in ours]
    if strangers:
        log(f"port {DASHBOARD_PORT} is held by pid(s) "
            f"{', '.join(str(p) for p in strangers)} that do not look like "
            f"{SERVER_BASENAME} — refusing to kill them")
    for pid in ours:
        if signal_pid(pid):
            log(f"SIGTERM to pid {pid}, the {SERVER_BASENAME} holding "
                f":{DASHBOARD_PORT}")
    if not ours:
        # Nothing of ours was signalled, so nothing is going to release the
        # port — waiting would just burn the tick.
        return
    deadline = time.time() + PORT_RELEASE_TIMEOUT_SECONDS
    while time.time() < deadline:
        if not port_is_held():
            return
        time.sleep(0.5)
    log(f"port {DASHBOARD_PORT} still held after "
        f"{PORT_RELEASE_TIMEOUT_SECONDS}s — relaunching anyway")


def wait_for_dashboard(timeout=None) -> bool:
    """Did a restart actually produce THE DASHBOARD? -> True/False.

    The honest success test for a restart, and the reason the detached fallback
    can fire at all (QA finding F3). `herdr pane run` exits 0 whenever the PANE
    accepted the text, which it does even when a foreground process in that
    pane (a `cat`, a pager, an editor) swallows the line as stdin and never
    runs it — reproduced live on 2026-09-09: rc=0, the text went into `cat`,
    no server. Judged on the return code alone that restart logged `restarted
    via pane`, and the fallback written for exactly this case could never fire,
    because it only runs when the pane call FAILS.

    **A SOCKET IS NOT PROOF EITHER (D4).** This was `port_is_held()`, which
    answers "did anything accept a TCP connection". Two confirmed shapes where
    that answered yes with no restart having happened: a foreign process
    holding :4711, and `lsof` unresolvable — `port_owner_pids()` returns `[]`,
    `kill_stale_server` reads that as "a free port needs no kill", the OLD
    process keeps the port, the new one dies on bind, and its socket answers
    for it. Both logged *"restarted via pane, listener confirmed"*.

    So this asks the SAME question every routine tick asks — `probe()`, i.e.
    HTTP 200 with a parseable JSON object (`classify_response`) — and nothing
    weaker. Note what that also buys: in the `lsof`-blind shape above, a still
    healthy old process answering 200 is a truthful "the board is up", because
    "is anything answering on :4711" is the only question this file has.

    Bounded on purpose (`RESTART_VERIFY_TIMEOUT_SECONDS`), and each read uses
    the fast `PROBE_TIMEOUT_SECONDS` budget so one hung read cannot eat the
    whole wait. `port_is_held` stays in use for the one question a socket IS
    the right answer to: did the pid we killed let go (`kill_stale_server`).
    """
    budget = RESTART_VERIFY_TIMEOUT_SECONDS if timeout is None else timeout
    deadline = time.time() + budget
    while True:
        try:
            alive, _ = probe()
        except Exception as exc:
            # An unmeasurable read is not a confirmed restart. Fall through to
            # the deadline rather than claiming either outcome from it.
            log(f"the restart verification read raised {type(exc).__name__}: "
                f"{exc}")
            alive = False
        if alive:
            return True
        if time.time() >= deadline:
            return False
        time.sleep(0.5)


def restart_in_pane() -> bool:
    """Preferred path: relaunch inside the PO's herdr pane so they keep the
    window.

    `herdr pane run` DOES submit the line in a shell pane — verified twice
    independently on 2026-09-09, once against the live pane `w2:p1A`: `herdr
    pane run <pane> "python3 scripts/chief-dashboard-server.py"` with NO
    `send-keys` started the server on its own. The long-standing project lore
    that "`pane run` types but does not submit" is wrong for shell panes, and
    the extra `herdr pane send-keys <pane> enter` it licensed was a blind
    keystroke fired into the PO's pane after every restart — unattended, from a
    LaunchAgent, up to 3 times per 15 minutes. Do not re-add it. A stale
    typed-but-unsubmitted line in a pane IS a real phenomenon (also reproduced
    2026-09-09), but a blind Enter is not its remedy: it lands wherever the
    cursor happens to be, and `wait_for_dashboard` is what actually catches a
    command that never ran.
    """
    herdr = herdr_bin()
    return _run([herdr, "pane", "run", DASHBOARD_PANE, f"python3 {SERVER_SCRIPT}"])


def restart_detached() -> bool:
    """Fallback when the pane restart did not produce a board (tab closed, or a
    foreground process ate the command): a headless board beats no board.
    Loses the PO's window, which is why it is second."""
    try:
        os.makedirs(os.path.dirname(FALLBACK_LOG), exist_ok=True)
        with open(FALLBACK_LOG, "a") as out:
            subprocess.Popen(["python3", SERVER_SCRIPT],
                             stdout=out, stderr=out, start_new_session=True,
                             cwd=DASHBOARD_HOME)
        return True
    except Exception as exc:
        log(f"detached fallback failed too: {exc}")
        return False


def restart_dashboard() -> str:
    """-> "pane" | "detached" | "failed", judged on the DASHBOARD's own HTTP
    answer — not on a return code (F3) and not on a socket (D4)."""
    kill_stale_server()
    if restart_in_pane():
        if wait_for_dashboard():
            return "pane"
        log(f"herdr pane {DASHBOARD_PANE} accepted the command but "
            f":{DASHBOARD_PORT} is not answering /api/state "
            f"{RESTART_VERIFY_TIMEOUT_SECONDS}s later (a foreground process in "
            f"a pane eats the line and still exits 0) — falling back to "
            f"detached")
    else:
        log(f"herdr pane {DASHBOARD_PANE} unreachable — falling back to detached")
    if not restart_detached():
        return "failed"
    if wait_for_dashboard():
        return "detached"
    log(f"the detached fallback launched but :{DASHBOARD_PORT} is still not "
        f"answering /api/state — recording the restart as failed")
    return "failed"


# ------------------------------------------------------------------- main

def flap_note(residue: dict) -> str | None:
    """The `FLAPPING:` log line for an episode residue, or None when there is
    no flap to report.

    Says only what the residue actually holds (D7). The line it replaces was
    hard-wired to claim "the restart ledger and the streak anchor are being
    kept", which it printed five times for six slow probes with the board never
    down and `restarts: []` — boasting about an empty ledger. It also fired on
    `recoveries` alone, so the one flap shape that leaves NO recoveries (D2's
    33%-duty outage, which never earns a second consecutive dead probe and so
    never a restart) was the one shape it stayed silent about.
    """
    recoveries = int(residue.get("recoveries") or 0)
    outage_starts = len(residue.get("outage_starts") or [])
    dead_probes = len(residue.get("dead_probes") or [])
    restarts = len(residue.get("restarts") or [])
    if (recoveries < FLAP_RECOVERIES_TO_REPORT
            and outage_starts < FLAP_OUTAGE_STARTS_TO_REPORT):
        return None
    window_minutes = RESTART_CAP_WINDOW_SECONDS // 60
    trouble_for = int(float(residue.get("cleared_at") or 0)
                      - float(residue.get("trouble_since") or 0))
    return (f"FLAPPING: {outage_starts} separate outage(s), {dead_probes} dead "
            f"probe(s), {restarts} restart(s) and {recoveries} recovery/"
            f"recoveries inside the rolling {window_minutes}m window of a "
            f"trouble episode that started {trouble_for}s ago — the ledgers "
            f"survive recoveries, so the {RESTART_CAP}-per-{window_minutes}m "
            f"cap counts across them")


def note_alive(note: str | None = None) -> None:
    """The healthy path: end the streak, keep the episode residue, and say in
    the log when there was something to end (or a flap worth naming)."""
    state = read_state()
    if state.get("count"):
        log(f"alive again after {int(state.get('count') or 0)} failed probe(s) — "
            f"streak cleared" + (f" ({note})" if note else ""))
    elif note:
        log(note)
    flap = flap_note(clear_failure())
    if flap:
        log(flap)


def main() -> None:
    os.chdir(DASHBOARD_HOME)
    if not STATE_STORE_IS_LOCKED:
        log("delivery_ops.filelock did not import — running the state file "
            "UNLOCKED (probe, streak and alarm all intact; see "
            "_load_state_store). Fix PLUGIN_SCRIPTS.")
    try:
        alive, reason = probe()
    except Exception as exc:  # unmeasurable != dead, but != nothing (trap 2)
        record_failure(f"probe raised {type(exc).__name__}: {exc}", restarted=False)
        log(f"probe raised {type(exc).__name__}: {exc} — NOT restarting (an "
            f"unmeasurable probe is not a death), but the failure IS recorded "
            f"in {FAILURE_FILE} so a repeating probe bug is still visible")
        return

    if alive:
        note_alive()
        return

    state = read_state()
    # Trap 3, guard 1: confirm the death on a second consecutive probe before
    # even considering a kill. `count` is the streak this same file already
    # keeps — no second state file.
    streak = int(state.get("count") or 0) + 1
    if streak < DEAD_PROBES_BEFORE_RESTART:
        record_failure(reason, restarted=False)
        log(f"dead ({reason}); dead probe {streak}/{DEAD_PROBES_BEFORE_RESTART} "
            f"— waiting for a second consecutive dead probe before restarting "
            f"(a slow answer is not a death)")
        return

    allowed, why_not = restart_decision(state)
    if not allowed:
        record_failure(reason, restarted=False)
        log(f"dead ({reason}); {why_not}")
        return

    # Trap 3, guard 2: one confirmation read on the long budget, taken only
    # here — on the verge of killing something. Two 5s probes 60s apart are
    # correlated when the cause is a minutes-long load spike; this is not.
    try:
        alive_on_confirm, confirm_reason = probe(CONFIRM_PROBE_TIMEOUT_SECONDS)
    except Exception as exc:
        record_failure(f"confirmation probe raised {type(exc).__name__}: {exc}",
                       restarted=False)
        log(f"dead ({reason}); the {CONFIRM_PROBE_TIMEOUT_SECONDS}s confirmation "
            f"read raised {type(exc).__name__}: {exc} — NOT killing anything on "
            f"an unmeasurable answer")
        return
    if alive_on_confirm:
        note_alive(f"answered the {CONFIRM_PROBE_TIMEOUT_SECONDS}s confirmation "
                   f"read after {streak} dead {PROBE_TIMEOUT_SECONDS}s probe(s) "
                   f"— slow, not dead; nothing was killed")
        return

    outcome = restart_dashboard()
    record_failure(f"{reason}; restart via {outcome}", restarted=True)
    if outcome == "failed":
        log(f"dead ({reason}, confirmed: {confirm_reason}) — restart FAILED: "
            f"nothing is listening on :{DASHBOARD_PORT} after the pane and the "
            f"detached fallback")
    else:
        log(f"dead ({reason}, confirmed: {confirm_reason}) — restarted via "
            f"{outcome}, listener confirmed on :{DASHBOARD_PORT}")


if __name__ == "__main__":
    main()
