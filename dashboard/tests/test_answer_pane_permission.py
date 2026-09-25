#!/usr/bin/env python3
"""Direct-run tests for `answer_pane_permission()` (POST /api/permission).

Pure herdr-free tests: `chief-dashboard-server.py` is loaded via
importlib.util (same trick as test_chief_dashboard_v3_reclaim.py, since its
filename is hyphenated and not a normal import target), then its
`run_json`/`_pane_run_raw` module globals are monkeypatched to a fake herdr
that never touches a real pane, a real port, or the live :4711 dashboard —
per this brief's HARD SAFETY rule.
"""
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


def check_raises(label, fn, want_substr):
    try:
        got = fn()
    except RuntimeError as e:
        ok = want_substr in str(e)
        if not ok:
            fails.append(f"{label}: raised {e!r}, want substring {want_substr!r}")
        print(f"  {'PASS' if ok else 'FAIL'}  {label}")
    else:
        fails.append(f"{label}: expected RuntimeError, got {got!r}")
        print(f"  FAIL  {label}")


PANE_ID = "w1:p1"

# The GATE_PERMISSION_PROMPT shape used elsewhere in this repo's fixtures
# (scripts/tests/test_classify_pane.py, classify_pane.py's own selftest).
SCREEN_3OPT = "\n".join([
    "⏺ Bash(rm -rf /tmp/aptusfit-maestro-sim.lock)",
    "  ⎿  Running…",
    "",
    "Do you want to proceed?",
    "❯ 1. Yes",
    "  2. Yes, and don't ask again for rm commands in /tmp",
    "  3. No, tell Claude what to do differently (esc)",
])
PERMISSION_3OPT = {
    "tool": "Bash", "detail": "rm -rf /tmp/aptusfit-maestro-sim.lock",
    "title": "Do you want to proceed?", "cursorIndex": 1,
    "options": [
        {"index": 1, "label": "Yes"},
        {"index": 2, "label": "Yes, and don't ask again for rm commands in /tmp"},
        {"index": 3, "label": "No, tell Claude what to do differently (esc)"},
    ],
}
# Box gone — the turn moved on, no cursor row left to parse.
SCREEN_GONE = "\n".join([
    "⏺ Bash(rm -rf /tmp/aptusfit-maestro-sim.lock)",
    "  ⎿  Done",
])

# Real Edit-box shape (agentbar-permission-edit-boxes brief, pane wB:p3K,
# 2026-09-19): option 2's "for this session" label, not "don't ask again" —
# proves the widened allow-always corroboration in _permission_target_index.
SCREEN_EDIT_BOX = "\n".join([
    "⏺ Update(.claude/chief-mode)",
    "",
    "────────────────────────────────────────",
    " Edit file",
    " .claude/chief-mode",
    "╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌",
    " 1  on 2026-09-15T04:21:16+00:00 84ac01f3-…",
    " 2 +",
    "╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌",
    " Do you want to make this edit to chief-mode?",
    " ❯ 1. Yes",
    "   2. Yes, and allow Claude to edit files in this project's .claude folder for this session",
    "   3. No",
    "",
    " Esc to cancel · Tab to amend",
])
PERMISSION_EDIT_BOX = {
    "tool": "Update",
    "detail": ".claude/chief-mode\n"
              " 1  on 2026-09-15T04:21:16+00:00 84ac01f3-…\n 2 +",
    "title": "Do you want to make this edit to chief-mode?", "cursorIndex": 1,
    "options": [
        {"index": 1, "label": "Yes"},
        {"index": 2, "label": "Yes, and allow Claude to edit files in "
                              "this project's .claude folder for this session"},
        {"index": 3, "label": "No"},
    ],
}


class FakeHerdr:
    """Fake `herdr pane read`/`send-keys`: never a subprocess, never a real
    pane. `screen` is what every read returns until a key is sent; after
    that, `reads_until_change` more reads still return the UNCHANGED screen
    (simulating a slow-to-render pane — measured elsewhere in this file's
    own comments as up to a few hundred ms, exercised here past several
    seconds) before flipping to `screen_after`. Default 0 means "changes
    immediately," i.e. the very next read after the press."""

    def __init__(self, screen, screen_after=SCREEN_GONE, reads_until_change=0):
        self.screen = screen
        self.screen_after = screen_after
        self.reads_until_change = reads_until_change
        self.sent_keys = []
        self._reads_since_press = 0

    def pane_run_raw(self, args, machine="local", timeout=15):
        # Bare subcommand argv (no leading "herdr" literal) — herdr_cmd_text
        # prepends the binary name itself, so a caller-side "herdr" here
        # would double-prefix (dashboard-pane-read-regression brief, Bug 1).
        if args[:2] == ["pane", "read"]:
            if self.sent_keys:
                self._reads_since_press += 1
                if self._reads_since_press > self.reads_until_change:
                    return self.screen_after
            return self.screen
        if args[:2] == ["pane", "send-keys"]:
            self.sent_keys.append(args[3])
            return ""
        raise AssertionError(f"unexpected herdr call in this test: {args}")


