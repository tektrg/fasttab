#!/usr/bin/env python3
"""POST /api/persona/start — Jev persona routing P3, local host only (see
`.claude/briefs/jev-persona-routing.md` in this repo's main worktree,
sections Delivery/Dashboard endpoints/What the agent reads/P3).

Split out of `personas.py` (registry + `GET /api/personas`, P1) to keep
that file focused: this module is the one WRITE action on top of the
read-only registry — deciding resume vs. fresh, building the `claude`
command, and running it in a new herdr tab.

SECURITY (brief: "Dashboard endpoints")
---------------------------------------
- A persona **name** only, never a path — looked up through
  `personas.offered_personas()`, so a hidden persona or one with no saved
  description can never be started (same rule Jev itself is held to).
- Localhost only: `chief-dashboard-server.py` answers 403 when the request
  arrived on the remote (tailscale) listener, BEFORE the body is parsed.
  The shared `_reject_foreign_write()` guard alone is not enough — it
  admits an authenticated remote caller.
- `Content-Type: application/json` is required (`is_json_content_type`),
  checked by the server before the body is parsed: a browser page can't
  send that cross-site without a preflight this dashboard never answers.
- `text` passes `chief_dashboard_actions.validate_message_text` (the Send
  message rules: one line, <= 8000 chars, tabs become spaces, no other
  terminal control characters, no slash command beyond /clear and
  /compact).
- One start per persona at a time, and none within `START_COOLDOWN_SEC`
  of the last success (`StartGuard`) — a double POST must not open two
  tabs.

COMMAND SHAPE
-------------
`claude [--resume <uuid>] --append-system-prompt-file=<path> -- "${PERSONA_MESSAGE:?}"`,
typed into the new tab's live interactive shell by `herdr pane run`
(herdr 0.9.1 docs: "`pane run` atomically sends command text and Enter").
The message itself is NEVER typed: `herdr tab create --env
PERSONA_MESSAGE=<text>` puts it in the new shell's environment (the same
variable name the brief gives `startScript`), and the typed line only
expands it inside double quotes — one argv element, no re-parsing; `:?`
makes the shell refuse to run claude at all if the variable arrived
unset/empty (rather than start it with a lost message). So the
typed line holds no user input at all: nothing in it can be a keystroke,
a quote break-out or a zsh `=word` expansion, it stays far below the
1024-byte canonical-line limit, and the message stays out of the shell
history. Every other token is always single-quoted (`_single_quote`, not
`shlex.quote`, which leaves `=word` bare for zsh's EQUALS expansion).
Verified against claude 2.1.283's own binary
(`claude --help` hides the flag; its option table and startup code read
it before the interactive/print split, so it applies to an interactive
session):
- `--append-system-prompt-file <file>`: "Read system prompt from a file
  and append to the default system prompt". The instructions (multi-line,
  ~1 KB) go in a 0600 file under the dashboard's state dir
  (`<STATE_HOME>/persona-prompts/`, dir 0700) instead of the typed line:
  no newline typed into a tty, no 1024-byte canonical-line limit hit by
  them, no copy in the shell history.
- `--`: claude's argv parser honours it as end-of-options (its own argv
  pre-scans slice at `--`), so a message starting with `-` (e.g.
  `--dangerously-skip-permissions`) is the prompt, never a flag.
- `--resume <uuid>`: resumes that exact conversation — not `--continue`,
  which would pick "the most recent conversation" again at launch time and
  could land on a different one than the one checked here.
Before typing, `wait_shell_ready` waits for the new tab's shell to draw
something (`herdr pane wait-output --regex \\S`) so the line isn't typed
into a shell that hasn't started; a shell that never shows anything fails
the start and the tab is closed. Heuristic only: a MOTD or an instant
prompt also counts, which is why the typed line is kept short.

RESUME DECISION (brief: "`--continue` ... only when")
------------------------------------------------------
1. `persona.idle == "resume"` and the caller didn't pass `fresh: true`.
2. The most recent conversation for that EXACT folder (not a
   subfolder/worktree) is within `resumeWithinDays`, found via the newest
   `<projects dir>/<encoded folder>/*.jsonl` mtime, and its id is a UUID.
   Claude Code's folder encoding (checked against real
   `~/.claude/projects/` entries: `/Users/x/01_Project/command-bar-macos`
   -> `-Users-x-01-Project-command-bar-macos`) replaces every character
   that is not `[A-Za-z0-9]` with `-`, one-for-one.
3. That conversation isn't already live in some pane (the dashboard's own
   `agentSession` rows for the same machine) — if it is, a fresh session
   starts instead of two panes fighting over one transcript.
`idle_start_for` gives `GET /api/personas` the same verdict (minus
`fresh`) as `idleStart`, from a short-lived per-folder cache.
"""
import copy
import hashlib
import os
import re
import sys
import tempfile
import threading
import time
import traceback

