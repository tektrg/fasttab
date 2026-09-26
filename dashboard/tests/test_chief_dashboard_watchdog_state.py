#!/usr/bin/env python3
"""Watchdog tests, part 1/3: probe classification + the failure-file's pure
state logic (streak accounting, clear-on-success, episode lifetime, restart
cap, cooldown, recoveries). No machine access anywhere in this file — no
herdr, no subprocess, no real port.

Ported from AptusFit's `scripts/tests/test_chief_dashboard_watchdog.py`
(~1390 lines) against this checkout's `scripts/chief-dashboard-watchdog.py`,
which is a straight behavioural copy — the P0 move only changed how
`FAILURE_FILE`/`FALLBACK_LOG`/`SERVER_SCRIPT`/`PLUGIN_SCRIPTS` resolve
(derived from `dashboard_config` instead of a literal AptusFit path) and
some log wording that referenced `chief-tick-gate.py` (AptusFit's own
chief-supervision-loop escalation, not part of this move — see
`dashboard/AGENTS.md`'s P0 move note in the watchdog module docstring). None
of that changes what these functions compute, so every case below is a
same-logic port, not an adaptation.

DROPPED from the AptusFit original, entirely and on purpose (see this
checkout's `dashboard/AGENTS.md` "Not done in P0" — `chief-tick-gate.py` was
never moved here, it is AptusFit's own chief-supervision-loop code):
- The whole `== gate: ... ==` section (`chief-tick-gate.py`'s
  `dashboard_down_reason`/`dashboard_flapping_reason`/
  `dashboard_continuous_outage_reason`/`annotate_dashboard_down`/
  `pane_feed_broken_reason`/`main()`, and the 03:00 quiet-hours check) — this
  checkout has no such module to import, let alone test.
- The end-to-end `_FakeClock` flap simulation that drives the watchdog's
  `main()` and the gate's `main()` together tick-by-tick — same reason, it
  needs the gate.
This is not a loss of watchdog coverage: every watchdog-side fact those
end-to-end sims proved (the restart cap holds across a clear, the episode
residue carries the right ledgers, blips don't miscount as recoveries) is
already pinned by the pure unit checks below and in the other two watchdog
test files, which this port keeps in full.

See also: test_chief_dashboard_watchdog_main.py (main()'s orchestration of
these functions) and test_chief_dashboard_watchdog_restart.py (the
restart-execution layer: herdr/kill/wait/restart).
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


wd = _load("chief_dashboard_watchdog_state_test", "chief-dashboard-watchdog.py")

fails = []


def check(label, got, want=True):
    ok = (got == want) if want is not True else bool(got)
    if not ok:
        fails.append(f"{label}: got {got!r}" + (f" want {want!r}" if want is not True else ""))
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def reset_state():
    """Delete the state file outright — not the same as `clear_failure()`,
    which leaves an episode residue behind on purpose (F1)."""
    try:
        os.unlink(wd.FAILURE_FILE)
    except OSError:
        pass


ALL_WARMING = '{"feeds": {"panes": {"warming": true, "broken": false}, ' \
    '"board": {"warming": true, "broken": false}}, ' \
    '"computed": {"agents": [], "needsYou": [], "residueCount": 0}}'
ONE_BROKEN = '{"feeds": {"panes": {"warming": false, "broken": true}, ' \
    '"board": {"warming": false, "broken": false}}, ' \
    '"computed": {"agents": [{"id": "a"}], "needsYou": [], "residueCount": 2}}'
HEALTHY = '{"feeds": {"panes": {"warming": false, "broken": false}}, ' \
    '"computed": {"agents": [], "needsYou": [], "residueCount": 0}}'

print("== probe classification: alive means SOMETHING ANSWERED, nothing more ==")
check("healthy 200 is alive", wd.classify_response(200, HEALTHY)[0], True)
# Trap 1. A cold start looks exactly like this for ~45 seconds.
check("EVERY feed warming is still ALIVE",
      wd.classify_response(200, ALL_WARMING)[0], True)
check("a broken feed is still ALIVE (the board's own alarm has an owner)",
      wd.classify_response(200, ONE_BROKEN)[0], True)

print("== probe classification: dead ==")
alive, why = wd.classify_response(500, "internal error")
check("500 is dead", alive, False)
check("500 says so", "500" in why, True)
alive, why = wd.classify_response(200, "<html>Not the dashboard</html>")
check("unparseable body is dead", alive, False)
check("unparseable body says so", "unparseable" in why, True)
check("truncated JSON is dead", wd.classify_response(200, '{"feeds": {"pan')[0], False)
check("empty body is dead", wd.classify_response(200, "")[0], False)
check("JSON that is not an object is dead",
      wd.classify_response(200, "[1, 2, 3]")[0], False)
check("a bare JSON number is dead", wd.classify_response(200, "0")[0], False)


print("== failure-file streak accounting ==")
tmpdir = tempfile.mkdtemp(prefix="chief-dashboard-watchdog-test-")
wd.FAILURE_FILE = os.path.join(tmpdir, ".chief-dashboard-failure.json")

check("no file means no streak", wd.read_state(), {})
t0 = time.time() - 600
wd.record_failure("no answer on :4711", restarted=True, now=t0)
state = wd.read_state()
check("streak count 1", state["count"], 1)
check("streak anchored", state["first_failed_at"], int(t0))
check("restart logged", len(state["restarts"]), 1)
check("error recorded", "no answer" in state["error"], True)

wd.record_failure("no answer on :4711", restarted=False, now=t0 + 60)
state = wd.read_state()
check("streak count 2", state["count"], 2)
check("anchor NOT reset by a later failure", state["first_failed_at"], int(t0))
check("last_failed_at advances", state["last_failed_at"], int(t0 + 60))
check("no restart logged when none was attempted", len(state["restarts"]), 1)
check("the episode anchor tracks the streak anchor inside one streak",
      state["trouble_since"], int(t0))
check("every dead probe joins the dead-probe ledger", len(state["dead_probes"]), 2)
check("...but a streak's later probes are NOT new outages",
      len(state["outage_starts"]), 1)
check("...and the one onset is the streak's first probe",
      state["outage_starts"], [int(t0)])

wd.record_failure("still dead", restarted=True, now=t0 + 120)
check("second restart logged", len(wd.read_state()["restarts"]), 2)
check("error is the latest one", wd.read_state()["error"], "still dead")

print("== clear-on-success: the STREAK ends, the EPISODE does not (F1) ==")
cleared = wd.clear_failure()
state = wd.read_state()
check("clearing drops every field a continuous-outage alarm would read",
      [k for k in ("first_failed_at", "last_failed_at", "count", "error")
       if k in state], [])
check("...so a reader sees the cleared file as no streak at all",
      wd.read_state().get("count"), None)
check("clearing KEEPS the rolling restart ledger", len(state.get("restarts") or []), 2)
check("clearing KEEPS the episode anchor", state.get("trouble_since"), int(t0))
check("clearing counts the recovery", state.get("recoveries"), 1)
check("clearing KEEPS the outage-onset ledger the flap alarm fires on",
      len(state.get("outage_starts") or []), 1)
check("clearing KEEPS the dead-probe ledger the episode's lifetime is timed by",
      len(state.get("dead_probes") or []), 3)
check("clear_failure hands back the residue it wrote", cleared, state)

wd.clear_failure()
check("clearing again does not invent a second recovery",
      wd.read_state().get("recoveries"), 1)

reset_state()
wd.clear_failure()  # must be idempotent — a healthy machine calls this forever
check("clearing an absent file is a no-op", wd.read_state(), {})
check("...and never creates a file just to say nothing is wrong",
      os.path.exists(wd.FAILURE_FILE), False)

print("== episode lifetime is driven by the last symptom (D3) ==")
stale = time.time() - wd.EPISODE_MEMORY_SECONDS - 60
wd.record_failure("dead", restarted=True, now=stale)
wd.clear_failure()
check("an episode with no symptom inside the memory window is forgotten",
      wd.read_state(), {})
check("...and its file is deleted, not left as an empty husk",
      os.path.exists(wd.FAILURE_FILE), False)

reset_state()
recent = time.time() - 120
wd.record_failure("one slow probe, nothing restarted", restarted=False, now=recent)
check("a restart-free episode leaves no restart ledger to expire from",
      wd.read_state()["restarts"], [])
wd.clear_failure(now=recent + 60)
check("a restart-free episode's residue SURVIVES its first good probe",
      bool(wd.read_state()), True)
wd.clear_failure(now=recent + 120)
check("...and its second, which is where the old rule deleted it",
      bool(wd.read_state()), True)
wd.clear_failure(now=recent + wd.EPISODE_MEMORY_SECONDS - 1)
check("...and survives right up to EPISODE_MEMORY_SECONDS after its last "
      "dead probe", bool(wd.read_state()), True)
wd.clear_failure(now=recent + wd.EPISODE_MEMORY_SECONDS + 1)
check("...and is forgotten one second past it — the lifetime the constant "
      "claims", wd.read_state(), {})

check("a long error string is truncated, not stored whole",
      len(wd.record_failure("x" * 5000, restarted=False)["error"]), 300)
reset_state()


print("== restart cap: 3 in a rolling 15 minutes ==")
now = time.time()
allowed, why = wd.restart_decision({}, now=now)
check("a fresh streak may restart", allowed, True)
allowed, why = wd.restart_decision({"restarts": [now - 600, now - 400]}, now=now)
check("2 recent restarts still allows a 3rd", allowed, True)
allowed, why = wd.restart_decision(
    {"restarts": [now - 800, now - 600, now - 400]}, now=now)
check("3 recent restarts blocks the 4th", allowed, False)
check("the cap says why", "cap" in why, True)
allowed, _ = wd.restart_decision(
    {"restarts": [now - 3000, now - 2000, now - 1000]}, now=now)
check("restarts older than the window do not count", allowed, True)
allowed, _ = wd.restart_decision(
    {"restarts": [now - 2000, now - 1000, now - 899]}, now=now)
check("the window boundary counts only what is inside it", allowed, True)

print("== restart cap: counted ACROSS a clear, not per streak (F1) ==")
reset_state()
now = time.time()
for age in (700, 500, 300):
    wd.record_failure("dead", restarted=True, now=now - age)
residue = wd.clear_failure(now=now - 200)
check("the ledger survives the recovery", len(residue.get("restarts") or []), 3)
allowed, why = wd.restart_decision(wd.read_state(), now=now)
check("a flapper's 4th restart inside the window is still refused", allowed, False)
check("...and it is the cap that says so", "cap" in why, True)

print("== two signals, not one field (D1/D2) ==")
state = wd.record_failure("dead again", restarted=False, now=now)
check("a new streak after a recovery starts its OWN continuous-outage clock",
      state["first_failed_at"], int(now))
check("...so the age a continuous-outage alarm would read is this streak's, "
      "not 700s", int(now) - state["first_failed_at"], 0)
check("...while the EPISODE anchor still remembers the older trouble",
      state["trouble_since"], int(now - 700))
check("...and its own consecutive-failure count starts at 1", state["count"], 1)
check("a new streak's first dead probe is a new outage onset",
      state["outage_starts"], [int(now - 700), int(now)])
check("...one onset per STREAK, not one per dead probe (the 3 failures above "
      "were one streak)", len(state["dead_probes"]), 4)
reset_state()

print("== restart cooldown: never restart into a server you just restarted ==")
allowed, why = wd.restart_decision({"restarts": [now - 10]}, now=now)
check("10s after a restart, hold off", allowed, False)
check("the cooldown says why", "warming" in why, True)
allowed, _ = wd.restart_decision({"restarts": [now - 50]}, now=now)
check("50s after a restart (past the ~45s warm-up), allowed", allowed, True)
check("garbage in the restarts list does not crash the decision",
      wd.restart_decision({"restarts": ["nonsense", None]}, now=now)[0], True)
check("the cooldown is shorter than the 60s tick it can never block",
      wd.RESTART_COOLDOWN_SECONDS < 60, True)
# D6. `now - t <= WINDOW` is true for any FUTURE timestamp, so a backwards NTP
# step made every stored stamp look like the future.
allowed, why = wd.restart_decision({"restarts": [now + 7200]}, now=now)
check("a restart stamped in the FUTURE does not disarm the cooldown",
      allowed, True)
check("...and it is not reported as a negative age", "-" in why, False)
check("...nor does it count against the cap",
      wd.restart_decision({"restarts": [now + 7200, now + 7300, now + 7400]},
                          now=now)[0], True)
check("a future stamp is pruned out of the ledger, not carried",
      wd._recent_stamps({"restarts": [now + 7200, now - 100]}, "restarts", now),
      [now - 100])

print("== recoveries count CONFIRMED deaths only (D7) ==")
reset_state()
blip_at = time.time() - 120
wd.record_failure("slow", restarted=False, now=blip_at)
check("a one-probe streak is not a recovery",
      wd.clear_failure(now=blip_at + 60).get("recoveries"), 0)
reset_state()
wd.record_failure("dead", restarted=False, now=blip_at)
wd.record_failure("dead", restarted=True, now=blip_at + 60)
check("a streak that reached DEAD_PROBES_BEFORE_RESTART is a real recovery",
      wd.clear_failure(now=blip_at + 120).get("recoveries"), 1)
note = wd.flap_note({"dead_probes": [1, 2, 3], "outage_starts": [1, 2, 3],
                     "restarts": [], "recoveries": 0,
                     "trouble_since": 0, "cleared_at": 900})
check("the FLAPPING log reports the counts it actually has", "0 restart(s)" in
      (note or ""), True)
check("...and reports a flap with no recovery at all, which is D2's shape",
      "0 recovery" in (note or ""), True)
check("an episode with one outage and nothing else is not logged as a flap",
      wd.flap_note({"outage_starts": [1], "dead_probes": [1], "restarts": [],
                    "recoveries": 0}), None)
reset_state()

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("All watchdog state checks passed.")
