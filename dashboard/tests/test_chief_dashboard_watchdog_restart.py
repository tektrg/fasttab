#!/usr/bin/env python3
"""Watchdog tests, part 3/3: the restart-execution layer — the code that
actually touches the machine (`herdr_bin`, `restart_in_pane`,
`kill_stale_server`, `wait_for_dashboard`, `restart_dashboard`) — plus the
state store's degraded-import fallback (F6). Pointed at a port and a pane
that cannot exist, with the three seams that reach out
(`port_owner_pids`, `pid_command`, `signal_pid`) stubbed, so nothing here
can signal a real pid or type into a real pane. The live board (whatever
port this Mac's production instance uses) is never addressed here.

Ported from AptusFit's `scripts/tests/test_chief_dashboard_watchdog.py`
against this checkout's `scripts/chief-dashboard-watchdog.py` — the P0 move
made `SERVER_SCRIPT` an absolute path (the server moved from `scripts/` to
`server/`) instead of a `REPO_ROOT`-relative one; every assertion below
reads `wd.SERVER_SCRIPT` back from the module rather than hard-coding it,
so that move needed no test changes. See test_chief_dashboard_watchdog_state
.py's docstring for the full list of what was dropped from the original
(the `chief-tick-gate.py` gate section — not part of this move).
"""
import os
import re
import signal
import sys
import tempfile

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))

import importlib.util  # noqa: E402

SCRIPTS = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts")


