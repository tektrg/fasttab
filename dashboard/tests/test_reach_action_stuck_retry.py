#!/usr/bin/env python3
"""Direct-run tests for `_handle_reach_action()` (POST /api/session/message):
the `/compact` / `/clear` stuck-retry fallback, and the `typed: false`
marker that tells the board's Composer a refusal typed nothing (the ONLY
case in which it may put the text back in the box — see the last section).

2026-09-22 added a defensive one-shot esc+enter retry for exactly these two
allowlisted commands when the input box still reads "stuck" right after the
first Enter. The retry is safety-critical: it re-reads the pane FRESH and
re-runs the SAME picker/permission guard the pre-send check uses
(`_picker_or_permission_open`) before sending the corrective keys — a stray
Enter hitting a live picker/permission box has caused real damage before
(see the guard's own docstring). This file proves that end to end, not just
the pure-function pieces (`is_allowed_slash_command`, `input_box_still_holds`)
already covered in test_chief_dashboard_v4_phase8.py — nothing in this repo
previously exercised `_handle_reach_action`'s retry branch at all.

Same pure herdr-free technique as test_answer_pane_question.py /
test_answer_pane_permission.py: import chief-dashboard-server.py via
importlib.util, fake `_pane_run_raw`/`run_json`/`herdr_transport.herdr_cmd_json`,
never a real pane/port/the live :4711 dashboard. `STORE.log_session_action`
is also stubbed so this never writes to the real board.db.
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
PANE_ID = "w1:p1"
ROW_ID = "sess-1"


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


# An ordinary idle screen: no question picker, no permission prompt — the
# pre-send guard must read this as clear.
IDLE_SCREEN = "\n".join([
    "some earlier output",
    "more output",
    "❯ ",
])

# Right after typing "/compact" + one Enter: the input box still holds our
# literal text on its last prompt line (`input_box_still_holds`'s exact
# trigger) — this is the "stuck" reading that arms the retry.
STUCK_COMPACT_SCREEN = "\n".join([
    "some earlier output",
    "❯ /compact",
])

# After the corrective esc+enter actually lands: box drained.
DRAINED_SCREEN = "\n".join([
    "❯ /compact",
    "",
    "Compacting…",
    "❯ ",
])

# A real permission prompt (canonical shape used elsewhere in this repo's
# fixtures, e.g. classify_pane.py's own selftest / test_answer_pane_permission.py)
# — this must read as NEEDS_HUMAN via classify_pane.classify.
PERMISSION_APPEARED_SCREEN = "\n".join([
    "Do you want to proceed?",
    "",
    "❯ 1. Yes",
    "  2. No",
])


class FakeHerdr:
    """Scripted screen sequence for `pane read`; `pane run` (types text) and
    `pane send-keys` are logged, never executed against a real pane."""

    def __init__(self, screens):
        self.screens = list(screens)
        self.sent_keys = []
        self.typed = []

    def pane_run_raw(self, args, machine="local", timeout=15):
        if args[:2] == ["pane", "read"]:
            if len(self.screens) > 1:
                return self.screens.pop(0)
            return self.screens[0]
        if args[:2] == ["pane", "send-keys"]:
            self.sent_keys.append(args[3])
            return ""
        if args[:2] == ["pane", "run"]:
            self.typed.append(args[3])
            return ""
        raise AssertionError(f"unexpected herdr call in this test: {args}")


def install_fake(fake):
    _srv._pane_run_raw = fake.pane_run_raw
    _srv.run_json = lambda args, cwd=None, timeout=10: (
        {"result": {"panes": [{"pane_id": PANE_ID}]}}
        if args[:3] == ["herdr", "pane", "list"]
        else {"result": {}})
    _srv.herdr_transport.herdr_cmd_json = lambda machine, args, **kw: (
        {"result": {"panes": [{"pane_id": PANE_ID}]}}
        if args[:3] == ["pane", "list"]
        else {"result": {}})
    _srv.time.sleep = lambda *a, **k: None
    agent = {
        "paneId": PANE_ID, "label": "worker", "agentSession": ROW_ID,
        "hasHookData": True, "hookState": "idle",
    }
    _srv.get_full_state = lambda: {
        "computed": {"agents": [agent]}, "feeds": {},
    }
    logged = []
    _srv.STORE.log_session_action = lambda *a, **k: logged.append((a, k))
    return logged


BODY = {"rowId": ROW_ID, "actor": "po", "text": "/compact", "confirm": True}


print("== stuck /compact, pane still clear on the retry re-read: ONE "
      "corrective esc+enter is sent, and it is sent only after a FRESH "
      "re-read (not the stale 'stuck' read) ==")
fake = FakeHerdr([
    IDLE_SCREEN,             # pre-send fresh-read guard
    STUCK_COMPACT_SCREEN,    # read right after type+enter: reads stuck
    IDLE_SCREEN,             # the retry's OWN fresh re-read: still clear
    DRAINED_SCREEN,          # read after the corrective esc+enter: drained
])
logged = install_fake(fake)
result = _srv.handle_session_action("message", BODY)
check("reports success", result.get("ok"), True)
check("state is message sent", result.get("state"), "message sent")
check("exactly one corrective esc+enter, in order",
      fake.sent_keys, ["enter", "esc", "enter"])
check("typed the command exactly once (no double-send)",
      fake.typed, ["/compact"])
check("the send was logged as sent (not left silently unaudited)",
      [k.get("status") for a, k in logged if a[1] == "message"], ["sent"])

print("== stuck /compact, but a permission prompt appears on the FRESH "
      "retry re-read: the corrective esc+enter must NOT be sent — a stray "
      "Enter would land in a live prompt ==")
fake = FakeHerdr([
    IDLE_SCREEN,                   # pre-send fresh-read guard
    STUCK_COMPACT_SCREEN,          # read right after type+enter: stuck
    PERMISSION_APPEARED_SCREEN,    # the retry's fresh re-read: now blocked
    # No further screen is ever read — the retry must bail before sending
    # esc+enter or reading again; a 5th `pane read` call is a bug.
])
logged = install_fake(fake)
result = _srv.handle_session_action("message", BODY)
check("reports failure, not a false success", result.get("ok"), False)
check("refuses as NOT SUBMITTED rather than silently landing",
      "NOT SUBMITTED" in (result.get("error") or ""), True)
check("no esc/enter corrective keys were sent — only the original enter",
      fake.sent_keys, ["enter"])
check("the failed attempt is logged (visible in /api/session/history)",
      [(a[3], k.get("status")) for a, k in logged if a[1] == "message"],
      [("NOT SUBMITTED — text stuck in the input box", "failed")])

print("== a question picker (not a permission prompt) appearing on the "
      "retry re-read is refused the same way ==")
# parse_question_block needs the AskUserQuestion box shape; reuse a minimal
# one — only `question is not None` matters to `_picker_or_permission_open`.
QUESTION_APPEARED_SCREEN = "\n".join([
    "────────────────────────────────────────",
    " ☐ Delivery",
    "",
    "How should this ship?",
    "",
    "❯ 1. Ship now",
    "  2. Type something.",
    "────────────────────────────────────────",
    "  3. Chat about this",
    "",
    "Enter to select · ↑/↓ to navigate · Esc to cancel",
])
fake = FakeHerdr([
    IDLE_SCREEN,
    STUCK_COMPACT_SCREEN,
    QUESTION_APPEARED_SCREEN,
])
logged = install_fake(fake)
result = _srv.handle_session_action("message", BODY)
check("reports failure", result.get("ok"), False)
check("no corrective keys sent once a picker is present",
      fake.sent_keys, ["enter"])

print("== typed:false marks ONLY refusals before the first keystroke ==")
# The Composer restores the text into the box only when every row says
# typed:false — so a marker on a post-typing failure is a double-send.
PLAIN_BODY = {"rowId": ROW_ID, "actor": "po", "text": "sentinel note"}

fake = FakeHerdr([IDLE_SCREEN])
install_fake(fake)
result = _srv.handle_session_action(
    "message", dict(PLAIN_BODY, text="sentinel\x03note"))
check("control-char refusal carries typed:false", result.get("typed"), False)
check("control-char refusal typed nothing", fake.typed, [])

fake = FakeHerdr([QUESTION_APPEARED_SCREEN])
install_fake(fake)
result = _srv.handle_session_action("message", PLAIN_BODY)
check("open-picker refusal carries typed:false", result.get("typed"), False)
check("open-picker refusal typed nothing", fake.typed, [])

fake = FakeHerdr([IDLE_SCREEN])
install_fake(fake)
result = _srv.handle_session_action(
    "message", dict(PLAIN_BODY, rowId="not-a-live-row"))
check("not-live refusal carries typed:false", result.get("typed"), False)

result = _srv.handle_session_action("message", dict(PLAIN_BODY, actor="x"))
check("bad-actor refusal carries typed:false", result.get("typed"), False)


class FailAfterTypingHerdr(FakeHerdr):
    """Types the text, then the Enter keystroke raises: the text may have
    landed in the pane, so this must never read as 'nothing typed'."""

    def pane_run_raw(self, args, machine="local", timeout=15):
        if args[:2] == ["pane", "send-keys"]:
            raise RuntimeError("sentinel transport drop")
        return super().pane_run_raw(args, machine, timeout)


fake = FailAfterTypingHerdr([IDLE_SCREEN])
install_fake(fake)
result = _srv.handle_session_action("message", PLAIN_BODY)
check("mid-sequence failure reports failure", result.get("ok"), False)
check("mid-sequence failure is NOT marked typed:false",
      "typed" in result, False)
check("mid-sequence failure did type the text", fake.typed, ["sentinel note"])

fake = FakeHerdr([IDLE_SCREEN, "\n".join(["output", "❯ sentinel note"])])
install_fake(fake)
result = _srv.handle_session_action("message", PLAIN_BODY)
check("NOT SUBMITTED is NOT marked typed:false", "typed" in result, False)

if fails:
    print(f"\n{len(fails)} FAILURE(S):")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("\nall reach-action stuck-retry checks pass")
