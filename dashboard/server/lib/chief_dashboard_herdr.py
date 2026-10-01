#!/usr/bin/env python3
"""One door for every herdr call, local or remote — see the delivery record
for the full rationale (memory/Projects/deliver-chief-dashboard-remote-herdr-workers/delivery.md,
rule R2/R3).

No other module should shell out to `herdr` or `ssh` directly. Every caller
resolves a pane key through split_pane_key(), then calls herdr_cmd_json() /
herdr_cmd_text() with the resolved machine name — so a bug can never send an
Air action to a same-numbered local pane, and a missing wrapper call fails
loudly (grep guard in scripts/tests/test_chief_dashboard_herdr.py) instead of
silently hitting local herdr with a remote id.

Local calls are byte-identical to what every caller did before this module
existed: `herdr <argv...>` via subprocess, no ssh, no config read on the hot
path. Remote calls reuse one ssh ControlMaster connection per machine and
shell-quote every argument so text lands on the Air literally, never
interpreted by the Air's login shell.
"""
import json
import os
import re
import shlex
import subprocess
import sys
import time

LOCAL_MACHINE = "local"
RESERVED_MACHINE_NAMES = {"local"}

# Config-load-time names that would be indistinguishable from herdr's own id
# shapes (w2, p_1, t3, w2:p1) — accepting one of these as a machine name would
# make split_pane_key's prefix test ambiguous with a bare local id.
_MACHINE_NAME_RE = re.compile(r"^[a-z][a-z0-9-]+$")
# Real local herdr ids are alphanumeric (e.g. "wB", "p3K", "t1H"), not just
# digits — verified against a live `herdr pane list`/`tab list` 2026-09-19,
# not guessed. A hyphenated machine name (e.g. "air-m1") never matches this.
# TRAP for future machine configs: a single-word, non-hyphenated name
# starting with w/p/t (e.g. "worker", "prod") WILL match this and get
# rejected by validate_machine_name below — and parse_machines_config fails
# closed for the WHOLE file on one bad name, so adding such a name would
# silently drop every configured remote machine back to local-only. Keep
# new machine names hyphenated (the existing "air-m1" convention) to avoid
# this entirely.
_HERDR_ID_SHAPE_RE = re.compile(r"^(w[0-9A-Za-z]+|p_?[0-9A-Za-z]+|t[0-9A-Za-z]+)$")

_ENV_MACHINES = "CHIEF_DASHBOARD_MACHINES"
_ENV_SSH_BIN = "CHIEF_SSH_BIN"
_ENV_HERDR_BIN = "CHIEF_HERDR_BIN"
_MACHINES_FILE_RELPATH = os.path.join(".claude", "dashboard-machines.json")


class HerdrError(RuntimeError):
    """Base for every herdr_cmd failure. Callers catch this, never a raw
    subprocess exception, so a new failure mode can't leak past a poll loop."""


class SshUnreachable(HerdrError):
    """ssh itself failed (refused, timed out, exit 255) — the MACHINE is the
    problem, never read as "the pane is gone"."""


class UnknownMachine(HerdrError):
    """A pane key or action named a machine that isn't configured, is
    reserved, or isn't a valid machine name."""


# --------------------------------------------------------------------------
# Machine name / config validation — pure, no I/O.
# --------------------------------------------------------------------------

def validate_machine_name(name):
    """Raise ValueError if `name` cannot be a configured machine name.
    Applied at config load time so an invalid name is rejected once, up
    front, rather than causing an ambiguous split_pane_key() later."""
    if name in RESERVED_MACHINE_NAMES:
        raise ValueError(f"machine name {name!r} is reserved")
    if not _MACHINE_NAME_RE.match(name):
        raise ValueError(
            f"machine name {name!r} must match {_MACHINE_NAME_RE.pattern}")
    if _HERDR_ID_SHAPE_RE.match(name):
        raise ValueError(
            f"machine name {name!r} looks like a herdr pane/tab/workspace id "
            "and would make pane-key parsing ambiguous")


