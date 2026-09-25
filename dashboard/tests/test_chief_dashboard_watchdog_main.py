#!/usr/bin/env python3
"""Watchdog tests, part 2/3: `main()`'s own orchestration — trap 3 (two
consecutive dead probes plus a longer confirmation read before any kill),
the anti-flap "one slow blip kills nothing" case, the cap/cooldown gating a
CONFIRMED death, and an unmeasurable probe being recorded but never treated
as a restart licence (F6). `probe` and `restart_dashboard` are stubbed
throughout so nothing here touches the network or a real pane.

Ported from AptusFit's `scripts/tests/test_chief_dashboard_watchdog.py`
against this checkout's `scripts/chief-dashboard-watchdog.py` — same
behaviour, only `FAILURE_FILE` resolution and some `chief-tick-gate.py`-
flavoured log wording moved (see test_chief_dashboard_watchdog_state.py's
docstring for the full P0-move rationale; nothing in this file's assertions
depended on that wording).

See test_chief_dashboard_watchdog_state.py for what was dropped wholesale
(the `chief-tick-gate.py` gate section — that module was never moved into
this checkout) and for the pure failure-file state logic this file's
`main()` calls drive. See test_chief_dashboard_watchdog_restart.py for the
restart-execution layer (`kill_stale_server`/`restart_in_pane`/
`restart_detached`/`wait_for_dashboard`).
"""
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))

import importlib.util  # noqa: E402


