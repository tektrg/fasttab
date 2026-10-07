#!/usr/bin/env python3
"""An unreachable remote machine (ssh hangs like a DNS lookup that never
answers) must cost ONE bounded probe, not one stuck ssh per caller.

Regression for 2026-10-07: Tailscale lost its coordination server, the Air's
host name stopped resolving (ConnectTimeout does not cover DNS: ~30s), every
/api/state request spawned its own ssh and blocked on it, requests piled up
and /api/state hung while Pro agents were fine. Fake ssh only, sentinel args."""
import os
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib"))

import chief_dashboard_herdr as herdr  # noqa: E402

fails = []


def check(label, ok, detail=""):
    if not ok:
        fails.append(f"{label} {detail}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label} {'' if ok else detail}")


with tempfile.TemporaryDirectory() as tmp:
    machines = {"air-m1": {"sshAlias": "nonexistent.invalid", "herdrPath": "/x/herdr",
                            "label": "Air", "maxParallel": 4}}
    count_file = os.path.join(tmp, "spawns")
    hang = os.path.join(tmp, "fake-ssh-hang")
    with open(hang, "w") as f:
        f.write(f'#!/bin/sh\necho x >> "{count_file}"\nsleep 31 &\nwait $!\n')
    os.chmod(hang, 0o755)
    os.environ["CHIEF_SSH_BIN"] = hang

    def spawns():
        try:
            with open(count_file) as f:
                return len(f.read().split())
        except FileNotFoundError:
            return 0

    herdr.reset_breakers()
    results = []

    def call():
        t0 = time.time()
        try:
            herdr.herdr_cmd_text("air-m1", ["pane", "list"], repo_root=tmp,
                                 machines=machines, timeout=2)
            results.append(("ok", time.time() - t0))
        except herdr.SshUnreachable:
            results.append(("unreachable", time.time() - t0))
        except Exception as e:  # noqa: BLE001
            results.append((type(e).__name__, time.time() - t0))

    threads = [threading.Thread(target=call) for _ in range(20)]
    t0 = time.time()
    for t in threads:
        t.start()
    for t in threads:
        t.join(15)
    wall = time.time() - t0
    check("20 concurrent callers all end SshUnreachable",
          [r[0] for r in results] == ["unreachable"] * 20, str(results))
    check("whole burst finished inside the hard deadline (+margin)", wall < 5, f"{wall:.1f}s")
    burst = spawns()
    check("burst spawned at most 2x maxParallel ssh (not 20)", burst <= 8, f"spawns={burst}")

    st = herdr.breaker_status("air-m1")
    check("breaker reports open with a retry time", st["open"] and st["retryInSec"] > 0, str(st))

    t0 = time.time()
    try:
        herdr.herdr_cmd_json("air-m1", ["agent", "list"], repo_root=tmp, machines=machines, timeout=2)
        raised = False
    except herdr.SshUnreachable:
        raised = True
    check("call while open fails instantly (<0.2s) without spawning",
          raised and time.time() - t0 < 0.2 and spawns() == burst,
          f"{time.time() - t0:.2f}s spawns={spawns()}")

    time.sleep(0.5)
    left = subprocess.run(["pgrep", "-f", "sleep 31"], capture_output=True, text=True)
    check("timed-out ssh left no orphan process", left.stdout.strip() == "", left.stdout)

    # Recovery: window elapses, one probe goes out, success closes the breaker.
    good = os.path.join(tmp, "fake-ssh-good")
    with open(good, "w") as f:
        f.write('#!/bin/sh\necho \'{"ok":true}\'\n')
    os.chmod(good, 0o755)
    os.environ["CHIEF_SSH_BIN"] = good
    herdr.BREAKER_OPEN_SEC = 0.0
    herdr._BREAKERS["air-m1"]["until"] = time.monotonic() - 1
    out = herdr.herdr_cmd_json("air-m1", ["pane", "list"], repo_root=tmp, machines=machines)
    check("probe after the window succeeds", out == {"ok": True}, str(out))
    check("breaker closed after a good probe", not herdr.breaker_status("air-m1")["open"])

    # A herdr-level error (ssh worked) must not trip the breaker.
    bad = os.path.join(tmp, "fake-ssh-rc1")
    with open(bad, "w") as f:
        f.write("#!/bin/sh\necho nope 1>&2\nexit 1\n")
    os.chmod(bad, 0o755)
    os.environ["CHIEF_SSH_BIN"] = bad
    try:
        herdr.herdr_cmd_text("air-m1", ["pane", "list"], repo_root=tmp, machines=machines)
    except herdr.SshUnreachable:
        check("exit 1 is not 'unreachable'", False)
    except herdr.HerdrError:
        check("exit 1 is a HerdrError", True)
    check("exit 1 leaves the breaker closed", not herdr.breaker_status("air-m1")["open"])
    del os.environ["CHIEF_SSH_BIN"]

if fails:
    print("\nFAILED:\n  " + "\n  ".join(fails))
    sys.exit(1)
print("\nall passed")