def parse_machines_config(raw_text):
    """Parse machines-config JSON text into (machines_dict, error).

    Pure function: no file I/O, no env read, so it's directly testable with
    hostile input. On success, error is None and machines_dict maps
    validated machine name -> {sshAlias, herdrPath, label, maxParallel}.
    On any problem (bad JSON, wrong shape, invalid/reserved/duplicate name)
    error is a human-readable string and machines_dict is {} — callers boot
    local-only rather than crash or half-apply a broken file."""
    try:
        raw = json.loads(raw_text)
    except json.JSONDecodeError as e:
        return {}, f"invalid JSON: {e}"
    if not isinstance(raw, dict):
        return {}, f"expected a JSON object of machine name -> config, got {type(raw).__name__}"

    machines = {}
    for name, cfg in raw.items():
        try:
            validate_machine_name(name)
        except ValueError as e:
            return {}, str(e)
        if not isinstance(cfg, dict):
            return {}, f"machine {name!r}: config must be an object"
        ssh_alias = cfg.get("sshAlias")
        herdr_path = cfg.get("herdrPath")
        if not ssh_alias or not isinstance(ssh_alias, str):
            return {}, f"machine {name!r}: missing/invalid sshAlias"
        if not herdr_path or not isinstance(herdr_path, str):
            return {}, f"machine {name!r}: missing/invalid herdrPath"
        repo_root = cfg.get("repoRoot")
        if repo_root is not None and not isinstance(repo_root, str):
            return {}, f"machine {name!r}: repoRoot must be a string"
        machines[name] = {
            "sshAlias": ssh_alias,
            "herdrPath": herdr_path,
            "label": cfg.get("label") or name,
            "maxParallel": int(cfg.get("maxParallel") or 4),
            # Optional: the machine's checkout root, mirroring this repo's
            # layout — only needed by --copy-file (nudge-pane.sh --file) to
            # compute where a local path lands over there. None when absent;
            # every other consumer of this dict already tolerates unknown
            # keys (dict.get with a default), so this is additive-only.
            "repoRoot": repo_root,
        }
    return machines, None


def load_machines_config(repo_root, env=None):
    """Return (machines_dict, error). CHIEF_DASHBOARD_MACHINES (JSON text,
    for tests) takes priority over the tracked file. A missing file is
    today's exact behaviour: {} and no error, no ssh ever attempted."""
    env = os.environ if env is None else env
    raw_text = env.get(_ENV_MACHINES)
    if raw_text is not None:
        return parse_machines_config(raw_text)
    path = os.path.join(repo_root, _MACHINES_FILE_RELPATH)
    if not os.path.exists(path):
        return {}, None
    try:
        with open(path, "r") as f:
            raw_text = f.read()
    except OSError as e:
        return {}, f"could not read {path}: {e}"
    return parse_machines_config(raw_text)


# --------------------------------------------------------------------------
# Pane-key parsing — pure.
# --------------------------------------------------------------------------

def split_pane_key(pane_key, machines):
    """Resolve a pane key to (machine_name, raw_pane_id).

    `machines` is the dict returned by load_machines_config (or {}).
    A prefix before the first ':' is:
      - "local"            -> explicit local (today's ids never write this,
                               but it round-trips make_pane_key).
      - a key in `machines` -> that remote machine.
      - herdr's own id shape (w2, p_1, t3, ...) -> not a machine prefix at
        all, just the bare LOCAL id unchanged (today's format). This is what
        keeps every stored last_pane, work-item pane match, nudge caller and
        saved SPA state resolving exactly as before this change (R18).
      - anything else (a typo, or a machine removed from config) -> REFUSED
        as UnknownMachine, never silently guessed as local (R19/QA-B3:
        an orphaned or misspelled machine prefix must not act on a
        same-numbered local pane)."""
    if ":" in pane_key:
        prefix, rest = pane_key.split(":", 1)
        if prefix == LOCAL_MACHINE:
            return LOCAL_MACHINE, rest
        if prefix in machines:
            return prefix, rest
        if _HERDR_ID_SHAPE_RE.match(prefix):
            return LOCAL_MACHINE, pane_key
        raise UnknownMachine(
            f"pane key {pane_key!r} names machine {prefix!r}, which is not "
            "configured")
    return LOCAL_MACHINE, pane_key