def _load(module_name, filename):
    spec = importlib.util.spec_from_file_location(
        module_name, os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "scripts", filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


wd = _load("chief_dashboard_watchdog_main_test", "chief-dashboard-watchdog.py")

fails = []


def check(label, got, want=True):
    ok = (got == want) if want is not True else bool(got)
    if not ok:
        fails.append(f"{label}: got {got!r}" + (f" want {want!r}" if want is not True else ""))
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def dead_probe(reason="no answer on :4711 (timed out)"):
    """A `wd.probe` stub. Takes the budget `main` passes for its confirmation
    read (F4) so a stub can never hide that second call behind a TypeError."""
    return lambda timeout=None: (False, reason)


def live_probe():
    return lambda timeout=None: (True, "")


def reset_state():
    try:
        os.unlink(wd.FAILURE_FILE)
    except OSError:
        pass


tmpdir = tempfile.mkdtemp(prefix="chief-dashboard-watchdog-main-test-")
wd.FAILURE_FILE = os.path.join(tmpdir, ".chief-dashboard-failure.json")

print("== main(): alive / dead / unmeasurable ==")
restarts_issued = []
real_probe, real_restart = wd.probe, wd.restart_dashboard
wd.restart_dashboard = lambda: (restarts_issued.append(1) or "pane")

wd.record_failure("earlier outage", restarted=True, now=time.time() - 120)
wd.probe = live_probe()
wd.main()
check("an alive probe ends the streak", wd.read_state().get("count"), None)
check("an alive probe restarts nothing", len(restarts_issued), 0)
reset_state()

print("== main(): trap 3 — one dead probe is not proof of death ==")
wd.probe = dead_probe()
wd.main()
check("the FIRST dead probe does NOT restart", len(restarts_issued), 0)
check("the first dead probe still records the streak", wd.read_state()["count"], 1)
check("nothing is logged for the cap when no restart was attempted",
      len(wd.read_state()["restarts"]), 0)
check("the streak anchor is set on the first dead probe",
      bool(wd.read_state()["first_failed_at"]), True)

wd.main()
check("the SECOND consecutive dead probe restarts", len(restarts_issued), 1)
check("the confirmed streak reads 2", wd.read_state()["count"], 2)
check("the restart is logged for the cap", len(wd.read_state()["restarts"]), 1)

wd.main()
check("the very next tick does not restart again (cooldown)", len(restarts_issued), 1)
check("but it does extend the streak", wd.read_state()["count"], 3)

print("== main(): trap 3 — a slow blip kills nothing (the anti-flap case) ==")
reset_state()
restarts_issued.clear()
wd.probe = dead_probe()
wd.main()
check("blip: the slow answer restarts nothing", len(restarts_issued), 0)
check("blip: a streak of 1 is on file", wd.read_state()["count"], 1)
wd.probe = live_probe()
wd.main()
check("blip: the next probe answering ends the streak",
      wd.read_state().get("count"), None)
check("blip: the residue keeps an episode anchor and nothing firable",
      sorted(wd.read_state()), ["cleared_at", "dead_probes", "outage_starts",
                                "recoveries", "restarts", "trouble_since"])
check("blip: and above all NO first_failed_at",
      "first_failed_at" in wd.read_state(), False)
wd.probe = dead_probe()
wd.main()
check("after a cleared streak the next dead probe is the FIRST of a NEW "
      "streak — still no restart", len(restarts_issued), 0)
check("...and the consecutive count starts over at 1", wd.read_state()["count"], 1)

print("== main(): the cap and the cooldown still gate a CONFIRMED death ==")
reset_state()
restarts_issued.clear()
now = time.time()
for age in (800, 600, 400):
    wd.record_failure("dead", restarted=True, now=now - age)
check("cap primed: 3 restarts inside the 15m window",
      len(wd.read_state()["restarts"]), 3)
wd.probe = dead_probe("no answer on :4711 (refused)")
wd.main()
check("cap reached: a confirmed dead probe still does not restart",
      len(restarts_issued), 0)
check("cap reached: the streak keeps growing",
      wd.read_state()["count"], 4)

reset_state()
restarts_issued.clear()
wd.record_failure("dead", restarted=True, now=time.time() - 10)
wd.main()
check("cooldown: 10s after a restart, a confirmed dead probe holds off",
      len(restarts_issued), 0)
check("cooldown: the failure is still recorded", wd.read_state()["count"], 2)


print("== main(): F4 — a confirmation read on a LONGER budget before any kill ==")
reset_state()
restarts_issued.clear()
budgets = []


def recording_probe(answers):
    """A probe that records the budget it was called with and answers from a
    list, so a test can see BOTH reads `main` makes on a restart tick."""
    queue = list(answers)

    def stub(timeout=None):
        budgets.append(timeout)
        return queue.pop(0) if queue else (False, "no answer on :4711 (refused)")
    return stub


wd.probe = recording_probe([(False, "dead"), (False, "dead")])
wd.main()   # first dead probe: streak only
wd.probe = recording_probe([(False, "dead"), (False, "dead")])
budgets.clear()
wd.main()   # second dead probe: confirmation read, then the restart
check("the confirmed death takes TWO reads on the same tick", len(budgets), 2)
check("the routine read uses the fast default budget", budgets[0], None)
check("the read taken on the verge of a kill uses the LONG budget",
      budgets[1] if len(budgets) > 1 else None, wd.CONFIRM_PROBE_TIMEOUT_SECONDS)
check("the long budget really is longer than the routine one",
      wd.CONFIRM_PROBE_TIMEOUT_SECONDS > wd.PROBE_TIMEOUT_SECONDS, True)
check("both reads dead: the restart happens", len(restarts_issued), 1)

reset_state()
restarts_issued.clear()
wd.probe = dead_probe()
wd.main()
wd.probe = recording_probe([(False, "slow"), (True, "")])
budgets.clear()
wd.main()
check("a server that answers the confirmation read is NOT killed",
      len(restarts_issued), 0)
check("...and the confirmation read is what asked (2 reads, the 2nd long)",
      budgets, [None, wd.CONFIRM_PROBE_TIMEOUT_SECONDS])
check("...and its streak ends, because it answered",
      wd.read_state().get("count"), None)

reset_state()
restarts_issued.clear()
wd.probe = dead_probe()
wd.main()


def _confirm_raises(timeout=None):
    if timeout is None:
        return False, "no answer on :4711 (refused)"
    raise RuntimeError("the confirmation read itself broke")


wd.probe = _confirm_raises
wd.main()
check("an unmeasurable confirmation read kills nothing", len(restarts_issued), 0)
check("...but the failure is still recorded",
      wd.read_state().get("count"), 2)
check("...and the state file says what went wrong",
      "confirmation probe raised" in (wd.read_state().get("error") or ""), True)


print("== main(): an unmeasurable probe is recorded, not silently swallowed (F6) ==")
reset_state()
restarts_issued.clear()


def _raise(timeout=None):
    raise RuntimeError("something this file never anticipated")


wd.probe = _raise
wd.main()
check("an unmeasurable probe never restarts", len(restarts_issued), 0)
check("an unmeasurable probe IS recorded, so the failure ledger still moves",
      wd.read_state().get("count"), 1)
check("...naming the exception, not a fake network error",
      "probe raised RuntimeError" in (wd.read_state().get("error") or ""), True)
check("...and it keeps advancing last_failed_at",
      bool(wd.read_state().get("last_failed_at")), True)
wd.probe, wd.restart_dashboard = real_probe, real_restart
reset_state()

print("== main(): a failed restart is recorded as failed, not as a success ==")
logged = []
wd.log = lambda message: logged.append(message)
wd.restart_dashboard = lambda: "failed"
wd.probe = dead_probe("no answer on :47110 (refused)")
wd.main()
wd.main()
state = wd.read_state()
check("the state file records the honest outcome",
      "restart via failed" in (state.get("error") or ""), True)
check("...the attempt still counts against the cap",
      len(state.get("restarts") or []), 1)
check("...and the log does not claim a restart",
      any("restart FAILED" in m for m in logged), True)
check("...and never says `restarted via failed`",
      any("restarted via failed" in m for m in logged), False)
wd.probe, wd.restart_dashboard = real_probe, real_restart
reset_state()

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("All watchdog main() checks passed.")
