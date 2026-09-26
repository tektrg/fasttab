#!/usr/bin/env python3
"""Direct-run tests for the machine-aware herdr transport (chief_dashboard_herdr).

Covers R2 (one wrapper, no bare herdr call left), R3 (transport shape: full
path, non-interactive, ControlMaster options, byte-exact quoting), R19
(machine config validation) and split_pane_key's local/remote/refuse
contract (R1, R6, R18)."""
import json
import os
import stat
import sys
import tempfile

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib"))

import chief_dashboard_herdr as herdr  # noqa: E402

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def check_raises(label, exc_type, fn):
    try:
        fn()
    except exc_type:
        print(f"  PASS  {label}")
        return
    except Exception as e:
        fails.append(f"{label}: raised {type(e).__name__} not {exc_type.__name__}")
        print(f"  FAIL  {label}")
        return
    fails.append(f"{label}: did not raise {exc_type.__name__}")
    print(f"  FAIL  {label}")


# --- validate_machine_name -------------------------------------------------

check_raises("reserved name 'local' rejected", ValueError,
             lambda: herdr.validate_machine_name("local"))
check_raises("uppercase name rejected", ValueError,
             lambda: herdr.validate_machine_name("Air-M1"))
check_raises("herdr pane-id-shaped name 'w2' rejected", ValueError,
             lambda: herdr.validate_machine_name("w2"))
check_raises("herdr pane-id-shaped name 'p_1' rejected", ValueError,
             lambda: herdr.validate_machine_name("p_1"))
try:
    herdr.validate_machine_name("air-m1")
    print("  PASS  valid name 'air-m1' accepted")
except ValueError as e:
    fails.append(f"valid name 'air-m1' wrongly rejected: {e}")
    print("  FAIL  valid name 'air-m1' accepted")


# --- parse_machines_config --------------------------------------------------

good_cfg = json.dumps({
    "air-m1": {"sshAlias": "trungs-air", "herdrPath": "/Users/wifey/.local/bin/herdr",
               "label": "Air"},
})
machines, err = herdr.parse_machines_config(good_cfg)
check("well-formed config: no error", err, None)
check("well-formed config: air-m1 present", "air-m1" in machines, True)
check("well-formed config: sshAlias round-trips", machines["air-m1"]["sshAlias"], "trungs-air")
check("well-formed config: default maxParallel", machines["air-m1"]["maxParallel"], 4)

machines, err = herdr.parse_machines_config("{not json")
check("malformed JSON: machines empty", machines, {})
check("malformed JSON: error is set", err is not None, True)

machines, err = herdr.parse_machines_config(json.dumps(["not", "a", "dict"]))
check("non-object JSON: machines empty", machines, {})
check("non-object JSON: error is set", err is not None, True)

machines, err = herdr.parse_machines_config(json.dumps({"local": {"sshAlias": "x", "herdrPath": "y"}}))
check("reserved name 'local' in file: machines empty", machines, {})
check("reserved name 'local' in file: error is set", err is not None, True)

machines, err = herdr.parse_machines_config(json.dumps({"air-m1": {"herdrPath": "y"}}))
check("missing sshAlias: machines empty", machines, {})
check("missing sshAlias: error is set", err is not None, True)


# --- load_machines_config ----------------------------------------------------

with tempfile.TemporaryDirectory() as tmp:
    machines, err = herdr.load_machines_config(tmp)
    check("missing machines file: empty dict", machines, {})
    check("missing machines file: no error (today's behaviour)", err, None)

    machines, err = herdr.load_machines_config(
        tmp, env={"CHIEF_DASHBOARD_MACHINES": good_cfg})
    check("env override: air-m1 present", "air-m1" in machines, True)


# --- split_pane_key ----------------------------------------------------------

MACHINES = {"air-m1": {"sshAlias": "trungs-air", "herdrPath": "/x/herdr",
                        "label": "Air", "maxParallel": 4}}

check("bare local id unchanged", herdr.split_pane_key("w2:p1", MACHINES),
      ("local", "w2:p1"))
check("bare local id, single segment", herdr.split_pane_key("p_3", MACHINES),
      ("local", "p_3"))
check("explicit local: prefix", herdr.split_pane_key("local:w2:p1", MACHINES),
      ("local", "w2:p1"))
check("namespaced remote id", herdr.split_pane_key("air-m1:w2:pM", MACHINES),
      ("air-m1", "w2:pM"))
check_raises("unconfigured/typo prefix refused, not guessed local",
             herdr.UnknownMachine,
             lambda: herdr.split_pane_key("air-m2:w2:p1", MACHINES))
