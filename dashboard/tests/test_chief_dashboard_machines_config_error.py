#!/usr/bin/env python3
"""Direct-run test: a broken .claude/dashboard-machines.json must surface a
diagnostic on /api/state, never silently vanish.

Bug: parse_machines_config() is all-or-nothing — any parse problem returns
({}, "error string"). get_full_state() used to only add feeds_snap["machines"]
`if MACHINES:` — since a config error always makes MACHINES falsy too, the
error string was dropped on the floor and a single typo in
dashboard-machines.json was indistinguishable, from /api/state, from "no
config file at all". Fixed by always setting feeds_snap["machinesConfigError"]
(None when there's no error) regardless of whether MACHINES is empty.

Runs in its own fresh process (no other test file's MACHINES-patching has run
yet), so FEEDS' per-machine entries — built once, at chief_dashboard_feeds.py's
own real import time, from whatever MACHINES the real dashboard-machines.json
config resolved to — are guaranteed to match whatever MACHINES/FEEDS this
process ends up with. This test only overwrites the already-imported
MACHINES_CONFIG_ERROR binding, never MACHINES/FEEDS, so that guarantee is
never at risk."""
import os
import sys

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib"))

import chief_dashboard_views as views  # noqa: E402

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


_ORIG_ERROR = views.MACHINES_CONFIG_ERROR

try:
    print("== a broken machines config surfaces a non-null error on /api/state ==")
    views.MACHINES_CONFIG_ERROR = ("could not parse "
                                    ".claude/dashboard-machines.json: "
                                    "Expecting ',' delimiter: line 4 column 3")
    state = views.get_full_state()
    check("machinesConfigError key is present",
          "machinesConfigError" in state["feeds"], True)
    check("machinesConfigError carries the parse error, not swallowed",
          state["feeds"]["machinesConfigError"], views.MACHINES_CONFIG_ERROR)

    print("== no config error -> the key is explicitly null, not missing ==")
    views.MACHINES_CONFIG_ERROR = None
    state2 = views.get_full_state()
    check("machinesConfigError key is still present when there's no error",
          "machinesConfigError" in state2["feeds"], True)
    check("machinesConfigError reads None (not absent) when config is clean",
          state2["feeds"]["machinesConfigError"], None)
finally:
    views.MACHINES_CONFIG_ERROR = _ORIG_ERROR

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("All machines-config-error checks passed.")
