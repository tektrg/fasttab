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
resumeWithinDays, start: in-place|script, startScript?}}, hidden: [address,
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
import json
import os
import sys

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
    if isinstance(resume_within_days, bool) or not isinstance(resume_within_days, (int, float)):
        _warn(address, "'resumeWithinDays' must be a number")
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

    return {
        "address": address, "machine": machine, "folder": folder,
        "resolvedFolder": _resolve_path(folder),
        "name": name.strip(), "description": description,
        "routesWhen": list(routes_when), "notFor": list(not_for),
        "extraInstructions": extra_instructions, "idle": idle,
        "resumeWithinDays": resume_within_days, "start": start,
        "startScript": start_script,
    }


def load_registry(path=None):
    """(globalInstructions, personas: {address: persona}, hidden: [addr]).

    Missing file -> empty registry, not an error. Unparseable file, wrong
    top-level shape, or an individual invalid persona entry -> that piece
    is skipped with a stderr log line; everything else still loads."""
    path = path or registry_path()
    if not os.path.exists(path):
        return dict(_EMPTY_REGISTRY, personas={}, hidden=[])

    try:
        with open(path) as f:
            raw = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        print(f"[personas] could not read/parse {path}: {e}", file=sys.stderr)
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

    return {"globalInstructions": global_instructions, "personas": personas, "hidden": hidden}


def offered_personas(registry):
    """Personas Jev/`/api/personas` may show: not hidden, and with a saved
    (non-empty) description — brief: "Jev never reads an unreviewed
    draft"."""
    hidden = set(registry.get("hidden") or [])
    return {addr: p for addr, p in (registry.get("personas") or {}).items()
            if addr not in hidden and (p.get("description") or "").strip()}


def resolve_persona_for_cwd(personas, machine, cwd):
    """The address of the persona whose folder contains `cwd` on `machine`
    — longest folder match wins, same machine only. None when `cwd`/
    `machine` is missing or nothing matches."""
    if not cwd or not machine:
        return None
    resolved_cwd = _resolve_path(cwd)
    best_addr, best_len = None, -1
    for addr, p in personas.items():
        if p["machine"] != machine:
            continue
        folder = p["resolvedFolder"]
        if resolved_cwd == folder or resolved_cwd.startswith(folder + os.sep):
            if len(folder) > best_len:
                best_len = len(folder)
                best_addr = addr
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
        if not addr or _resolve_path(root) != personas[addr]["resolvedFolder"]:
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
    exact = [r for r in rows_for_persona
             if _resolve_path(r.get("cwd")) == persona["resolvedFolder"]]
    if not exact:
        return None
    exact.sort(key=_recency_key)
    return resolve_agent_row_id(exact[0])


def get_personas_state():
    """GET /api/personas's payload: `[{name, address, description,
    routesWhen, notFor, idle, start, offline, mainRowId, sessionRowIds}]`.
    `offline` is true only for a configured REMOTE machine currently
    unreachable (`machines_status()` status "broken") — always false for
    "local"."""
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
        })
    return result