def install_fake(fake):
    _srv._pane_run_raw = fake.pane_run_raw
    _srv.run_json = lambda args, cwd=None, timeout=10: (
        {"result": {"panes": [{"pane_id": PANE_ID}]}}
        if args[:3] == ["herdr", "pane", "list"]
        else (_ for _ in ()).throw(AssertionError(f"unexpected run_json: {args}")))
    # answer_pane_permission/answer_pane_question's own pane-existence check
    # now goes through the machine-aware wrapper, not run_json — same fake
    # answer, new door (chief_dashboard_herdr transport, slice 0).
    _srv.herdr_transport.herdr_cmd_json = lambda machine, args, **kw: (
        {"result": {"panes": [{"pane_id": PANE_ID}]}}
        if args[:3] == ["pane", "list"]
        else (_ for _ in ()).throw(
            AssertionError(f"unexpected herdr_cmd_json: {args}")))
    _srv.time.sleep = lambda *a, **k: None  # no real waiting in a unit test


print("== allow presses option 1 only when its label starts 'Yes' ==")
fake = FakeHerdr(SCREEN_3OPT)
install_fake(fake)
result = _srv.answer_pane_permission(PANE_ID, "allow", PERMISSION_3OPT)
check("sends exactly key '1'", fake.sent_keys, ["1"])
check("landed send reports no next prompt", result, {"next": None})

print("== deny presses the LAST option only when its label starts 'No' ==")
fake = FakeHerdr(SCREEN_3OPT)
install_fake(fake)
result = _srv.answer_pane_permission(PANE_ID, "deny", PERMISSION_3OPT)
check("sends exactly key '3' (last option, not option count)", fake.sent_keys, ["3"])
check("landed send reports no next prompt", result, {"next": None})

print("== allow-always refuses cleanly when no such option exists ==")
permission_2opt = dict(PERMISSION_3OPT, options=[
    {"index": 1, "label": "Yes"},
    {"index": 2, "label": "No"},
])
fake = FakeHerdr("\n".join([
    "⏺ Bash(rm -rf /tmp/aptusfit-maestro-sim.lock)", "  ⎿  Running…", "",
    "Do you want to proceed?", "❯ 1. Yes", "  2. No",
]))
install_fake(fake)
check_raises(
    "raises 'no allow-always option'",
    lambda: _srv.answer_pane_permission(PANE_ID, "allow-always", permission_2opt),
    "no allow-always option on this prompt")
check("no key sent on refusal", fake.sent_keys, [])

print("== stale/mismatched echoed permission refuses WITHOUT sending a key ==")
stale_permission = dict(PERMISSION_3OPT, detail="rm -rf /tmp/some-other-lockfile")
fake = FakeHerdr(SCREEN_3OPT)  # live box still shows the ORIGINAL detail
install_fake(fake)
check_raises(
    "refuses on detail mismatch (race guard)",
    lambda: _srv.answer_pane_permission(PANE_ID, "allow", stale_permission),
    "permission prompt changed or gone")
check("no key sent — the core safety guarantee", fake.sent_keys, [])

print("== bad choice string refuses, never defaults to allow ==")
fake = FakeHerdr(SCREEN_3OPT)
install_fake(fake)
check_raises(
    "raises 'bad choice'",
    lambda: _srv.answer_pane_permission(PANE_ID, "yolo", PERMISSION_3OPT),
    "bad choice: must be 'allow', 'deny', or 'allow-always'")
check("no key sent on bad choice", fake.sent_keys, [])

print("== allow/deny refuse when the LIVE box's own labels don't "
      "corroborate the direction (never trust position alone) ==")
