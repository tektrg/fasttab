#!/usr/bin/env python3
"""Regression test for dashboard-pane-read-regression brief, Bug 1:
`_pane_run_raw`'s callers (`_read_pane_now`, `_send_keys`, `_type_text` in
chief-dashboard-server.py) must hand `herdr_cmd_text` bare subcommand argv
(no leading "herdr" literal) — `herdr_cmd_text`'s local branch prepends the
binary name itself, so a caller-side "herdr" double-prefixes into
`herdr herdr pane read ...`, which real herdr rejects with "unknown command:
herdr" (see the brief's live-dashboard evidence).

Deliberately does NOT fake `_pane_run_raw` itself (that fake would agree with
whichever convention the caller used and could never catch this bug — which
is exactly how the old test suite missed it). Instead this stubs
CHIEF_HERDR_BIN with a real, if fake, subprocess and asserts on the argv it
actually received — same technique as test_chief_dashboard_herdr.py's local
herdr_cmd_json check, one level up the call stack.
"""
import importlib.util
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib"))

_spec = importlib.util.spec_from_file_location(
    "chief_dashboard_server",
    os.path.join(os.path.dirname(__file__), "..", "server", "chief-dashboard-server.py"))
_srv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_srv)

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


PANE_ID = "wB:p3K"


def install_fake_herdr_bin(tmp, name, stdout="fake screen text\n"):
    """A real (if fake) subprocess standing in for `herdr` itself — the argv
    it receives is exactly what herdr_cmd_text's local branch built, so a
    stray leading "herdr" in the caller's argv shows up here as a SECOND
    "herdr" token, not swallowed by a mock that only checks a suffix.
    `name` gives each call its own log file — this fake binary is reused
    across several `_pane_run_raw` calls in this file, and a shared log
    would silently accumulate every prior call's argv too."""
    log_path = os.path.join(tmp, f"argv-{name}.log")
    fake_bin = os.path.join(tmp, f"fake-herdr-{name}")
    with open(fake_bin, "w") as f:
        f.write(
            "#!/bin/sh\n"
            f'echo "$@" >> "{log_path}"\n'
            "case \"$1\" in\n"
            "  pane) : ;;\n"
            "  *) echo \"unknown command: $1\" 1>&2; exit 2 ;;\n"
            "esac\n"
            f'printf %s "{stdout}"\n'
        )
    os.chmod(fake_bin, 0o755)
    return fake_bin, log_path


with tempfile.TemporaryDirectory() as tmp:
    fake_bin, log_path = install_fake_herdr_bin(tmp, "read", stdout="idle prompt\n")
    os.environ["CHIEF_HERDR_BIN"] = fake_bin
    try:
        lines, _q = _srv._read_pane_now(PANE_ID, read_lines=10)
        check("_read_pane_now succeeds against a stubbed real herdr binary "
              "(would fail with 'unknown command: herdr' under Bug 1)",
              lines, ["idle prompt"])
        with open(log_path) as f:
            logged = f.read().split()
        check("argv sent to the herdr binary starts with the real "
              "subcommand, not a second 'herdr' literal",
              logged[0], "pane")
    finally:
        del os.environ["CHIEF_HERDR_BIN"]

    fake_bin, log_path = install_fake_herdr_bin(tmp, "send-keys")
    os.environ["CHIEF_HERDR_BIN"] = fake_bin
    try:
        _srv._send_keys(PANE_ID, "1", machine=_srv.herdr_transport.LOCAL_MACHINE)
        with open(log_path) as f:
            logged = f.read().split()
        check("_send_keys argv starts with 'pane', not 'herdr pane'",
              logged[:2], ["pane", "send-keys"])
    finally:
        del os.environ["CHIEF_HERDR_BIN"]

    fake_bin, log_path = install_fake_herdr_bin(tmp, "run")
    os.environ["CHIEF_HERDR_BIN"] = fake_bin
    try:
        _srv._type_text(PANE_ID, "hello", machine=_srv.herdr_transport.LOCAL_MACHINE)
        with open(log_path) as f:
            logged = f.read().split()
        check("_type_text argv starts with 'pane', not 'herdr pane'",
              logged[:2], ["pane", "run"])
    finally:
        del os.environ["CHIEF_HERDR_BIN"]


print()
if fails:
    print(f"{len(fails)} FAILURES")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("all _pane_run_raw herdr-prefix checks pass")