def make_pane_key(machine, raw_pane_id):
    """Inverse of split_pane_key for LOCAL rows: local ids stay bare so
    existing consumers are untouched; remote ids get the namespaced form."""
    if machine == LOCAL_MACHINE:
        return raw_pane_id
    return f"{machine}:{raw_pane_id}"


# --------------------------------------------------------------------------
# Remote command construction — pure (no subprocess), so hostile-text
# round-tripping is unit-testable without a network call.
# --------------------------------------------------------------------------

def build_remote_command(herdr_path, argv):
    """Build the single command STRING ssh sends to the remote login shell.

    OpenSSH joins every argument after the host into one string and hands it
    to the remote user's shell — it does not execve remote args directly. So
    each argument is shell-quoted here (shlex.quote) before joining; a
    remote shell then sees each token as one opaque, literal word, and
    metacharacters ($, `, ;, newline, leading '-') in pane text can never be
    interpreted as a shell command (E8)."""
    return " ".join(shlex.quote(part) for part in [herdr_path] + list(argv))


def build_ssh_argv(ssh_bin, ssh_alias, control_path, herdr_path, argv,
                    connect_timeout=5):
    """Build the full ssh argv for one herdr call. Pure — takes every
    variable as an argument so tests can assert on the exact list without
    running ssh."""
    return [
        ssh_bin,
        "-o", "BatchMode=yes",
        "-o", f"ConnectTimeout={connect_timeout}",
        "-o", "ControlMaster=auto",
        "-o", "ControlPersist=600",
        "-o", f"ControlPath={control_path}",
        "-o", "ServerAliveInterval=5",
        ssh_alias,
        build_remote_command(herdr_path, argv),
    ]


def control_path_for(ssh_alias, base_dir=None):
    """One ControlPath per ssh alias, in a private per-uid directory kept
    short via ssh's own %C token (QA-B10: total path must stay well under
    the ~104-byte AF_UNIX sun_path limit regardless of hostname length).

    Deliberately `/tmp`, never `tempfile.gettempdir()`: measured live against
    the real Air (2026-09-19), gettempdir() resolves $TMPDIR, which on macOS
    is a long per-session sandbox path (/var/folders/xx/<22-char-token>/T/) —
    that alone plus this directory name plus the %C token's 40-char SHA1
    already exceeds 104 bytes, so EVERY remote call failed
    ('ControlPath too long') no matter how short the alias or hostname was.
    No unit test caught this because control_path_for's own tests always
    pass an explicit short base_dir. /tmp is short on every machine this
    runs on and is the standard place for ssh control sockets for exactly
    this reason."""
    base_dir = base_dir or os.path.join(
        "/tmp", f"chief-dashboard-ssh-{os.getuid()}")
    os.makedirs(base_dir, exist_ok=True, mode=0o700)
    os.chmod(base_dir, 0o700)
    return os.path.join(base_dir, "%C")


# --------------------------------------------------------------------------
# Subprocess execution — the only impure part. Kills the whole process group
# on timeout so a backgrounded grandchild (e.g. `sleep 30 &` inside a remote
# shell, or a hung ssh child) can never outlive the call (R8/QA-A3: the
# original run_json() timeout raised on time but left an orphan running).
# --------------------------------------------------------------------------

def _run(argv, cwd, timeout):
    proc = subprocess.Popen(
        argv, cwd=cwd, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, start_new_session=True,
    )
    try:
        stdout, stderr = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        _kill_process_group(proc)
        try:
            proc.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        raise
    return proc.returncode, stdout, stderr


def _kill_process_group(proc):
    try:
        pgid = os.getpgid(proc.pid)
        os.killpg(pgid, 9)
    except (ProcessLookupError, PermissionError, OSError):
        proc.kill()


