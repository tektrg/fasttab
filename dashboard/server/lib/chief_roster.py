#!/usr/bin/env python3
"""Desktop chiefs: which Claude Desktop session is a chief, and its workers.

Chief redesign rollout item 12 (plan: agent-skills
`plugins/delivery-ops/docs/2026-11-26-chief-redesign-plan.md`).

A CHIEF FOLDER is `<project root>/.claude/chief/<name>/` holding
  * `brief.md`    - the user-owned focus doc. Its header names the chief
                    session (`Session: local_<uuid>`), and its "## Roster"
                    section lists the workers' Desktop session ids.
  * `config.yaml` - optional, flat `key: value` lines (no nesting, no lists):
                    `session` (overrides the brief's), `checkin_cron`,
                    `checkin_marker`, `wake` (on|off). Read by
                    chief_checkin.py; this module only passes it through.

Workers of a Desktop chief = the union of
  1. Desktop "linked sessions": every session whose `spawnedFrom` chain
     reaches the chief (a worker's own side session nests under the chief
     too: the tree is two levels only), and
  2. the brief's roster ids (full `local_<uuid>`, or a unique prefix the
     chief shortened with an ellipsis, `local_485c3041…`).

Where chief folders are looked for: every `~/01_Project/*/` (the portfolio
layout agent_tree.project_for_cwd already assumes), or env `CHIEF_HOMES`
(os.pathsep list of project roots; tests).

Pure except `ChiefFolderReader.read` (filesystem, mtime-cached).
"""
import glob
import os
import re
import stat

import claude_sessions

CHIEF_HOMES_ENV = "CHIEF_HOMES"
_DEFAULT_HOME_GLOB = "~/01_Project/*"
_CHIEF_SUBDIR = os.path.join(".claude", "chief")
BRIEF_NAME = "brief.md"
CONFIG_NAME = "config.yaml"
#: A brief or config bigger than this is not one; never read into memory.
MAX_FILE_BYTES = 512 * 1024
#: `spawnedFrom` hops walked up to find a chief (worker -> its side session ...).
MAX_LINK_DEPTH = 4

_SESSION_LINE_RE = re.compile(r"\bSession:\s*(local_[A-Za-z0-9-]{1,64})")
_LOCAL_ID_RE = re.compile(r"local_[A-Za-z0-9-]{1,64}(?:…|\.\.\.)?")
_ROSTER_HEADING_RE = re.compile(r"^##\s+Roster\b", re.IGNORECASE)
#: Shortest prefix accepted for an ellipsis-shortened id (`local_` + 8 hex).
_MIN_PREFIX_LEN = len("local_") + 8


# ── parsing (pure) ─────────────────────────────────────────────────────────

def parse_config_yaml(text):
    """Flat `key: value` lines -> {key: value-string}. Blank lines and `#`
    comments are skipped; a value may be single/double quoted (a `#` inside
    quotes is kept). Anything nested or malformed is ignored, never raised:
    a typo costs that one line."""
    out = {}
    for raw in (text or "").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or ":" not in line or raw[:1].isspace():
            continue
        key, _, value = line.partition(":")
        key = key.strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            continue
        value = value.strip()
        if value[:1] in ("'", '"'):
            quote = value[0]
            end = value.find(quote, 1)
            value = value[1:end] if end > 0 else value[1:]
        else:
            value = value.split(" #", 1)[0].strip()
        out[key] = value
    return out


def parse_brief(text):
    """{"sessionId": str|None, "rosterIds": [full ids], "rosterPrefixes":
    [prefixes]} from a brief. The chief session is the first `Session:
    local_…` line; roster ids come only from the `## Roster` section (up to
    the next `## ` heading), so ids mentioned in prose elsewhere never
    become workers."""
    text = text or ""
    m = _SESSION_LINE_RE.search(text)
    session_id = m.group(1) if m else None
    roster_ids, prefixes = [], []
    in_roster = False
    for line in text.splitlines():
        if line.startswith("## "):
            in_roster = bool(_ROSTER_HEADING_RE.match(line))
            continue
        if not in_roster:
            continue
        for token in _LOCAL_ID_RE.findall(line):
            if token.endswith("…") or token.endswith("..."):
                prefix = token.rstrip(".…")
                if len(prefix) >= _MIN_PREFIX_LEN and prefix not in prefixes:
                    prefixes.append(prefix)
            elif token not in roster_ids:
                roster_ids.append(token)
    return {"sessionId": session_id, "rosterIds": roster_ids, "rosterPrefixes": prefixes}


def chief_key(project_root, name):
    """Stable key of a chief: `<project folder>/<chief name>` (ssv-shared/digital)."""
    return f"{os.path.basename(project_root.rstrip('/'))}/{name}"


