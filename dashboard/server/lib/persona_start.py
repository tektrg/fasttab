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
  message rules: one line, <= 2000 chars, no terminal control characters,
  no slash command beyond /clear and /compact).
- One start per persona at a time, and none within `START_COOLDOWN_SEC`
  of the last success (`StartGuard`) — a double POST must not open two
  tabs.

COMMAND SHAPE
-------------
`claude [--resume <uuid>] --append-system-prompt-file=<path> -- "$PERSONA_MESSAGE"`,
typed into the new tab's live interactive shell by `herdr pane run`
(herdr 0.9.1 docs: "`pane run` atomically sends command text and Enter").
The message itself is NEVER typed: `herdr tab create --env
PERSONA_MESSAGE=<text>` puts it in the new shell's environment (the same
variable name the brief gives `startScript`), and the typed line only
expands it inside double quotes — one argv element, no re-parsing. So the
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
HERDR_CALL_TIMEOUT_SEC = 7
SHELL_READY_TIMEOUT_MS = 8000

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


#: {(projects_dir, resolved_folder): (scanned_at_epoch, (id, mtime))}
_idle_start_scan_cache = {}


def idle_start_for(persona, live_session_ids, *, now=None, projects_dir=None):
    """GET /api/personas's `idleStart`: "resume" or "fresh". Only a local
    `start: in-place` persona can resume from here (a script persona or a
    remote one is refused by the start endpoint anyway, and this Mac's disk
    says nothing about a remote machine's history). The folder scan is
    reused for `IDLE_START_CACHE_TTL_SEC` — the endpoint is polled, the
    start path always rescans."""
    if persona.get("start") != "in-place" or \
            persona.get("machine") != herdr_transport.LOCAL_MACHINE:
        return "fresh"
    now = now if now is not None else time.time()
    projects_dir = projects_dir or claude_projects_dir()
    key = (projects_dir, persona["resolvedFolder"])
    cached = _idle_start_scan_cache.get(key)
    if cached is None or now - cached[0] > IDLE_START_CACHE_TTL_SEC:
        cached = (now, latest_conversation_for_folder(persona["resolvedFolder"], projects_dir))
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
    "$PERSONA_MESSAGE"` (module docstring). No user text goes in here: the
    message arrives through the tab's environment. Raises ValueError on a
    non-UUID resume id or a control character anywhere in the line — last
    line of defence; callers validate earlier."""
    parts = [claude_bin or CLAUDE_BIN]
    if resume_session_id is not None:
        if not _SESSION_UUID_RE.fullmatch(resume_session_id):
            raise ValueError(f"not a session UUID: {resume_session_id!r}")
        parts += ["--resume", resume_session_id]
    parts += [f"--append-system-prompt-file={instructions_path}", "--"]
    command = " ".join(_single_quote(p) for p in parts) + f' "${MESSAGE_ENV_VAR}"'
    control_char = find_terminal_control_char(command)
    if control_char is not None:
        raise ValueError(f"control character {control_char!r} in the start command")
    return command


# ── herdr I/O (local host only; tests pass a fake with the same methods) ──

class HerdrTabOps:
    """The 4 herdr calls a start makes, all through the one transport door
    (`herdr_cmd_json`/`herdr_cmd_text`), all on the local machine."""

    def _json(self, argv, timeout=HERDR_CALL_TIMEOUT_SEC):
        return herdr_transport.herdr_cmd_json(
            herdr_transport.LOCAL_MACHINE, argv,
            repo_root=REPO_ROOT, machines=MACHINES, timeout=timeout)

    def _text(self, argv, timeout=HERDR_CALL_TIMEOUT_SEC):
        return herdr_transport.herdr_cmd_text(
            herdr_transport.LOCAL_MACHINE, argv,
            repo_root=REPO_ROOT, machines=MACHINES, timeout=timeout)

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
        self._text(["tab", "close", tab_id])


# ── Double-POST guard ──

class StartGuard:
    """One start per persona at a time, and none within
    `START_COOLDOWN_SEC` of the last successful one. A failed start frees
    the persona at once (a retry is allowed)."""

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
    roster, clock, projects dir, instructions dir, guard)."""

    def __init__(self, *, registry=None, agent_rows=None, herdr=None, now_fn=None,
                 projects_dir=None, instructions_dir=None, guard=None):
        self.registry = registry
        self.agent_rows = agent_rows
        self.herdr = herdr or HerdrTabOps()
        self.now_fn = now_fn or time.time
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
    """(name, text, fresh, None) or (None, None, None, error)."""
    if not isinstance(body, dict):
        return None, None, None, "malformed request body"
    name = body.get("persona")
    if not isinstance(name, str) or not name.strip():
        return None, None, None, "missing persona name"
    fresh = body.get("fresh", False)
    if not isinstance(fresh, bool):
        return None, None, None, "'fresh' must be true or false"
    text = body.get("text")
    if not isinstance(text, str):
        return None, None, None, "missing text"
    ok, cleaned_or_reason = validate_message_text(text)
    if not ok:
        return None, None, None, cleaned_or_reason
    return name, cleaned_or_reason, fresh, None


def _start_persona(body, deps):
    name, text, fresh, error = _validate_request(body)
    if error:
        return _refuse(error)

    registry = deps.load_registry()
    address, persona = find_offered_persona_by_name(registry, name)
    if persona is None:
        return _refuse(f"unknown persona {name!r}")
    if persona["start"] == "script":
        return _refuse(f"persona {name!r} uses start:script — not supported yet")
    if persona["machine"] != herdr_transport.LOCAL_MACHINE:
        return _refuse(f"starting on {persona['machine']} isn't supported yet")
    folder = persona["resolvedFolder"]
    if not os.path.isdir(folder):
        return _refuse(f"{name!r}'s folder {folder} doesn't exist")

    known_names = sorted(p["name"] for p in personas.offered_personas(registry).values())
    instructions = build_instructions(registry, persona, known_names)
    control_char = find_terminal_control_char(instructions, _INSTRUCTIONS_ALLOWED_CONTROL)
    if control_char is not None:
        return _refuse(f"{name!r}'s instructions contain control character "
                       f"{control_char!r} — fix them in Settings")

    refusal = deps.guard.claim(name, deps.now_fn())
    if refusal:
        return _refuse(refusal)
    succeeded = False
    try:
        result = _launch(deps, persona, text, fresh, instructions)
        succeeded = result["ok"]
    finally:
        deps.guard.release(name, deps.now_fn(), succeeded)
    if succeeded:
        print(f"[persona_start] {name!r} address={address!r}: mode={result['mode']} "
              f"pane={result['paneId']}", file=sys.stderr)
    return result


def _launch(deps, persona, text, fresh, instructions):
    """Resume decision, instructions file, then the herdr tab. Closes the
    tab again if anything after `tab create` fails."""
    live_ids = live_session_ids_for_machine(deps.live_agent_rows(), persona["machine"])
    resume_id = decide_resume(
        persona, latest_conversation_for_folder(persona["resolvedFolder"], deps.projects_dir),
        fresh=fresh, live_session_ids=live_ids, now=deps.now_fn())
    instructions_path = write_instructions_file(
        deps.instructions_dir or default_instructions_dir(), persona["name"], instructions)
    command = build_start_command(instructions_path, resume_session_id=resume_id)

    try:
        tab_id, pane_id = deps.herdr.tab_create(
            persona["resolvedFolder"], persona["name"], {MESSAGE_ENV_VAR: text})
    except Exception as e:  # noqa: BLE001 — no pane id -> no tab we could close
        return _refuse(f"herdr couldn't open a tab: {e}")
    try:
        deps.herdr.wait_shell_ready(pane_id)
        deps.herdr.pane_run(pane_id, command)
    except Exception as e:  # noqa: BLE001 — any failure here leaves a half-made tab
        cleanup_note = _close_tab_quietly(deps.herdr, tab_id)
        return _refuse(f"herdr failed after opening a tab: {e}{cleanup_note}")
    return {"ok": True, "paneId": pane_id, "mode": "resumed" if resume_id else "started"}


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
