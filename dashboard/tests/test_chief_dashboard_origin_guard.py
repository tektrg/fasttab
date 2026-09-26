#!/usr/bin/env python3
"""Direct-run tests for R20: write routes refuse a foreign Origin or
non-loopback Host with 403, before any handler runs — for local and Air
panes alike (the check has nothing to do with which pane is targeted)."""
import importlib.util
import os
import sys

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib"))

_spec = importlib.util.spec_from_file_location(
    "chief_dashboard_server",
    os.path.join(os.path.dirname(__file__), "..", "server", "chief-dashboard-server.py"))
_srv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_srv)

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


class FakeHandler(_srv.Handler):
    """Real Handler subclass so _is_loopback_netloc (a classmethod) resolves
    normally — but skips BaseHTTPRequestHandler.__init__ (no real socket),
    just supplying `.headers` and a `._send_json` that records what it sent."""

    def __init__(self, headers):  # noqa: super-init-not-called (intentional)
        self.headers = headers
        self.sent = None

    def _send_json(self, obj, status=200):
        self.sent = (obj, status)


def run(headers):
    h = FakeHandler(headers)
    rejected = h._reject_foreign_write()
    return rejected, h.sent


print("== no Origin, no Host: never foreign (curl / same-page fetch) ==")
rejected, sent = run({})
check("not rejected", rejected, False)
check("nothing sent", sent, None)

print("== loopback Origin: allowed ==")
rejected, sent = run({"Origin": "http://127.0.0.1:4711"})
check("not rejected", rejected, False)

print("== localhost Origin: allowed ==")
rejected, sent = run({"Origin": "http://localhost:4711"})
check("not rejected", rejected, False)

print("== foreign Origin: refused with 403 before any handler ==")
rejected, sent = run({"Origin": "http://evil.example"})
check("rejected", rejected, True)
check("403", sent[1] if sent else None, 403)
check("names the reason", "Origin" in (sent[0] or {}).get("error", ""), True)

print("== non-loopback Host: refused with 403 ==")
rejected, sent = run({"Host": "evil.example"})
check("rejected", rejected, True)
check("403", sent[1] if sent else None, 403)

print("== loopback Host with a port: allowed ==")
rejected, sent = run({"Host": "127.0.0.1:4711"})
check("not rejected", rejected, False)

print("== IPv6 loopback Origin/Host: allowed ==")
rejected, sent = run({"Origin": "http://[::1]:4711"})
check("not rejected (Origin)", rejected, False)
rejected, sent = run({"Host": "[::1]:4711"})
check("not rejected (Host)", rejected, False)

print("== do_POST/do_PATCH/do_DELETE/do_PUT all check before routing ==")
import inspect  # noqa: E402
for name in ("do_POST", "do_PATCH", "do_DELETE", "do_PUT"):
    src = inspect.getsource(getattr(_srv.Handler, name))
    check(f"{name} calls _reject_foreign_write first",
          "_reject_foreign_write" in src.splitlines()[1],
          True)

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("All R20 Origin/Host guard checks passed.")
