#!/usr/bin/env python3
"""Hook-vs-screen precedence (`resolve_state`) and the dashboard's derived
state column agree with each other, including the "parked on a background
agent/monitor" carve-out and its 2h ceiling.

Ported from AptusFit scripts/tests/test_pane_liveness_background.py (P0
move). That file's first half (`heartbeat()` -> `THE FALSE ALARM` / `THE
BOUND` / `MED-3` / `CONTROL` / `NOT LOGGED IN` sections) exercises
`pane_liveness.liveness()` + the agent-skills delivery-ops plugin's
`supervisor.supervise()` end to end — both NOT-CARRIED (they run inside
worker sessions via `pane-tick-writer.py`, which stays in AptusFit; the
dashboard server never imports them). Dropped here.

Kept: `HOOK vs SCREEN PRECEDENCE`, `LOW-6`, `LOW-3`, and `THE DASHBOARD'S
STATE COLUMN` sections — these exercise `pane_screen_signals.resolve_state`
and `chief_dashboard_store.derived_values_for_agent`, both in the MOVE set,
with no dependency on `pane_liveness`/`supervisor`.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "server", "lib"))

import pane_screen_signals as signals  # noqa: E402
import chief_dashboard_store as store  # noqa: E402

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


print("HOOK vs SCREEN PRECEDENCE (resolve_state)")
for label, hook, screen, want in [
    ("hook idle during a live spinner -> working", "idle", "ACTIVE", "working"),
    ("hook working while a dialog is open -> blocked", "working", "NEEDS_HUMAN", "blocked"),
    ("hook blocked over a correct crash read -> crashed", "blocked", "CRASHED", "crashed"),
    ("hook working over a login wall -> blocked (a person must act)", "working", "NEEDS_LOGIN", "blocked"),
    ("hook working but the turn is over -> idle", "working", "WAITING", "idle"),
    ("hook working (no age known) but the turn is over -> idle", "working", "WAITING", "idle"),
    ("hook idle but parked on background work -> working", "idle", "WAITING_ON_BACKGROUND", "working"),
    ("hook blocked, screen says idle -> blocked stands (fail open)", "blocked", "WAITING", "blocked"),
    ("hook blocked, screen unreadable -> blocked stands", "blocked", None, "blocked"),
    ("hook blocked, screen UNKNOWN -> blocked stands", "blocked", "UNKNOWN", "blocked"),
    ("hookless (second Mac) pane: screen alone decides", None, "NEEDS_HUMAN", "blocked"),
    ("hookless pane, screen idle", None, "WAITING", "idle"),
    ("no opinion anywhere", None, None, None),
]:
    check(label, signals.resolve_state(hook, screen), want)

print("\nLOW-6: a FRESH hook `working` beats a finished-looking screen")
for label, hook, screen, age, want in [
    ("fresh working + screen WAITING -> working", "working", "WAITING", 5, "working"),
    ("fresh working + parked -> working", "working", "WAITING_ON_BACKGROUND", 5, "working"),
    ("STALE working (10 min) + screen WAITING -> idle", "working", "WAITING", 600, "idle"),
    ("fresh working never beats an open dialog", "working", "NEEDS_HUMAN", 5, "blocked"),
    ("fresh working never beats a crash", "working", "CRASHED", 5, "crashed"),
    ("fresh working never beats a login wall", "working", "NEEDS_LOGIN", 5, "blocked"),
    ("fresh idle hook + screen WAITING -> idle", "idle", "WAITING", 5, "idle"),
]:
    check(label, signals.resolve_state(hook, screen, hook_age_sec=age), want)
check("dashboard column: fresh hook working over a WAITING screen shows working",
      store.derived_values_for_agent({"machine": "local", "hookState": "working",
                                      "hasHookData": True, "screenState": "WAITING",
                                      "hookSinceSec": 4})["derived:state"], "working")

print("\nLOW-3: a parked pane stops reading `working` past the 2h ceiling")
CEILING = signals.BACKGROUND_WAIT_CEILING_SEC
check("the dashboard ceiling equals the supervisor's (2h)", CEILING, 2 * 60 * 60)
for label, hook, screen, age, want in [
    ("parked 1h55m -> still working", "idle", "WAITING_ON_BACKGROUND", 6900, "working"),
    ("parked 2h+ -> idle (the dead frame no longer reads green)",
     "idle", "WAITING_ON_BACKGROUND", 7300, "idle"),
    ("parked 2h+ over a frozen hook `working` -> idle",
     "working", "WAITING_ON_BACKGROUND", 7300, "idle"),
    ("parked, age unknown (hookless) -> working (cannot judge)",
     None, "WAITING_ON_BACKGROUND", None, "working"),
    ("parked 2h+ never hides a hook `blocked`",
     "blocked", "WAITING_ON_BACKGROUND", 7300, "blocked"),
]:
    check(label, signals.resolve_state(hook, screen, hook_age_sec=age), want)
check("expiry helper: parked past the ceiling",
      signals.background_wait_expired("WAITING_ON_BACKGROUND", 7300), True)
check("expiry helper: a plain WAITING pane is never 'expired parked'",
      signals.background_wait_expired("WAITING", 99999), False)
check("expiry helper: unknown age is not expired",
      signals.background_wait_expired("WAITING_ON_BACKGROUND", None), False)
check("dashboard column: parked 2h+ shows idle",
      store.derived_values_for_agent({"machine": "local", "hookState": "idle",
                                      "hasHookData": True,
                                      "screenState": "WAITING_ON_BACKGROUND",
                                      "hookSinceSec": 7300})["derived:state"], "idle")

print("\nTHE DASHBOARD'S STATE COLUMN uses that same rule")
def state_column(hook, screen, machine="local"):
    return store.derived_values_for_agent({
        "machine": machine, "hookState": hook, "hasHookData": hook is not None,
        "screenState": screen})["derived:state"]

check("local: stale hook `idle` over a live spinner shows working",
      state_column("idle", "ACTIVE"), "working")
check("local: stale hook `working` over an open dialog shows blocked",
      state_column("working", "NEEDS_HUMAN"), "blocked")
check("local: hook `blocked` over a correct crash read shows crashed",
      state_column("blocked", "CRASHED"), "crashed")
check("local: no screen reading -> the hook word stands",
      state_column("idle", None), "idle")
check("local: no hook and no screen -> 'no data' (unchanged)",
      state_column(None, None), "no data")
check("second Mac (hookless): a parked-on-monitor pane shows working",
      state_column(None, "WAITING_ON_BACKGROUND", "air"), "working")
check("second Mac: a login wall shows blocked",
      state_column(None, "NEEDS_LOGIN", "air"), "blocked")
check("second Mac: unreadable stays 'unknown' (unchanged)",
      state_column(None, "UNKNOWN", "air"), "unknown")

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("All pane-liveness background checks passed.")
