#!/usr/bin/env python3
"""Jev persona registry + routing (P1 — see `.claude/briefs/jev-persona-
routing.md` in this repo's main worktree, sections Vocabulary/Registry/
Machines/Dashboard endpoints/Phases P1).

REGISTRY
--------
`~/.config/agentbar/personas.json` (override: env `AGENTBAR_PERSONAS_FILE`,
for tests and a second local instance). AgentBar edits this file only
through dashboard endpoints (P4) — this module is the one reader/writer.
Shape: `{globalInstructions, personas: {"<machine>:<folder>": {name,
description, routesWhen[], notFor[], extraInstructions, idle: resume|fresh,
resumeWithinDays, start: in-place|script, startScript?, runsOn?}}, hidden: [address,
…]}`.

A missing file is not an error (empty registry, same "no config yet" rule
every other dashboard config file follows — see dashboard_config.py). An
unreadable/malformed file, or an individual persona entry with the wrong
shape, is skipped with a log line to stderr — never a crash: one bad entry
must not take down every other persona or /api/personas itself.

A persona with an empty/unreviewed `description` is a valid registry entry
(Settings, P4, can still list and edit it) but is never OFFERED to Jev or
returned by /api/personas — brief: "Jev never reads an unreviewed draft".
Use `offered_personas()` for anything routing-facing; `load_registry()`
alone for anything registry-editing-facing.

SESSION -> PERSONA MAPPING
---------------------------
A session (a dashboard agent row: `machine` + `cwd`) belongs to the persona
whose folder contains that `cwd`, longest folder match wins, same machine
only (`resolve_persona_for_cwd`). `~` and symlinks are resolved (realpath)
on both sides so a worktree under a project's checkout still maps to that
project's persona, not a shorter-prefix sibling (e.g. `portfolio` at
`~/01_Project` never steals a session that's actually inside
`~/01_Project/AptusFit`).

MAIN SESSION
------------
Per the brief: the agent-tree root (chief) inside the persona's folder;
else the most recently active session whose `cwd` is EXACTLY the folder
(not a subfolder); else none. "Inside the persona's folder" is read as "the
chief whose project root IS the persona's folder" (`main_chiefs_by_persona`)
rather than path containment — that distinction matters for `portfolio`,
which contains the other pilots' folders AND every project with no persona
of its own: a chief in `~/01_Project/AptusFit` or `~/01_Project/speechtodo`
must never become `portfolio`'s main session.
"Most recently active" ranks by `hookSinceSec` ascending (seconds since the
last hook event — smaller is more recent); rows with no hook data sort
last, never crash the comparison.
"""
import copy
import json
import math
import os
import re
import sys

import dashboard_config  # noqa: E402
from chief_dashboard_feeds import machines_status  # noqa: E402
from chief_dashboard_store import resolve_agent_row_id  # noqa: E402
from chief_dashboard_views import get_agent_tree_state, get_full_state  # noqa: E402

_ENV_PERSONAS_FILE = "AGENTBAR_PERSONAS_FILE"
_DEFAULT_PATH = os.path.expanduser("~/.config/agentbar/personas.json")

VALID_IDLE = ("resume", "fresh")
VALID_START = ("in-place", "script")

#: Brief's "Default global instructions (editable in Settings)" block,
#: verbatim, used whenever the registry omits/blanks `globalInstructions`.
DEFAULT_GLOBAL_INSTRUCTIONS = """\
You are the persona "<name>": <description>.
Messages reach you from the user through AgentBar, which picks the most relevant persona. You may get one mid-task or in a fresh session.
Misrouted? If a message clearly belongs to another persona, don't do the work. Reply in one line: "Misrouted — better: <persona> (<why>)". Never forward it yourself.
Unclear? Ask one short question instead of guessing.
Bigger work: delegate with this folder's own tools (workers, worktrees, briefs) and stay the front door.
Keep durable notes in this folder: sessions can start fresh.
Reply: first line = outcome (done / blocked / needs your decision). Scannable, no preamble.\
"""