check_raises("removed-machine prefix refused when config is now empty",
             herdr.UnknownMachine,
             lambda: herdr.split_pane_key("air-m1:w2:p1", {}))

check("make_pane_key local stays bare", herdr.make_pane_key("local", "w2:p1"), "w2:p1")
check("make_pane_key remote is namespaced", herdr.make_pane_key("air-m1", "w2:p1"),
      "air-m1:w2:p1")

# Regression (dashboard-pane-read-regression brief, Bug 2): real local herdr
# ids are alphanumeric, not just digits — confirmed via a live `herdr pane
# list`/`tab list` 2026-09-19 (workspace "wB", pane "wB:p3K", tab "wB:t39").
# The old digit-only _HERDR_ID_SHAPE_RE treated the "wB" colon-prefix as an
# unconfigured machine name and raised UnknownMachine for every one of these.
check("real alphanumeric pane id (wB:p3K) resolves local, not as machine 'wB'",
      herdr.split_pane_key("wB:p3K", MACHINES), ("local", "wB:p3K"))
check("real alphanumeric tab id (w6:t9) resolves local",
      herdr.split_pane_key("w6:t9", MACHINES), ("local", "w6:t9"))
check("real alphanumeric bare workspace/pane id (p_3) resolves local",
      herdr.split_pane_key("p_3", MACHINES), ("local", "p_3"))
check("a real configured machine prefix still routes remote, not local "
      "(the widened id-shape regex must not swallow it)",
      herdr.split_pane_key("air-m1:wB:p3K", MACHINES), ("air-m1", "wB:p3K"))


# --- build_remote_command / build_ssh_argv (pure, no subprocess) -----------

hostile = ["$(rm -rf /)", "`whoami`", "it's", "-leading-dash", "line1\nline2",
           "a;b", "quote\"inside"]
cmd = herdr.build_remote_command("/Users/wifey/.local/bin/herdr",
                                  ["pane", "run", "w2:p1"] + hostile)
import shlex as _shlex  # noqa: E402
round_tripped = _shlex.split(cmd)
check("build_remote_command: round-trips every hostile token exactly",
      round_tripped, ["/Users/wifey/.local/bin/herdr", "pane", "run", "w2:p1"] + hostile)

argv = herdr.build_ssh_argv("ssh", "trungs-air", "/tmp/x/%C",
                             "/Users/wifey/.local/bin/herdr", ["pane", "list"])
check("build_ssh_argv: BatchMode set", "BatchMode=yes" in argv, True)
check("build_ssh_argv: ControlMaster set", "ControlMaster=auto" in argv, True)
check("build_ssh_argv: ControlPersist set", "ControlPersist=600" in argv, True)
check("build_ssh_argv: ControlPath included", any("ControlPath=/tmp/x/%C" == a for a in argv), True)
check("build_ssh_argv: alias present", "trungs-air" in argv, True)
check("build_ssh_argv: last arg is the remote command string",
      argv[-1], herdr.build_remote_command("/Users/wifey/.local/bin/herdr", ["pane", "list"]))


# --- control_path_for: short, private ---------------------------------------

with tempfile.TemporaryDirectory() as tmp:
    base = os.path.join(tmp, "sockdir")
    cp = herdr.control_path_for("trungs-air", base_dir=base)
    check("control_path_for: uses ssh's %C token (short regardless of hostname)",
          cp, os.path.join(base, "%C"))
    mode = stat.S_IMODE(os.stat(base).st_mode)
    check("control_path_for: directory is 0700 (private)", oct(mode), "0o700")

# Regression (measured live against the real Air, 2026-09-19): the DEFAULT
# base_dir (no base_dir passed — what every real call uses) must stay short
# even under macOS's real $TMPDIR, which is a long per-session sandbox path
# (/var/folders/xx/<22-char-token>/T/). Every other test above sidesteps this
# by always passing its own short base_dir, which is exactly why this bug
# shipped: ssh refused with "ControlPath too long" on every real Air call.
_saved_tmpdir = os.environ.get("TMPDIR")
os.environ["TMPDIR"] = "/var/folders/z2/ch3ql1cd4wgd22j94c1r_vww0000gn/T/"
try:
    default_cp = herdr.control_path_for("trungs-air")
    # AF_UNIX sun_path is ~104 bytes on macOS/BSD, 108 on Linux — stay well
    # under the tighter of the two regardless of platform.
    check("control_path_for: default base_dir stays under the sun_path limit "
          "even with a long $TMPDIR",
          len(default_cp) < 100, True)
    check("control_path_for: default base_dir ignores $TMPDIR entirely (uses /tmp)",
          default_cp.startswith("/tmp/"), True)
