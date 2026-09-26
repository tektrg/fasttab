#!/usr/bin/env python3
"""Direct-run tests for `choice: "select"` on `answer_pane_permission()`
(POST /api/permission) against an open plan-approval box — the
dashboard-plan-approval brief, plus the dashboard-plan-feedback-approves
brief's fix (feedback submits with `enter`, never `shift+tab`) and its
ask-#2 post-send auto-mode-warning guard.

Same pure herdr-free technique as test_answer_pane_permission.py (import
chief-dashboard-server.py via importlib.util, fake `_pane_run_raw`/
`run_json`/`herdr_transport.herdr_cmd_json`, never a real pane/port/the
live :4711 dashboard). FakeHerdr here additionally answers `pane
send-text` (literal, no embedded Enter) since the feedback-option path
uses it — see `_answer_plan_select`'s docstring for why `pane run`
(embeds Enter) is wrong there.
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

# Real capture (throwaway panes wB:p3X/wB:p3Y, 2026-09-20), same wording
# `classify_pane.py`'s own selftest fixture uses.
SCREEN_PLAN = "\n".join([
    "Claude has written up a plan and is ready to execute. Would you like "
    "to proceed?",
    "",
    "❯ 1. Yes, and use auto mode",
    "  2. Yes, manually approve edits",
    "  3. Tell Claude what to change",
    "     shift+tab to approve with this feedback",
    "",
    "ctrl+g to edit in Vim · ~/.claude/plans/dapper-strolling-sprout.md",
])
PERMISSION_PLAN = {
    "tool": "ExitPlanMode", "kind": "plan", "detail": None,
    "title": "Claude has written up a plan and is ready to execute. Would "
             "you like to proceed?",
    "cursorIndex": 1,
    "planPath": "~/.claude/plans/dapper-strolling-sprout.md",
    "options": [
        {"index": 1, "label": "Yes, and use auto mode"},
        {"index": 2, "label": "Yes, manually approve edits"},
        {"index": 3, "label": "Tell Claude what to change"},
    ],
}
# Screen after option 3's digit press: cursor moves onto that row, box
# stays fully open (real-pane finding — NOT an instant submit like 1/2).
SCREEN_PLAN_CURSOR_ON_3 = "\n".join([
    "Claude has written up a plan and is ready to execute. Would you like "
    "to proceed?",
    "",
    "  1. Yes, and use auto mode",
    "  2. Yes, manually approve edits",
    "❯ 3. Tell Claude what to change",
    "     shift+tab to approve with this feedback",
    "",
    "ctrl+g to edit in Vim · ~/.claude/plans/dapper-strolling-sprout.md",
])
# Screen after typing feedback text via `pane send-text`: option 3's label
# is REPLACED in place by the typed text (real-pane finding), box still
# open, still cursor-on-3.
SCREEN_PLAN_FEEDBACK_TYPED = "\n".join([
    "Claude has written up a plan and is ready to execute. Would you like "
    "to proceed?",
    "",
    "  1. Yes, and use auto mode",
    "  2. Yes, manually approve edits",
    "❯ 3. also cover the multi-select case",
    "     shift+tab to approve with this feedback",
    "",
    "ctrl+g to edit in Vim · ~/.claude/plans/dapper-strolling-sprout.md",
])
# Box gone — options 1/2 are an instant submit+dismiss; shift+tab on the
# feedback path also dismisses it.
SCREEN_GONE = "Cancelled — no changes made, plan file left as-is.\n"

# A DIFFERENT plan (same fixed wording/options, different planPath) — the
# `_same_permission` planPath-comparison regression fixture.
SCREEN_PLAN_OTHER_FILE = SCREEN_PLAN.replace(
    "dapper-strolling-sprout.md", "some-other-plan.md")

# A composer screen with the "auto mode on" mode footer — what the pane
# shows if a plan got approved into auto-accept (real capture shape, see
# `_AUTO_MODE_FOOTER_RE`).
SCREEN_AUTO_MODE_FOOTER = "\n".join([
    "─────────────────────────────────────────────────────────────────",
    "❯ ",
    "─────────────────────────────────────────────────────────────────",
    "    [Sonnet 5] 6% context | git:main | ~77 | pane:w1:p1",
    "  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent",
])

# A plain (non-plan) permission box — 'select' must refuse on this shape.
SCREEN_PLAIN_PERMISSION = "\n".join([
    "⏺ Bash(rm -rf /tmp/aptusfit-maestro-sim.lock)", "  ⎿  Running…", "",
    "Do you want to proceed?", "❯ 1. Yes", "  2. No",
])
PERMISSION_PLAIN = {
    "tool": "Bash", "detail": "rm -rf /tmp/aptusfit-maestro-sim.lock",
    "title": "Do you want to proceed?", "cursorIndex": 1,
    "options": [{"index": 1, "label": "Yes"}, {"index": 2, "label": "No"}],
}


class FakeHerdrRaisingOnGuardRead(object):
    """Same as FakeHerdr through settle, then raises on the ask-#2 guard's
    OWN extra read — proves a read failure there is swallowed (the send
    already succeeded; the guard is a bonus signal, never a new failure
    mode for a good send)."""

    def __init__(self, screens_before_guard_read):
        self.screens = list(screens_before_guard_read)
        self.sent_keys = []
        self.sent_text = []
        self._reads = 0

    def pane_run_raw(self, args, machine="local", timeout=15):
        if args[:2] == ["pane", "read"]:
            self._reads += 1
            if self._reads > len(self.screens):
                # `_pane_run_raw` (bypassed here since the fake replaces it
                # wholesale) is what normally turns a HerdrError into this
                # RuntimeError — `_read_pane_now`'s callers only ever see
                # the RuntimeError shape, so the fake raises that directly.
                raise RuntimeError("pane gone — herdr call failed")
            return self.screens[self._reads - 1]
        if args[:2] == ["pane", "send-keys"]:
            self.sent_keys.append(args[3])
            return ""
        if args[:2] == ["pane", "send-text"]:
            self.sent_text.append(args[3])
            return ""
        raise AssertionError(f"unexpected herdr call in this test: {args}")


class FakeHerdr:
    """Same shape as test_answer_pane_permission.py's FakeHerdr, plus a
    `pane send-text` branch (the feedback-typing primitive) and a way to
    swap the "current screen" mid-sequence (`advance()`), since the
    feedback path reads the pane THREE times (initial check, post-type
    verify, post-submit settle) with a DIFFERENT screen expected each time
    — unlike the single-screen-then-gone shape the simpler tests need."""

    def __init__(self, screens):
        self.screens = list(screens)  # consumed one read at a time
        self.sent_keys = []
        self.sent_text = []

    def pane_run_raw(self, args, machine="local", timeout=15):
        if args[:2] == ["pane", "read"]:
            if len(self.screens) > 1:
                return self.screens.pop(0)
            return self.screens[0]  # last screen repeats once exhausted
        if args[:2] == ["pane", "send-keys"]:
            self.sent_keys.append(args[3])
            return ""
        if args[:2] == ["pane", "send-text"]:
            self.sent_text.append(args[3])
            return ""
        raise AssertionError(f"unexpected herdr call in this test: {args}")


def install_fake(fake):
    _srv._pane_run_raw = fake.pane_run_raw
    _srv.run_json = lambda args, cwd=None, timeout=10: (
        {"result": {"panes": [{"pane_id": PANE_ID}]}}
        if args[:3] == ["herdr", "pane", "list"]
        else (_ for _ in ()).throw(AssertionError(f"unexpected run_json: {args}")))
    _srv.herdr_transport.herdr_cmd_json = lambda machine, args, **kw: (
        {"result": {"panes": [{"pane_id": PANE_ID}]}}
        if args[:3] == ["pane", "list"]
        else (_ for _ in ()).throw(
            AssertionError(f"unexpected herdr_cmd_json: {args}")))
    _srv.time.sleep = lambda *a, **k: None


print("== select index=1 (auto mode) is an instant single-key press, "
      "same shape as allow/deny — no shift+tab ==")
fake = FakeHerdr([SCREEN_PLAN, SCREEN_GONE, SCREEN_GONE, SCREEN_GONE, SCREEN_GONE])
install_fake(fake)
result = _srv.answer_pane_permission(
    PANE_ID, "select", PERMISSION_PLAN, index=1)
check("sends exactly key '1', no shift+tab", fake.sent_keys, ["1"])
check("no text typed", fake.sent_text, [])
check("landed send reports no next prompt", result, {"next": None})
check("index 1 IS auto mode by design — never warned", "warning" in result, False)

print("== select index=2 (manually approve edits) is likewise instant ==")
fake = FakeHerdr([SCREEN_PLAN, SCREEN_GONE, SCREEN_GONE, SCREEN_GONE, SCREEN_GONE])
install_fake(fake)
result = _srv.answer_pane_permission(
    PANE_ID, "select", PERMISSION_PLAN, index=2)
check("sends exactly key '2'", fake.sent_keys, ["2"])
check("landed send reports no next prompt", result, {"next": None})
check("box actually gone, no auto-mode footer -> no warning",
      "warning" in result, False)

print("== select index=2, but the pane unexpectedly shows auto mode after "
      "-> ask-#2 guard: {ok:true, ..., warning}, never silent, never raises ==")
fake = FakeHerdr([SCREEN_PLAN, SCREEN_GONE, SCREEN_AUTO_MODE_FOOTER])
install_fake(fake)
result = _srv.answer_pane_permission(
    PANE_ID, "select", PERMISSION_PLAN, index=2)
check("still reports success (settle already landed)", result.get("next"), None)
check("warning present and names the mismatch",
      "auto mode on" in result.get("warning", ""), True)

print("== select refuses an index the live box doesn't have — never "
      "defaults, never presses a key ==")
fake = FakeHerdr([SCREEN_PLAN])
install_fake(fake)
check_raises(
    "raises 'no option 99'",
    lambda: _srv.answer_pane_permission(
        PANE_ID, "select", PERMISSION_PLAN, index=99),
    "no option 99 on this prompt")
check("no key sent on refusal", fake.sent_keys, [])

print("== select index=3 (feedback option) with NO text refuses immediately "
      "— never sends the cursor-move digit and waits 8s for a 'press did "
      "not land' timeout (QA-caught: option 3 doesn't submit on its own, "
      "so a missing 'text' must be its own clear error) ==")
fake = FakeHerdr([SCREEN_PLAN])
install_fake(fake)
check_raises(
    "raises \"option 3 requires 'text'\"",
    lambda: _srv.answer_pane_permission(
        PANE_ID, "select", PERMISSION_PLAN, index=3),
    "option 3 requires 'text' — it does not submit on its own")
check("no key sent — never even tries the digit", fake.sent_keys, [])

print("== select with text on a NON-feedback option refuses ==")
fake = FakeHerdr([SCREEN_PLAN])
install_fake(fake)
check_raises(
    "raises \"'text' is only valid on\" for index=1",
    lambda: _srv.answer_pane_permission(
        PANE_ID, "select", PERMISSION_PLAN, index=1, text="do X instead"),
    "'text' is only valid on the 'Tell Claude what to change' option")
check("no key sent on refusal", fake.sent_keys, [])

print("== select+text on the feedback option: type via send-text (NOT "
      "pane run), verify it landed, submit with enter (NEVER shift+tab — "
      "dashboard-plan-feedback-approves: shift+tab approves the plan into "
      "auto mode instead of rejecting it with the feedback) ==")
fake = FakeHerdr([
    SCREEN_PLAN,                    # initial fresh-read/race-guard check
    SCREEN_PLAN_FEEDBACK_TYPED,     # re-read after send-text, to verify
    SCREEN_GONE, SCREEN_GONE, SCREEN_GONE, SCREEN_GONE,  # settle after enter
])
install_fake(fake)
result = _srv.answer_pane_permission(
    PANE_ID, "select", PERMISSION_PLAN, index=3,
    text="also cover the multi-select case")
check("navigates to option 3 first", fake.sent_keys[0], "3")
check("types the feedback via send-text (literal, no embedded Enter)",
      fake.sent_text, ["also cover the multi-select case"])
check("submits with enter, never shift+tab", fake.sent_keys[1:], ["enter"])
check("landed send reports no next prompt", result, {"next": None})
check("box actually gone, no auto-mode footer -> no warning",
      "warning" in result, False)

print("== select+text on the feedback option: even after a correct "
      "enter-submit, the pane can show auto mode (e.g. Claude's own "
      "plan-revision flow, reproduced live wB:p48 2026-09-20) -> ask-#2 "
      "guard still warns, since index 3 is never auto mode by design ==")
fake = FakeHerdr([
    SCREEN_PLAN, SCREEN_PLAN_FEEDBACK_TYPED,
    SCREEN_GONE, SCREEN_AUTO_MODE_FOOTER,
])
install_fake(fake)
result = _srv.answer_pane_permission(
    PANE_ID, "select", PERMISSION_PLAN, index=3,
    text="also cover the multi-select case")
check("submitted with enter", fake.sent_keys[1:], ["enter"])
check("warning present and names the mismatch",
      "auto mode on" in result.get("warning", ""), True)

print("== feedback path refuses without pressing shift+tab when the typed "
      "text did NOT land (e.g. the box changed mid-type) ==")
fake = FakeHerdr([
    SCREEN_PLAN,
    SCREEN_PLAN_CURSOR_ON_3,  # cursor moved but label still unchanged —
                              # send-text's effect never showed up
])
install_fake(fake)
check_raises(
    "raises 'typed feedback did not land'",
    lambda: _srv.answer_pane_permission(
        PANE_ID, "select", PERMISSION_PLAN, index=3, text="also cover X"),
    "typed feedback did not land — re-check the pane")
check("shift+tab never sent (nor enter, since it never got that far)",
      "shift+tab" not in fake.sent_keys and "enter" not in fake.sent_keys, True)

print("== feedback path: enter silently fails to submit (box stays "
      "open, unchanged since the post-typing verify) -> must RAISE, never "
      "report false success (QA-caught regression, 2026-09-20, carried over "
      "from the shift+tab-era version of this test: settle used to compare "
      "against the PRE-typing perm, whose option-3 label still read 'Tell "
      "Claude what to change' — a layout mismatch against the still-open, "
      "still-typed box, which read as a NEW `next` prompt instead of "
      "'press did not land') ==")
fake = FakeHerdr([
    SCREEN_PLAN,                    # initial fresh-read/race-guard check
    SCREEN_PLAN_FEEDBACK_TYPED,     # re-read after send-text, to verify
    # enter sent but the box never actually changes — every settle
    # poll re-reads the SAME post-typing screen.
    SCREEN_PLAN_FEEDBACK_TYPED, SCREEN_PLAN_FEEDBACK_TYPED,
    SCREEN_PLAN_FEEDBACK_TYPED, SCREEN_PLAN_FEEDBACK_TYPED,
])
install_fake(fake)
check_raises(
    "raises 'press did not land' instead of false-successing with a "
    "phantom `next`",
    lambda: _srv.answer_pane_permission(
        PANE_ID, "select", PERMISSION_PLAN, index=3,
        text="also cover the multi-select case"),
    "press did not land — re-check the pane")
check("shift+tab is NEVER sent by this path any more", "shift+tab" in fake.sent_keys, False)
check("enter was sent (the attempt happened, it just didn't land)",
      "enter" in fake.sent_keys, True)

print("== stale/mismatched echoed permission refuses WITHOUT sending a "
      "key, same race guard as allow/deny ==")
fake = FakeHerdr([SCREEN_PLAN])
install_fake(fake)
stale = dict(PERMISSION_PLAN, planPath="~/.claude/plans/some-other-plan.md")
check_raises(
    "refuses on planPath mismatch (a DIFFERENT plan, same fixed wording)",
    lambda: _srv.answer_pane_permission(PANE_ID, "select", stale, index=1),
    "permission prompt changed or gone")
check("no key sent — the core safety guarantee", fake.sent_keys, [])

print("== ask-#2 guard: a read failure on its OWN extra check is swallowed "
      "— the send already succeeded, a failed bonus check must never turn "
      "a good send into an error ==")
fake = FakeHerdrRaisingOnGuardRead([SCREEN_PLAN, SCREEN_GONE])
install_fake(fake)
result = _srv.answer_pane_permission(
    PANE_ID, "select", PERMISSION_PLAN, index=2)
check("still reports success despite the guard's read failing",
      result, {"next": None})
check("no warning fabricated from a failed check", "warning" in result, False)

print("== select refuses on a plain (non-plan) permission box — 'select' "
      "is plan-approval only ==")
fake = FakeHerdr([SCREEN_PLAIN_PERMISSION])
install_fake(fake)
check_raises(
    "raises \"choice 'select' only applies to a plan-approval box\"",
    lambda: _srv.answer_pane_permission(
        PANE_ID, "select", PERMISSION_PLAIN, index=1),
    "choice 'select' only applies to a plan-approval box")
check("no key sent", fake.sent_keys, [])

print("== existing allow/deny/allow-always choices are UNCHANGED by this "
      "addition (regression) ==")
fake = FakeHerdr([SCREEN_PLAIN_PERMISSION, SCREEN_GONE, SCREEN_GONE,
                  SCREEN_GONE, SCREEN_GONE])
install_fake(fake)
result = _srv.answer_pane_permission(PANE_ID, "allow", PERMISSION_PLAIN)
check("allow still sends key '1'", fake.sent_keys, ["1"])
check("allow still reports no next prompt", result, {"next": None})

print()
if fails:
    print(f"{len(fails)} FAILURES")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("all plan-approval 'select' checks pass")