_EMPTY_REGISTRY = {"globalInstructions": DEFAULT_GLOBAL_INSTRUCTIONS, "personas": {}, "hidden": []}


def registry_path():
    """The registry file path — `AGENTBAR_PERSONAS_FILE` (tests / a second
    local instance) wins over the default `~/.config/agentbar/
    personas.json`. Read at call time (not cached at import) so a test can
    set the env var right before calling `load_registry()`."""
    return os.environ.get(_ENV_PERSONAS_FILE) or _DEFAULT_PATH


def _resolve_path(raw_path):
    """`~` + symlinks resolved sensibly; never raises on a nonexistent
    path (realpath just normalizes it) so a fake-home test folder that was
    never actually created still matches correctly."""
    expanded = os.path.expanduser(str(raw_path or ""))
    try:
        return os.path.realpath(expanded)
    except OSError:
        return os.path.normpath(expanded)


def _warn(address, message):
    print(f"[personas] skipping {address!r}: {message}", file=sys.stderr)


def _is_str_list(value):
    return isinstance(value, list) and all(isinstance(x, str) for x in value)


def _normalize_persona(address, raw):
    """One registry entry -> a normalized persona dict, or None (invalid —
    caller logs and skips it, the rest of the registry still loads)."""
    if not isinstance(raw, dict):
        _warn(address, "persona value is not an object")
        return None
    if ":" not in address:
        _warn(address, "address missing ':' (expected <machine>:<folder>)")
        return None
    machine, folder = address.split(":", 1)
    if not machine or not folder:
        _warn(address, "empty machine or folder in address")
        return None

    name = raw.get("name")
    if not isinstance(name, str) or not name.strip():
        _warn(address, "missing/invalid 'name'")
        return None

    description = raw.get("description", "")
    if not isinstance(description, str):
        _warn(address, "'description' must be a string")
        return None

    routes_when = raw.get("routesWhen", [])
    if not _is_str_list(routes_when):
        _warn(address, "'routesWhen' must be a list of strings")
        return None

    not_for = raw.get("notFor", [])
    if not _is_str_list(not_for):
        _warn(address, "'notFor' must be a list of strings")
        return None

    extra_instructions = raw.get("extraInstructions", "")
    if not isinstance(extra_instructions, str):
        _warn(address, "'extraInstructions' must be a string")
        return None

    idle = raw.get("idle", "resume")
    if idle not in VALID_IDLE:
        _warn(address, f"'idle' must be one of {VALID_IDLE}, got {idle!r}")
        return None

    resume_within_days = raw.get("resumeWithinDays", 3)
    # json.load accepts NaN/Infinity: NaN compares False to everything (it
    # would silently mean "always resume") and Infinity never expires.
    if isinstance(resume_within_days, bool) or \
            not isinstance(resume_within_days, (int, float)) or \
            not math.isfinite(resume_within_days):
        _warn(address, "'resumeWithinDays' must be a finite number")
        return None

    start = raw.get("start", "in-place")
    if start not in VALID_START:
        _warn(address, f"'start' must be one of {VALID_START}, got {start!r}")
        return None

    start_script = raw.get("startScript")
    if start == "script":
        if not isinstance(start_script, str) or not start_script.strip():
            _warn(address, "'start' is 'script' but 'startScript' is missing")
            return None
    elif start_script is not None and not isinstance(start_script, str):
        _warn(address, "'startScript' must be a string")
        return None

    # Which machine a start opens the session on: "local" (this dashboard's
    # Mac) or a configured machine id. Distinct from the address's machine,
    # which is where the persona's folder is matched against sessions (and
    # the default when unset).
    runs_on = raw.get("runsOn", machine)
    if not isinstance(runs_on, str) or not runs_on.strip():
        _warn(address, "'runsOn' must be a machine id")
        return None

    return {
        "address": address, "machine": machine, "folder": folder,
        "resolvedFolder": _resolve_path(folder),
        "name": name.strip(), "description": description,
        "routesWhen": list(routes_when), "notFor": list(not_for),
        "extraInstructions": extra_instructions, "idle": idle,
        "resumeWithinDays": resume_within_days, "start": start,
        "startScript": start_script, "runsOn": runs_on.strip(),
    }