import chief_dashboard_herdr as herdr_transport  # noqa: E402
import dashboard_config  # noqa: E402
import personas  # noqa: E402
from chief_dashboard_actions import (  # noqa: E402
    find_terminal_control_char, validate_message_text)
from chief_dashboard_feeds import REPO_ROOT, MACHINES  # noqa: E402
from chief_dashboard_views import get_full_state  # noqa: E402

#: Override for tests — never for real use (the whole point is running the
#: user's actual `claude` on PATH).
CLAUDE_BIN = os.environ.get("PERSONA_START_CLAUDE_BIN", "claude")

#: `~/.claude/projects` override (tests, or a second local instance) — read
#: at call time, same convention as `CLAUDE_SESSIONS_DIR`.
_ENV_PROJECTS_DIR = "CLAUDE_PROJECTS_DIR"

#: Claude Code session ids are lowercase UUIDs; anything else found on disk
#: is never passed to `--resume`.
_SESSION_UUID_RE = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

#: A second start of the same persona within this window is refused.
START_COOLDOWN_SEC = 10

#: How long `idle_start_for` (GET /api/personas) reuses one folder scan.
IDLE_START_CACHE_TTL_SEC = 30

#: Per-call herdr budgets, kept so a whole start (tab create + shell wait +
#: pane run) stays under AgentBar's 30s `personaStartTimeoutSeconds`.
#: Worst case (every call times out): 4 + (16 + 2) + 4 + 2 (tab close) = 28s.
#: The shell wait gets most of it: measured live 2026-09-26 at load average
#: ~34, a new tab's zsh drew its first prompt after 6.3-8.2s, so the old 8s
#: wait refused a real start. The herdr socket calls themselves took
#: 0.01-0.04s on that same run, so 4s/2s is still ~100x headroom.
HERDR_CALL_TIMEOUT_SEC = 4
SHELL_READY_TIMEOUT_MS = 16000
TAB_CLOSE_TIMEOUT_SEC = 2

#: Remote prep (instructions file + folder check) is one ssh call.
REMOTE_PREPARE_TIMEOUT_SEC = 8

#: Shared bash: `resolve_dir <folder>` sets $dir (`~` = that Mac's home);
#: `latest_conversation` prints `<mtime> <uuid>` of the newest UUID-named
#: transcript for $dir's realpath (same encoding + UUID-first rule as
#: `latest_conversation_for_folder`), or an empty line.
_REMOTE_SHELL_LIB = r"""
resolve_dir() { case "$1" in "~") dir="$HOME";; "~/"*) dir="$HOME/${1#"~/"}";; *) dir="$1";; esac; }
latest_conversation() {
  local real enc
  real=$(cd "$dir" && pwd -P) || { echo; return; }
  enc=$(printf '%s' "$real" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')
  { stat -f '%m %N' "$HOME/.claude/projects/$enc"/*.jsonl 2>/dev/null || true; } \
    | sed -E 's#^([0-9]+) .*/([^/]*)\.jsonl$#\1 \2#' \
    | grep -E '^[0-9]+ [0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
    | sort -rn | head -1
  echo
}
"""

