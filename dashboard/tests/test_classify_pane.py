#!/usr/bin/env python3
"""Prove ordinary agent prose is never read as a human gate — and that every
real gate still is.

WHAT HAPPENED (QA pass 2 over live code, 2026-09-14)
----------------------------------------------------
`classify()` read NEEDS_HUMAN off any line that merely TALKED about a prompt.
Six of seven realistic pane tails false-positived: an end-of-turn question with
numbered options, a numbered answer list beginning "1. Yes, …", a note that a
hook will "always allow" a command. The wording patterns matched line-by-line
with no corroboration that a selector was actually on screen.

WHY THAT IS NOT MERELY A SPURIOUS ALERT
---------------------------------------
`supervisor.assess()` ranks `screenBlocked` ABOVE its idle and stillness
branches, so one false match permanently costs that session automated recovery:

    true state          without it            with a false block
    idle, work owed     dropped -> redispatch needs-human (never reclaimed)
    working, silent 50m stalled -> nudge      needs-human (never nudged)

And an idle pane's screen never changes, so the verdict never clears itself.

WHY IT GOT WORSE RECENTLY
-------------------------
Observation widened from `working` panes to EVERY pane. A working pane's tail is
spinners and tool output; an idle pane's tail is the agent's closing prose —
exactly the text these patterns misread. The old status filter was incidentally
shielding the weakest patterns.

THE TRADE-OFF THIS SUITE DEFENDS
--------------------------------
Under-reporting a human gate leaves a worker stopped forever, so the classifier
fails OPEN. The goal here is to remove matches on PROSE, not to make real gates
harder to detect — so every genuine-selector fixture below must stay
NEEDS_HUMAN, and two that were silent false negatives must start reporting.

Fixture shapes are the ones `herdr pane read --source recent-unwrapped`
actually returns (measured across five live panes, 2026-09-14): Claude Code's
boxes come through as full-width horizontal rules, with `❯` at column 0 and no
vertical border character.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "server", "lib"))

import classify_pane  # noqa: E402

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def state(text):
    return classify_pane.classify(text)[0]


# ── The prose corpus: an IDLE worker's closing words ────────────────────────
# Six of these matched a permission pattern before 2026-09-14. None is a gate;
# every one is the agent talking about its own finished work.

PROSE_END_OF_TURN_QUESTION = """\
⏺ Both routes work, and the difference only shows up on the next release.
  Do you want to reuse the existing worker pane, or open a fresh tab for this?
  1. Reuse w8:p2R — keeps the branch context and the warm Metro
  2. Open a fresh tab — clean slate, costs a two-minute warm-up

✻ Baked for 2m 49s · done 3:34 PM
"""

PROSE_NUMBERED_ANSWER_LIST = """\
⏺ I checked all three of the questions you left:
  1. Yes, the timeout is present — scripts/run-e2e.sh sets it to 120s.
  2. No, the retry loop was removed in a76e1f27 and never came back.
  3. Partly: the guard fires, but only on the simulator path.

※ recap: answered the three open questions about the e2e timeout. Nothing
  pending on my end.
"""

PROSE_WOULD_YOU_LIKE_TO_PROCEED = """\
⏺ The rebase is staged and the unit suite is green (26/26).
  Would you like to proceed with the merge into release/v1.0.10?

✻ Baked for 1m 12s · done 4:02 PM
"""

PROSE_ALWAYS_ALLOW = """\
⏺ Added the settings entry, so the hook will always allow bare `git log`
  without a prompt from now on. Nothing else in that file changed.
"""

PROSE_YOLO_MODE = """\
⏺ Wrote the rule down in AGENTS.md: never run release.sh in yolo mode — a bad
  tag deploys the production backend and is unrecoverable once pushed.
"""

PROSE_ALLOW_THIS_COMMAND = """\
⏺ The permission entry should allow this command without asking, but the
  pattern is anchored wrong — it matches only the bare invocation, so the
  piped form still prompts.
"""

#: The seventh sample — the one that did NOT false-positive. It is here so the
#: corpus proves the fix is a change of CLASSIFICATION, not of coverage.
PROSE_CLEAN_RECAP = """\
※ recap: Cleaned up eleven finished dev worktrees and their herdr panes.
  Nothing is waiting on you.