# Options reordered on screen: index 1 is a "No" row, index 2 is "Yes". The
# echoed `permission` must match this exact live box for the race guard to
# pass, so it is built from the same reordered screen, not from PERMISSION_3OPT.
screen_reordered = "\n".join([
    "⏺ Bash(rm -rf /tmp/x)", "  ⎿  Running…", "",
    "Do you want to proceed?", "❯ 1. No, definitely not", "  2. Yes",
])
permission_reordered = {
    "tool": "Bash", "detail": "rm -rf /tmp/x",
    "title": "Do you want to proceed?", "cursorIndex": 1,
    "options": [
        {"index": 1, "label": "No, definitely not"},
        {"index": 2, "label": "Yes"},
    ],
}
fake = FakeHerdr(screen_reordered)
install_fake(fake)
check_raises(
    "allow refuses when option 1 isn't a 'Yes' row",
    lambda: _srv.answer_pane_permission(PANE_ID, "allow", permission_reordered),
    "no allow option on this prompt")
check("no key sent (would have wrongly denied by pressing index 1)",
      fake.sent_keys, [])

screen_no_clear_no = "\n".join([
    "⏺ Bash(rm -rf /tmp/x)", "  ⎿  Running…", "",
    "Do you want to proceed?", "❯ 1. Yes", "  2. Maybe, ask me later",
])
permission_no_clear_no = {
    "tool": "Bash", "detail": "rm -rf /tmp/x",
    "title": "Do you want to proceed?", "cursorIndex": 1,
    "options": [
        {"index": 1, "label": "Yes"},
        {"index": 2, "label": "Maybe, ask me later"},
    ],
}
fake = FakeHerdr(screen_no_clear_no)
install_fake(fake)
check_raises(
    "deny refuses when the last option isn't a 'No' row",
    lambda: _srv.answer_pane_permission(PANE_ID, "deny", permission_no_clear_no),
    "no deny option on this prompt")
check("no key sent (would have wrongly allowed by pressing the last index)",
      fake.sent_keys, [])

print("== a null/empty echoed permission refuses, never matches by accident ==")
fake = FakeHerdr(SCREEN_3OPT)
install_fake(fake)
check_raises(
    "refuses on permission=None",
    lambda: _srv.answer_pane_permission(PANE_ID, "allow", None),
    "permission prompt changed or gone")
check("no key sent", fake.sent_keys, [])

print("== settle catches a box that clears on its LAST poll, not just an "
      "earlier one (regression: the loop's own final re-read used to be "
      "computed and then silently discarded before the raise) ==")
# _settle_after_permission does 1 read up front + 1 more per loop iteration
# (4 iterations) = 5 reads total. reads_until_change=4 means the first 4 are
# unchanged and only the 5th — the one done at the very tail of the loop's
# last iteration — shows the box gone. The old code checked reads 1-4 (each
# at the TOP of the next iteration) but exited the loop without ever
# checking read 5, and raised unconditionally.
fake = FakeHerdr(SCREEN_3OPT, reads_until_change=4)
install_fake(fake)
result = _srv.answer_pane_permission(PANE_ID, "allow", PERMISSION_3OPT)
check("sends key '1'", fake.sent_keys, ["1"])
check("reports success from that final read instead of a false failure",
      result, {"next": None})

print("== settle genuinely RAISES when the box never clears at all "
      "(the retry budget must not paper over a real stuck press) ==")
fake = FakeHerdr(SCREEN_3OPT, reads_until_change=999)
install_fake(fake)
check_raises(
    "raises 'press did not land' when the box is still there after retrying",
    lambda: _srv.answer_pane_permission(PANE_ID, "allow", PERMISSION_3OPT),
    "press did not land — re-check the pane")

print("== allow-always on an Edit box presses option 2, matched by "
      "'for this session' (not just 'don't ask again') ==")
fake = FakeHerdr(SCREEN_EDIT_BOX)
install_fake(fake)
result = _srv.answer_pane_permission(PANE_ID, "allow-always", PERMISSION_EDIT_BOX)
check("sends exactly key '2'", fake.sent_keys, ["2"])
check("landed send reports no next prompt", result, {"next": None})

print("== Edit-box refuses WITHOUT sending a key when the box changed "
      "(multi-line diff `detail` must still be compared exactly) ==")
changed_edit_box = dict(
    PERMISSION_EDIT_BOX,
    detail=".claude/chief-mode\n"
           " 1  on 2026-09-15T04:21:16+00:00 84ac01f3-…\n 2 +\n 3 +extra line")
fake = FakeHerdr(SCREEN_EDIT_BOX)  # live box still shows the ORIGINAL diff
install_fake(fake)
check_raises(
    "refuses on detail mismatch (box changed)",
    lambda: _srv.answer_pane_permission(PANE_ID, "allow", changed_edit_box),
    "permission prompt changed or gone")
check("no key sent — the core safety guarantee", fake.sent_keys, [])

print()
if fails:
    print(f"{len(fails)} FAILURES")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("all answer_pane_permission checks pass")