#: $1 instructions, $2 file name, $3 folder (`~`-relative or absolute).
#: Prints `OK\n<instructions path>\n<folder>\n<latest>` or `NO_FOLDER <folder>`.
REMOTE_PREPARE_SCRIPT = _REMOTE_SHELL_LIB + r"""set -e
umask 077
d="$HOME/Library/Application Support/agent-dashboard/persona-prompts"
mkdir -p "$d"; chmod 700 "$d"
f="$d/$2"
printf '%s' "$1" > "$f.tmp-$$"; mv "$f.tmp-$$" "$f"
resolve_dir "$3"
[ -d "$dir" ] || { printf 'NO_FOLDER %s\n' "$dir"; exit 0; }
printf 'OK\n%s\n%s\n' "$f" "$dir"
latest_conversation
"""

#: $1 folder. Prints `OK\n<latest>` or `NO_FOLDER <folder>` — the read-only
#: lookup behind a remote persona's `idleStart`.
REMOTE_LATEST_SCRIPT = _REMOTE_SHELL_LIB + r"""set -e
resolve_dir "$1"
[ -d "$dir" ] || { printf 'NO_FOLDER %s\n' "$dir"; exit 0; }
echo OK
latest_conversation
"""

#: A remote `idleStart` lookup must never stall GET /api/personas for long.
REMOTE_LATEST_TIMEOUT_SEC = 3


def parse_remote_latest(line):
    """`<mtime> <uuid>` -> (uuid, mtime); anything else -> (None, None)."""
    parts = (line or "").split()
    if len(parts) != 2 or not parts[0].isdigit() or not _SESSION_UUID_RE.fullmatch(parts[1]):
        return None, None
    return parts[1], float(parts[0])


def remote_latest_conversation(machine, resolved_folder):
    """(uuid, mtime) of the newest conversation for this persona folder on
    a REMOTE machine, over ssh. (None, None) when there's none, the folder
    is missing there, or the machine can't be asked — the caller then
    starts fresh, never fails."""
    try:
        out = herdr_transport.remote_shell_text(
            machine, REMOTE_LATEST_SCRIPT, repo_root=REPO_ROOT, machines=MACHINES,
            timeout=REMOTE_LATEST_TIMEOUT_SEC, args=(_home_relative(resolved_folder),))
    except herdr_transport.HerdrError as e:
        print(f"[persona_start] {machine} history lookup failed: {e}", file=sys.stderr)
        return None, None
    lines = out.splitlines()
    if not lines or lines[0] != "OK":
        return None, None
    return parse_remote_latest(lines[1] if len(lines) > 1 else "")

#: The new shell's env var holding the message (brief: `$PERSONA_MESSAGE`).
MESSAGE_ENV_VAR = "PERSONA_MESSAGE"

#: Instructions may span lines; every other control character is refused.
_INSTRUCTIONS_ALLOWED_CONTROL = "\n\t"


def is_json_content_type(header_value):
    """True only for `application/json`, with or without a `; charset=...`
    suffix. Missing/blank header -> False (never treated as JSON)."""
    if not header_value:
        return False
    return header_value.split(";")[0].strip().lower() == "application/json"


def find_offered_persona_by_name(registry, name):
    """(address, persona) for the OFFERED persona (not hidden, has a saved
    description; names are unique among these) named `name`, or
    (None, None)."""
    for address, persona in personas.offered_personas(registry).items():
        if persona["name"] == name:
            return address, persona
    return None, None


# ── Folder -> projects dir -> most recent conversation ──

def claude_projects_dir():
    return (os.environ.get(_ENV_PROJECTS_DIR)
            or os.path.join(os.path.expanduser("~"), ".claude", "projects"))


def encode_project_dir(folder_abspath):
    """Claude Code's on-disk project-dir encoding for a cwd (see module
    docstring). Not officially documented; if a future Claude Code version
    changes it, the only effect is finding no history (-> start fresh)."""
    return re.sub(r"[^A-Za-z0-9]", "-", folder_abspath)