"""

PROSE_CORPUS = [
    ("an end-of-turn question with numbered options", PROSE_END_OF_TURN_QUESTION, "WAITING"),
    ("a numbered answer list starting `1. Yes, …`", PROSE_NUMBERED_ANSWER_LIST, "UNKNOWN"),
    ("`Would you like to proceed` as prose", PROSE_WOULD_YOU_LIKE_TO_PROCEED, "WAITING"),
    ("`always allow` describing a hook rule", PROSE_ALWAYS_ALLOW, "UNKNOWN"),
    ("`yolo mode` quoted in a written-down rule", PROSE_YOLO_MODE, "UNKNOWN"),
    ("`allow this command` describing a pattern bug", PROSE_ALLOW_THIS_COMMAND, "UNKNOWN"),
    ("a clean recap with no trigger wording", PROSE_CLEAN_RECAP, "UNKNOWN"),
]

print("ORDINARY PROSE IS NOT A HUMAN GATE (6 of these 7 matched before):")
for label, text, want in PROSE_CORPUS:
    check(label, state(text), want)
    check(f"  ...and specifically not NEEDS_HUMAN — {label}",
          state(text) == "NEEDS_HUMAN", False)


# ── Genuine interactive selectors: every one must still be NEEDS_HUMAN ──────

GATE_PERMISSION_PROMPT = """\
⏺ Bash(rm -rf /tmp/aptusfit-maestro-sim.lock)
  ⎿  Running…

Do you want to proceed?
❯ 1. Yes
  2. Yes, and don't ask again for rm commands in /tmp
  3. No, tell Claude what to do differently (esc)
"""

#: The 2026-09-03 case: a tall AskUserQuestion whose cursor row sits 16 lines
#: above the bottom, with model-authored option labels and no permission
#: wording anywhere.
GATE_TALL_ASKUSERQUESTION = """\
Which release should this land on?

  Target release
❯ 1. release/v1.0.10
     ships with the pending fix
  2. release/v1.0.11
     waits for the next cut
  3. Hold
     decide after the e2e proof
  4. Type something.

  Press enter to confirm

  filler
  filler
  filler
  filler
"""

#: The shape a real capture has: horizontal rules, no vertical border, the
#: keybinding footer under the box.
GATE_BOXED_ASKUSERQUESTION = """\
⏺ Two flags are red on the manifest; pick how to proceed.

────────────────────────────────────────────────────────────
 ☐ Target release

Which release should this land on?

❯ 1. release/v1.0.10
     ships with the pending fix
  2. release/v1.0.11
  3. Type something.
────────────────────────────────────────────────────────────
  4. Chat about this

Enter to select · ↑/↓ to navigate · Esc to cancel
"""

#: The AskUserQuestion review step: numbered rows again, and just as stopped.
GATE_REVIEW_SCREEN = """\
Review your answers

 ● Which release should this land on?
   → release/v1.0.10

Ready to submit your answers?

❯ 1. Submit answers
  2. Cancel
"""

print("\nEVERY GENUINE SELECTOR STILL REPORTS THE GATE:")
for label, text in (
        ("a plain yes/no permission prompt", GATE_PERMISSION_PROMPT),
        ("a tall AskUserQuestion box", GATE_TALL_ASKUSERQUESTION),
        ("a box-drawn AskUserQuestion, real capture shape", GATE_BOXED_ASKUSERQUESTION),
        ("the AskUserQuestion review step", GATE_REVIEW_SCREEN)):
    check(label, state(text), "NEEDS_HUMAN")


# ── Two shapes that were SILENT false negatives before 2026-09-14 ───────────
# Failing to report a gate is the direction this module must never fail in:
# the worker stays stopped and nothing on the floor says so.

#: The cursor parked on a multi-select's EXIT row. It carries no digit, so the
#: `❯ <n>.` anchor could not see it — and a form sitting on `Submit` is exactly
#: as stopped as one sitting on an option.
GATE_CURSOR_ON_SUBMIT_ROW = """\
────────────────────────────────────────────────────────────
←  ☒ Which flows to re-run  ✔ Submit  →

