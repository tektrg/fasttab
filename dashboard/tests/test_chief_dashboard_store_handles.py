#!/usr/bin/env python3
"""Direct-run test: BoardStore closes every sqlite connection it opens.

Regression for 2026-09-27: `with sqlite3.connect() as conn` never closes, so
the live server held ~40 chief-board.db handles 25 minutes after start. GC is
disabled here so a leak shows up deterministically instead of whenever the
cycle collector happens to run.
"""
import gc
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib"))

from chief_dashboard_store import BoardStore, resolve_agent_row_id  # noqa: E402

fails = []


def check(label, ok, detail=""):
    if not ok:
        fails.append(f"{label}: {detail}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label} {detail}")


def open_fd_count():
    """Open file descriptors of this process (macOS /dev/fd, Linux /proc)."""
    fd_dir = "/proc/self/fd" if os.path.isdir("/proc/self/fd") else "/dev/fd"
    return len(os.listdir(fd_dir))


def agent(session):
    return {
        "agentSession": session, "paneId": "w1:p2", "paneIdSanitized": "w1-p2",
        "label": "worker", "cwd": "/repo", "focused": False, "hookState": "idle",
    }


def one_cycle(store, agents, row_ids):
    """What one /api/state feed tick + a few requests do to the store."""
    store.build_session_board(agents)
    store.archived_map("session", row_ids)
    store.list_links()
    store.last_ladder_action(row_ids)
    store.session_action_annotations(row_ids)
    store.list_properties()
    store.list_views()


tempdir = tempfile.TemporaryDirectory()
store = BoardStore(os.path.join(tempdir.name, "chief-board.db"),
                   os.path.join(tempdir.name, "chief-board-schema.json"))
agents = [agent(f"sess-{i}") for i in range(5)]
row_ids = [resolve_agent_row_id(a) for a in agents]
store.log_session_action(row_ids[0], "stop", "test")

gc.collect()
gc.disable()
try:
    one_cycle(store, agents, row_ids)  # warm-up
    before = open_fd_count()
    for _ in range(50):
        one_cycle(store, agents, row_ids)
    after = open_fd_count()
finally:
    gc.enable()

check("fd count flat over 50 feed/request cycles", after <= before,
      f"(before={before} after={after})")

tempdir.cleanup()
if fails:
    print(f"\n{len(fails)} failure(s)")
    sys.exit(1)
print("\nall passed")