def make_chief_def(project_root, name, brief_text, config_text):
    """One chief folder's definition (pure)."""
    brief = parse_brief(brief_text)
    config = parse_config_yaml(config_text)
    session = config.get("session") or brief["sessionId"]
    if session and not claude_sessions.DESKTOP_SESSION_ID_RE.fullmatch(session):
        session = None
    folder = os.path.join(project_root, _CHIEF_SUBDIR, name)
    return {
        "key": chief_key(project_root, name),
        "name": name,
        "project": os.path.basename(project_root.rstrip("/")),
        "projectRoot": project_root,
        "dir": folder,
        "briefPath": os.path.join(folder, BRIEF_NAME) if brief_text is not None else None,
        "desktopSessionId": session,
        "rosterIds": brief["rosterIds"],
        "rosterPrefixes": brief["rosterPrefixes"],
        "config": config,
    }


# ── building (pure) ────────────────────────────────────────────────────────

def build_desktop_chiefs(chief_defs, desktop_sessions):
    """[{**chief_def, "session": record|None, "children": [records]}], one per
    chief def that names a Desktop session. `desktop_sessions` is
    desktop_sessions.DesktopSessionScanner.scan()'s output (non-archived,
    recent). `session` None = the chief's session is archived, deleted or
    idle past the scan window ("gone": no wakes, shown as such).

    A worker claimed by two chiefs goes to the first (defs are sorted by key,
    so it is stable). A chief's own session is never its own child, and a
    session that is itself a chief never nests under another."""
    by_id = {s["desktopSessionId"]: s for s in desktop_sessions or [] if s.get("desktopSessionId")}
    chief_ids = {d["desktopSessionId"] for d in chief_defs if d.get("desktopSessionId")}
    claimed = set()
    out = []
    for d in sorted(chief_defs, key=lambda d: d["key"]):
        chief_id = d.get("desktopSessionId")
        if not chief_id:
            continue
        member_ids = []
        for sid, rec in by_id.items():
            if _reaches(sid, chief_id, by_id):
                member_ids.append(sid)
        member_ids.extend(i for i in d.get("rosterIds") or [] if i in by_id)
        for prefix in d.get("rosterPrefixes") or []:
            hits = [sid for sid in by_id if sid.startswith(prefix)]
            if len(hits) == 1:
                member_ids.append(hits[0])
        children = []
        for sid in member_ids:
            if sid == chief_id or sid in chief_ids or sid in claimed:
                continue
            claimed.add(sid)
            children.append(by_id[sid])
        children.sort(key=lambda s: -(s.get("lastActiveTs") or 0))
        out.append(dict(d, session=by_id.get(chief_id), children=children))
    return out


def _reaches(session_id, chief_id, by_id):
    """True when `session_id`'s spawnedFrom chain reaches `chief_id`
    within MAX_LINK_DEPTH hops (a cycle stops at the depth cap)."""
    current = (by_id.get(session_id) or {}).get("parentDesktopId")
    for _ in range(MAX_LINK_DEPTH):
        if not current:
            return False
        if current == chief_id:
            return True
        current = (by_id.get(current) or {}).get("parentDesktopId")
    return False


# ── filesystem ─────────────────────────────────────────────────────────────

def default_homes():
    override = os.environ.get(CHIEF_HOMES_ENV)
    if override is not None:
        return [h for h in override.split(os.pathsep) if h]
    return sorted(glob.glob(os.path.expanduser(_DEFAULT_HOME_GLOB)))


def _read_small(path):
    """Text of a regular, non-symlink file under MAX_FILE_BYTES, else None."""
    try:
        st = os.lstat(path)
    except OSError:
        return None
    if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_FILE_BYTES:
        return None
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def _mtime(path):
    try:
        return os.lstat(path).st_mtime
    except OSError:
        return None


class ChiefFolderReader:
    """Every chief folder's definition, cached by (brief mtime, config
    mtime). One instance per server; `read` is cheap enough for every
    agent-tree build (a glob + two stats per chief folder)."""

    def __init__(self, homes=None):
        self._homes = homes
        self._cache = {}  # folder -> ((brief mtime, config mtime), def)

    def read(self):
        homes = self._homes if self._homes is not None else default_homes()
        defs, seen = [], {}
        for root in homes:
            base = os.path.join(root, _CHIEF_SUBDIR)
            try:
                entries = sorted(os.scandir(base), key=lambda e: e.name)
            except OSError:
                continue
            for entry in entries:
                if not entry.is_dir(follow_symlinks=False) or entry.name.startswith("."):
                    continue
                brief_path = os.path.join(entry.path, BRIEF_NAME)
                config_path = os.path.join(entry.path, CONFIG_NAME)
                stamp = (_mtime(brief_path), _mtime(config_path))
                if stamp == (None, None):
                    continue
                cached = self._cache.get(entry.path)
                if cached and cached[0] == stamp:
                    chief = cached[1]
                else:
                    chief = make_chief_def(root.rstrip("/"), entry.name,
                                           _read_small(brief_path), _read_small(config_path))
                seen[entry.path] = (stamp, chief)
                defs.append(chief)
        self._cache = seen
        return defs