#: Last successfully-parsed registry per resolved path, keyed by the
#: (mtime, size) it was read at (QA gap fix, P3: a registry read landing
#: mid-write — the save is a truncate-then-rewrite, not atomic — must not
#: blank out every persona for that one unlucky request). A read that
#: fails to parse reuses this instead of falling back to empty; a read
#: whose file stat hasn't changed since skips reparsing entirely.
_last_good_by_path = {}


def load_registry(path=None):
    """(globalInstructions, personas: {address: persona}, hidden: [addr]).

    Missing file -> empty registry, not an error. Unparseable file, wrong
    top-level shape, or an individual invalid persona entry -> that piece
    is skipped with a stderr log line; everything else still loads. A
    parse failure reuses the last known-good parse for this path, if any
    (see `_last_good_by_path`).

    Always returns a fresh deep copy: the cached parse is shared across
    requests, so a caller mutating what it got back must never corrupt
    the next caller's registry."""
    path = path or registry_path()
    if not os.path.exists(path):
        return dict(_EMPTY_REGISTRY, personas={}, hidden=[])

    try:
        stat = os.stat(path)
    except OSError:
        stat = None
    cached = _last_good_by_path.get(path)
    if stat is not None and cached is not None and \
            cached["mtime"] == stat.st_mtime and cached["size"] == stat.st_size:
        return copy.deepcopy(cached["registry"])

    try:
        with open(path) as f:
            raw = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        print(f"[personas] could not read/parse {path}: {e}", file=sys.stderr)
        if cached is not None:
            print(f"[personas] reusing last-good registry for {path} "
                  "(read likely landed mid-write)", file=sys.stderr)
            return copy.deepcopy(cached["registry"])
        return dict(_EMPTY_REGISTRY, personas={}, hidden=[])

    if not isinstance(raw, dict):
        print(f"[personas] expected a JSON object in {path}, got {type(raw).__name__}",
              file=sys.stderr)
        return dict(_EMPTY_REGISTRY, personas={}, hidden=[])

    global_instructions = raw.get("globalInstructions")
    if not isinstance(global_instructions, str) or not global_instructions.strip():
        global_instructions = DEFAULT_GLOBAL_INSTRUCTIONS

    personas = {}
    raw_personas = raw.get("personas")
    if isinstance(raw_personas, dict):
        for address, entry in raw_personas.items():
            normalized = _normalize_persona(address, entry)
            if normalized:
                personas[address] = normalized
    elif raw_personas is not None:
        print(f"[personas] 'personas' must be an object, got {type(raw_personas).__name__}",
              file=sys.stderr)

    hidden_raw = raw.get("hidden")
    hidden = [h for h in hidden_raw if isinstance(h, str)] if isinstance(hidden_raw, list) else []

    result = {"globalInstructions": global_instructions, "personas": personas, "hidden": hidden}
    if stat is not None:
        _last_good_by_path[path] = {"mtime": stat.st_mtime, "size": stat.st_size,
                                     "registry": result}
    return copy.deepcopy(result)


#: Addresses already warned about as a shadowed duplicate name — the
#: warning fires on every GET otherwise (offered_personas runs per request).
_warned_duplicate_addresses = set()


def offered_personas(registry):
    """Personas Jev/`/api/personas` may show: not hidden, and with a saved
    (non-empty) description — brief: "Jev never reads an unreviewed
    draft". Names are unique among what's offered (the start endpoint
    looks a persona up by name): a duplicate keeps the first one in
    registry order. Deduped AFTER the hidden/undescribed filter, so a
    hidden or draft entry can never shadow a listed persona of the same
    name."""
    hidden = set(registry.get("hidden") or [])
    offered, seen_names = {}, set()
    for addr, persona in (registry.get("personas") or {}).items():
        if addr in hidden or not (persona.get("description") or "").strip():
            continue
        if persona["name"] in seen_names:
            if addr not in _warned_duplicate_addresses:
                _warned_duplicate_addresses.add(addr)
                _warn(addr, f"duplicate persona name {persona['name']!r} — "
                            "keeping the first one in registry order")
            continue
        seen_names.add(persona["name"])
        offered[addr] = persona
    return offered