finally:
    if _saved_tmpdir is None:
        os.environ.pop("TMPDIR", None)
    else:
        os.environ["TMPDIR"] = _saved_tmpdir


# --- herdr_cmd_text / herdr_cmd_json, local path (stubbed bin) --------------

with tempfile.TemporaryDirectory() as tmp:
    fake_herdr = os.path.join(tmp, "fake-herdr")
    with open(fake_herdr, "w") as f:
        f.write("#!/bin/sh\necho '{\"result\": {\"panes\": []}}'\n")
    os.chmod(fake_herdr, 0o755)
    os.environ["CHIEF_HERDR_BIN"] = fake_herdr
    try:
        out = herdr.herdr_cmd_json("local", ["pane", "list"], repo_root=tmp)
        check("local herdr_cmd_json: parses stdout", out, {"result": {"panes": []}})
    finally:
        del os.environ["CHIEF_HERDR_BIN"]

    fake_fail = os.path.join(tmp, "fake-herdr-fail")
    with open(fake_fail, "w") as f:
        f.write("#!/bin/sh\necho 'boom' 1>&2\nexit 3\n")
    os.chmod(fake_fail, 0o755)
    os.environ["CHIEF_HERDR_BIN"] = fake_fail
    try:
        check_raises("local herdr nonzero exit raises HerdrError", herdr.HerdrError,
                     lambda: herdr.herdr_cmd_text("local", ["pane", "list"], repo_root=tmp))
    finally:
        del os.environ["CHIEF_HERDR_BIN"]


# --- herdr_cmd_text, remote path (stubbed ssh) ------------------------------

with tempfile.TemporaryDirectory() as tmp:
    machines = {"air-m1": {"sshAlias": "trungs-air", "herdrPath": "/x/herdr",
                            "label": "Air", "maxParallel": 4}}

    check_raises("unconfigured machine refused before any process starts",
                 herdr.UnknownMachine,
                 lambda: herdr.herdr_cmd_text("air-m9", ["pane", "list"],
                                               repo_root=tmp, machines=machines))

    log_path = os.path.join(tmp, "ssh-argv.log")
    fake_ssh = os.path.join(tmp, "fake-ssh")
    with open(fake_ssh, "w") as f:
        f.write(f'#!/bin/sh\necho "$@" >> "{log_path}"\necho \'{{"ok":true}}\'\n')
    os.chmod(fake_ssh, 0o755)
    os.environ["CHIEF_SSH_BIN"] = fake_ssh
    try:
        out = herdr.herdr_cmd_json("air-m1", ["pane", "list"], repo_root=tmp,
                                    machines=machines)
        check("remote herdr_cmd_json: parses stdout", out, {"ok": True})
        with open(log_path) as f:
            logged = f.read()
        check("remote call used full herdr path, not bare 'herdr'",
              "/x/herdr" in logged, True)
        check("remote call used the configured ssh alias",
              "trungs-air" in logged, True)
        check("remote call used BatchMode (never an interactive prompt)",
              "BatchMode=yes" in logged, True)
    finally:
        del os.environ["CHIEF_SSH_BIN"]

    fake_ssh_255 = os.path.join(tmp, "fake-ssh-255")
    with open(fake_ssh_255, "w") as f:
        f.write("#!/bin/sh\necho 'ssh: connect refused' 1>&2\nexit 255\n")
    os.chmod(fake_ssh_255, 0o755)
    os.environ["CHIEF_SSH_BIN"] = fake_ssh_255
    try:
        check_raises("ssh exit 255 raises SshUnreachable, not a generic error",
                     herdr.SshUnreachable,
                     lambda: herdr.herdr_cmd_text("air-m1", ["pane", "list"],
                                                   repo_root=tmp, machines=machines))
    finally:
        del os.environ["CHIEF_SSH_BIN"]

    fake_ssh_hang = os.path.join(tmp, "fake-ssh-hang")
    with open(fake_ssh_hang, "w") as f:
        f.write("#!/bin/sh\nsleep 30 &\nwait $!\n")
    os.chmod(fake_ssh_hang, 0o755)
    os.environ["CHIEF_SSH_BIN"] = fake_ssh_hang
    try:
        import time as _time
        t0 = _time.time()
        check_raises("hung ssh times out within the given budget (not 30s)",
                     herdr.SshUnreachable,
                     lambda: herdr.herdr_cmd_text("air-m1", ["pane", "list"],
                                                   repo_root=tmp, machines=machines,
                                                   timeout=2))
        elapsed = _time.time() - t0
        check("hung-ssh timeout returned in well under 30s", elapsed < 10, True)
        _time.sleep(0.5)
        import subprocess as _sp
        leftover = _sp.run(["pgrep", "-f", "sleep 30"], capture_output=True, text=True)
        check("hung-ssh timeout leaves no orphan 'sleep 30' process",
              leftover.stdout.strip(), "")
    finally:
        del os.environ["CHIEF_SSH_BIN"]