def latest_conversation_for_folder(resolved_folder, projects_dir=None):
    """(session_id, mtime_epoch) of the newest UUID-named `*.jsonl`
    transcript for this EXACT folder, or (None, None) when there's none.
    Non-UUID files are skipped BEFORE picking the newest, so a stray file
    can't hide a real recent conversation."""
    project_dir = os.path.join(projects_dir or claude_projects_dir(),
                               encode_project_dir(resolved_folder))
    try:
        entries = os.listdir(project_dir)
    except OSError:
        return None, None
    best_id, best_mtime = None, None
    for entry in entries:
        session_id = entry[: -len(".jsonl")] if entry.endswith(".jsonl") else None
        if not session_id or not _SESSION_UUID_RE.fullmatch(session_id):
            continue
        try:
            mtime = os.path.getmtime(os.path.join(project_dir, entry))
        except OSError:
            continue
        if best_mtime is None or mtime > best_mtime:
            best_id, best_mtime = session_id, mtime
    return best_id, best_mtime


def live_session_ids_for_machine(agent_rows, machine):
    """The set of `agentSession` ids currently live in some pane on
    `machine` — the resume guard's "already live somewhere" check."""
    return {r.get("agentSession") for r in (agent_rows or [])
            if r.get("machine") == machine and r.get("agentSession")}


def decide_resume(persona, latest_conversation, *, fresh=False,
                  live_session_ids=(), now):
    """The session id to `--resume`, or None to start fresh — the brief's
    3-part rule (module docstring). `latest_conversation` is
    `latest_conversation_for_folder`'s (id, mtime) for the persona's
    folder. Pure: no disk, no clock."""
    if fresh or persona.get("idle") != "resume":
        return None
    session_id, mtime = latest_conversation
    if session_id is None or not _SESSION_UUID_RE.fullmatch(session_id):
        return None
    if (now - mtime) > persona.get("resumeWithinDays", 3) * 86400:
        return None
    if session_id in (live_session_ids or ()):
        return None
    return session_id


#: {(projects_dir, resolved_folder): (scanned_at_monotonic, (id, mtime))}
_idle_start_scan_cache = {}


def idle_start_for(persona, live_session_ids, *, now=None, monotonic_now=None,
                   projects_dir=None, offline_machines=(), remote_lookup=None):
    """GET /api/personas's `idleStart`: "resume" or "fresh", for the
    persona's Runs-on machine. A script persona is always "fresh"; a remote
    Runs-on machine is asked over ssh (`remote_latest_conversation`), never
    while `offline_machines` lists it. The folder scan (local or remote) is
    reused for `IDLE_START_CACHE_TTL_SEC` — the endpoint is polled, the
    start path always rescans. `live_session_ids` must be the Runs-on
    machine's.

    Two clocks on purpose: the cache TTL runs on `monotonic_now`
    (`time.monotonic`), so a backwards wall-clock step can't pin a stale
    scan forever; only the transcript-age check uses `now` (`time.time`),
    because transcript mtimes are wall-clock epochs."""
    runs_on = persona.get("runsOn", persona.get("machine"))
    if persona.get("start") != "in-place" or runs_on in (offline_machines or ()):
        return "fresh"
    now = now if now is not None else time.time()
    monotonic_now = monotonic_now if monotonic_now is not None else time.monotonic()
    projects_dir = projects_dir or claude_projects_dir()
    key = (runs_on, projects_dir, persona["resolvedFolder"])
    cached = _idle_start_scan_cache.get(key)
    if cached is None or monotonic_now - cached[0] > IDLE_START_CACHE_TTL_SEC:
        if runs_on == herdr_transport.LOCAL_MACHINE:
            latest = latest_conversation_for_folder(persona["resolvedFolder"], projects_dir)
        else:
            latest = (remote_lookup or remote_latest_conversation)(
                runs_on, persona["resolvedFolder"])
        cached = (monotonic_now, latest)
        _idle_start_scan_cache[key] = cached
    resume_id = decide_resume(persona, cached[1], live_session_ids=live_session_ids, now=now)
    return "resume" if resume_id else "fresh"


