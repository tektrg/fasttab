#!/usr/bin/env python3
"""Install / uninstall AgentBar's OpenCode plugin and Codex hooks.

  python3 dashboard/integrations/install.py install   [--tool opencode|codex|all] [--json]
  python3 dashboard/integrations/install.py uninstall [--tool ...] [--json]
  python3 dashboard/integrations/install.py status    [--tool ...] [--json]

MERGES, never rewrites: other vendors' entries (vibe-island, AgentPeek,
OpenIsland, ...) in ~/.codex/hooks.json and ~/.config/opencode/plugins/ are
left exactly as they are; only entries carrying our marker are added or
removed. Idempotent (a second install changes nothing). Every file it is
about to change is first copied to `<file>.bak-agentbar-<timestamp>`.

Config dirs: $OPENCODE_CONFIG_DIR (default ~/.config/opencode) and
$CODEX_HOME (default ~/.codex) — tests point both at temp dirs.
`--json` prints one object {ok, tools: {name: {installed, changed, detail}}}
for AgentBar Settings to read.
"""
import argparse
import json
import os
import shlex
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
OPENCODE_PLUGIN_SRC = os.path.join(HERE, "opencode", "agentbar-status.js")
OPENCODE_PLUGIN_NAME = "agentbar-status.js"
OPENCODE_MARKER = "agentbar-status-plugin-marker"
CODEX_HOOK_SRC = os.path.join(HERE, "codex", "agentbar-codex-hook.py")
CODEX_PERMISSION_SRC = os.path.join(HERE, "codex", "agentbar-codex-permission.py")
#: Every script of ours contains this; a hook entry is "ours" if its command does.
CODEX_MARKER = "agentbar-codex-"
CODEX_STATUS_MARKER = "agentbar-codex-hook.py"
CODEX_PERMISSION_MARKER = "agentbar-codex-permission.py"
#: Holds a prompt up to AGENTBAR_CODEX_HOLD_SEC (default 300s), so it needs room.
CODEX_PERMISSION_TIMEOUT_SEC = 3600
CODEX_EVENTS = ("SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
                "PostToolUse", "PermissionRequest", "PreCompact", "PostCompact",
                "Stop", "SubagentStart", "SubagentStop")
CODEX_HOOK_TIMEOUT_SEC = 5


def opencode_dir():
    return os.path.expanduser(os.environ.get("OPENCODE_CONFIG_DIR") or "~/.config/opencode")


def codex_dir():
    return os.path.expanduser(os.environ.get("CODEX_HOME") or "~/.codex")


def backup(path):
    """Copy `path` aside before changing it; returns the backup path."""
    stamp = time.strftime("%Y%m%d-%H%M%S")
    target = f"{path}.bak-agentbar-{stamp}"
    n = 1
    while os.path.exists(target):
        target = f"{path}.bak-agentbar-{stamp}-{n}"
        n += 1
    shutil.copy2(path, target)
    return target


def _write_atomic(path, text):
    tmp = path + ".agentbar-tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


# ── OpenCode: one plugin file of ours in plugins/ ──────────────────────────

def _opencode_target():
    return os.path.join(opencode_dir(), "plugins", OPENCODE_PLUGIN_NAME)


def _read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def opencode_status():
    target = _opencode_target()
    installed = os.path.isfile(target) and OPENCODE_MARKER in _read(target)
    return {"installed": installed, "changed": False, "detail": target}


def opencode_install():
    target = _opencode_target()
    wanted = _read(OPENCODE_PLUGIN_SRC)
    if os.path.lexists(target):
        if os.path.islink(target) or OPENCODE_MARKER not in _read(target):
            raise RuntimeError(f"{target} exists and is not ours; left untouched")
        if _read(target) == wanted:
            return {"installed": True, "changed": False, "detail": target}
        backup(target)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    _write_atomic(target, wanted)
    return {"installed": True, "changed": True, "detail": target}


def opencode_uninstall():
    target = _opencode_target()
    if not os.path.isfile(target) or os.path.islink(target) or OPENCODE_MARKER not in _read(target):
        return {"installed": False, "changed": False, "detail": target}
    backup(target)
    os.remove(target)
    return {"installed": False, "changed": True, "detail": target}


# ── Codex: our command entries merged into hooks.json ──────────────────────

def _codex_hooks_path():
    return os.path.join(codex_dir(), "hooks.json")


def codex_command(src=None):
    return f"python3 {shlex.quote(src or CODEX_HOOK_SRC)}"