def herdr_cmd_text(machine, argv, *, repo_root, machines=None, timeout=15,
                    cwd=None):
    """Run one herdr call and return its raw stdout text.

    machine == "local" (or machines is empty/machine absent): bare
    `herdr <argv>`, byte-identical to every call site before this module —
    no ssh, no config read.
    Any other machine: must be present in `machines` (load_machines_config's
    result) or UnknownMachine is raised before any process starts. Runs over
    a reused ssh ControlMaster to that machine's configured full herdr path.
    """
    machines = machines or {}
    if machine == LOCAL_MACHINE:
        herdr_bin = os.environ.get(_ENV_HERDR_BIN, "herdr")
        full_argv = [herdr_bin] + list(argv)
        try:
            rc, out, err = _run(full_argv, cwd or repo_root, timeout)
        except subprocess.TimeoutExpired:
            raise HerdrError(f"local herdr timed out after {timeout}s: {argv}")
        if rc != 0:
            raise HerdrError(f"local herdr {argv} exited {rc}: {err.strip()[:500]}")
        return out

    cfg = machines.get(machine)
    if cfg is None:
        raise UnknownMachine(f"machine {machine!r} is not configured")
    return _run_over_ssh(machine, cfg, cfg["herdrPath"], argv,
                         cwd=cwd or repo_root, timeout=timeout, what="herdr")


def remote_shell_text(machine, script, *, repo_root, machines=None,
                      timeout=120, args=()):
    """Run one non-herdr shell script on a REMOTE machine (e.g. the harness's
    own `scripts/session-worktree.sh new` in that machine's repoRoot) over the
    same ControlMaster + quoting as herdr_cmd_text, instead of a caller
    growing its own bare ssh. The script runs under /bin/bash -c with the
    remote's bare non-interactive PATH, so call node/bun/herdr by full path.
    Local machines are refused: this door exists only for remote work."""
    machines = machines or {}
    cfg = machines.get(machine)
    if machine == LOCAL_MACHINE or cfg is None:
        raise UnknownMachine(f"machine {machine!r} is not a configured remote")
    # `args` reach the script as $1..$n (quoted like every other token), so
    # data never has to be spliced into the script text itself.
    return _run_over_ssh(machine, cfg, "/bin/bash", ["-c", script, "remote-shell", *args],
                         cwd=repo_root, timeout=timeout, what="shell")


def _run_over_ssh(machine, cfg, remote_program, argv, *, cwd, timeout, what):
    """Shared ssh execution + error mapping for every remote call."""
    ssh_bin = os.environ.get(_ENV_SSH_BIN, "ssh")
    control_path = control_path_for(cfg["sshAlias"])
    full_argv = build_ssh_argv(
        ssh_bin, cfg["sshAlias"], control_path, remote_program, argv)
    try:
        rc, out, err = _run(full_argv, cwd, timeout)
    except subprocess.TimeoutExpired:
        raise SshUnreachable(
            f"ssh {cfg['sshAlias']} timed out after {timeout}s calling {argv}")
    if rc == 255:
        raise SshUnreachable(
            f"ssh {cfg['sshAlias']} unreachable (exit 255): {err.strip()[:500]}")
    if rc != 0:
        raise HerdrError(
            f"{what} on {machine} {argv} exited {rc}: "
            f"{(err.strip() or out.strip())[:500]}")
    return out


def herdr_cmd_json(machine, argv, **kwargs):
    """herdr_cmd_text, parsed as JSON. Raises HerdrError on non-JSON output
    (a banner, truncated output, an empty reply) — never returns a value
    that would read as "zero results" for garbage (R7)."""
    out = herdr_cmd_text(machine, argv, **kwargs)
    try:
        return json.loads(out)
    except json.JSONDecodeError as e:
        raise HerdrError(
            f"herdr on {machine} {argv} produced non-JSON stdout: {e} "
            f"(first 200 chars: {out[:200]!r})")


CLI_UNKNOWN_MACHINE_EXIT = 3
CLI_SSH_UNREACHABLE_EXIT = 4