# ── Instructions + command ──

def build_instructions(registry, persona, known_names):
    """Global instructions with `<name>`/`<description>` filled, a line
    naming every known persona (so "better: X" always names something
    real), then the persona's own `extraInstructions` if non-empty."""
    template = registry.get("globalInstructions") or personas.DEFAULT_GLOBAL_INSTRUCTIONS
    block = template.replace("<name>", persona["name"]).replace(
        "<description>", persona["description"])
    pieces = [block, "Known personas: " + ", ".join(known_names) + "."]
    extra = (persona.get("extraInstructions") or "").strip()
    if extra:
        pieces.append(extra)
    return "\n".join(pieces)


def _instructions_filename(persona_name):
    """A filesystem-safe, collision-free file name for one persona."""
    readable = re.sub(r"[^A-Za-z0-9_-]", "_", persona_name)[:40]
    digest = hashlib.sha256(persona_name.encode("utf-8")).hexdigest()[:10]
    return f"{readable}-{digest}.md"


def default_instructions_dir():
    return os.path.join(dashboard_config.STATE_HOME, "persona-prompts")


def write_instructions_file(instructions_dir, persona_name, instructions):
    """Write `instructions` to `<instructions_dir>/<persona file>` (dir
    0700, file 0600, atomic replace) and return its path. One file per
    persona, overwritten on each start; claude reads it once at launch."""
    os.makedirs(instructions_dir, mode=0o700, exist_ok=True)
    os.chmod(instructions_dir, 0o700)
    path = os.path.join(instructions_dir, _instructions_filename(persona_name))
    fd, tmp_path = tempfile.mkstemp(dir=instructions_dir, prefix=".tmp-", suffix=".md")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(instructions)
        os.replace(tmp_path, path)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise
    return path


def _single_quote(token):
    """POSIX/zsh single quoting, ALWAYS applied (unlike `shlex.quote`,
    which leaves `=word` unquoted — zsh would expand it)."""
    return "'" + token.replace("'", "'\\''") + "'"


def build_start_command(instructions_path, *, resume_session_id=None, claude_bin=None):
    """`claude [--resume <uuid>] --append-system-prompt-file=<path> --
    "${PERSONA_MESSAGE:?}"` (module docstring). No user text goes in here: the
    message arrives through the tab's environment. Raises ValueError on a
    non-UUID resume id or a control character anywhere in the line — last
    line of defence; callers validate earlier."""
    parts = [claude_bin or CLAUDE_BIN]
    if resume_session_id is not None:
        if not _SESSION_UUID_RE.fullmatch(resume_session_id):
            raise ValueError(f"not a session UUID: {resume_session_id!r}")
        parts += ["--resume", resume_session_id]
    parts += [f"--append-system-prompt-file={instructions_path}", "--"]
    command = " ".join(_single_quote(p) for p in parts) + f' "${{{MESSAGE_ENV_VAR}:?}}"'
    control_char = find_terminal_control_char(command)
    if control_char is not None:
        raise ValueError(f"control character {control_char!r} in the start command")
    return command


# ── herdr I/O (local host only; tests pass a fake with the same methods) ──