# --- _cli_main: the bash-facing door nudge-pane.sh routes through -----------
# (Slice 4 / R2 for bash callers: one wrapper, not a second drifting ssh
# implementation in shell.)

import contextlib  # noqa: E402
import io  # noqa: E402


def run_cli(argv, env_extra=None):
    """Run _cli_main in-process (no subprocess) and capture (rc, stdout,
    stderr) — env_extra is applied for the duration of the call only."""
    env_extra = env_extra or {}
    saved = {k: os.environ.get(k) for k in env_extra}
    os.environ.update(env_extra)
    out, err = io.StringIO(), io.StringIO()
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = herdr._cli_main(argv)
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
    return rc, out.getvalue(), err.getvalue()


with tempfile.TemporaryDirectory() as tmp:
    fake_herdr = os.path.join(tmp, "fake-herdr")
    log_path = os.path.join(tmp, "herdr-argv.log")
    with open(fake_herdr, "w") as f:
        f.write(f'#!/bin/sh\necho "$@" >> "{log_path}"\necho \'{{"ok":true}}\'\n')
    os.chmod(fake_herdr, 0o755)

    rc, out, err = run_cli(
        ["w2:p1", "pane", "get", "w2:p1"],
        {"CHIEF_HERDR_BIN": fake_herdr, "CHIEF_REPO_ROOT": tmp,
         "CHIEF_DASHBOARD_MACHINES": "{}"})
    check("CLI local pane: exit 0", rc, 0)
    check("CLI local pane: prints herdr's stdout", out, '{"ok":true}\n')
    with open(log_path) as f:
        logged_local = f.read()
    check("CLI local pane: raw id passed through unchanged", "w2:p1" in logged_local, True)

    fake_ssh = os.path.join(tmp, "fake-ssh")
    ssh_log = os.path.join(tmp, "ssh-argv.log")
    with open(fake_ssh, "w") as f:
        f.write(f'#!/bin/sh\necho "$@" >> "{ssh_log}"\necho \'{{"ok":true}}\'\n')
    os.chmod(fake_ssh, 0o755)
    remote_cfg = json.dumps({"air-m1": {"sshAlias": "trungs-air",
                                         "herdrPath": "/x/herdr", "label": "Air"}})
    rc, out, err = run_cli(
        ["air-m1:w2:pM", "pane", "get", "air-m1:w2:pM"],
        {"CHIEF_SSH_BIN": fake_ssh, "CHIEF_REPO_ROOT": tmp,
         "CHIEF_DASHBOARD_MACHINES": remote_cfg})
    check("CLI remote pane: exit 0", rc, 0)
    with open(ssh_log) as f:
        logged_remote = f.read()
    check("CLI remote pane: pane_key rewritten to its RAW id on the wire",
          "w2:pM" in logged_remote and "air-m1:w2:pM" not in logged_remote, True)
    check("CLI remote pane: routed over the configured ssh alias",
          "trungs-air" in logged_remote, True)

    rc, out, err = run_cli(
        ["air-m9:w2:p1", "pane", "get", "air-m9:w2:p1"],
        {"CHIEF_REPO_ROOT": tmp, "CHIEF_DASHBOARD_MACHINES": remote_cfg})
    check("CLI unknown machine prefix: exit 3 (bad target, not silently local)",
          rc, herdr.CLI_UNKNOWN_MACHINE_EXIT)
    check("CLI unknown machine prefix: says why on stderr", "air-m9" in err, True)

    fake_ssh_255 = os.path.join(tmp, "fake-ssh-255")
    with open(fake_ssh_255, "w") as f:
        f.write("#!/bin/sh\necho 'ssh: connect refused' 1>&2\nexit 255\n")
    os.chmod(fake_ssh_255, 0o755)
    rc, out, err = run_cli(
        ["air-m1:w2:pM", "pane", "get", "air-m1:w2:pM"],
        {"CHIEF_SSH_BIN": fake_ssh_255, "CHIEF_REPO_ROOT": tmp,
         "CHIEF_DASHBOARD_MACHINES": remote_cfg})
    check("CLI ssh unreachable: exit 4, distinct from unknown-machine and generic error",
          rc, herdr.CLI_SSH_UNREACHABLE_EXIT)

    rc, out, err = run_cli(["only-one-arg"])
    check("CLI usage error (missing herdr argv): exit 2", rc, 2)


print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("All chief-dashboard herdr transport checks passed.")
