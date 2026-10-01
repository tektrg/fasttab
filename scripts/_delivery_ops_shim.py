"""Find the delivery-ops plugin and run one of its scripts in this project.

WHY SHIMS EXIST
---------------
The delivery-ops mechanism (review loop, chief gates, the tick) moved out of this
repo into a plugin so every project can share one implementation. But roughly two
dozen places address it as `python3 scripts/deliver-notion.py …` — AGENTS.md, the
`deliver` workflow's agent prompts, `/chief`, and several memory notes.

`${CLAUDE_PLUGIN_ROOT}` is substituted for HOOK commands only, never for an
ordinary Bash call, so none of those call sites can address the plugin directly.
Rewriting all of them would be a large diff that breaks muscle memory and has to
be redone in every adopting project.

So the filenames stay exactly where they were and forward. Each shim holds no
logic at all — this module is the only place resolution lives — which is what
makes drift between shim and plugin impossible rather than merely unlikely.

A shim also settles the root question for good: it lives in the project, so it
KNOWS which project this is and exports `$CLAUDE_PROJECT_DIR` before handing over.
Every child process inherits it, so nothing downstream has to guess.
"""

from __future__ import annotations

import os
import runpy
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent

#: Optional explicit pointer, one line holding the plugin directory. For a layout
#: the search below cannot guess (a checkout somewhere unusual, a pinned version).
POINTER = PROJECT_ROOT / ".claude" / "delivery-ops-root"


def _candidates():
    """Plugin directories to try, most explicit first."""
    env = os.environ.get("DELIVERY_OPS_ROOT")
    if env:
        yield Path(env).expanduser()
    if POINTER.is_file():
        text = POINTER.read_text().strip()
        if text:
            yield Path(text).expanduser()
    home = Path.home() / ".claude"
    # Personal-scope / dev install: a symlink into the checkout, so edits are live.
    yield home / "skills" / "delivery-ops"
    # Marketplace install: copied into the cache, possibly under a version dir.
    cache = home / "plugins" / "cache"
    for pattern in ("*/delivery-ops", "*/delivery-ops/*"):
        yield from sorted(cache.glob(pattern), reverse=True)


def plugin_root() -> Path:
    for candidate in _candidates():
        if (candidate / "scripts" / "delivery_ops_config.py").is_file():
            return candidate.resolve()
    raise SystemExit(
        "delivery-ops plugin not found. Install it one of these ways:\n"
        "  ln -s <checkout>/plugins/delivery-ops ~/.claude/skills/delivery-ops\n"
        "  /plugin marketplace add tektrg/agent-skills   (then install delivery-ops)\n"
        "  echo <path> > .claude/delivery-ops-root\n"
        f"Searched from {PROJECT_ROOT}."
    )


def forward(script: str) -> None:
    """Run the plugin's `scripts/<script>` as if it were this file."""
    scripts_dir = plugin_root() / "scripts"
    target = scripts_dir / script
    if not target.is_file():
        raise SystemExit(f"delivery-ops plugin has no scripts/{script} ({scripts_dir})")
    # The one thing a shim knows that the plugin cannot: which project this is.
    os.environ.setdefault("CLAUDE_PROJECT_DIR", str(PROJECT_ROOT))
    sys.path.insert(0, str(scripts_dir))
    sys.argv[0] = str(target)
    runpy.run_path(str(target), run_name="__main__")
