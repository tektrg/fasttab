#!/usr/bin/env python3
"""Regression test: GET /api/pane/screen (`handle_pane_screen` in
chief-dashboard-server.py) must resolve a machine-namespaced paneId via
`herdr_transport.split_pane_key` before reading the pane — same pattern as
every other handler in this file (`focus_pane`, `_handle_reach_action`,
`handle_session_action`, `_resolve_stopped_pane`, `answer_pane_question`,
`answer_pane_permission`).

THE BUG (red, before this file's fix)
--------------------------------------
`handle_pane_screen` passed the raw query-string `paneId` straight into
`_read_pane_now(pane_id, read_lines=read_lines)` with no split and no
`machine=` — `_read_pane_now` defaults `machine=LOCAL_MACHINE`, so a
namespaced id like "air-m1:w2:p1" was handed WHOLE to LOCAL herdr instead of
being split into ("air-m1", "w2:p1") and routed to the Air. This produced a
false "agent=claude, alternate_screen=no" refusal reading some unrelated (or
nonexistent) LOCAL pane instead of the real remote one.

Deliberately fakes `herdr_transport.herdr_cmd_text` (the one door, R2/R3)
rather than `_read_pane_now` or `_pane_run_raw` itself — a fake at either of
those levels would agree with whichever routing the caller used and could
never catch a missing split, exactly like test_pane_liveness_remote.py's own
rationale.
"""
import importlib.util
import os
import sys

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib"))

MACHINES_JSON = (
    '{"air-m1": {"sshAlias": "trungs-air", "herdrPath": "/x/herdr", '
    '"label": "Air", "maxParallel": 4}}'
)
os.environ["CHIEF_DASHBOARD_MACHINES"] = MACHINES_JSON

_spec = importlib.util.spec_from_file_location(
    "chief_dashboard_server_pane_screen_test",
    os.path.join(os.path.dirname(__file__), "..", "server", "chief-dashboard-server.py"))
_srv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_srv)

del os.environ["CHIEF_DASHBOARD_MACHINES"]

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


print("== handle_pane_screen routes a namespaced paneId to the configured "
      "remote machine, not local ==")
calls = []


def fake_cmd_text(machine, argv, **kwargs):
    calls.append((machine, list(argv)))
    return "some remote screen text\n"


_orig = _srv.herdr_transport.herdr_cmd_text
_srv.herdr_transport.herdr_cmd_text = fake_cmd_text
try:
    payload, status = _srv.handle_pane_screen(
        {"paneId": ["air-m1:w2:p1"], "lines": ["10"]})
finally:
    _srv.herdr_transport.herdr_cmd_text = _orig

check("HTTP status 200", status, 200)
check("ok True", payload.get("ok"), True)
check("response paneId stays the ORIGINAL namespaced id (dashboard UI keys "
      "off this)", payload.get("paneId"), "air-m1:w2:p1")
check("exactly one herdr transport call made", len(calls), 1)
check("routed to the configured REMOTE machine, not 'local'",
      calls[0][0] if calls else None, "air-m1")
check("the RAW (un-namespaced) pane id crosses the wire, not the full key",
      calls[0][1][2] if calls and len(calls[0][1]) > 2 else None, "w2:p1")

print("\n== an unconfigured/typo machine prefix refuses cleanly (never "
      "silently reads local) ==")
calls = []
_srv.herdr_transport.herdr_cmd_text = fake_cmd_text
try:
    payload, status = _srv.handle_pane_screen(
        {"paneId": ["air-m9:w2:p1"], "lines": ["10"]})
finally:
    _srv.herdr_transport.herdr_cmd_text = _orig
check("no herdr call made for an unknown machine prefix", len(calls), 0)
check("ok False", payload.get("ok"), False)
check("response paneId still the original string",
      payload.get("paneId"), "air-m9:w2:p1")

print("\n== a bare local paneId is byte-for-byte unaffected ==")
calls = []
_srv.herdr_transport.herdr_cmd_text = fake_cmd_text
try:
    payload, status = _srv.handle_pane_screen(
        {"paneId": ["w1:p1"], "lines": ["10"]})
finally:
    _srv.herdr_transport.herdr_cmd_text = _orig
check("ok True", payload.get("ok"), True)
check("routed to local", calls[0][0] if calls else None, "local")
check("raw id unchanged for a local pane",
      calls[0][1][2] if calls and len(calls[0][1]) > 2 else None, "w1:p1")

print()
if fails:
    print(f"{len(fails)} FAILURES")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("all handle_pane_screen remote-routing checks pass")