_LOCAL_MACHINE = "local"
_REMOTE_HOME_RE = re.compile(r"^/Users/[^/]+(?=/|$)")


def home_relative(path):
    """A LOCAL path -> `~`/`~/x` when it's under this Mac's home (realpath
    on both sides), else the resolved path unchanged."""
    path = _resolve_path(path)
    home = _resolve_path("~")
    if path == home:
        return "~"
    if path.startswith(home + os.sep):
        return "~/" + path[len(home) + 1:]
    return path


def _portable_path(machine, path):
    """A path on `machine` in a form comparable across Macs: `~/x` for
    anything under that Mac's home. Remote paths can't be realpath'd from
    here; a remote home is taken to be `/Users/<user>` (macOS)."""
    if not path:
        return None
    if machine == _LOCAL_MACHINE:
        return home_relative(path)
    path = os.path.normpath(str(path))
    if path.startswith("~"):
        return path
    return _REMOTE_HOME_RE.sub("~", path, count=1)


def _folder_on(persona, machine):
    """(persona folder, cwd normalizer) for comparing against a session on
    `machine`: the persona's own machine compares resolved local paths
    (today's rule); any OTHER Mac compares `~`-relative forms, so a
    session in the same project folder on the Air counts for a persona
    whose address is on the Pro (persona-start-on-air, slice 4)."""
    if machine == persona["machine"] and machine == _LOCAL_MACHINE:
        return persona["resolvedFolder"], _resolve_path
    folder = _portable_path(persona["machine"], persona["folder"])
    return folder, lambda p: _portable_path(machine, p)


def _is_within(folder, path):
    return path == folder or path.startswith(folder.rstrip("/") + "/")


def persona_folder_match(persona, machine, cwd, *, exact=False):
    """Length of the persona folder when `cwd` on `machine` is inside it
    (or IS it, with `exact`), else -1."""
    if not cwd or not machine:
        return -1
    folder, normalize = _folder_on(persona, machine)
    path = normalize(cwd)
    if not folder or not path:
        return -1
    hit = path == folder if exact else _is_within(folder, path)
    return len(folder) if hit else -1


def resolve_persona_for_cwd(personas, machine, cwd):
    """The address of the persona whose folder contains `cwd` on `machine`
    — longest folder match wins. Any Mac counts (the same `~/x` folder on
    the other Mac is the same project). None when `cwd`/`machine` is
    missing or nothing matches."""
    best_addr, best_len = None, -1
    for addr, p in personas.items():
        length = persona_folder_match(p, machine, cwd)
        if length > best_len:
            best_len, best_addr = length, addr
    return best_addr


def _recency_key(row):
    """Sort key for "most recently active": ascending `hookSinceSec`
    (smaller = more recent); rows with no hook data sort last."""
    since = row.get("hookSinceSec")
    return (since is None, since if since is not None else float("inf"))


def main_chiefs_by_persona(personas, chiefs, rows):
    """{address: chief id} — each persona's front-door chief, if any.

    A live chief counts for a persona only when its project root IS the
    persona's folder (same machine). Mapping by containment alone is the
    containment trap one level up: `portfolio` (`~/01_Project`) contains
    every project with no persona of its own, so a chief running in
    `~/01_Project/speechtodo` would become portfolio's front door and get
    cross-project questions. The project root (agent_tree.project_for_cwd)
    already folds a worktree back to its checkout, so an AptusFit chief in
    `.claude/worktrees/x` still counts for `chief-aptus`.

    Several chiefs for one persona: the most recently active one (its
    dashboard row's `hookSinceSec`), then lowest id — deterministic."""
    recency_by_id = {resolve_agent_row_id(r): _recency_key(r) for r in rows}
    no_data = (True, float("inf"))
    candidates = {}
    for chief in chiefs:
        if not chief.get("alive") or not chief.get("id"):
            continue
        root = chief.get("projectRoot")
        addr = resolve_persona_for_cwd(personas, chief.get("machine"), root)
        if not addr or persona_folder_match(personas[addr], chief.get("machine"), root,
                                            exact=True) < 0:
            continue
        candidates.setdefault(addr, []).append(chief["id"])
    return {addr: min(ids, key=lambda i: (recency_by_id.get(i, no_data), i))
            for addr, ids in candidates.items()}


