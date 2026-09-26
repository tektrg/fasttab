#!/usr/bin/env python3
"""Direct-run tests for `read_one_pane_screen`'s NEEDS_HUMAN-only unwrapped
re-read (agentbar-permission-edit-boxes brief, item 3: "the feed reads the
screen wrapped so a long Bash command returns None").

Pure function + a fake `herdr_cmd_text` — no herdr, no panes, no network.
`feeds.herdr_transport.herdr_cmd_text` is monkeypatched for the duration of
this file and restored at the end. Both herdr reads in this module route
through that one door (R2/R3) rather than a bare `subprocess.run`, so that's
the seam to fake, not `feeds.subprocess`.
"""
import os
import sys

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib"))

import chief_dashboard_feeds as feeds  # noqa: E402
import chief_dashboard_herdr as herdr_transport  # noqa: E402

fails = []
PANE_ID = "w1:p1"

_ORIG_HERDR_CMD_TEXT = feeds.herdr_transport.herdr_cmd_text


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


# A long Bash command WRAPPED across two visual rows by `--source visible` —
# `PERMISSION_RECEIPT_RE`'s single-line match can't see it, so the wrapped
# read alone parses `permission` as None even though a real box is open.
WRAPPED_SCREEN = "\n".join([
    "⏺ Bash(rm -rf /tmp/some/very/long/path/that/wraps/across/the/termin",
    "al/width/because/it/is/long-lockfile.lock)",
    "",
    "Do you want to proceed?",
    "❯ 1. Yes",
    "  2. No",
])
# The SAME box, read unwrapped — one logical line, so the receipt matches.
UNWRAPPED_SCREEN = "\n".join([
    "⏺ Bash(rm -rf /tmp/some/very/long/path/that/wraps/across/the/terminal/width/because/it/is/long-lockfile.lock)",
    "",
    "Do you want to proceed?",
    "❯ 1. Yes",
    "  2. No",
])
NEEDS_HUMAN_DETAIL = ("rm -rf /tmp/some/very/long/path/that/wraps/across/"
                      "the/terminal/width/because/it/is/long-lockfile.lock")

# A plain non-blocked pane — must never trigger the second read at all.
IDLE_SCREEN = "\n".join([
    "❯ some prompt",
    "",
])

# dashboard-plan-approval brief: the unwrapped-read recovery path must cover
# a plan-approval box too, not just a plain Bash/Edit permission box —
# `_recompute_permission_unwrapped` was switched to
# `parse_permission_or_plan_block`, and nothing else in this file's suite
# exercises that switch. The plan box's title itself never wraps in these
# fixtures (short enough), so this proves the SWITCH (right parser called),
# not a wrap-recovery scenario on the plan box specifically — the wrap case
# is already covered above for the plain-box shape both parsers share.
PLAN_WRAPPED_SCREEN = "\n".join([
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


def install_fake(calls_log, *, second_read_stdout=UNWRAPPED_SCREEN,
                 second_read_rc=0):
    def fake_cmd_text(machine, argv, *, repo_root=None, machines=None,
                       timeout=15, cwd=None):
        calls_log.append(list(argv))
        pane_id, source = argv[2], argv[3:5]
        if source == ["--source", "visible"]:
            if "plan" in pane_id:
                return PLAN_WRAPPED_SCREEN
            return WRAPPED_SCREEN if "wrapped" in pane_id else IDLE_SCREEN
        if source == ["--source", "recent-unwrapped"]:
            if second_read_rc != 0:
                # herdr_cmd_text raises on a nonzero exit rather than
                # returning one, same as the real door (R2/R3).
                raise herdr_transport.HerdrError("fake herdr exited nonzero")
            if "plan" in pane_id:
                return PLAN_WRAPPED_SCREEN
            return second_read_stdout
        raise AssertionError(f"unexpected herdr_cmd_text call: {argv}")
    feeds.herdr_transport.herdr_cmd_text = fake_cmd_text


print("== NEEDS_HUMAN pane with a wrapped command recovers `permission` "
      "via a second unwrapped read ==")
calls = []
install_fake(calls)
key, entry = feeds.read_one_pane_screen("wrapped-pane")
check("state is NEEDS_HUMAN", entry["state"], "NEEDS_HUMAN")
check("permission recovered from the unwrapped read",
      entry["permission"]["detail"] if entry["permission"] else None,
      NEEDS_HUMAN_DETAIL)
check("exactly 2 herdr reads issued for this blocked pane", len(calls), 2)
check("2nd read used --source recent-unwrapped", calls[1][3:5],
      ["--source", "recent-unwrapped"])

print("== a non-blocked (idle) pane never pays the second read ==")
calls = []
install_fake(calls)
key, entry = feeds.read_one_pane_screen("idle-pane")
check("state is not NEEDS_HUMAN", entry["state"] != "NEEDS_HUMAN", True)
check("only ONE herdr read issued (cost stays scoped to blocked panes)",
      len(calls), 1)

print("== unwrapped read failing (nonzero exit) falls back to the wrapped "
      "(still-None) permission rather than raising ==")
calls = []
install_fake(calls, second_read_stdout="", second_read_rc=1)
key, entry = feeds.read_one_pane_screen("wrapped-pane")
check("state still reads NEEDS_HUMAN", entry["state"], "NEEDS_HUMAN")
check("permission falls back to the wrapped-tail result (None)",
      entry["permission"], None)

print("== dashboard-plan-approval: a NEEDS_HUMAN plan-approval box survives "
      "the unwrapped-read path (permission recomputed via "
      "parse_permission_or_plan_block, not lost as a plain-permission-only "
      "None) ==")
calls = []
install_fake(calls)
key, entry = feeds.read_one_pane_screen("plan-pane")
check("state is NEEDS_HUMAN", entry["state"], "NEEDS_HUMAN")
check("permission is the plan-approval shape, not None",
      entry["permission"]["kind"] if entry["permission"] else None, "plan")
check("planPath carried through the unwrapped re-read",
      entry["permission"]["planPath"] if entry["permission"] else None,
      "~/.claude/plans/dapper-strolling-sprout.md")
check("still exactly 2 herdr reads for this blocked pane", len(calls), 2)

feeds.herdr_transport.herdr_cmd_text = _ORIG_HERDR_CMD_TEXT

print()
if fails:
    print(f"{len(fails)} FAILURES")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("all read_one_pane_screen checks pass")