def _cli_main(argv):
    """Bash-facing door onto herdr_cmd_text — so a shell script (nudge-pane.sh)
    routes through this ONE wrapper instead of growing a second, drifting
    ssh/quoting implementation of its own (the exact bug this module exists
    to prevent, just moved to bash — see the module docstring).

    Usage: chief_dashboard_herdr.py <pane_key> <herdr argv...>
    `pane_key` is resolved via split_pane_key(); every argv token equal to
    the ORIGINAL pane_key (bash call sites pass "$PANE" as one of their own
    args, same as they did calling herdr directly) is rewritten to the
    resolved raw id before the call runs on the resolved machine. Prints
    herdr's raw stdout on success. Exit 0 ok, 2 usage, 3 unknown machine,
    4 ssh unreachable, 1 any other herdr error — stderr always has why.
    """
    if len(argv) < 2:
        print("usage: chief_dashboard_herdr.py <pane_key> <herdr argv...>",
              file=sys.stderr)
        return 2
    pane_key, herdr_argv = argv[0], argv[1:]
    repo_root = os.environ.get("CHIEF_REPO_ROOT") or os.getcwd()
    machines, err = load_machines_config(repo_root)
    if err:
        # A broken config must not silently disable remote routing as if it
        # were local (P0-16/R19) — but a local-only pane key still has to
        # work. machines stays {}, so split_pane_key below still resolves a
        # bare/local id fine and only refuses a namespaced one.
        print(f"chief_dashboard_herdr: machines config error: {err}",
              file=sys.stderr)
    try:
        machine, raw_pane_id = split_pane_key(pane_key, machines)
    except UnknownMachine as e:
        print(f"chief_dashboard_herdr: {e}", file=sys.stderr)
        return CLI_UNKNOWN_MACHINE_EXIT
    resolved_argv = [raw_pane_id if a == pane_key else a for a in herdr_argv]
    try:
        out = herdr_cmd_text(machine, resolved_argv, repo_root=repo_root,
                              machines=machines)
    except SshUnreachable as e:
        print(f"chief_dashboard_herdr: {e}", file=sys.stderr)
        return CLI_SSH_UNREACHABLE_EXIT
    except HerdrError as e:
        print(f"chief_dashboard_herdr: {e}", file=sys.stderr)
        return 1
    sys.stdout.write(out)
    return 0


def copy_file_over_ssh(cfg, local_path, remote_dir, remote_dest, *,
                        connect_timeout=8, timeout=20):
    """One-shot `mkdir -p && cat >` over a PLAIN ssh call (no ControlMaster
    reuse, unlike herdr_cmd_text's hot path): a file copy pays connection
    setup once per nudge-pane.sh --file call and is never in a loop, so the
    added ControlMaster/ControlPath complexity buys nothing here — deliberate
    per the --file design, not an oversight.

    Still the ONE place that shells `ssh` for this purpose (module docstring
    R2/R3 applies to file transport too — a second ssh implementation in
    nudge-pane.sh's bash would be exactly the drift this module exists to
    prevent)."""
    ssh_bin = os.environ.get(_ENV_SSH_BIN, "ssh")
    remote_cmd = f"mkdir -p {shlex.quote(remote_dir)} && cat > {shlex.quote(remote_dest)}"
    argv = [ssh_bin, "-o", "BatchMode=yes",
            "-o", f"ConnectTimeout={connect_timeout}",
            cfg["sshAlias"], remote_cmd]
    try:
        with open(local_path, "rb") as f:
            proc = subprocess.run(argv, stdin=f, capture_output=True,
                                   timeout=timeout)
    except subprocess.TimeoutExpired:
        raise SshUnreachable(
            f"ssh {cfg['sshAlias']} timed out after {timeout}s copying {local_path}")
    if proc.returncode == 255:
        raise SshUnreachable(
            f"ssh {cfg['sshAlias']} unreachable (exit 255): "
            f"{proc.stderr.decode(errors='replace').strip()[:500]}")
    if proc.returncode != 0:
        raise HerdrError(
            f"copy to {cfg['sshAlias']} failed (exit {proc.returncode}): "
            f"{proc.stderr.decode(errors='replace').strip()[:500]}")