def _load(module_name, filename):
    spec = importlib.util.spec_from_file_location(
        module_name, os.path.join(SCRIPTS, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


wd = _load("chief_dashboard_watchdog_restart_test", "chief-dashboard-watchdog.py")

fails = []


def check(label, got, want=True):
    ok = (got == want) if want is not True else bool(got)
    if not ok:
        fails.append(f"{label}: got {got!r}" + (f" want {want!r}" if want is not True else ""))
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def live_probe():
    return lambda timeout=None: (True, "")


def dead_probe(reason="no answer (timed out)"):
    return lambda timeout=None: (False, reason)


def reset_state():
    try:
        os.unlink(wd.FAILURE_FILE)
    except OSError:
        pass


tmpdir = tempfile.mkdtemp(prefix="chief-dashboard-watchdog-restart-test-")
wd.FAILURE_FILE = os.path.join(tmpdir, ".chief-dashboard-failure.json")
wd.DASHBOARD_PORT = 47110
wd.DASHBOARD_PANE = "test:pane-that-does-not-exist"
logged = []
wd.log = lambda message: logged.append(message)

print("== herdr_bin: a PATH regression must not silently disarm restarts ==")
saved_herdr_bin_env = os.environ.pop("HERDR_BIN", None)
real_which = wd.which
wd.which = lambda name: None
check("with herdr off PATH, the literal ~/.local/bin fallback is used",
      wd.herdr_bin(), os.path.expanduser("~/.local/bin/herdr"))
wd.which = lambda name: "/opt/somewhere/herdr"
check("with herdr on PATH, PATH wins", wd.herdr_bin(), "/opt/somewhere/herdr")
os.environ["HERDR_BIN"] = "/explicit/herdr"
check("an explicit HERDR_BIN beats both", wd.herdr_bin(), "/explicit/herdr")
del os.environ["HERDR_BIN"]
if saved_herdr_bin_env is not None:
    os.environ["HERDR_BIN"] = saved_herdr_bin_env
wd.which = real_which

print("== restart_in_pane: ONE command, and never a blind Enter (F2) ==")
commands = []
real_run = wd._run
wd._run = lambda argv, timeout=15: (commands.append(argv) or True)
wd.which = lambda name: "/usr/bin/herdr"
check("the pane restart succeeds when herdr accepts the command",
      wd.restart_in_pane(), True)
check("it issues exactly ONE herdr command", len(commands), 1)
check("...and it is `pane run`, carrying the server command",
      commands[0][1:3] + [commands[0][4]],
      ["pane", "run", f"python3 {wd.SERVER_SCRIPT}"])
check("no send-keys is ever sent — a blind Enter lands wherever the cursor is",
      any("send-keys" in argv for argv in commands), False)
check("...and it targets the configured pane, not a hard-coded one",
      commands[0][3], wd.DASHBOARD_PANE)

commands.clear()
wd._run = lambda argv, timeout=15: (commands.append(argv) or False)
check("a pane that will not take the command reports failure",
      wd.restart_in_pane(), False)
check("...after trying exactly once", len(commands), 1)
wd.which = real_which

print("== kill_stale_server: the PORT's owner, and only it (F5) ==")
signalled = []
owners = []
real_command_output = wd._command_output
real_owner_pids, real_pid_command, real_signal_pid = (
    wd.port_owner_pids, wd.pid_command, wd.signal_pid)
real_port_is_held = wd.port_is_held
wd.signal_pid = lambda pid, sig=signal.SIGTERM: (signalled.append((pid, sig)) or True)
wd.port_owner_pids = lambda port=None: list(owners)
wd.pid_command = lambda pid: {
    19581: f"python3 {wd.SERVER_SCRIPT}",
    12345: f"python3 {wd.SERVER_SCRIPT} --port 47110",
    777: "/usr/bin/some-unrelated-listener --serve",
}.get(pid, "")

owners = []
wd.port_is_held = lambda port=None, timeout=1.0: False
wd.kill_stale_server()
check("a free port is not killed at all", signalled, [])

owners = [12345]
holds = [True, True, False]
polls = []
wd.port_is_held = lambda port=None, timeout=1.0: (
    polls.append(1) or (holds.pop(0) if holds else False))
logged.clear()
wd.kill_stale_server()
check("the pid holding the target port is signalled", [p for p, _ in signalled], [12345])
check("...with SIGTERM", signalled[0][1], signal.SIGTERM)
check("it WAITS for the port to be released before returning", len(polls) >= 2, True)
check("...and does not complain about a port that did let go",
      any("still held" in m for m in logged), False)

signalled.clear()
owners = [777]
logged.clear()
wd.port_is_held = lambda port=None, timeout=1.0: True
wd.kill_stale_server()
check("a listener that is NOT this server is left alone", signalled, [])
check("...and the refusal is logged, not silent",
      any("refusing to kill" in m for m in logged), True)

signalled.clear()
owners = [12345, 777]
logged.clear()
holds = [False]
wd.port_is_held = lambda port=None, timeout=1.0: (holds.pop(0) if holds else False)
wd.kill_stale_server()
check("with a stranger sharing the port, only our pid is signalled",
      [p for p, _ in signalled], [12345])

signalled.clear()
owners = [12345]
logged.clear()
wd.port_is_held = lambda port=None, timeout=1.0: True
wd.PORT_RELEASE_TIMEOUT_SECONDS, saved_release = 1, wd.PORT_RELEASE_TIMEOUT_SECONDS
wd.kill_stale_server()
check("a port that never releases is reported, not silently relaunched over",
      any("still held" in m for m in logged), True)
wd.PORT_RELEASE_TIMEOUT_SECONDS = saved_release

print("== wait_for_dashboard: judged on the HTTP answer, not a rc (F3) or a "
      "socket (D4) ==")
wd.port_is_held = lambda port=None, timeout=1.0: True
wd.probe = live_probe()
check("the dashboard answering /api/state is a restart that took",
      wd.wait_for_dashboard(0.2), True)
wd.probe = lambda timeout=None: (False, "unparseable body from /api/state "
                                        "(not JSON)")
check("a socket held by something that is NOT the dashboard is a restart that "
      "did NOT take", wd.wait_for_dashboard(0.2), False)
wd.probe = lambda timeout=None: (False, "HTTP 404 from /api/state")
check("...and so is a listener answering non-200", wd.wait_for_dashboard(0.2),
      False)
wd.probe = dead_probe()
check("nothing answering within the budget is a restart that did NOT take",
      wd.wait_for_dashboard(0.2), False)
answers = [(False, "dead"), (False, "dead"), (True, "")]
wd.probe = lambda timeout=None: (answers.pop(0) if answers else (True, ""))
check("a dashboard that answers a moment later still counts",
      wd.wait_for_dashboard(5), True)
logged.clear()


def _raise(timeout=None):
    raise RuntimeError("something this file never anticipated")


wd.probe = _raise
check("a verification read that RAISES is not a confirmed restart",
      wd.wait_for_dashboard(0.2), False)
check("...and it says so in the log rather than swallowing the exception",
      any("verification read raised" in m for m in logged), True)

print("== restart_dashboard: pane first, and the fallback can actually fire (F3) ==")
detached_launched = []
real_kill, real_restart_in_pane, real_restart_detached, real_wait = (
    wd.kill_stale_server, wd.restart_in_pane, wd.restart_detached,
    wd.wait_for_dashboard)
wd.kill_stale_server = lambda: None
wd.restart_detached = lambda: (detached_launched.append(1) or True)

wd.restart_in_pane = lambda: True
wd.wait_for_dashboard = lambda timeout=None: True
check("pane restart + a listener = restarted via the pane",
      wd.restart_dashboard(), "pane")
check("...and the fallback is NOT launched (the PO keeps their window)",
      len(detached_launched), 0)

detached_launched.clear()
logged.clear()
listener_answers = [False, True]   # no listener after the pane, one after the fallback
wd.wait_for_dashboard = lambda timeout=None: (
    listener_answers.pop(0) if listener_answers else True)
check("pane rc=0 but NO listener falls through to the fallback",
      wd.restart_dashboard(), "detached")
check("...and the fallback really was launched", len(detached_launched), 1)
check("...and the log says the pane took the command without producing a board",
      any("accepted the command" in m for m in logged), True)

detached_launched.clear()
wd.restart_in_pane = lambda: False
wd.wait_for_dashboard = lambda timeout=None: True
check("an unreachable pane falls back to detached", wd.restart_dashboard(), "detached")
check("...launching it once", len(detached_launched), 1)

wd.restart_detached = lambda: False
check("no pane and no fallback is an honest `failed`", wd.restart_dashboard(), "failed")

detached_launched.clear()
wd.restart_detached = lambda: (detached_launched.append(1) or True)
wd.wait_for_dashboard = lambda timeout=None: False
check("a fallback that launches but produces no listener is `failed`, not "
      "`detached`", wd.restart_dashboard(), "failed")

(wd.kill_stale_server, wd.restart_in_pane, wd.restart_detached,
 wd.wait_for_dashboard) = (real_kill, real_restart_in_pane,
                          real_restart_detached, real_wait)
(wd.port_owner_pids, wd.pid_command, wd.signal_pid, wd.port_is_held) = (
    real_owner_pids, real_pid_command, real_signal_pid, real_port_is_held)
wd._run, wd._command_output = real_run, real_command_output
reset_state()


print("== the state store survives a moved plugin path (F6) ==")
# A module-level `from delivery_ops import filelock` made a moved plugin path
# FATAL at import: no probe, no streak, no alarm. This file takes the same
# degrade-don't-crash stance for itself.
check("normally the real, LOCKED delivery_ops.filelock is used",
      wd.STATE_STORE_IS_LOCKED, True)


def import_watchdog_with_the_plugin_gone():
    """Import the watchdog FROM SOURCE with its plugin path pointing at nothing
    and `delivery_ops` unimportable — the exact shape of a moved plugin dir.
    -> (module, exception). A bare module-level import raises right here, and
    that raise is the whole finding: the probe never runs at all."""
    source = open(os.path.join(SCRIPTS, "chief-dashboard-watchdog.py")).read()
    source, swapped = re.subn(
        r'PLUGIN_SCRIPTS = os\.path\.expanduser\(\s*"[^"]+"\)',
        'PLUGIN_SCRIPTS = "/nonexistent/delivery-ops/scripts"',
        source, count=1)
    assert swapped == 1, "PLUGIN_SCRIPTS is no longer the expected expanduser() call"
    saved_path = list(sys.path)
    saved_modules = {name: module for name, module in sys.modules.items()
                     if name.split(".")[0] == "delivery_ops"}
    for name in saved_modules:
        del sys.modules[name]
    sys.path[:] = [p for p in sys.path if "delivery-ops" not in p]
    sandbox = importlib.util.module_from_spec(
        importlib.util.spec_from_loader("chief_dashboard_watchdog_no_plugin", loader=None))
    real_script_path = os.path.join(SCRIPTS, "chief-dashboard-watchdog.py")
    # This copy's module-level code resolves its own paths from `__file__`
    # (P0 move: `SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))`,
    # replacing AptusFit's literal `REPO_ROOT` string) — a bare `exec()` has
    # no `__file__` in its globals, so it must be seeded here or the sandbox
    # fails on a NameError that has nothing to do with the plugin-path finding
    # this test is actually about.
    sandbox.__dict__["__file__"] = real_script_path
    try:
        exec(compile(source, real_script_path, "exec"), sandbox.__dict__)
        return sandbox, None
    except Exception as exc:
        return None, exc
    finally:
        sys.path[:] = saved_path
        sys.modules.update(saved_modules)


degraded, import_error = import_watchdog_with_the_plugin_gone()
check("a moved plugin path does NOT kill the watchdog at import",
      import_error, None)
check("...it degrades to the unlocked state store instead",
      degraded is not None and degraded.STATE_STORE_IS_LOCKED, False)

degraded_store = degraded.STATE_STORE if degraded else wd._UnlockedJsonStore()
fallback_file = os.path.join(tmpdir, "fallback-store.json")
check("the unlocked stand-in reads a missing file as empty",
      degraded_store.read_json(fallback_file, {}), {})
degraded_store.update_json(fallback_file, lambda current: {"count": 1})
check("the unlocked stand-in writes",
      degraded_store.read_json(fallback_file)["count"], 1)
check("...and read-modify-writes",
      degraded_store.update_json(
          fallback_file,
          lambda current: {"count": current["count"] + 1})["count"], 2)
check("...atomically, leaving no .tmp file behind",
      [f for f in os.listdir(tmpdir) if ".tmp" in f], [])

if degraded:
    degraded.FAILURE_FILE = os.path.join(tmpdir, "degraded-streak.json")
    degraded.log = lambda message: None
    check("a watchdog running on the fallback store still records a streak",
          degraded.record_failure("dead", restarted=False).get("count"), 1)
    check("...and still ends it on a good probe",
          degraded.clear_failure().get("count"), None)
reset_state()

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("All watchdog restart-execution checks passed.")
