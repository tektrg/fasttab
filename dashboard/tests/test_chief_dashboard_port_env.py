#!/usr/bin/env python3
"""HOST/PORT in chief_dashboard_feeds.py are read at import time, so this
runs each case in its OWN subprocess — the only way to prove a fresh import
sees a given environment without polluting this process's already-imported
module cache.

Why this exists: Slice 6 verifies against the real Air through a SECOND
dashboard instance on a spare port, run from this worktree, WITHOUT ever
touching the live :4711 instance. That needs the server to actually listen
on an overridden port; watch-worker-events.py already reads
CHIEF_DASHBOARD_PORT on the client side, but the server hardcoded 4711
until this change — the env var did nothing.
"""
import os
import subprocess
import sys

DASHBOARD_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB_DIR = os.path.join(DASHBOARD_DIR, "server", "lib")

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def host_port(env_overrides):
    env = dict(os.environ)
    env.pop("CHIEF_DASHBOARD_HOST", None)
    env.pop("CHIEF_DASHBOARD_PORT", None)
    env.update(env_overrides)
    out = subprocess.run(
        [sys.executable, "-c",
         f"import sys; sys.path.insert(0, {LIB_DIR!r}); "
         "import chief_dashboard_feeds as f; print(f.HOST, f.PORT)"],
        env=env, capture_output=True, text=True, timeout=15, cwd=DASHBOARD_DIR,
    )
    assert out.returncode == 0, out.stderr
    host, port = out.stdout.strip().split()
    return host, int(port)


print("== no override: byte-identical default (127.0.0.1:4711) ==")
host, port = host_port({})
check("default host", host, "127.0.0.1")
check("default port", port, 4711)

print("== CHIEF_DASHBOARD_PORT overrides the port only ==")
host, port = host_port({"CHIEF_DASHBOARD_PORT": "4799"})
check("host unchanged", host, "127.0.0.1")
check("port overridden", port, 4799)

print("== CHIEF_DASHBOARD_HOST overrides the host too (both settable) ==")
host, port = host_port({"CHIEF_DASHBOARD_HOST": "127.0.0.2",
                         "CHIEF_DASHBOARD_PORT": "4799"})
check("host overridden", host, "127.0.0.2")
check("port overridden", port, 4799)

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("All HOST/PORT env-override checks passed.")
