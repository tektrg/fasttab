#!/usr/bin/env python3
"""Direct-run tests for `answer_pane_question()` (POST /api/answer) —
dashboard-answer-stray-enter brief: a typed "Other" answer on a
single-select question could send a STRAY follow-up Enter onto a
DIFFERENT question that had already auto-advanced underneath it (QA-caught
on a real run, pane wB:p6, session c7db27d6, 2026-09-20).

Same pure herdr-free technique as test_answer_pane_permission.py: import
chief-dashboard-server.py via importlib.util, fake `_pane_run_raw`/
`run_json`/`herdr_transport.herdr_cmd_json`, never a real pane/port/the
live :4711 dashboard.
"""
import importlib.util
import os
import sys

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib"))

import classify_pane as cp  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "chief_dashboard_server",
    os.path.join(os.path.dirname(__file__), "..", "server", "chief-dashboard-server.py"))
_srv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_srv)

fails = []
PANE_ID = "w1:p1"


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


# Minimal single-select shape, 2 options: a real choice + the free-text
# "Other" row (otherIndex=2) — the smallest fixture that exercises the
# text-answer path's `_park_on_row` navigation (one 'down' from option 1).
def _single_select(title, question, opt1_label, cursor_on=1,
                    other_label="Type something."):
    cursor_row_1 = f"❯ 1. {opt1_label}" if cursor_on == 1 else f"  1. {opt1_label}"
    cursor_row_2 = f"❯ 2. {other_label}" if cursor_on == 2 else f"  2. {other_label}"
    return "\n".join([
        "────────────────────────────────────────",
        f" ☐ {title}",
        "",
        question,
        "",
        cursor_row_1,
        cursor_row_2,
        "────────────────────────────────────────",
        "  3. Chat about this",
        "",
        "Enter to select · ↑/↓ to navigate · Esc to cancel",
    ])


Q1_FRESH = _single_select("Delivery", "How should this ship?", "Ship now")
Q2_FRESH = _single_select(
    "Versioning", "How should the version bump?",
    "Let it auto-increment (Recommended)")
# Q1 with the Other row now cursor-parked (after _park_on_row's 'down').
Q1_ON_OTHER = _single_select("Delivery", "How should this ship?", "Ship now",
                              cursor_on=2)
# Q1 with the typed feedback visible in the Other row's label, cursor
# still parked there, still the SAME question (title/question unchanged) —
# the "still open" case: typed text landed but the embedded Enter did NOT
# auto-submit this time.
Q1_TYPED_STILL_OPEN = _single_select(
    "Delivery", "How should this ship?", "Ship now", cursor_on=2,
    other_label="ship it Friday instead")

QUESTION_Q1 = {"title": "Delivery", "question": "How should this ship?"}


# Multi-select shape: same 2-row layout (a real checkbox option + the
# free-text "Other" row at otherIndex=2) so the `_park_on_row` navigation
# is identical to the single-select fixtures above — only the checkbox
# brackets differ, which is what `parse_question_block` reads as `multi`.
def _multi_select(title, question, opt1_label, opt1_checked=False,
                   cursor_on=1, other_checked=False,
                   other_label="Type something."):
    box1 = "[✔]" if opt1_checked else "[ ]"
    box2 = "[✔]" if other_checked else "[ ]"
    row1 = f"❯ 1. {box1} {opt1_label}" if cursor_on == 1 else f"  1. {box1} {opt1_label}"
    row2 = f"❯ 2. {box2} {other_label}" if cursor_on == 2 else f"  2. {box2} {other_label}"
    return "\n".join([
        "────────────────────────────────────────",
        f" ☐ {title}",
        "",
        question,
        "",
        row1,
        row2,
        "     Submit",
        "────────────────────────────────────────",
        "  3. Chat about this",
        "",
        "Enter to select · ↑/↓ to navigate · Esc to cancel",
    ])


QM1_FRESH = _multi_select("Findings", "Which should be recorded?", "8 red tests")
QM2_FRESH = _multi_select("Follow-up", "Anything else to log?", "Nothing else")
# QM1 with the Other row cursor-parked (after _park_on_row's 'down').
QM1_ON_OTHER = _multi_select("Findings", "Which should be recorded?",
                              "8 red tests", cursor_on=2)
# QM1 with the typed feedback visible in the Other row, cursor still
# parked there, still the SAME question, NOT yet checked on (the
# checkbox-confirm Enter hasn't been sent yet in this reading).
QM1_TYPED_STILL_OPEN = _multi_select(
    "Findings", "Which should be recorded?", "8 red tests", cursor_on=2,
    other_label="also log the stale baseline")

