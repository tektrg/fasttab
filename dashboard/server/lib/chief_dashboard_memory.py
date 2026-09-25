#!/usr/bin/env python3
"""Measured per-pane memory for the chief dashboard (v3 reclaim, phase 5).

For each agent row, sums RSS across the pane's foreground process tree:

  herdr pane process-info --pane <paneId>
    -> result.process_info.foreground_processes[].pid   # the agent process
  ONE `ps -eo pid=,ppid=,rss=` for the whole machine -> ppid->children map,
  walk each root. One `ps` call serves all panes — never shell out per pane.

Rules (from the brief):
  - Root the walk at the FOREGROUND pids (the agent), not shell_pid.
  - Sample on a ~15s cadence in a background thread; the 2s render tick only
    reads the cache and must stay cheap.
  - Unmeasurable rows read None (the UI renders `—`, never `0` — an
    unmeasurable reading must never sort as "cheapest to keep").
  - RSS double-counts shared pages, so the sum overstates. Valid for ranking,
    wrong as an absolute — the column carries that caveat visibly.

This module is deliberately separate from chief_dashboard_feeds.py /
chief_dashboard_views.py (the pure layer four phases depend on — HARD RULE:
do not modify them). The server enriches agents from the cache here.
"""

import subprocess
import threading
import time

import chief_dashboard_herdr as herdr_transport

try:
    from chief_dashboard_feeds import REPO_ROOT
except Exception:  # pragma: no cover - direct-run tests stub this
    import os
    REPO_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "..", "..")

#: Refresh cadence for the background sampler. The render tick is 2s.
SAMPLE_INTERVAL_SEC = 15

#: `ps` reports RSS in 1K blocks on macOS and KiB on Linux — both are 1024
#: bytes per unit for our purposes.
RSS_UNIT_BYTES = 1024


def format_bytes(n):
    """Render a byte count the way the column shows it (`2.1 GB`)."""
    if n is None:
        return None
    n = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{int(n)} B"
        n /= 1024
    return f"{n:.1f} TB"  # unreachable, keeps linters calm


def parse_ps(output):
    """Parse `ps -eo pid=,ppid=,rss=` into ({pid: ppid}, {pid: rss_bytes})."""
    ppid_of, rss_of = {}, {}
    for line in (output or "").splitlines():
        parts = line.split()
        if len(parts) != 3:
            continue
        try:
            pid, ppid, rss = int(parts[0]), int(parts[1]), int(parts[2])
        except ValueError:
            continue
        ppid_of[pid] = ppid
        rss_of[pid] = rss * RSS_UNIT_BYTES
    return ppid_of, rss_of


def sum_tree(roots, ppid_of, rss_of):
    """Sum RSS over `roots` plus all descendants. Unknown pids contribute
    nothing; a root with no readable pids at all returns None (unmeasurable,
    never 0)."""
    children = {}
    for pid, ppid in ppid_of.items():
        children.setdefault(ppid, []).append(pid)
    total, seen_any = 0, False
    stack = [r for r in (roots or []) if r is not None]
    visited = set()
    while stack:
        pid = stack.pop()
        if pid in visited:
            continue
        visited.add(pid)
        if pid in rss_of:
            total += rss_of[pid]
            seen_any = True
        stack.extend(children.get(pid, ()))
    return total if seen_any else None


def _pane_foreground_pids(pane_id, timeout=10):
    """Foreground pids for one pane (the agent process). Empty = the pane
    sits at a shell prompt or is unreadable; both read as unmeasurable.

    Local-only by design (R16): RSS is a `ps` walk of THIS Mac's process
    tree, so a remote row is never measurable — it gets memoryBytes=None,
    never a value read off the wrong machine's pids."""
    try:
        data = herdr_transport.herdr_cmd_json(
            "local", ["pane", "process-info", "--pane", pane_id],
            repo_root=REPO_ROOT, timeout=timeout)
    except herdr_transport.HerdrError:
        return []
    info = (data.get("result") or {}).get("process_info") or {}
    out = []
    for fp in info.get("foreground_processes") or []:
        try:
            out.append(int(fp.get("pid")))
        except (TypeError, ValueError):
            continue
    return out


def _read_ps(timeout=15):
    proc = subprocess.run(
        ["ps", "-eo", "pid=,ppid=,rss="],
        timeout=timeout, capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"ps exited {proc.returncode}")
    return proc.stdout


class MemorySampler:
    """Background ~15s sampler. `snapshot()` is the cheap read the render
    tick uses; `sample_once()` does one full pass (used by the thread and by
    tests with injected fns)."""

    def __init__(self, pane_ids_fn=None, proc_info_fn=None, ps_fn=None,
                 interval=SAMPLE_INTERVAL_SEC):
        self._pane_ids_fn = pane_ids_fn
        self._proc_info_fn = proc_info_fn or _pane_foreground_pids
        self._ps_fn = ps_fn or _read_ps
        self.interval = interval
        self._lock = threading.Lock()
        self._cache = {}  # pane_id -> bytes | None
        self._last_sample_ts = None
        self._thread = None
        self._stop = threading.Event()

    def start(self):
        if self._thread is not None:
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._loop, daemon=True,
                                        name="memory-sampler")
        self._thread.start()

    def stop(self):
        self._stop.set()

    def _loop(self):
        while not self._stop.is_set():
            try:
                self.sample_once()
            except Exception:
                pass
            self._stop.wait(self.interval)

    def sample_once(self, pane_ids=None):
        ids = list(pane_ids) if pane_ids is not None else self._live_pane_ids()
        roots = {}
        for pid in ids:
            try:
                roots[pid] = self._proc_info_fn(pid)
            except Exception:
                roots[pid] = []
        try:
            ppid_of, rss_of = parse_ps(self._ps_fn())
        except Exception:
            ppid_of, rss_of = {}, {}
        now_cache = {}
        for pane_id, fg in roots.items():
            now_cache[pane_id] = sum_tree(fg, ppid_of, rss_of) if fg else None
        with self._lock:
            self._cache = now_cache
            self._last_sample_ts = time.time()
        return dict(now_cache)

    def _live_pane_ids(self):
        if self._pane_ids_fn is not None:
            try:
                return list(self._pane_ids_fn() or [])
            except Exception:
                return []
        # Default: fresh `herdr pane list` on THIS Mac — the live feed is
        # the truth for which panes exist, never a stored list. Local-only
        # (see _pane_foreground_pids); remote panes are never RSS-sampled.
        try:
            data = herdr_transport.herdr_cmd_json(
                "local", ["pane", "list"], repo_root=REPO_ROOT, timeout=10)
            panes = (data.get("result") or {}).get("panes") or []
            return [p.get("pane_id") for p in panes if p.get("pane_id")]
        except Exception:
            return []

    def snapshot(self):
        """pane_id -> bytes | None. Cheap: no subprocess, lock only."""
        with self._lock:
            return dict(self._cache)

    def age_sec(self, now=None):
        with self._lock:
            ts = self._last_sample_ts
        if ts is None:
            return None
        return (now if now is not None else time.time()) - ts


SAMPLER = MemorySampler()
