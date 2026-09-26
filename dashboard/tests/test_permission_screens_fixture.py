#!/usr/bin/env python3
"""Guards `scripts/tests/fixtures/permission-screens.json` against silent
drift from `classify_pane.py` — the fixture exists so the AgentBar Swift
parser can check its own output against a real captured screen's EXPECTED
parse, and a fixture that quietly stops matching the Python source of
truth would defeat that purpose without any test ever failing.

Re-parses every fixture screen with the CURRENT classify_pane parsers and
diffs against the fixture's recorded output — byte-for-byte, not just
"both non-None". Run: python3 scripts/tests/test_permission_screens_fixture.py
"""
import json
import os
import sys

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib"))
import classify_pane as cp

FIXTURE_PATH = os.path.join(
    os.path.dirname(__file__), "fixtures", "permission-screens.json")

PARSERS = {
    "parse_permission_or_plan_block": cp.parse_permission_or_plan_block,
    "parse_plan_approval_block": cp.parse_plan_approval_block,
    "parse_permission_block": cp.parse_permission_block,
    "parse_question_block": cp.parse_question_block,
}

fail = 0
with open(FIXTURE_PATH) as f:
    fixture = json.load(f)

for name, case in fixture["cases"].items():
    tail = case["screen"].splitlines()
    for fn_name, fn in PARSERS.items():
        got = fn(tail)
        want = case[fn_name]
        if got != want:
            print(f"FAIL {name}.{fn_name}: fixture is stale\n"
                  f"  fixture says: {want!r}\n"
                  f"  parser now returns: {got!r}")
            fail = 1
    if not fail:
        print(f"PASS {name}")

# dashboard-plan-box-wrapped brief: the narrow (hard-wrapped title+footer)
# and wide (single-line) captures of the SAME plan-approval box must parse
# to the byte-identical object — proves the wrap-tolerance fix reconstructs
# exactly what the unwrapped screen would have given, not an approximation.
narrow = fixture["cases"]["plan_approval_box_narrow_wrapped"]
wide = fixture["cases"]["plan_approval_box_wide_equivalent"]
if narrow["parse_plan_approval_block"] != wide["parse_plan_approval_block"]:
    print("FAIL narrow vs wide plan-approval box: parsed objects differ\n"
          f"  narrow: {narrow['parse_plan_approval_block']!r}\n"
          f"  wide:   {wide['parse_plan_approval_block']!r}")
    fail = 1
else:
    print("PASS narrow-wrapped and wide plan-approval boxes parse identically")

if fail:
    print("\nRegenerate the fixture (see scripts/tests/fixtures/ generation "
          "note in the plan-approval brief report) before committing.")
    sys.exit(1)
print("\nfixture matches classify_pane.py exactly")