def main_session_for_persona(persona, rows_for_persona, chief_id):
    """The persona's main session row id, or None. `chief_id` is the id of
    the (already resolved, already known to map to this persona) live
    agent-tree root, if any. `rows_for_persona` is every agent row already
    known to map to this persona (see `resolve_persona_for_cwd`)."""
    if chief_id:
        return chief_id
    # Pane-less rows (Claude Desktop, a plain-terminal CLI) can't take a message,
    # so they never count: otherwise a busy Desktop chat in the folder would make
    # AgentBar open a new tab for every message.
    exact = [r for r in rows_for_persona
             if r.get("paneId")
             and persona_folder_match(persona, r.get("machine") or persona["machine"],
                                      r.get("cwd"), exact=True) >= 0]
    if not exact:
        return None
    exact.sort(key=_recency_key)
    return resolve_agent_row_id(exact[0])


def get_personas_state():
    """GET /api/personas's payload: `[{name, address, description,
    routesWhen, notFor, idle, start, offline, mainRowId, sessionRowIds,
    idleStart, runsOn, machines}]`. `runsOn` is the persona's default
    machine id and `machines` the [{id, label}] it may be started on
    (`dashboard_config.machine_choices()`, "local" first) — AgentBar's
    confirm row draws these as chips and sends the chosen one as
    `/api/persona/start`'s `machine`. `offline` is true only for a configured REMOTE machine
    currently unreachable (`machines_status()` status "broken") — always
    false for "local". `idleStart` (P3) is `persona_start.idle_start_for`'s
    verdict — "resume" or "fresh" — so AgentBar can label the confirm row
    before anyone actually starts anything (cheap: cached per folder, see
    that function).
    Imported lazily (inside this function, not at module top) because
    `persona_start` imports `personas` itself; importing it back at module
    load time would be a load-order-dependent circular import."""
    import persona_start  # noqa: E402  (lazy — see docstring)

    registry = load_registry()
    personas = offered_personas(registry)
    if not personas:
        return []

    full_state = get_full_state()
    agent_rows = full_state["computed"]["agents"]
    tree = get_agent_tree_state()
    offline_machines = {m for m, info in machines_status().items()
                        if info.get("status") == "broken"}

    sessions_by_persona = {}
    for row in agent_rows:
        addr = resolve_persona_for_cwd(personas, row.get("machine"), row.get("cwd"))
        if addr:
            sessions_by_persona.setdefault(addr, []).append(row)

    main_chief_by_persona = main_chiefs_by_persona(
        personas, tree.get("chiefs", []), agent_rows)

    live_ids_by_machine = {
        m: persona_start.live_session_ids_for_machine(agent_rows, m)
        for m in {p["runsOn"] for p in personas.values()}
    }

    machine_choices = dashboard_config.machine_choices()
    result = []
    for addr, persona in personas.items():
        rows = sessions_by_persona.get(addr, [])
        result.append({
            "name": persona["name"],
            "address": addr,
            "description": persona["description"],
            "routesWhen": persona["routesWhen"],
            "notFor": persona["notFor"],
            "idle": persona["idle"],
            "start": persona["start"],
            "offline": persona["machine"] in offline_machines,
            "mainRowId": main_session_for_persona(
                persona, rows, main_chief_by_persona.get(addr)),
            "sessionRowIds": [resolve_agent_row_id(r) for r in rows],
            "idleStart": persona_start.idle_start_for(
                persona, live_ids_by_machine.get(persona["runsOn"], set()),
                offline_machines=offline_machines),
            "runsOn": persona["runsOn"],
            "machines": machine_choices,
        })
    return result
