#!/usr/bin/env python3
"""Direct-run test: the server serves the React build from dashboard/ui/dist.

After the move, UI_DIST still pointed at the AptusFit layout
(server/chief-dashboard-ui/dist), which does not exist here, so / silently
fell back to the legacy page and the React board never showed (caught live
2026-09-25). Same importlib technique as test_answer_pane_question.py; no
port, no pane.
"""
import importlib.util
import os
import sys

DASHBOARD_HOME = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(DASHBOARD_HOME, "server", "lib"))

_spec = importlib.util.spec_from_file_location(
    "chief_dashboard_server",
    os.path.join(DASHBOARD_HOME, "server", "chief-dashboard-server.py"))
_srv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_srv)

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


check("UI_DIST is dashboard/ui/dist",
      os.path.realpath(_srv.Handler.UI_DIST),
      os.path.realpath(os.path.join(DASHBOARD_HOME, "ui", "dist")))
check("UI_DIST's parent is the UI source folder (has package.json)",
      os.path.exists(os.path.join(os.path.dirname(_srv.Handler.UI_DIST), "package.json")),
      True)

if fails:
    print(f"\nFAILED ({len(fails)}):")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("\nall passed")