QUESTION_QM1 = {"title": "Findings", "question": "Which should be recorded?"}


class FakeHerdr:
    """Scripted screen sequence: each `pane read` pops the next screen (the
    last one repeats once exhausted, simulating a pane that stopped
    changing). `pane run` (used by `_type_text`) and `pane send-keys` are
    both logged, never executed."""

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
        else (_ for _ in ()).throw(AssertionError(f"unexpected run_json: {args}")))
    _srv.herdr_transport.herdr_cmd_json = lambda machine, args, **kw: (
        {"result": {"panes": [{"pane_id": PANE_ID}]}}
        if args[:3] == ["pane", "list"]
        else (_ for _ in ()).throw(
            AssertionError(f"unexpected herdr_cmd_json: {args}")))
    _srv.time.sleep = lambda *a, **k: None


print("== typed-Other auto-advance (the reported bug): `pane run`'s "
      "embedded Enter already submitted Q1 and the pane shows Q2 — must "
      "return next==Q2 and send NO follow-up key at all ==")
fake = FakeHerdr([
    Q1_FRESH,       # answer_pane_question's own fresh-read/race-guard check
    Q1_FRESH,       # _park_on_row(1): already parked, no key needed
    Q1_FRESH,       # _park_on_row(otherIndex=2), 1st read: not parked yet
    Q1_ON_OTHER,    # _park_on_row(otherIndex=2), 2nd read: after one 'down'
    Q2_FRESH,       # read right after _type_text — Q1 already auto-submitted
])
install_fake(fake)
result = _srv.answer_pane_question(
    PANE_ID, {"type": "text", "value": "ship it Friday instead"}, QUESTION_Q1)
check("typed the answer via `pane run` (the embedded-Enter primitive)",
      fake.typed, ["ship it Friday instead"])
check("exactly one navigation key sent (the single 'down' to reach the "
      "Other row) — NO Enter after typing", fake.sent_keys, ["down"])
got_next = result.get("next") or {}
check("next question is Q2, not a mis-answered Q2",
      (got_next.get("title"), got_next.get("question")),
      ("Versioning", "How should the version bump?"))

print("== same question still open after typing (embedded Enter did NOT "
      "submit this time): existing behavior UNCHANGED — one Enter is still "
      "sent, then settle ==")
fake = FakeHerdr([
    Q1_FRESH, Q1_FRESH, Q1_FRESH, Q1_ON_OTHER, Q1_TYPED_STILL_OPEN,
    # after the (correctly sent) Enter, settle sees the form has moved on
    # to Q2 directly — resolves inside _settle_after_submit's own loop,
    # never falls through to the wall-clock-bound _wait_for_next.
    Q2_FRESH,
])
install_fake(fake)
result = _srv.answer_pane_question(
    PANE_ID, {"type": "text", "value": "ship it Friday instead"}, QUESTION_Q1)
check("navigation 'down' + the submit 'enter' both sent, in order",
      fake.sent_keys, ["down", "enter"])
got_next = result.get("next") or {}
check("settle correctly picks up the queued Q2",
      (got_next.get("title"), got_next.get("question")),
      ("Versioning", "How should the version bump?"))

print("== multi-select typed-Other auto-advance (QA1's gap: the SAME "
      "`_type_text`-embedded-Enter risk as the single-select bug above, but "
      "in the multi-select sub-path, missed in the first pass) — must "
      "return next==Q2 and send NO checkbox-confirm Enter at all ==")
fake = FakeHerdr([
    QM1_FRESH,        # answer_pane_question's own fresh-read/race-guard check
    QM1_FRESH,        # _park_on_row(1): already parked, no key needed
    QM1_FRESH,        # _park_on_row(otherIndex=2), 1st read: not parked yet
    QM1_ON_OTHER,     # _park_on_row(otherIndex=2), 2nd read: after one 'down'
    QM2_FRESH,        # read right after _type_text — Q1 already auto-advanced
])
install_fake(fake)
result = _srv.answer_pane_question(
    PANE_ID, {"type": "text", "value": "also log the stale baseline"},
    QUESTION_QM1)
check("typed the answer via `pane run` (the embedded-Enter primitive)",
      fake.typed, ["also log the stale baseline"])
check("exactly one navigation key sent (the single 'down' to reach the "
      "Other row) — NO checkbox-confirm Enter, no _submit_multi",
      fake.sent_keys, ["down"])