def _cli_copy_file(argv):
    """`--copy-file <pane_key> <local_path>` — nudge-pane.sh --file's door.

    LOCAL pane: no-op (same machine already has the file — nudge-pane.sh
    just sends the pointer, today's documented workaround unchanged).
    REMOTE pane: copies local_path to the SAME PATH RELATIVE TO
    CHIEF_REPO_ROOT inside that machine's configured `repoRoot`. Refuses
    (nonzero exit, no copy attempted) if the machine has no repoRoot
    configured, or the local path isn't inside CHIEF_REPO_ROOT (nothing to
    replicate a relative path from).

    Exit 0 ok (local no-op or remote copy succeeded), 2 usage / local path
    missing, 3 unknown machine, 4 ssh unreachable, 1 any other failure (no
    repoRoot configured, path outside repo root, remote mkdir/cat failed).
    stderr always says why."""
    if len(argv) != 2:
        print("usage: chief_dashboard_herdr.py --copy-file <pane_key> <local_path>",
              file=sys.stderr)
        return 2
    pane_key, local_path = argv
    if not os.path.isfile(local_path):
        print(f"chief_dashboard_herdr: --copy-file: {local_path!r} does not "
              "exist locally", file=sys.stderr)
        return 2
    repo_root = os.environ.get("CHIEF_REPO_ROOT") or os.getcwd()
    machines, err = load_machines_config(repo_root)
    if err:
        print(f"chief_dashboard_herdr: machines config error: {err}",
              file=sys.stderr)
    try:
        machine, _raw = split_pane_key(pane_key, machines)
    except UnknownMachine as e:
        print(f"chief_dashboard_herdr: {e}", file=sys.stderr)
        return CLI_UNKNOWN_MACHINE_EXIT
    if machine == LOCAL_MACHINE:
        return 0  # same machine — nothing to copy, caller just sends the pointer
    cfg = machines.get(machine) or {}
    remote_repo_root = cfg.get("repoRoot")
    if not remote_repo_root:
        print(f"chief_dashboard_herdr: --copy-file: machine {machine!r} has "
              "no repoRoot configured in .claude/dashboard-machines.json — "
              "cannot compute where the file goes", file=sys.stderr)
        return 1
    abs_local = os.path.abspath(local_path)
    abs_root = os.path.abspath(repo_root)
    if abs_local != abs_root and not abs_local.startswith(abs_root + os.sep):
        print(f"chief_dashboard_herdr: --copy-file: {local_path!r} is not "
              f"inside CHIEF_REPO_ROOT ({repo_root!r}) — no relative path to "
              f"replicate onto {machine!r}", file=sys.stderr)
        return 1
    rel_path = os.path.relpath(abs_local, abs_root)
    remote_dest = remote_repo_root.rstrip("/") + "/" + rel_path
    remote_dir = os.path.dirname(remote_dest)
    try:
        copy_file_over_ssh(cfg, abs_local, remote_dir, remote_dest)
    except SshUnreachable as e:
        print(f"chief_dashboard_herdr: {e}", file=sys.stderr)
        return CLI_SSH_UNREACHABLE_EXIT
    except HerdrError as e:
        print(f"chief_dashboard_herdr: {e}", file=sys.stderr)
        return 1
    print(f"copied to {machine}:{remote_dest}")
    return 0


def ssh_master_alive(ssh_alias, ssh_bin=None):
    """True if a ControlMaster is currently up for this alias. Diagnostic
    only (used by the transport tests / QA-B10-B11 probes), never on a hot
    call path."""
    ssh_bin = ssh_bin or os.environ.get(_ENV_SSH_BIN, "ssh")
    control_path = control_path_for(ssh_alias)
    proc = subprocess.run(
        [ssh_bin, "-o", f"ControlPath={control_path}", "-O", "check", ssh_alias],
        capture_output=True, text=True, timeout=5,
    )
    return proc.returncode == 0


if __name__ == "__main__":
    _argv = sys.argv[1:]
    if _argv and _argv[0] == "--copy-file":
        sys.exit(_cli_copy_file(_argv[1:]))
    sys.exit(_cli_main(_argv))
