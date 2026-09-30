#!/usr/bin/env python3
"""P0 dashboard move (design call #1): splits the old single AptusFit-
hardcoded REPO_ROOT into three explicit things, so this server can run from
ANY checkout (command-bar-macos) while still pointing its herdr/pane reads
at the actual project(s) that have live Claude Code sessions.

  - DASHBOARD_HOME  — this dashboard/ folder (code, built UI). Never
                       configurable; it is wherever this checkout lives.
  - config.json     — ~/.config/agent-dashboard/config.json: `machines`
                       (the Air/remote config), `projectRoots` (a list; v1
                       default is just AptusFit), `port`.
  - state dir       — ~/Library/Application Support/agent-dashboard/: the
                       board db + its schema export. Nothing else writes
                       here yet in P0.

Env overrides (a second instance on a spare port, or a test): both
directories can be redirected with CHIEF_DASHBOARD_CONFIG_HOME /
CHIEF_DASHBOARD_STATE_HOME. CHIEF_DASHBOARD_MACHINES (tests; see
chief_dashboard_herdr.load_machines_config) and CHIEF_DASHBOARD_PORT/_HOST
(chief_dashboard_feeds.py) are unaffected by this module — those stay exactly
as they were.

P0 SCOPE NOTE (flagged, not fixed here): `projectRoots` is accepted as a
list, but only PROJECT_ROOTS[0] (LOCAL_REPO_ROOT) is actually consulted
anywhere below — every call site this replaces (herdr cwd, the machines-
config fallback file, the pane-tick-cache.json read) was single-project
before this move and stays single-project now. A real multi-project
dashboard needs those call sites taught to loop PROJECT_ROOTS and merge;
deferred to P1. See dashboard/AGENTS.md.
"""
import json
import os

LIB_DIR = os.path.dirname(os.path.abspath(__file__))
SERVER_DIR = os.path.dirname(LIB_DIR)
DASHBOARD_HOME = os.path.dirname(SERVER_DIR)

CONFIG_HOME = (os.environ.get("CHIEF_DASHBOARD_CONFIG_HOME")
               or os.path.expanduser("~/.config/agent-dashboard"))
CONFIG_PATH = os.path.join(CONFIG_HOME, "config.json")

STATE_HOME = (os.environ.get("CHIEF_DASHBOARD_STATE_HOME")
              or os.path.expanduser("~/Library/Application Support/agent-dashboard"))

#: v1 default: the one project this was built against and still the only
#: one anything here actually reads from (see the P0 scope note above).
DEFAULT_PROJECT_ROOTS = [os.path.expanduser("~/01_Project/AptusFit")]
DEFAULT_PORT = 4711

#: Legacy per-project machines file (today's exact behaviour, read straight
#: off a project root rather than the new shared config.json) — kept as the
#: fallback so an install with no config.json yet behaves exactly as before
#: this move. See _load_machines below.
_LEGACY_MACHINES_RELPATH = os.path.join(".claude", "dashboard-machines.json")


def load_config(path=None):
    """(machines, projectRoots, port, error) from config.json.

    A missing/unreadable file is not an error — it's "no config yet",
    exactly like load_machines_config's own missing-file rule — so callers
    boot on defaults (AptusFit, port 4711, machines resolved by the legacy
    fallback below) rather than refuse to start."""
    path = path or CONFIG_PATH
    raw = {}
    error = None
    if os.path.exists(path):
        try:
            with open(path) as f:
                raw = json.load(f) or {}
            if not isinstance(raw, dict):
                error = f"expected a JSON object in {path}, got {type(raw).__name__}"
                raw = {}
        except (OSError, json.JSONDecodeError) as e:
            error = f"could not parse {path}: {e}"
            raw = {}
    roots = raw.get("projectRoots") or DEFAULT_PROJECT_ROOTS
    roots = [os.path.expanduser(str(r)) for r in roots if r]
    if not roots:
        roots = DEFAULT_PROJECT_ROOTS
    return {
        "machines": raw.get("machines") if isinstance(raw.get("machines"), dict) else {},
        "projectRoots": roots,
        "port": int(raw.get("port") or DEFAULT_PORT),
        "localLabel": raw.get("localLabel") if isinstance(raw.get("localLabel"), str) and raw.get("localLabel").strip() else DEFAULT_LOCAL_LABEL,
        "configError": error,
    }


def _load_machines(project_roots, raw_machines):
    """(machines_dict, error) — config.json's own "machines" key wins when
    present; otherwise the legacy per-project file at
    <projectRoots[0]>/.claude/dashboard-machines.json (today's exact
    lookup), so nothing needs a config.json to keep working. Either way,
    CHIEF_DASHBOARD_MACHINES (tests) still takes priority — enforced by
    load_machines_config itself, which every path below eventually calls."""
    import chief_dashboard_herdr as herdr_transport  # local import: avoid a cycle
    env_override = os.environ.get("CHIEF_DASHBOARD_MACHINES")
    if env_override is not None:
        return herdr_transport.parse_machines_config(env_override)
    if raw_machines:
        return herdr_transport.parse_machines_config(json.dumps(raw_machines))
    fallback_root = project_roots[0] if project_roots else None
    if not fallback_root:
        return {}, None
    return herdr_transport.load_machines_config(fallback_root)


#: Display name of the machine this dashboard runs on (machine id "local" is
#: relative to the dashboard, so a UI needs a real name like "Pro" for it).
DEFAULT_LOCAL_LABEL = "This Mac"

_CONFIG = load_config()
PROJECT_ROOTS = _CONFIG["projectRoots"]
CONFIG_ERROR = _CONFIG["configError"]
PORT_FROM_CONFIG = _CONFIG["port"]

#: The one local project root herdr commands run against today — cwd for
#: local `herdr` invocations, base for the legacy machines-config file, base
#: for the pane-tick-cache.json read. See the P0 scope note above.
LOCAL_REPO_ROOT = PROJECT_ROOTS[0] if PROJECT_ROOTS else DASHBOARD_HOME

MACHINES, MACHINES_CONFIG_ERROR = _load_machines(PROJECT_ROOTS, _CONFIG["machines"])
if CONFIG_ERROR and not MACHINES_CONFIG_ERROR:
    MACHINES_CONFIG_ERROR = CONFIG_ERROR

LOCAL_MACHINE_LABEL = _CONFIG["localLabel"].strip()


def machine_choices():
    """[{id, label}] a persona can run on: "local" (this dashboard's own
    Mac) first, then every configured remote machine."""
    return [{"id": "local", "label": LOCAL_MACHINE_LABEL}] + [
        {"id": name, "label": cfg["label"]} for name, cfg in MACHINES.items()]