got_next = result.get("next") or {}
check("next question is Q2, not a mis-checked Q2",
      (got_next.get("title"), got_next.get("question")),
      ("Follow-up", "Anything else to log?"))

print("== multi-select: SAME question after typing (checkbox-confirm Enter "
      "correctly sent), but the pane advances to a DIFFERENT Q2 once that "
      "Enter lands — must return next==Q2 and never call _submit_multi "
      "against the stale Q1 ==")
fake = FakeHerdr([
    QM1_FRESH, QM1_FRESH, QM1_FRESH, QM1_ON_OTHER, QM1_TYPED_STILL_OPEN,
    # the checkbox-confirm Enter's re-read shows a genuinely different
    # question — must be caught by the SECOND _same_question gate (after
    # q3), never fall through to _submit_multi with the stale QM1.
    QM2_FRESH,
])
install_fake(fake)
result = _srv.answer_pane_question(
    PANE_ID, {"type": "text", "value": "also log the stale baseline"},
    QUESTION_QM1)
check("navigation 'down' + the checkbox-confirm 'enter' both sent, in "
      "order — nothing further (no _submit_multi keys)",
      fake.sent_keys, ["down", "enter"])
got_next = result.get("next") or {}
check("returns the queued Q2 instead of submitting the stale Q1",
      (got_next.get("title"), got_next.get("question")),
      ("Follow-up", "Anything else to log?"))

REVIEW_SCREEN = "\n".join([
    "────────────────────────────────────────",
    "←  ☒ Ship date  ✔ Submit  →",
    "",
    "Review your answers",
    "",
    " ● Which day should it ship?",
    "   → ship it Friday instead",
    "",
    "Ready to submit your answers?",
    "",
    "❯ 1. Submit answers",
    "  2. Cancel",
])
AFTER_SUBMIT = "✻ Working… (esc to interrupt)"

print("== typed-Other on the form's LAST question lands on the REVIEW screen "
      "(2026-09-21 report: 'send answer, it not submit') — must press Enter "
      "on `Submit answers`, not just wait for a next question ==")
fake = FakeHerdr([
    Q1_FRESH, Q1_FRESH, Q1_FRESH, Q1_ON_OTHER,
    REVIEW_SCREEN,   # read right after _type_text: no picker, review is up
    REVIEW_SCREEN,   # _settle_after_submit's own read
    REVIEW_SCREEN,   # _submit_review: cursor confirmed on Submit answers
    AFTER_SUBMIT,    # after the Enter: review gone
])
install_fake(fake)
result = _srv.answer_pane_question(
    PANE_ID, {"type": "text", "value": "ship it Friday instead"}, QUESTION_Q1)
check("navigation 'down', then exactly one 'enter' on the review's Submit row",
      fake.sent_keys, ["down", "enter"])
check("no next question after the form is submitted",
      result.get("next"), None)

print()
print("== cursor-on-exit real capture parses with the new additive flag "
      "(classify_pane.question_cursor_on_exit) — regression guard "
      "for the brief's item 2/3, kept alongside the send-path tests since "
      "it's the same fixture family ==")
CURSOR_ON_SUBMIT = "\n".join([
    "────────────────────────────────────────────────────────────────────────────────────────",
    "←  ☒ How to finish  ☐ Record findings  ✔ Submit  →",
    "",
    "Three findings currently exist only in this conversation. Which "
    "should I write up as durable records before anything else?",
    "",
    "  1. [ ] 8 red tests on the shipping line",
    "       desc one",
    "  2. [✔] Plan-settings silent data loss",
    "       desc two",
    "  3. [✔] Stale lint baseline in CLAUDE.md",
    "       desc three",
    "  4. [✔] Deliver run cost / fragility",
    "       desc four",
    "  5. [ ] Type something",
    "❯    Submit",
    "────────────────────────────────────────────────────────────────────────────────────────",
    "  6. Chat about this",
    "",
    "Enter to select · ↑/↓ to navigate · Esc to cancel",
])
check("parse_question_block reads None (cursor search needs a digit row)",
      cp.parse_question_block(CURSOR_ON_SUBMIT.splitlines()), None)
check("question_cursor_on_exit reads True — picker is still open",
      cp.question_cursor_on_exit(CURSOR_ON_SUBMIT.splitlines()), True)

print()
if fails:
    print(f"{len(fails)} FAILURES")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("all answer_pane_question stray-enter checks pass")