Pick the flows to re-run

  1. [✔] 03_plan_builder
  2. [ ] 09_swap_cooldown
  3. [✔] 15_search_fts
❯    Submit
────────────────────────────────────────────────────────────
  4. Chat about this
"""

#: DEFECT D, settled as NOT REPRODUCED in the wild but fixed defensively.
#: Measured 2026-09-14 across five live panes: `herdr pane read --source
#: recent-unwrapped` renders Claude Code's boxes as full-width horizontal rules
#: with no vertical border, so `❯` starts at column 0 — which is also why the
#: dashboard's "answer from the page" path (same anchor) has been working live
#: since 2026-09-05. Tolerating a border costs nothing: no prose line begins
#: with one.
GATE_VERTICAL_BORDER_HYPOTHESIS = """\
╭──────────────────────────────────────────────────────────╮
│ Which release should this land on?                       │
│                                                          │
│ ❯ 1. release/v1.0.10                                     │
│   2. release/v1.0.11                                     │
╰──────────────────────────────────────────────────────────╯
"""

print("\n...AND TWO SHAPES THAT USED TO GO UNREPORTED NOW DO:")
check("the cursor parked on a multi-select's `Submit` row",
      state(GATE_CURSOR_ON_SUBMIT_ROW), "NEEDS_HUMAN")
check("a selector drawn with vertical borders (defensive; not seen live)",
      state(GATE_VERTICAL_BORDER_HYPOTHESIS), "NEEDS_HUMAN")


# ── The corroboration route, and its limit ─────────────────────────────────

#: Wording ALONE is not evidence — but wording under an open option block with
#: the picker's own keybinding footer is. This is the second, independent route
#: to a real prompt whose cursor glyph a capture happened to lose, and it is
#: why the wording patterns were kept rather than deleted.
GATE_WORDING_WITH_KEYBINDING_FOOTER = """\
Do you want to proceed?
  1. Yes
  2. Yes, and don't ask again
  3. No, tell Claude what to do differently (esc)

Esc to cancel · Enter to select
"""

print("\nWORDING COUNTS ONLY WITH THE PICKER'S OWN FOOTER UNDER IT:")
check("a cursorless prompt with a keybinding footer still reports",
      state(GATE_WORDING_WITH_KEYBINDING_FOOTER), "NEEDS_HUMAN")
check("the same wording with a done-spinner under it does not",
      state(PROSE_END_OF_TURN_QUESTION), "WAITING")
check("`_interactive_selector_open` is the discriminator (prose)",
      classify_pane._interactive_selector_open(
          PROSE_END_OF_TURN_QUESTION.splitlines()), False)
check("...and the selector (footer present)",
      classify_pane._interactive_selector_open(
          GATE_WORDING_WITH_KEYBINDING_FOOTER.splitlines()), True)


# ── The positional contest is unchanged ────────────────────────────────────
# MOST RECENT EVIDENCE WINS still decides between a gate and what came after
# it. These are the 2026-09-03 cases, re-asserted here because the permission
# pattern list is now built per pane rather than being a constant.

QUESTION_THEN_MAIN_SPINNER = """\
Which release should this land on?
❯ 1. release/v1.0.10
✻ Cogitating… (12s · ↓ 3.1k tokens)
"""

QUESTION_THEN_SUBAGENT_LINE = """\
Which release should this land on?
❯ 1. release/v1.0.10
◯ general-purpose  Grepping cli.js … 4m 23s · ↓ 143.2k tokens
"""

print("\nTHE POSITIONAL CONTEST IS UNCHANGED:")
check("the MAIN turn's spinner below a box proves the box was answered",
      state(QUESTION_THEN_MAIN_SPINNER), "ACTIVE")
check("a background subagent's line below one does not",
      state(QUESTION_THEN_SUBAGENT_LINE), "NEEDS_HUMAN")
check("a crash below a gate still wins",
      state("Do you want to proceed?\n❯ 1. Yes\n⏺ API Error: Connection error\n"),
      "CRASHED")
check("...and a gate below a crash still wins",
      state("⏺ API Error: Connection error\nDo you want to proceed?\n❯ 1. Yes\n"),
      "NEEDS_HUMAN")


print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("All classify-pane checks passed.")