def _codex_entries(event, command):
    """(marker, command, timeout) of each hook of ours on `event`: the status
    hook everywhere, plus the answering hook on PermissionRequest."""
    entries = [(CODEX_STATUS_MARKER, command, CODEX_HOOK_TIMEOUT_SEC)]
    if event == "PermissionRequest":
        entries.append((CODEX_PERMISSION_MARKER, codex_command(CODEX_PERMISSION_SRC),
                        CODEX_PERMISSION_TIMEOUT_SEC))
    return entries


def _is_ours(hook):
    return isinstance(hook, dict) and CODEX_MARKER in str(hook.get("command") or "")


def _load_hooks_file(path):
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as f:
        data = json.load(f)  # a broken file raises: never overwrite what we can't read
    if not isinstance(data, dict):
        raise RuntimeError(f"{path} is not a JSON object; left untouched")
    return data


def _event_has_ours(groups, marker=None):
    return any(_is_ours(h) and (marker is None or marker in str(h.get("command")))
               for g in groups if isinstance(g, dict) for h in (g.get("hooks") or []))


def merge_codex_hooks(data, command):
    """`data` with our entry on every event; theirs untouched. Returns (data, changed)."""
    hooks = data.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise RuntimeError("hooks.json 'hooks' is not an object; left untouched")
    changed = False
    for event in CODEX_EVENTS:
        groups = hooks.setdefault(event, [])
        if not isinstance(groups, list):
            raise RuntimeError(f"hooks.json '{event}' is not a list; left untouched")
        for marker, hook_command, timeout in _codex_entries(event, command):
            if _event_has_ours(groups, marker):
                continue
            groups.append({"hooks": [{"type": "command", "command": hook_command,
                                      "timeout": timeout}]})
            changed = True
    return data, changed


def remove_codex_hooks(data):
    """`data` without our entries (and without groups/events we emptied)."""
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        return data, False
    changed = False
    for event in list(hooks):
        groups = hooks[event]
        if not isinstance(groups, list) or not _event_has_ours(groups):
            continue
        kept_groups = []
        for group in groups:
            inner = group.get("hooks") if isinstance(group, dict) else None
            if not isinstance(inner, list) or not any(_is_ours(h) for h in inner):
                kept_groups.append(group)
                continue
            kept = [h for h in inner if not _is_ours(h)]
            if kept:
                kept_groups.append({**group, "hooks": kept})
        changed = True
        if kept_groups:
            hooks[event] = kept_groups
        else:
            del hooks[event]
    return data, changed


def _save_codex(path, data):
    if os.path.exists(path):
        backup(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    _write_atomic(path, json.dumps(data, indent=2) + "\n")


def codex_status():
    path = _codex_hooks_path()
    hooks = _load_hooks_file(path).get("hooks") or {}
    installed = isinstance(hooks, dict) and all(
        _event_has_ours(hooks.get(e) or [], marker)
        for e in CODEX_EVENTS for marker, _, _ in _codex_entries(e, ""))
    return {"installed": installed, "changed": False, "detail": path}


def codex_install():
    path = _codex_hooks_path()
    data, changed = merge_codex_hooks(_load_hooks_file(path), codex_command())
    if changed:
        _save_codex(path, data)
    return {"installed": True, "changed": changed, "detail": path}


def codex_uninstall():
    path = _codex_hooks_path()
    data, changed = remove_codex_hooks(_load_hooks_file(path))
    if changed:
        _save_codex(path, data)
    return {"installed": False, "changed": changed, "detail": path}


ACTIONS = {
    "opencode": {"install": opencode_install, "uninstall": opencode_uninstall,
                 "status": opencode_status},
    "codex": {"install": codex_install, "uninstall": codex_uninstall,
              "status": codex_status},
}


def run(action, tools):
    report = {"ok": True, "tools": {}}
    for tool in tools:
        try:
            report["tools"][tool] = ACTIONS[tool][action]()
        except Exception as e:  # noqa: BLE001  one tool's failure never blocks the other
            report["ok"] = False
            report["tools"][tool] = {"installed": None, "changed": False, "error": str(e)}
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("action", choices=("install", "uninstall", "status"))
    parser.add_argument("--tool", choices=("opencode", "codex", "all"), default="all")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    tools = list(ACTIONS) if args.tool == "all" else [args.tool]
    report = run(args.action, tools)
    if args.json:
        print(json.dumps(report))
    else:
        for tool, result in report["tools"].items():
            state = result.get("error") or (
                ("installed" if result["installed"] else "not installed")
                + (" (changed)" if result["changed"] else " (no change)"))
            print(f"{tool}: {state} — {result.get('detail', '')}")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