class HerdrTabOps:
    """The herdr calls a start makes, all through the one transport door
    (`herdr_cmd_json`/`herdr_cmd_text`/`remote_shell_text`), on whichever
    machine the start targets (`self.machine`, set per start)."""

    machine = herdr_transport.LOCAL_MACHINE

    def for_machine(self, machine):
        ops = copy.copy(self)
        ops.machine = machine
        return ops

    def _json(self, argv, timeout=HERDR_CALL_TIMEOUT_SEC):
        return herdr_transport.herdr_cmd_json(
            self.machine, argv,
            repo_root=REPO_ROOT, machines=MACHINES, timeout=timeout)

    def _text(self, argv, timeout=HERDR_CALL_TIMEOUT_SEC):
        return herdr_transport.herdr_cmd_text(
            self.machine, argv,
            repo_root=REPO_ROOT, machines=MACHINES, timeout=timeout)

    def prepare_remote(self, folder, filename, instructions):
        """One ssh call on a remote target: write the instructions file
        there, resolve the folder (`~` = that Mac's home) and check it
        exists, and report its newest conversation there. Returns
        (instructions_path, folder, (uuid, mtime) or (None, None)) or raises ValueError
        when the folder is missing; HerdrError/SshUnreachable pass through."""
        out = herdr_transport.remote_shell_text(
            self.machine, REMOTE_PREPARE_SCRIPT, repo_root=REPO_ROOT, machines=MACHINES,
            timeout=REMOTE_PREPARE_TIMEOUT_SEC, args=(instructions, filename, folder))
        lines = out.splitlines()
        if lines and lines[0].startswith("NO_FOLDER"):
            raise ValueError(f"folder {lines[0][len('NO_FOLDER '):]} doesn't exist there")
        if len(lines) < 3 or lines[0] != "OK":
            raise herdr_transport.HerdrError(f"unexpected prepare output: {out[:200]!r}")
        return lines[1], lines[2], parse_remote_latest(lines[3] if len(lines) > 3 else "")

    def tab_create(self, folder, label, env):
        """(tab_id, pane_id) of a new unfocused tab whose shell runs in
        `folder` with `env` ({name: value}) set. tab_id may be None if
        herdr didn't report one."""
        argv = ["tab", "create", "--cwd", folder, "--label", label, "--no-focus"]
        for env_name, env_value in env.items():
            argv += ["--env", f"{env_name}={env_value}"]
        data = self._json(argv)
        result = (data.get("result") if isinstance(data, dict) else None) or {}
        root_pane = result.get("root_pane") or {}
        pane_id = root_pane.get("pane_id")
        if not pane_id:
            raise RuntimeError(f"herdr tab create returned no pane id: {data!r}")
        tab_id = (result.get("tab") or {}).get("tab_id") or root_pane.get("tab_id")
        return tab_id, pane_id

    def wait_shell_ready(self, pane_id):
        """Returns once the pane shows any non-blank text (the shell's
        prompt); raises HerdrError on timeout."""
        self._text(["pane", "wait-output", pane_id, "--regex", r"\S",
                    "--source", "visible", "--timeout", str(SHELL_READY_TIMEOUT_MS)],
                   timeout=SHELL_READY_TIMEOUT_MS // 1000 + 2)

    def pane_run(self, pane_id, command):
        self._text(["pane", "run", pane_id, command])

    def tab_close(self, tab_id):
        self._text(["tab", "close", tab_id], timeout=TAB_CLOSE_TIMEOUT_SEC)


# ── Double-POST guard ──

class StartGuard:
    """One start per persona at a time, and none within
    `START_COOLDOWN_SEC` of the last successful one. A failed start frees
    the persona at once (a retry is allowed). Every `now` passed in is a
    MONOTONIC reading (`time.monotonic`): a backwards wall-clock step must
    never read as "just started" and block starts."""

    def __init__(self):
        self._lock = threading.Lock()
        self._in_flight = set()
        self._last_success_at = {}

    def claim(self, name, now):
        """None when claimed; otherwise the refusal reason."""
        with self._lock:
            if name in self._in_flight:
                return f"{name!r} is already starting — wait for that start to finish"
            last = self._last_success_at.get(name)
            if last is not None and now - last < START_COOLDOWN_SEC:
                return (f"{name!r} was started {int(now - last)}s ago — "
                        "check its new tab before starting it again")
            self._in_flight.add(name)
            return None

    def release(self, name, now, succeeded):
        with self._lock:
            self._in_flight.discard(name)
            if succeeded:
                self._last_success_at[name] = now


_START_GUARD = StartGuard()


# ── Orchestration ──

class StartDeps:
    """Everything `start_persona` reads or calls outside itself. Defaults
    are the real thing; tests override each (a fake registry, herdr, agent
    roster, clocks, projects dir, instructions dir, guard).

    Two clocks: `wall_clock_fn` (epoch seconds) only for comparing against
    transcript mtimes; `monotonic_fn` for the double-POST guard, which must
    survive a wall-clock step."""

    def __init__(self, *, registry=None, agent_rows=None, herdr=None, wall_clock_fn=None,
                 monotonic_fn=None, projects_dir=None, instructions_dir=None, guard=None):
        self.registry = registry
        self.agent_rows = agent_rows
        self.herdr = herdr or HerdrTabOps()
        self.wall_clock_fn = wall_clock_fn or time.time
        self.monotonic_fn = monotonic_fn or time.monotonic
        self.projects_dir = projects_dir
        self.instructions_dir = instructions_dir
        self.guard = guard or _START_GUARD

    def load_registry(self):
        if self.registry is not None:
            return copy.deepcopy(self.registry)
        return personas.load_registry()

    def live_agent_rows(self):
        if self.agent_rows is not None:
            return self.agent_rows
        return get_full_state()["computed"]["agents"]


def _refuse(error):
    return {"ok": False, "error": error}


def start_persona(body, deps=None):
    """POST /api/persona/start's body -> `{ok: True, paneId, mode:
    started|resumed}` or `{ok: False, error}`. Never raises: anything
    unexpected becomes `{ok: False, error}` (traceback to stderr)."""
    try:
        return _start_persona(body, deps or StartDeps())
    except Exception as e:  # noqa: BLE001 — the endpoint's contract is "never a 500"
        traceback.print_exc(file=sys.stderr)
        return _refuse(f"persona start failed: {e}")


def _validate_request(body):
    """(name, text, fresh, machine-or-None, None) or (..., error).
    `machine` is the caller's one-off override of the persona's Runs on."""
    bad = lambda reason: (None, None, None, None, reason)  # noqa: E731
    if not isinstance(body, dict):
        return bad("malformed request body")
    name = body.get("persona")
    if not isinstance(name, str) or not name.strip():
        return bad("missing persona name")
    fresh = body.get("fresh", False)
    if not isinstance(fresh, bool):
        return bad("'fresh' must be true or false")
    machine = body.get("machine")
    if machine is not None and machine not in _machine_ids():
        return bad(f"unknown machine — choose one of: {', '.join(_machine_ids())}")
    text = body.get("text")
    if not isinstance(text, str):
        return bad("missing text")
    ok, cleaned_or_reason = validate_message_text(text)
    if not ok:
        return bad(cleaned_or_reason)
    return name, cleaned_or_reason, fresh, machine, None


def _machine_ids():
    return [m["id"] for m in dashboard_config.machine_choices()]


def _machine_label(machine):
    return next((m["label"] for m in dashboard_config.machine_choices()
                 if m["id"] == machine), machine)


def _home_relative(folder):
    """`/Users/<me>/x` -> `~/x`, so a remote Mac (other user name) resolves
    it under its own home. Anything else is passed through."""
    home = os.path.realpath(os.path.expanduser("~"))  # resolvedFolder is a realpath
    if folder == home:
        return "~"
    if folder.startswith(home + os.sep):
        return "~/" + folder[len(home) + 1:]
    return folder


def _unreachable(machine, detail):
    """Refusal for a target Mac that can't be reached, plus the machine a
    one-press retry would use. Nothing is ever started elsewhere on its
    own (user decision 2026-10-01)."""
    label = _machine_label(machine)
    print(f"[persona_start] {machine} unreachable: {detail}", file=sys.stderr)
    result = _refuse(f"{label} is unreachable (asleep or offline?) — nothing was started.")
    result["unreachable"] = True
    other = next((m for m in dashboard_config.machine_choices() if m["id"] != machine), None)
    if other:
        result["retryOn"] = other
    return result


def _start_persona(body, deps):
    name, text, fresh, machine_override, error = _validate_request(body)
    if error:
        return _refuse(error)

    registry = deps.load_registry()
    address, persona = find_offered_persona_by_name(registry, name)
    if persona is None:
        return _refuse(f"unknown persona {name!r}")
    if persona["start"] == "script":
        return _refuse(f"persona {name!r} uses start:script — not supported yet")
    target = machine_override or persona["runsOn"]
    if target not in _machine_ids():
        return _refuse(f"{name!r} runs on {target!r}, which isn't a configured "
                       "machine — change Runs on in Settings")
    folder = persona["resolvedFolder"]
    if target == herdr_transport.LOCAL_MACHINE and not os.path.isdir(folder):
        return _refuse(f"{name!r}'s folder {folder} doesn't exist")

    known_names = sorted(p["name"] for p in personas.offered_personas(registry).values())
    instructions = build_instructions(registry, persona, known_names)
    control_char = find_terminal_control_char(instructions, _INSTRUCTIONS_ALLOWED_CONTROL)
    if control_char is not None:
        return _refuse(f"{name!r}'s instructions contain control character "
                       f"{control_char!r} — fix them in Settings")

    refusal = deps.guard.claim(name, deps.monotonic_fn())
    if refusal:
        return _refuse(refusal)
    succeeded = False
    try:
        result = _launch(deps, persona, text, fresh, instructions, target)
        succeeded = result["ok"]
    finally:
        deps.guard.release(name, deps.monotonic_fn(), succeeded)
    if succeeded:
        print(f"[persona_start] {name!r} address={address!r} on={target}: mode={result['mode']} "
              f"pane={result['paneId']}", file=sys.stderr)
    return result


def _launch(deps, persona, text, fresh, instructions, target):
    """Resume decision, instructions file, then the herdr tab — all on
    `target`. Closes the tab again if anything after `tab create` fails."""
    herdr = deps.herdr.for_machine(target)
    live_ids = live_session_ids_for_machine(deps.live_agent_rows(), target)
    if target == herdr_transport.LOCAL_MACHINE:
        latest = latest_conversation_for_folder(persona["resolvedFolder"], deps.projects_dir)
        folder = persona["resolvedFolder"]
        instructions_path = write_instructions_file(
            deps.instructions_dir or default_instructions_dir(), persona["name"], instructions)
    else:
        try:
            instructions_path, folder, latest = herdr.prepare_remote(
                _home_relative(persona["resolvedFolder"]),
                _instructions_filename(persona["name"]), instructions)
        except herdr_transport.SshUnreachable as e:
            return _unreachable(target, e)
        except ValueError as e:
            return _refuse(f"{persona['name']!r} can't start on {_machine_label(target)}: {e}")
    resume_id = decide_resume(persona, latest, fresh=fresh, live_session_ids=live_ids,
                              now=deps.wall_clock_fn())
    command = build_start_command(instructions_path, resume_session_id=resume_id)

    try:
        tab_id, pane_id = herdr.tab_create(folder, persona["name"], {MESSAGE_ENV_VAR: text})
    except herdr_transport.SshUnreachable as e:
        return _unreachable(target, e)
    except Exception as e:  # noqa: BLE001 — no pane id -> no tab we could close
        return _refuse(f"herdr couldn't open a tab: {e} (if a new "
                       f"{persona['name']!r} tab appeared anyway, close it by hand)")
    try:
        herdr.wait_shell_ready(pane_id)
        herdr.pane_run(pane_id, command)
    except Exception as e:  # noqa: BLE001 — any failure here leaves a half-made tab
        cleanup_note = _close_tab_quietly(herdr, tab_id)
        return _refuse(f"herdr failed after opening a tab: {e}{cleanup_note}")
    return {"ok": True, "paneId": herdr_transport.make_pane_key(target, pane_id), "machine": target,
            "mode": "resumed" if resume_id else "started"}


def _close_tab_quietly(herdr, tab_id):
    """Close the half-made tab; returns a note saying what happened, for
    the error message. Never raises."""
    if not tab_id:
        return " (tab id unknown — close the new tab by hand)"
    try:
        herdr.tab_close(tab_id)
        return " (the new tab was closed)"
    except Exception as e:  # noqa: BLE001
        return f" (closing the new tab {tab_id} also failed: {e})"
