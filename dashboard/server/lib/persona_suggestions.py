#!/usr/bin/env python3
"""GET /api/personas/suggestions (Jev persona routing P4 — brief sections
"Registry" + "Description fallback").

Folders where Claude sessions ran recently, offered in AgentBar Settings as
"Adopt as persona?". Local host only (the brief's remote host comes later).

- Source: every `~/.claude/projects/*/*.jsonl` (override
  `CLAUDE_PROJECTS_DIR`) modified in the last `SUGGESTION_WINDOW_DAYS`. The
  session's `cwd` is the first `"cwd"` field in the file's head (never the
  whole file: transcripts reach 100MB+).
- Each cwd folds to its git root; a git worktree (`.git` is a file pointing
  at `<main>/.git/worktrees/<name>`) folds to its main repo. A cwd outside
  any repo stays as is.
- Excluded: temp folders outside home (`/private/tmp`, `/tmp`, `/var/folders`), any path
  with a `scratchpad` component, the home folder itself and `/`, folders
  that no longer exist, existing personas (any, hidden or not) and hidden
  addresses.
- `draftDescription`: the folder's `AGENTS.md`, else `CLAUDE.md` — its
  opening heading plus first paragraph. Read-only, first 64KB only. Settings
  pre-fills it for the user to edit; it is never saved or offered unedited
  by this module.

Every folder here is read only. Nothing in this module writes anything.
"""
import glob
import json
import os
import re
import time

import persona_start
import personas

SUGGESTION_WINDOW_DAYS = 30
_HEAD_BYTES = 64 * 1024
_DRAFT_MAX_CHARS = 600
_EXCLUDED_PREFIXES = ("/private/tmp", "/tmp", "/private/var/folders", "/var/folders")
_INSTRUCTION_FILES = ("AGENTS.md", "CLAUDE.md")
_CONTROL_CHARS_RE = re.compile(r"[\x00-\x1f\x7f]")

#: transcript path -> cwd (None = no cwd found). A session's cwd never
#: changes, so the head is read once per file for the life of the process.
_cwd_by_transcript = {}


def _cwd_of_transcript(path):
    if path in _cwd_by_transcript:
        return _cwd_by_transcript[path]
    cwd = None
    try:
        with open(path, "rb") as f:
            head = f.read(_HEAD_BYTES)
    except OSError:
        return None
    for line in head.splitlines():
        try:
            entry = json.loads(line)
        except (ValueError, UnicodeDecodeError):
            continue
        if isinstance(entry, dict) and isinstance(entry.get("cwd"), str) and entry["cwd"]:
            cwd = entry["cwd"]
            break
    _cwd_by_transcript[path] = cwd
    return cwd


def git_root_for(folder):
    """The repo a folder belongs to: its git root, or — for a worktree —
    the main checkout. A folder in no repo is returned unchanged."""
    current = folder
    while True:
        dot_git = os.path.join(current, ".git")
        if os.path.isdir(dot_git):
            return current
        if os.path.isfile(dot_git):
            return _main_repo_of_worktree(dot_git) or current
        parent = os.path.dirname(current)
        if parent == current:
            return folder
        current = parent


def _main_repo_of_worktree(dot_git_file):
    try:
        with open(dot_git_file) as f:
            first_line = f.readline().strip()
    except OSError:
        return None
    if not first_line.startswith("gitdir:"):
        return None
    gitdir = first_line[len("gitdir:"):].strip()
    marker = os.sep + ".git" + os.sep + "worktrees" + os.sep
    if marker not in gitdir:
        return None
    return os.path.realpath(gitdir.split(marker, 1)[0])


def is_excluded_folder(folder):
    home = os.path.realpath(os.path.expanduser("~"))
    if folder in (home, os.sep):
        return True
    under_home = folder.startswith(home + os.sep)  # a test's fake home may itself sit in a temp dir
    if not under_home and any(folder == p or folder.startswith(p + os.sep) for p in _EXCLUDED_PREFIXES):
        return True
    return "scratchpad" in folder.split(os.sep)


def address_for_folder(folder):
    """`local:~/…` for a folder under home (same shape as the hand-written
    pilots), else `local:<absolute path>`."""
    home = os.path.realpath(os.path.expanduser("~"))
    if folder.startswith(home + os.sep):
        return "local:~" + folder[len(home):]
    return "local:" + folder


def draft_description(folder):
    """Opening heading + first paragraph of the folder's AGENTS.md, else
    CLAUDE.md; "" when neither has usable text."""
    for filename in _INSTRUCTION_FILES:
        try:
            with open(os.path.join(folder, filename), encoding="utf-8", errors="replace") as f:
                text = f.read(_HEAD_BYTES)
        except OSError:
            continue
        draft = _heading_and_first_paragraph(text)
        if draft:
            return draft
    return ""


def _heading_and_first_paragraph(text):
    heading, paragraph, in_code = "", [], False
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if line.startswith("```"):
            in_code = not in_code
            if paragraph:
                break
            continue
        if in_code:
            continue
        if line.startswith("#"):
            if paragraph:
                break
            if not heading:
                heading = line.lstrip("#").strip()
            continue
        if not line:
            if paragraph:
                break
            continue
        if line.startswith("@") or line.startswith("<!--"):
            continue  # a CLAUDE.md import / comment is not a description
        paragraph.append(line)
    parts = [p for p in (heading, " ".join(paragraph)) if p]
    draft = _CONTROL_CHARS_RE.sub(" ", " — ".join(parts)).strip()
    if len(draft) > _DRAFT_MAX_CHARS:
        draft = draft[: _DRAFT_MAX_CHARS - 1].rstrip() + "…"
    return draft


def _recent_session_folders(projects_dir, now):
    """{repo folder: (sessionCount, lastActive epoch)} from recent transcripts."""
    cutoff = now - SUGGESTION_WINDOW_DAYS * 86400
    folders = {}
    for path in glob.glob(os.path.join(projects_dir, "*", "*.jsonl")):
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            continue
        if mtime < cutoff:
            continue
        cwd = _cwd_of_transcript(path)
        if not cwd:
            continue
        folder = git_root_for(os.path.realpath(os.path.expanduser(cwd)))
        count, last = folders.get(folder, (0, 0))
        folders[folder] = (count + 1, max(last, mtime))
    return folders


def _taken_folders(registry):
    """Resolved folders of every registry persona and every hidden address
    (local machine only — suggestions are local-host only)."""
    taken = {p["resolvedFolder"] for p in registry["personas"].values() if p["machine"] == "local"}
    for address in registry.get("hidden") or []:
        machine, _, folder = address.partition(":")
        if machine == "local" and folder:
            taken.add(personas._resolve_path(folder))
    return taken


def get_suggestions(registry=None, projects_dir=None, now=None):
    """The endpoint's payload: `[{address, lastActive, sessionCount,
    draftDescription}]`, most recently active first. `lastActive` is epoch
    seconds."""
    registry = registry or personas.load_registry()
    projects_dir = projects_dir or persona_start.claude_projects_dir()
    now = time.time() if now is None else now
    taken = _taken_folders(registry)
    rows = []
    for folder, (count, last) in _recent_session_folders(projects_dir, now).items():
        if folder in taken or is_excluded_folder(folder) or not os.path.isdir(folder):
            continue
        rows.append({"address": address_for_folder(folder), "lastActive": last,
                     "sessionCount": count, "draftDescription": draft_description(folder)})
    rows.sort(key=lambda r: (-r["lastActive"], r["address"]))
    return rows
