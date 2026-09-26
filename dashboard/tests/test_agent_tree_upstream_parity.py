#!/usr/bin/env python3
"""Drift guard: server/lib/agent_tree.py must stay byte-identical to
AptusFit's scripts/lib/agent_tree.py.

Both copies write the SAME file (~/.claude/agent-tree.json): AptusFit's
launch/report/heartbeat scripts through theirs, this dashboard's attach/
detach through this one. When the copies drifted (2026-09-26), this
dashboard's older prune rules deleted live Air workers' edges that
AptusFit's rules keep. Fix drift by copying AptusFit's file over this one
(after pulling AptusFit), never by editing this copy on its own.

Upstream path: $AGENT_TREE_UPSTREAM, else ~/01_Project/AptusFit/scripts/lib/
agent_tree.py. No upstream checkout on this machine -> SKIP, not a failure.
"""
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LOCAL = HERE.parent / "server" / "lib" / "agent_tree.py"
UPSTREAM = Path(os.environ.get("AGENT_TREE_UPSTREAM") or
                Path.home() / "01_Project" / "AptusFit" / "scripts" / "lib" / "agent_tree.py")

if not UPSTREAM.is_file():
    print(f"  SKIP  no upstream agent_tree.py at {UPSTREAM}")
    sys.exit(0)

if LOCAL.read_bytes() == UPSTREAM.read_bytes():
    print(f"  PASS  agent_tree.py matches {UPSTREAM}")
    sys.exit(0)

print(f"  FAIL  agent_tree.py differs from {UPSTREAM}\n"
      f"        sync: pull AptusFit to its latest main first (a stale checkout\n"
      f"        also fails here), then cp {UPSTREAM} {LOCAL}\n"
      f"        and port any new tests from AptusFit's scripts/tests/test_agent_tree.py")
sys.exit(1)
