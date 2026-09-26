#!/usr/bin/env python3
"""Classify a worker pane's current state from its raw screen text (stdin).

Pure text in, one line out: "STATE\tsignal line". No herdr, no network — this
module only does string classification, so it can be unit-tested (and is, by
check-worker-panes.sh --selftest) without a live pane to read from.

See scripts/check-worker-panes.sh for why this exists and what each state means.
"""
import re
import sys

import pane_screen_signals as signals
import pane_live_work as live_work

CHROME_RE = re.compile(r'^[\s─-╿•■-◿✦✧✎✴⭘●○❯✻✔◼◻☢⏺]*$')
# The bottom status bar is present in EVERY pane regardless of state ("auto mode
# on", the model/context-percent line, the update-check line) — never a useful
# signal, but often the last non-blank text, so it must be excluded explicitly
# rather than relying on length/chrome filtering alone.
FOOTER_RE = re.compile(
    r'auto mode on|for agents|Auto-update (failed|available)|Run claude doctor'
    r'|\d+%\s*context|shift\+tab to cycle|new task\? /clear to save'
    # Added 2026-09-03: the chief dashboard renders this signal line as the
    # REASON a pane is on its "needs you" list, so a line that is technically
    # the last text but says nothing about the work is worse than useless there.
    r'|disable recaps|Update installed|Restart to update|until auto-compact'
    # The done-spinner line ("✻ Baked for 2m 49s · done 3:34 PM") proves the
    # turn ended — which DONE_SPINNER_RE below already detects on its own — but
    # as a reason it tells the human nothing. Skip past it to the actual last
    # thing the worker said.
    r'|for (\d+h\s*)?(\d+m\s*)?\d+s\s*·\s*done\b',
    re.IGNORECASE,
)

#: A horizontal rule with a label sitting in it (herdr draws the tab label into
#: the prompt-box border: "──────── chief 1.0.7 ─") is still chrome, but it is
#: not PURE chrome, so CHROME_RE's all-or-nothing match lets it through — and it
#: surfaced as a row's reason on the dashboard.
#:
#: Keyed on the LONGEST RUN of box characters, not their proportion (QA found
#: proportion wrong in both directions: it kept "──── chief 1.0.7 ─" at 0.41,
#: and discarded "╭── Which release should this land on? ──╮" at 0.54 — which
#: is a real question, and the detail text of the highest-urgency row there is.
#: A border always spans the terminal, so its run is long; a box drawn AROUND
#: text has short runs on the text line and puts its own long runs on separate
#: lines, which CHROME_RE already catches.
BOX_DRAWING_RUN_RE = re.compile(r'[\u2500-\u257f]{20,}')

#: THE SELECTOR'S OWN CURSOR — the shape every interactive selector shares,
#: whatever its wording, and the only evidence strong enough to stand alone.
#:
#: Added 2026-09-03 after QA proved a pane blocked on `AskUserQuestion` was
#: invisible to all three of the chief dashboard's detectors: the tool is
#: auto-allowed so no permission notification fires, `claude agents --json`
#: reports an interactive session only busy/idle (never waiting), and every
#: WORDING pattern below needs phrasing an AskUserQuestion box does not have —
#: its options are model-authored labels ("1. release/v1.0.6"). It surfaced
#: only after the 25-minute stall threshold, as a low-urgency "quiet for a
#: while" row. That gate is the delivery workflow's PRIMARY way of asking the
#: human a question, so missing it defeats the dashboard's whole purpose.
#:
#: `❯` plus a digit and a period is the cursor: the empty prompt box draws a
#: bare `❯`, and ordinary agent output does not draw that glyph at all.
#:
#: The second shape is the multi-select's EXIT row with the cursor parked on
#: it (`❯    Submit` / `❯    Next`). It has no digit, so the first pattern
#: cannot see it — and a form sitting on its own exit row is just as stopped
#: as one sitting on an option. Added 2026-09-14; it was a silent false
#: negative, the direction this module must never fail in.
#:
#: The optional leading `│` is defensive only. Measured 2026-09-14 across five
#: live panes: `herdr pane read --source recent-unwrapped` renders Claude Code's
#: boxes as full-width horizontal rules with NO vertical border, so `❯` starts
#: at column 0 today. Tolerating a border costs nothing (no prose line begins
#: with one) and removes a whole class of future capture-format surprise.
SELECTOR_CURSOR_PATTERNS = [
    r'^\s*[│┃]?\s*❯\s*\d+\.\s+\S',
    r'^\s*[│┃]?\s*❯\s*(?:Submit|Next)\s*$',
]

#: WORDING alone is not evidence — it is what an agent's own prose sounds like.
#: These six read `NEEDS_HUMAN` off any line that merely TALKS about a prompt:
#: an end-of-turn question ("Do you want to reuse the pane, or open a fresh
#: tab?"), a numbered answer list ("1. Yes, the timeout is present…"), a note
#: about a permission rule ("the hook will always allow bare git log"). QA ran
#: the real `classify()` on seven realistic pane tails and SIX matched
#: (2026-09-14).
#:
#: The damage is not a spurious alert. `supervisor.assess()` ranks a screen
#: block ABOVE its idle and stillness branches, so one false match permanently
#: costs that session automated recovery: an idle worker owing work is never
#: re-dispatched, a silent one is never nudged — and an idle pane's screen
#: never changes, so the verdict never clears on its own.
#:
#: It got worse when the observer widened from `working` panes to EVERY pane. A
#: working pane's tail is spinners and tool output; an idle pane's tail is the
#: agent's closing prose — exactly the text these patterns misread. The old
#: status filter was incidentally shielding them.
#:
#: So they are kept, but only with CORROBORATION — see
#: `_interactive_selector_open`. Kept rather than deleted deliberately: under-
#: reporting a human gate leaves a worker stopped forever, so this module fails
#: OPEN, and these are the second, independent route to a real prompt whose
#: cursor glyph a capture happened to lose.
PERMISSION_WORDING_PATTERNS = [
    r'\bDo you want to\b.*\?',
    r'\bAllow this (action|command|edit)\b',
    r'^\s*❯?\s*1\.\s*Yes\b',
    r'Always allow',
    r'\byolo mode\b',
    r'\bWould you like to proceed\b',
]

CRASH_PATTERNS = [
    r'\bAPI Error\b',
    r'FailedToOpenSocket',
    r'\bECONNRESET\b',
    r'\boverloaded_error\b',
    r'\brate_limit_error\b',
    r'\bConnection error\b',
    r'\bTraceback \(most recent call last\)',
    r'\bUnhandledPromiseRejection\b',
    r"Can'?t reach the API server",
    r'Request rejected \(\d{3}\)',
    r'credentials for model .* are cooling down',
    # Account-level walls (2026-09-20). Anchored to the line start (after an
    # optional result marker) so prose that merely MENTIONS a limit — "you've
    # hit your limit of retries" — is not a banner.
    r"^\s*(?:[⎿⏺]\s*)?You'?ve hit your (?:usage |session |weekly )?limit\b",
    r'^\s*(?:[⎿⏺]\s*)?Credit balance is too low',
    r'^\s*(?:[⎿⏺]\s*)?(?:Claude )?usage limit reached',
    r'^\s*(?:[⎿⏺]\s*)?(?:Session|Weekly|Opus|Sonnet)(?: weekly)? limit reached\b',
]

# Claude Code rotates its spinner verb, the amount of text before the ellipsis,
# AND its leading glyph freely (glyphs seen: ✻ ✢ ◯ ⏺ ✽ ✳ ·; verb phrases seen:
# "Ebbing", "Cogitating", "Implementing the four sub-changes") — so a strict
# "glyph + single gerund + ellipsis" shape is a losing enumeration game, and cost
# two real false-negatives while this script was being tested live. The one
# signal that held across every sample: an ELLIPSIS immediately followed by an
# open-paren elapsed-time counter only ever appears on a spinner that is still
# running. A completed one reports "for <duration>" instead, with no ellipsis.
LIVE_SPINNER_RE = re.compile(r'…\s*\(\d')
RUNNING_TOOL_TAIL_RE = re.compile(r'^\s*(Ran \d+ shell command|⏺\s|\$\s)')
# A background Workflow or subagent's own status line, e.g.
# "◯ deliver  ... 0/3 agents done · 4m 3s · ↓ 343.7k tokens" or
# "◯ general-purpose (+2)  Grepping ... 4m 23s · ↓ 143.2k tokens" — both carry a
# live token-count readout, which a finished line never does.
RUNNING_AGENT_RE = re.compile(r'^\s*[◯⏺]\s+\S.*↓\s*[\d.,]+k?\s*tokens', re.MULTILINE)
# `[^\W\d_]` = any Unicode letter: the verb rotates through words like "Sautéed",
# which an ASCII-only class read as "no done marker" (a 2h9m-finished pane read
# UNKNOWN — one of the review's "no call" rows). Still case-sensitive.
DONE_SPINNER_RE = re.compile(r'^\S\s*[A-ZÀ-Ý][^\W\d_]* for (\d+h\s*)?(\d+m\s*)?\d+s', re.MULTILINE)


#: Claude Code's end-of-turn recap ("※ recap: … Next action is yours: …") is the
#: single most useful reason text a finished worker leaves behind — it says what
#: the work was and what it is waiting for. But it is a HARD-WRAPPED BLOCK, so
#: walking backwards for "the last content line" lands on its tail fragment: a
#: live pane showed a top-urgency row whose entire stated reason was "/config)",
#: the wrapped remainder of "(disable recaps in /config)". Reading the block as
#: one unit is the fix; skipping the fragment would only expose the fragment
#: above it.
RECAP_START_RE = re.compile(r'^\s*※\s*recap\b', re.IGNORECASE)
#: The recap's own trailer, which WRAPS: "(disable recaps in" ends one line and
#: "/config)" begins the next. Stripped per line, before the footer test —
#: skipping whole lines that match "disable recaps" would delete the recap's
#: closing sentence along with it, which is the sentence the ASKED rank reads.
RECAP_TRAILER_RE = re.compile(
    r'\s*\(disable recaps in(\s*/config\))?|^\s*/config\)\s*$', re.IGNORECASE)


#: An OPEN prompt box draws its options last and a keybinding footer under
#: them — and none of that says what is being ASKED. Walking backwards for
#: "the last content line" therefore lands on "Esc to cancel · Tab to amend",
#: which on 2026-09-06 was the entire stated reason of a live BLOCKED row: the
#: dashboard knew a pane was stopped and could not say what for. The question
#: is drawn ABOVE the options, so a prompt box has to be read top-down, the
#: same way the ※ recap block is.
PROMPT_OPTION_RE = re.compile(r'^\s*❯?\s*\d+\.\s+\S')
PROMPT_HINT_RE = re.compile(
    r'^(Tip:|Esc to cancel|Enter to select|Press \w|↑/↓)', re.IGNORECASE)
#: How far above the options the box's own text may reach. A bound, not a
#: guess: without one, a numbered list in ordinary transcript output would let
#: this walk arbitrarily far back into unrelated work.
PROMPT_BOX_LOOKBACK = 12


def _open_option_block(tail_lines):
    """Index of the last option row of an OPEN prompt box, or None.

    "Open" is structural, not textual: the options must be the last thing on
    the pane apart from hint/chrome lines. A numbered list somewhere in a
    finished turn's output fails that test, which is the point — otherwise
    every transcript containing "1. …" would report a phantom prompt.

    One definition, three callers (`_prompt_box_signal`, `review_screen_open`,
    `_interactive_selector_open`): two of them had this scan copied verbatim,
    and a structural test that two functions can disagree about is worse than
    an imperfect one they share.
    """
    content = [i for i, l in enumerate(tail_lines) if l.strip()]
    if not content:
        return None
    last_opt = None
    for i in reversed(content):
        if PROMPT_OPTION_RE.match(tail_lines[i].strip()):
            last_opt = i
            break
    if last_opt is None:
        return None
    for i in content:
        if i <= last_opt:
            continue
        s = tail_lines[i].strip()
        if not (PROMPT_HINT_RE.match(s) or CHROME_RE.match(s)
                or FOOTER_RE.search(s) or BOX_DRAWING_RUN_RE.search(s)):
            return None  # output below the options: the box is closed
    return last_opt


def _interactive_selector_open(tail_lines):
    """Is a real interactive selector on screen, corroborating mere wording?

    An open option block ALONE does not qualify. A finished turn whose closing
    prose offers numbered choices, with only a done-spinner under it, passes
    that test — and the done-spinner is skipped as a footer, so the block reads
    "open". That is precisely the shape QA measured false-positiving.

    What prose never has is the picker's KEYBINDING FOOTER ("Esc to cancel",
    "Enter to select", "↑/↓ to navigate"): Claude Code draws it only while a
    selector is actually accepting keys. So corroboration is an open option
    block WITH that footer under it.

    Deliberately a second route rather than the only one: the cursor row
    (`SELECTOR_CURSOR_PATTERNS`) stands on its own and carries every selector
    shape seen live. This exists so a capture that loses the cursor glyph but
    keeps the footer still reports the gate — failing open, as the module's
    trade-off requires.
    """
    last_opt = _open_option_block(tail_lines)
    if last_opt is None:
        return False
    return any(PROMPT_HINT_RE.match(tail_lines[i].strip())
               for i in range(last_opt + 1, len(tail_lines)))


#: The keybinding footer only an ACCEPTING selector draws. Narrower than
#: PROMPT_HINT_RE on purpose: "Tip:" and "Press X" lines also appear in ordinary
#: transcript output.
SELECTOR_FOOTER_RE = re.compile(r'^\s*(Enter to select|Esc to cancel|↑/↓)', re.IGNORECASE)


def _selector_footer_index(tail_lines):
    """Index of the keybinding footer under an OPEN option block, or None.

    Second, independent route to a picker when the capture lost the cursor glyph
    (`❯`) and the options carry model-authored labels no wording pattern knows.
    Hookless panes (the second Mac) have no hook `blocked` to fall back on, so
    the screen alone must carry this — measured 2026-09-20: a live 4-option
    picker read idle on 41 of 45 sweeps.
    """
    last_opt = _open_option_block(tail_lines)
    if last_opt is None:
        return None
    for i in range(len(tail_lines) - 1, last_opt, -1):
        if SELECTOR_FOOTER_RE.match(tail_lines[i]):
            return i
    return None


def _permission_patterns(tail_lines):
    """The NEEDS_HUMAN patterns in force for THIS pane.

    The cursor anchors always apply; the wording patterns only when the pane
    structurally shows an open selector. See `PERMISSION_WORDING_PATTERNS` for
    what a bare wording match costs.
    """
    if _interactive_selector_open(tail_lines):
        return SELECTOR_CURSOR_PATTERNS + PERMISSION_WORDING_PATTERNS
    return SELECTOR_CURSOR_PATTERNS


def _prompt_box_signal(tail_lines):
    """What an open prompt box is ASKING, or None if no box is open."""
    last_opt = _open_option_block(tail_lines)
    if last_opt is None:
        return None

    parts = []
    for i in range(last_opt - 1, max(-1, last_opt - 1 - PROMPT_BOX_LOOKBACK), -1):
        s = tail_lines[i].strip()
        if BOX_DRAWING_RUN_RE.search(s):
            break
        if (not s or PROMPT_OPTION_RE.match(s) or PROMPT_HINT_RE.match(s)
                or CHROME_RE.match(s) or FOOTER_RE.search(s)):
            continue
        parts.append(s)
    if not parts:
        return None
    return ' · '.join(reversed(parts))[:160]


def _last_signal_index(tail_lines):
    """Index of the last line carrying content a human would want to read."""
    for i in range(len(tail_lines) - 1, -1, -1):
        s = tail_lines[i].strip()
        if not s or CHROME_RE.match(s) or FOOTER_RE.search(s):
            continue
        if BOX_DRAWING_RUN_RE.search(s):
            continue
        # The prompt box: whatever the human has typed but not sent. Handing
        # that back as "the reason this pane needs you" is circular — a live
        # pane's reason read "❯ yes, add it to memory/…", the human's own words.
        if s.startswith('❯'):
            continue
        if len(s) < 8:
            continue
        return i
    return None


def _joined_recap(tail_lines, start):
    """Fold a wrapped ※ recap block, from `start`, back into one line.

    Footer lines are SKIPPED, not merely stopped at: Claude Code draws its
    right-aligned "new task? /clear to save N tokens" hint on the line
    immediately below the recap with no blank line between them, so folding
    blindly appended it — which then (a) pushed "(disable recaps in /config)"
    off the end where the trailer strip could not reach it, and (b) made the
    both-ends truncation take its tail from the FOOTER instead of the recap's
    closing sentence, demoting a real ask to DONE. Measured on 2 live panes
    (QA round 3, 2026-09-04) — green in every test, broken in production,
    because no fixture fed a real recap with a pane footer under it.
    """
    parts = []
    for l in tail_lines[start:]:
        s = l.strip()
        if not s or BOX_DRAWING_RUN_RE.search(s):
            break
        s = RECAP_TRAILER_RE.sub('', s).strip()
        if not s or FOOTER_RE.search(s) or CHROME_RE.match(s):
            continue
        parts.append(s)
    return ' '.join(parts).strip()


def last_signal_line(tail_lines):
    # An open prompt box wins outright: the pane is STOPPED on it, so nothing
    # further up the transcript is what the human needs to read.
    box = _prompt_box_signal(tail_lines)
    if box:
        return box

    i = _last_signal_index(tail_lines)
    if i is None:
        return "(no readable content)"

    # If the last content sits INSIDE a recap block, report the whole block.
    for r in range(i, -1, -1):
        if RECAP_START_RE.match(tail_lines[r]):
            joined = _joined_recap(tail_lines, r)
            if joined:
                # BOTH ENDS of a long recap, not the first 140 characters: a
                # recap opens with what the work WAS and closes with what it is
                # waiting on ("…or wait for your input"), and the dashboard
                # ranks a row by whether that closing sentence asks the human
                # anything. Truncating from the front threw away the half that
                # decides the rank.
                if len(joined) > 150:
                    head = joined[:88].rsplit(' ', 1)[0]
                    tail = joined[-58:].split(' ', 1)[-1]
                    return f"{head} … {tail}"
                return joined
            break
        if not tail_lines[r].strip():
            break  # blank line = the recap, if any, ended above this text

    return tail_lines[i].strip()[:140]


#: Marker classes, each mapping to the state its presence implies. A terminal
#: is a log, so the rule is simply MOST RECENT EVIDENCE WINS — see classify().
#: NEEDS_HUMAN's patterns are not a constant: which of them are in force
#: depends on the pane (`_permission_patterns`), so classify() builds the pair.
_CRASH_MARKER = ("CRASHED", CRASH_PATTERNS)


def _last_match_index(tail, patterns):
    """Index of the LAST line in `tail` matching any of `patterns`, or None."""
    for i in range(len(tail) - 1, -1, -1):
        line = tail[i]
        if any(re.search(p, line, re.IGNORECASE) for p in patterns):
            return i
    return None


def _last_live_index(tail, allow_agent_lines=True):
    """Index of the last line showing work actually in flight.

    `allow_agent_lines=False` counts only the MAIN turn's own spinner. The two
    are not equivalent evidence: a background subagent's status line proves a
    subagent is running, which is perfectly compatible with the main turn being
    stopped at a permission box — whereas the main turn's spinner is not, since
    Claude Code stops animating it to draw the box. Treating them alike would
    let a subagent line drawn under an open question read ACTIVE, which both
    hides the row AND stops the nudge clock: the worst pair of failures this
    module has (raised unverifiable by QA round 3, so closed by construction).
    """
    for i in range(len(tail) - 1, -1, -1):
        # `live_work` also reads the shapes LIVE_SPINNER_RE cannot: a spinner
        # whose parenthetical is progress text (wrapped, e.g. right after a
        # compaction) and one in its first moments with no counter yet.
        if LIVE_SPINNER_RE.search(tail[i]) or live_work.is_live_spinner_line(tail, i):
            return i
        if allow_agent_lines and RUNNING_AGENT_RE.search(tail[i]):
            return i
    return None


def classify(text):
    """Classify a pane from its screen text: MOST RECENT EVIDENCE WINS.

    WHY POSITIONAL, NOT A PRIORITY CHAIN (rewritten 2026-09-03)
    ----------------------------------------------------------
    This used to be an ordered chain, and every ordering was wrong for some
    real pane, because a terminal is a log: which marker is TRUE is decided by
    which one happened LAST, not by which class it belongs to. Two QA rounds
    each found a hole that was really the same hole:

      * Crash-before-live: an already-retried transient error ("API Error: 500
        … Retrying in 1s (attempt 1/10)", which Claude Code prints inline and
        carries on from) sat in the window and read CRASHED for the rest of the
        turn — a top-urgency row whose own text proved the pane was alive.
      * Live-before-crash, the naive fix: a pane that crashed AFTER a spinner
        draw read ACTIVE. Far worse, because `pane_liveness.py` treats ACTIVE
        as "healthy, clock not running", so a crashed worker would never be
        nudged — the silent freeze this whole mechanism exists to prevent.
      * A 15-line window for permission patterns while everything else got 40:
        the HIGHEST-urgency detector had the NARROWEST reach, so a tall
        AskUserQuestion box (4 options with descriptions) pushed its own cursor
        line out of range and went silent.

    Position answers all three at once, with no windows to tune. Ties go to
    NEEDS_HUMAN: a prompt drawn on the same line as anything else is still a
    prompt, and under-reporting a human gate is the one failure mode that
    leaves a worker waiting forever.
    """
    lines = [l.rstrip() for l in text.splitlines()]
    tail = lines[-40:] if len(lines) > 40 else lines
    signal = last_signal_line(tail)

    permission_patterns = _permission_patterns(tail)
    candidates = []
    for state, patterns in (("NEEDS_HUMAN", permission_patterns), _CRASH_MARKER):
        i = _last_match_index(tail, patterns)
        if i is not None:
            candidates.append((i, state))

    asked_i = _last_match_index(tail, permission_patterns)
    selector_i = _selector_footer_index(tail)
    if selector_i is not None:
        candidates.append((selector_i, "NEEDS_HUMAN"))
        asked_i = selector_i if asked_i is None else max(asked_i, selector_i)

    login_i = signals.not_logged_in_index(tail)
    if login_i is not None:
        candidates.append((login_i, "NEEDS_LOGIN"))

    live_i = _last_live_index(tail, allow_agent_lines=asked_i is None)
    if live_i is not None:
        candidates.append((live_i, "ACTIVE"))

    if candidates:
        # Highest line index wins; NEEDS_HUMAN wins a tie.
        best = max(candidates, key=lambda c: (c[0], c[1] == "NEEDS_HUMAN"))
        if best[1] == "NEEDS_LOGIN":
            return best[1], tail[best[0]].strip().lstrip('⎿').strip()
        return best[1], signal

    # A done marker is the WEAKEST evidence, and is deliberately outside the
    # positional contest above: when a turn dies on an API error the turn also
    # ENDS, so Claude Code prints "✻ Crunched for 2m · done 3:14 PM" BELOW the
    # crash line. That epilogue is not evidence against the crash — treating it
    # positionally read a real 429 cooldown as WAITING (2026-08-15), which is
    # what widened the crash scan in the first place. So WAITING is reached
    # only when nothing stronger matched anywhere in the tail.
    # A tool call on the last line beats a done marker ABOVE it: the previous
    # turn's "✻ Crunched for 2m · done" stays in a 40-line tail long after the
    # next turn starts, and reading that as WAITING starts the auto-nudge clock
    # on a pane that is mid-Bash (QA round 3 — a real regression from moving the
    # done check up).
    tail_nonempty = [l for l in tail if l.strip()]
    if tail_nonempty and RUNNING_TOOL_TAIL_RE.match(tail_nonempty[-1].strip()):
        return "ACTIVE", signal

    other_tui = signals.opencode_state(tail)
    if other_tui is not None:
        return other_tui, signal

    # A turn that ENDED but left a Monitor / background task / agent running is
    # parked on purpose, not finished: a distinct state so nothing downstream
    # reads it as "turn ended, nobody picked it up" (the false `stalled`).
    parked = signals.background_work_open(tail)

    # Case-SENSITIVE, deliberately: _last_match_index() forces IGNORECASE, which
    # made "Waiting for 30s before retrying" and "Sleeping for 60s to let the
    # sim settle" read as a finished turn.
    if any(DONE_SPINNER_RE.search(l) for l in tail):
        return ("WAITING_ON_BACKGROUND" if parked else "WAITING"), signal

    return ("WAITING_ON_BACKGROUND" if parked else "UNKNOWN"), signal


def main():
    text = sys.stdin.read()
    state, signal = classify(text)
    print(f"{state}\t{signal}")


# ── AskUserQuestion block parser (chief dashboard "answer from the page") ──

#: An option row inside an AskUserQuestion picker, e.g. `❯ 1. Apple`,
#: `  2. [ ] Green`, `❯ 3. [✔] spike-ship-raft1`. Group 1 is the digit, group
#: 2 the optional checkbox contents, group 3 the label.
OPTION_LINE_RE = re.compile(
    r'^\s*(?:❯\s*)?(\d+)\.\s+(?:\[\s*([✔xX]?)\s*\]\s+)?(\S.*\S|\S)\s*$')
#: The current-cursor variant: only the row the cursor sits on carries `❯`.
CURSOR_OPTION_RE = re.compile(r'^\s*❯\s*(\d+)\.\s+')
#: The picker's exit row (`❯    Submit` when focused, `     Submit` when not)
#: — the multi-select's way out of its own box.
#:
#: `Next` is the same row under another name. v2.1.263 renders a whole
#: AskUserQuestion turn as ONE TABBED FORM (`←  ☐ Ships  ☐ Speed  ✔ Submit  →`)
#: instead of the sequential pickers this file was written against, and the
#: exit row is labelled for where it goes: `Next` on every question but the
#: last, `Submit` on the last. Knowing only the word `Submit` meant a
#: multi-select anywhere but last could never be parked on or left — the send
#: path pressed `down` twelve times and refused, with the boxes already ticked
#: (2026-09-06).
SUBMIT_ROW_RE = re.compile(r'^\s*(?:❯\s*)?(?:Submit|Next)\s*$')
#: The question title line carries a ballot-box glyph: `☐ Test fruit`
#: (single-select) or `←  ☒ Test colors  ✔ Submit  →` (multi-select). A plain
#: yes/no permission prompt has no such line, which is what keeps it out of
#: scope here.
TITLE_GLYPH_RE = re.compile(r'[☐☒]')
#: The review screen (`Review your answers … ❯ 1. Submit answers`) reuses
#: numbered `❯` rows. Answering THAT as if it were a question would double-
#: submit an answer the human already staged from the terminal — so a block
#: containing it never parses as an open question.
REVIEW_MARKERS_RE = re.compile(
    r'Review your answers|Ready to submit your answers\?|Submit answers')
#: The review screen's own action row, `❯ 1. Submit answers` (the row under it
#: is `2. Cancel` — which is why nothing here presses a key it has not first
#: confirmed the cursor is standing on).
REVIEW_SUBMIT_ROW_RE = re.compile(r'^\s*(❯\s*)?\d+\.\s+Submit answers\s*$')
#: How far above the last option row the review's own Submit row may sit.
REVIEW_BOX_LOOKBACK = 12
#: The always-present free-text row, haunting both shapes: `4. Type
#: something.` (single-select, note the trailing period) and
#: `3. [ ] Type something` (multi-select).
OTHER_LABEL_RE = re.compile(r'^\s*Type something\.?\s*$', re.IGNORECASE)


def _block_bounds(tail_lines, cursor_i):
    """(top, bottom) of the bordered block holding line `cursor_i`.

    Same border-bounded pattern as `_joined_recap`: the picker draws long box
    runs above and below its rows, and everything outside them (the "Chat
    about this" row, older answered questions) is not this question.
    """
    top = 0
    for r in range(cursor_i, -1, -1):
        if BOX_DRAWING_RUN_RE.search(tail_lines[r]):
            top = r + 1
            break
    bottom = len(tail_lines)
    for r in range(cursor_i + 1, len(tail_lines)):
        if BOX_DRAWING_RUN_RE.search(tail_lines[r]):
            bottom = r
            break
    return top, bottom


def _clean_title(line):
    """Strip box chrome, nav arrows and the header's own glyphs from a title."""
    s = re.sub(r'[─━│┃┌┐└┘├┤┬┴┼╭╮╰╯←→☐☒✔]', ' ', line)
    s = s.replace('Submit', ' ').strip()
    return re.sub(r'\s{2,}', ' ', s).strip()


def _is_desc_line(line):
    """Could this block line be an option's description text?"""
    s = line.strip()
    if not s:
        return False
    if SUBMIT_ROW_RE.match(line) or TITLE_GLYPH_RE.search(line):
        return False
    if REVIEW_MARKERS_RE.search(line):
        return False
    if CHROME_RE.match(s) or BOX_DRAWING_RUN_RE.search(s):
        return False
    if FOOTER_RE.search(s):
        return False
    return True


#: Startup-banner artifacts, not conversation: the model/billing header, the
#: cwd line, the MCP auth warning. They read as plain prose, so the context
#: walk must name them explicitly (measured 2026-09-05: a fresh pane's whole
#: banner landed in `context` above Q1).
CONTEXT_SKIP_RE = re.compile(
    r'API Usage Billing|MCP servers need authentication|Claude Code v\d'
    r'|~/|^\s*⚠')


def _context_above(lines, top, max_lines=5, max_chars=600):
    """Claude's last prose above the picker box, for answer context.

    Walks up past the box's top border collecting plain content lines.
    Structural lines are walls (an older box, title, or spent review screen
    ends the search — never contributes); chrome, borders, receipts (⏺/⎿),
    the human's own prompt-box typing (❯), and footers are transparent.
    Newest last (chronological), capped. "" when nothing readable sits above.
    """
    picked = []
    for i in range(top - 1, -1, -1):
        if len(picked) >= max_lines:
            break
        l = lines[i]
        s = l.strip()
        if not s:
            continue
        if (REVIEW_MARKERS_RE.search(s) or OPTION_LINE_RE.match(l)
                or SUBMIT_ROW_RE.match(l) or TITLE_GLYPH_RE.search(s)):
            break
        if CHROME_RE.match(s) or BOX_DRAWING_RUN_RE.search(s):
            continue
        if FOOTER_RE.search(s) or CONTEXT_SKIP_RE.search(s):
            continue
        if s[0] in ('❯', '⏺', '⎿'):
            continue
        # Wrapped continuation of the human's own prompt echo above a fresh
        # box: the line sits directly between the ❯ prompt (above) and the
        # box's own top border (below, past blanks). Both sides must hold —
        # Claude's own reply lines also sit under a ❯ prompt, but with reply
        # text (not the border) below them, so they are kept.
        j = i + 1
        while j < len(lines) and (
                not lines[j].strip()
                or BOX_DRAWING_RUN_RE.search(lines[j])):
            j += 1
        if j == top:
            k = i - 1
            while k >= 0 and not lines[k].strip():
                k -= 1
            if k >= 0 and lines[k].lstrip().startswith('❯'):
                continue
        picked.append(re.sub(r'\s{2,}', ' ', s))
    picked.reverse()
    return ' '.join(picked).strip()[:max_chars]


def review_screen_open(tail_lines):
    """True when the pane is parked on an AskUserQuestion form's REVIEW step.

    v2.1.263 renders a whole turn as one tabbed form, and answering its last
    question always lands here — single- and multi-select alike:

        ←  ☒ Fruit  ☒ Colour  ✔ Submit  →
        Review your answers
         ● Which fruit?  → Apple
        Ready to submit your answers?
        ❯ 1. Submit answers
          2. Cancel

    Before that build only a multi-select reached a review, so the answer path
    read "review still on screen" purely as evidence that a send had FAILED.
    It is the opposite: the send landed, and the form is waiting for its last
    keypress. Detecting it without pressing it left the worker frozen on
    `Submit answers` while the dashboard reported the answer lost (2026-09-06).

    "Open" is structural, exactly as in `_prompt_box_signal`: the review's
    numbered rows must be the last thing on the pane apart from hint/chrome.
    A SPENT review screen sitting in scrollback above a resumed turn's output
    therefore reads closed — which is what stops the caller pressing `enter`
    into a live prompt box.
    """
    last_opt = _open_option_block(tail_lines)
    if last_opt is None:
        return False
    for i in range(last_opt, max(-1, last_opt - REVIEW_BOX_LOOKBACK), -1):
        if BOX_DRAWING_RUN_RE.search(tail_lines[i]):
            break
        if REVIEW_SUBMIT_ROW_RE.match(tail_lines[i]):
            return True
    return False


def cursor_on_review_submit(tail_lines):
    """True when the review screen's cursor stands on `Submit answers`.

    The row below it is `Cancel`, which throws the answers away — so the
    caller confirms this before it presses `enter`, never after.
    """
    return any(REVIEW_SUBMIT_ROW_RE.match(l) and l.lstrip().startswith('❯')
               for l in tail_lines)


def parse_question_block(tail_lines):
    """Parse an open AskUserQuestion picker out of a pane tail, or None.

    Returns a JSON-safe dict {title, question, multi, options, cursorIndex,
    otherIndex, hasSubmit, context} where options is
    [{index, label, desc, checked, other}] in displayed order (`desc` is the
    indented description line(s) under the option, or "") and `context` is
    Claude's last prose above the box (or ""). Returns None for anything that
    is not an answerable AskUserQuestion shape — a closed pane, a plain yes/no
    permission prompt (no ballot-box title, no Other row), or the mid-submit
    review screen.
    """
    lines = [l.rstrip() for l in tail_lines]
    cursor_i = None
    for i in range(len(lines) - 1, -1, -1):
        if CURSOR_OPTION_RE.match(lines[i]):
            cursor_i = i
            break
    if cursor_i is None:
        return None

    top, bottom = _block_bounds(lines, cursor_i)
    block = lines[top:bottom]

    # The review screen (`Review your answers … ❯ 1. Submit answers`) reuses
    # numbered `❯` rows, and answering THAT as if it were a question would
    # double-submit an answer the human already staged from the terminal.
    # Scoped to THIS block, not the whole tail: a multi-question turn leaves
    # each answer's spent review screen in scrollback, and a whole-tail check
    # made every question after the first unparsable (panel gone, worker
    # stuck on Q3 with only the terminal to answer from — 2026-09-05).
    if any(REVIEW_MARKERS_RE.search(l) for l in block):
        return None

    title = None
    for l in block:
        if TITLE_GLYPH_RE.search(l):
            title = _clean_title(l)
            break
    if not title:
        return None

    options = []
    first_opt = last_opt = None
    for r, l in enumerate(block):
        m = OPTION_LINE_RE.match(l)
        if not m:
            # A description line under an option ("Crisp red fruit"): no digit
            # of its own, so it never matches above — attach it to the running
            # option instead of dropping it. Anything structural (submit row,
            # chrome, borders, footers, an old review remnant) ends the run
            # rather than becoming answer text.
            if options and _is_desc_line(l):
                prev = options[-1]
                bit = l.strip()
                if bit and prev['desc'] != bit:
                    prev['desc'] = (prev['desc'] + ' ' + bit).strip()[:300]
            continue
        # A wrapped label continuation lands in `desc` too — cosmetically it
        # reads as one line under the option, which is where it belongs.
        idx = int(m.group(1))
        checked = (m.group(2) or '') in ('✔', 'x', 'X')
        label = m.group(3).strip()
        other = bool(OTHER_LABEL_RE.match(label))
        options.append({
            'index': idx, 'label': label, 'desc': '',
            'checked': checked, 'other': other,
        })
        if first_opt is None:
            first_opt = r
        last_opt = r
    if len(options) < 2:
        return None
    if not any(o['other'] for o in options):
        # Someone already typed into the free-text row (typing REPLACES the
        # "Type something" placeholder with their text — measured in the
        # spike), or the tool rendered it last without the exact label. The
        # tool always appends its free-text row LAST, so position is the
        # backup detector. Permission prompts still cannot reach here: they
        # have no ballot-box title line (checked above).
        options[-1]['other'] = True
    other_idx = next(
        (o['index'] for o in options if o['other']), None)

    # The question is the prose between the title line and the first option
    # (it wraps: join the content lines, skip chrome/empties).
    question_parts = []
    for l in block[:first_opt]:
        s = l.strip()
        if not s or TITLE_GLYPH_RE.search(l):
            continue
        if CHROME_RE.match(s) or BOX_DRAWING_RUN_RE.search(s):
            continue
        if FOOTER_RE.search(s):
            continue
        question_parts.append(s)
    question = re.sub(r'\s{2,}', ' ', ' '.join(question_parts)).strip()
    if not question:
        question = title

    multi = any('[' in (l) and ']' in (l) for l in block
                if OPTION_LINE_RE.match(l))
    cursor_m = CURSOR_OPTION_RE.match(lines[cursor_i])
    has_submit = any(SUBMIT_ROW_RE.match(l) for l in block)

    return {
        'title': title,
        'question': question,
        'multi': multi,
        'options': options,
        'cursorIndex': int(cursor_m.group(1)),
        'otherIndex': other_idx,
        'hasSubmit': has_submit,
        'context': _context_above(lines, top),
    }


def question_cursor_on_exit(tail_lines):
    """True when an open AskUserQuestion picker's cursor sits on its own
    Submit/Next exit row (`❯    Submit` / `❯    Next`), False otherwise —
    additive sibling to `parse_question_block` (dashboard-answer-stray-
    enter brief, item 2), which cannot see this cursor position at all:
    its own cursor search (`CURSOR_OPTION_RE`) requires a `❯ <digit>.` row,
    so a picker parked on the exit row reads identically (None) to a form
    that has genuinely closed. A caller reading that None has no way to
    tell "picker still open, one more Enter would submit it" from "form is
    gone, nothing to send". Real capture (dashboard-answer-stray-enter
    brief, 2026-09-20): a multi-select with 4 checked rows, cursor parked
    on `❯    Submit`.

    Named without the `parse_` prefix on purpose — like its boolean
    siblings `review_screen_open`/`cursor_on_review_submit`, that prefix
    is reserved here for functions returning a parsed dict, not a bare
    state check.

    Does NOT change `parse_question_block`'s return value or any existing
    caller's behavior — this is a wholly separate read of the same tail.
    Boolean only, not a shape: nothing today needs more than "is it
    parked here", and a corroborating title/question can be added later
    without breaking this contract.

    Structural, not textual, same as `parse_question_block`: the exit
    row's own block is bounded by `_block_bounds` (borders above/below),
    and must carry a ballot-box title line (`TITLE_GLYPH_RE`), no
    review-screen marker, and at least 2 real numbered option rows
    (`OPTION_LINE_RE`) — the same admission gate `parse_question_block`
    uses (`len(options) < 2`) so both "is this an open question" checks
    agree on what counts as one, not just a stray ☐/☒ title glyph with an
    unrelated Submit-shaped row nearby.
    """
    lines = [l.rstrip() for l in tail_lines]
    cursor_i = None
    for i in range(len(lines) - 1, -1, -1):
        if SUBMIT_ROW_RE.match(lines[i]) and lines[i].lstrip().startswith('❯'):
            cursor_i = i
            break
    if cursor_i is None:
        return False
    top, bottom = _block_bounds(lines, cursor_i)
    block = lines[top:bottom]
    if not any(TITLE_GLYPH_RE.search(l) for l in block):
        return False
    if any(REVIEW_MARKERS_RE.search(l) for l in block):
        return False
    if sum(1 for l in block if OPTION_LINE_RE.match(l)) < 2:
        return False
    return True


#: Title wording for a plain permission box — mutually exclusive with
#: `TITLE_GLYPH_RE`'s ballot-box AskUserQuestion title. Narrowed to a whole
#: line (unlike the eager any-line `PERMISSION_WORDING_PATTERNS` above, which
#: exists to catch an agent merely TALKING about a prompt) since this one
#: decides whether to parse a structured, sendable box.
#:
#: The edit-box wording ("Do you want to make this edit to <name>?") is a
#: real capture (2026-09-19, pane wB:p3K — see the `edit_box` selftest
#: fixture). "Do you want to create <file>?" (Write making a NEW file) is
#: NOT added here — no real capture or existing fixture confirms its exact
#: wording, and this file's own rule is "return null rather than a guess",
#: so an unverified box shape stays unrecognized (None) until one is seen.
PERMISSION_TITLE_RE = re.compile(
    r'^\s*(Do you want to proceed\?'
    r'|Would you like to proceed\?'
    r'|Do you want to make this edit to .+\?)\s*$')
#: The `⏺ Tool(args)` receipt line Claude prints right before asking
#: permission for that call, e.g. `⏺ Bash(rm -rf /tmp/...)`,
#: `⏺ Write(scripts/foo.py)`, `⏺ Update(.claude/chief-mode)`. This is the one
#: field the whole feature exists to expose, so no receipt found above the
#: title means no confident answer — `parse_permission_block` returns None
#: rather than a guess.
PERMISSION_RECEIPT_RE = re.compile(r'^\s*⏺\s*([A-Za-z]\w*)\((.*)\)\s*$')
#: How far above the title line to look for that receipt. An edit box has a
#: bordered "Edit file"/path header plus a diff excerpt sitting BETWEEN the
#: receipt and the title (real capture: 9 lines) — wider than a bare Bash
#: prompt's 2-3 — so this must clear that plus headroom for a longer diff.
#: Generous on purpose: an unrelated receipt is never picked up regardless
#: of width, because the walk below stops at the first structural wall
#: (another prompt's own title/cursor/review marker), not just at this line
#: count. Trade-off: an edit whose diff excerpt runs past ~45 lines pushes
#: its OWN receipt out of range too, and the whole block then reads None
#: (fails closed — no tool/detail is exposed, not a guessed one).
PERMISSION_RECEIPT_LOOKBACK = 60
#: A border ROW — nothing else on the line. Stricter than the substring-
#: anywhere `BOX_DRAWING_RUN_RE` (used elsewhere to find a border on an
#: otherwise-mixed line, e.g. an AskUserQuestion picker's title row): the
#: walk below crosses through an edit box's own diff EXCERPT, i.e.
#: arbitrary file content, and a diff line can itself contain a substring
#: that merely LOOKS like a border (e.g. a line that edits this very
#: file's own 40-dash border-constant string) — `BOX_DRAWING_RUN_RE` would
#: miscount that content line as a real border and corrupt the excerpt
#: extraction below (QA-caught 2026-09-19, reproduced against a diff
#: touching classify_pane.py's own border constants). A genuine border
#: row is never anything but the border.
PERMISSION_BORDER_LINE_RE = re.compile(r'^[─-╿]{20,}$')
#: Title/cursor/glyph/marker lines that mean "a DIFFERENT prompt's chrome,
#: stop" — same shapes `parse_question_block`'s own box uses to tell one
#: turn from another. Checked ONLY on lines the walk has not yet
#: recognized as inside this box's own bordered furniture (see the walk
#: below) — an edit box's diff excerpt is arbitrary file content and WILL
#: sometimes contain a literal ☐/☒ or "Review your answers"/"Submit
#: answers" substring (this file's own fixtures do), which would
#: otherwise read as a false wall and drop the whole permission block to
#: None despite a real receipt sitting right above (QA-caught 2026-09-19,
#: reproduced by diffing this file's own `TITLE_GLYPH_RE` line).
_PERMISSION_RECEIPT_WALLS = (PERMISSION_TITLE_RE, TITLE_GLYPH_RE,
                             CURSOR_OPTION_RE, REVIEW_MARKERS_RE,
                             SUBMIT_ROW_RE)
#: Cap on how much of an edit's diff excerpt rides along in `detail` — the
#: human must see WHAT changes, not the whole file. Truncation is noted
#: rather than silently dropped.
PERMISSION_DIFF_EXCERPT_MAX_LINES = 20


def _permission_receipt_and_diff(lines, title_abs):
    """(tool, detail) for the box at `title_abs`, or (None, None).

    Walks upward from the title for the `⏺ Tool(args)` receipt
    (`PERMISSION_RECEIPT_LOOKBACK` lines, or until a wall, whichever comes
    first). A Bash-style prompt has nothing but blank/chrome between
    receipt and title, so `detail` is just the receipt's own args and the
    walls (`_PERMISSION_RECEIPT_WALLS`) apply the whole way, exactly as
    before this box shape existed.

    An edit box additionally draws a bordered header ("Edit file" / path)
    then a bordered diff excerpt between receipt and title — a single
    contiguous unit belonging to THIS box, never another prompt's chrome.
    So once the walk crosses the FIRST real border row
    (`PERMISSION_BORDER_LINE_RE`), wall-checking turns off for the rest of
    the walk: everything from there up to the receipt is this box's own
    furniture/diff content, and checking it against the walls only risks
    a false hit on content that happens to contain a wall-shaped substring
    (see `_PERMISSION_RECEIPT_WALLS`'s comment). Walls stay fully active
    below the first border, which is exactly where a genuinely different,
    already-resolved prompt's leftover cursor/title row could still be
    sitting in scrollback.

    The diff excerpt itself is recognized purely by BORDER POSITION (the
    last two `PERMISSION_BORDER_LINE_RE` rows before the title), not by
    header wording, so it works the same for "Edit file" and any future
    "Create file" header without needing to special-case either. It's
    appended to `detail`, capped and marked if longer than
    `PERMISSION_DIFF_EXCERPT_MAX_LINES`.
    """
    receipt_i = None
    tool = detail = None
    floor = max(-1, title_abs - 1 - PERMISSION_RECEIPT_LOOKBACK)
    inside_bordered_panel = False
    for i in range(title_abs - 1, floor, -1):
        line = lines[i]
        m = PERMISSION_RECEIPT_RE.match(line)
        if m:
            receipt_i = i
            tool, detail = m.group(1), m.group(2).strip()
            break
        if PERMISSION_BORDER_LINE_RE.match(line):
            inside_bordered_panel = True
            continue
        if not inside_bordered_panel and any(
                w.search(line) for w in _PERMISSION_RECEIPT_WALLS):
            break
    if tool is None:
        return None, None

    border_indices = [i for i in range(receipt_i + 1, title_abs)
                       if PERMISSION_BORDER_LINE_RE.match(lines[i])]
    if len(border_indices) >= 2:
        diff_lines = list(lines[border_indices[-2] + 1:border_indices[-1]])
        if diff_lines:
            shown = diff_lines[:PERMISSION_DIFF_EXCERPT_MAX_LINES]
            extra = len(diff_lines) - len(shown)
            excerpt = '\n'.join(shown)
            if extra > 0:
                excerpt += f'\n… ({extra} more line(s) truncated)'
            detail = f'{detail}\n{excerpt}'
    return tool, detail


def parse_permission_block(tail_lines):
    """Parse an open plain yes/no permission box out of a pane tail, or None.

    Returns a JSON-safe dict {tool, detail, title, options, cursorIndex}
    where options is [{index, label}] in displayed order. Mutually exclusive
    with `parse_question_block`'s AskUserQuestion shape: bails on a
    ballot-box title (`TITLE_GLYPH_RE`) or a review screen
    (`REVIEW_MARKERS_RE`) sharing the block. Lenient by design — anything not
    confidently read (non-Claude panes, plan-mode approvals, a permission-
    worded box with no `⏺ Tool(args)` receipt above it, an unverified "Do
    you want to …?" wording not in `PERMISSION_TITLE_RE`) returns None
    rather than a guess.

    Covers both shapes seen so far: a bare Bash-style yes/no ("Do you want
    to proceed?", `detail` = the command) and an Edit/Update file box ("Do
    you want to make this edit to <name>?", `detail` = the file path plus a
    capped diff excerpt when one is drawn — see `_permission_receipt_and_diff`).
    """
    lines = [l.rstrip() for l in tail_lines]
    cursor_i = None
    for i in range(len(lines) - 1, -1, -1):
        if CURSOR_OPTION_RE.match(lines[i]):
            cursor_i = i
            break
    if cursor_i is None:
        return None

    top, bottom = _block_bounds(lines, cursor_i)
    block = lines[top:bottom]
    if any(TITLE_GLYPH_RE.search(l) for l in block):
        return None
    if any(REVIEW_MARKERS_RE.search(l) for l in block):
        return None

    title_abs = None
    for i in range(top, bottom):
        if PERMISSION_TITLE_RE.match(lines[i]):
            title_abs = i
            break
    if title_abs is None:
        return None

    options = []
    for l in lines[title_abs + 1:bottom]:
        m = OPTION_LINE_RE.match(l)
        if m:
            options.append({'index': int(m.group(1)), 'label': m.group(3).strip()})
    if len(options) < 2:
        return None
    cursor_m = CURSOR_OPTION_RE.match(lines[cursor_i])

    tool, detail = _permission_receipt_and_diff(lines, title_abs)
    if tool is None:
        return None

    return {
        'tool': tool,
        'detail': detail,
        'title': lines[title_abs].strip(),
        'options': options,
        'cursorIndex': int(cursor_m.group(1)),
    }


#: The ExitPlanMode plan-approval box's title — a full, fixed sentence,
#: never one of `PERMISSION_TITLE_RE`'s shorter alternatives, so the two
#: never collide (`parse_permission_block` already returns None on this box
#: from title alone — its own docstring names "plan-mode approvals" as a
#: known gap; this is the parser that fills it). Real capture (dashboard-
#: plan-approval brief, throwaway panes wB:p3X/wB:p3Y, 2026-09-20):
#: reproduced 4 times across 2 throwaway `claude-aptus` panes, byte-
#: identical wording every time.
PLAN_APPROVAL_TITLE_RE = re.compile(
    r'^\s*Claude has written up a plan and is ready to execute\.\s*'
    r'Would you like to proceed\?\s*$')
#: The footer line naming the plan file, e.g. "ctrl+g to edit in Vim ·
#: ~/.claude/plans/dapper-strolling-sprout.md" (same real captures as
#: above). Returned EXACTLY as rendered — the leading "~" is NOT expanded:
#: this module never knows which machine/user is actually running the pane
#: (R2 exists precisely because remote machines are real), so expanding
#: against the dashboard SERVER's own home directory could silently name
#: the wrong file. Absent from the block -> `planPath` is None, never
#: guessed.
PLAN_PATH_FOOTER_RE = re.compile(
    r'ctrl\+g to edit in Vim\s*·\s*(\S+\.md)\s*$')
#: The footer prefix ALONE, with no path on the same line — a narrower pane
#: pushes the path onto the next line(s) entirely (dashboard-plan-box-
#: wrapped brief, real capture 2026-09-20).
PLAN_PATH_FOOTER_PREFIX_RE = re.compile(r'ctrl\+g to edit in Vim\s*·\s*$')
#: How many extra physical lines to scan for a path once the bare prefix
#: (above) is seen — one for "path is whole on the very next line", a couple
#: more for "the path itself is long enough to wrap again with no space".
_PLAN_PATH_MAX_WRAP_LINES = 3


def _join_wrapped_lines(lines, start, end, max_lines=3):
    """Yield `(joined_text, lines_consumed)` for joining 1..max_lines
    physical lines starting at `start`, each stripped and rejoined with a
    single space then whitespace-normalised — smallest join first.

    Exists because a narrow pane makes Claude Code's OWN renderer hard-wrap
    fixed prompt text into real newlines (this is the app computing its own
    layout for the reported terminal width, not the terminal reflowing a
    long line — `herdr pane read --source recent-unwrapped` cannot undo it,
    since there is no single logical line to unwrap back to; see
    `parse_plan_approval_block`'s docstring). A caller tries its exact-text
    regex against each join in turn and stops at the first match — this
    never guesses which line count is right, the regex alone decides, so a
    coincidental partial match can't silently win over the real one.
    """
    for n in range(1, max_lines + 1):
        if start + n > end:
            break
        joined = ' '.join(l.strip() for l in lines[start:start + n])
        yield re.sub(r'\s{2,}', ' ', joined).strip(), n


def parse_plan_approval_block(tail_lines):
    """Parse an open ExitPlanMode plan-approval box out of a pane tail, or
    None.

    Returns {tool, kind, detail, title, options, cursorIndex, planPath} —
    the same object shape `parse_permission_block` returns (`row.permission`)
    plus two additive fields (`kind`, `planPath`). `tool` is always the
    literal "ExitPlanMode" and `detail` is always None: unlike a Bash/Edit
    permission box, this one has no `⏺ Tool(args)` receipt above it to read
    either from (confirmed on all 4 real captures above). `kind` is always
    "plan" — an explicit marker a client can check without string-matching
    `tool`.

    Mutually exclusive with `parse_permission_block`/`parse_question_block`
    by construction: gated on `PLAN_APPROVAL_TITLE_RE`, a full sentence that
    never matches `PERMISSION_TITLE_RE`'s shorter alternatives or
    `TITLE_GLYPH_RE`'s ballot-box title, and this function bails on a
    ballot-box title or review screen sharing the block, same as the other
    two parsers.

    Options are read purely structurally (`OPTION_LINE_RE`), not enumerated
    or wording-matched the way `parse_permission_block`'s allow/deny options
    are — this box's exact option wording is known to vary by Claude Code
    version/settings (e.g. an unverified "Yes, and bypass permissions"
    variant), and this file's rule is to read what is actually on screen
    rather than encode an allowlist of guesses. Only the TITLE must match
    exactly; an unverified title still returns None.

    WRAP-TOLERANT (dashboard-plan-box-wrapped brief, 2026-09-20): a narrow
    pane makes Claude Code hard-wrap its own fixed title sentence and the
    "ctrl+g to edit in Vim · <path>" footer across real newlines — this is
    the APP's own layout for the reported terminal width, baked into the
    actual bytes, not a terminal-emulator reflow. Inferred, not itself
    independently re-tested here: the PO's own report (real narrow capture,
    throwaway pane wB:p44) says an unwrapped re-read of the SAME pane still
    failed to parse ("wrapped or my manual unwrap of it"), which is
    consistent with this being a hard-wrap a terminal-level unwrap can't
    reverse, but no live `recent-unwrapped` re-read was captured to confirm
    the mechanism directly. The title is matched by joining 1-3 physical
    lines (`_join_wrapped_lines`) and testing the exact-sentence regex
    against each join — never a guess, the fixed sentence still has to
    match verbatim once rejoined. The footer's path is joined the same way
    when it lands on its own line(s) after a bare "ctrl+g to edit in
    Vim ·" — WITHOUT a space, since a path has none internally and the
    wrap only ever splits it mid-token — but only from a candidate line
    preceded by a blank line, and only when exactly one such candidate
    exists in the block (see the footer-scan comment below for why).
    """
    lines = [l.rstrip() for l in tail_lines]
    cursor_i = None
    for i in range(len(lines) - 1, -1, -1):
        if CURSOR_OPTION_RE.match(lines[i]):
            cursor_i = i
            break
    if cursor_i is None:
        return None

    top, bottom = _block_bounds(lines, cursor_i)
    block = lines[top:bottom]
    if any(TITLE_GLYPH_RE.search(l) for l in block):
        return None
    if any(REVIEW_MARKERS_RE.search(l) for l in block):
        return None

    title_abs = title_text = None
    title_lines = 1
    for i in range(top, bottom):
        for joined, n in _join_wrapped_lines(lines, i, bottom):
            if PLAN_APPROVAL_TITLE_RE.match(joined):
                title_abs, title_text, title_lines = i, joined, n
                break
        if title_abs is not None:
            break
    if title_abs is None:
        return None

    options = []
    i = title_abs + title_lines
    while i < bottom:
        m = OPTION_LINE_RE.match(lines[i])
        if m:
            options.append({'index': int(m.group(1)), 'label': m.group(3).strip()})
        i += 1
    if len(options) < 2:
        return None
    cursor_m = CURSOR_OPTION_RE.match(lines[cursor_i])

    # Footer: a SEPARATE pass over the same range, not interleaved with the
    # option scan above, and gated on the same structural cue every real
    # capture shows — a blank line between the last option's own content
    # and "ctrl+g to edit in Vim · <path>" (QA-caught 2026-09-20: without
    # this anchor, a coincidental line reading exactly like the footer
    # phrase — e.g. a wrapped OPTION label's own continuation line, which
    # is never blank-preceded — could fabricate a planPath out of nothing,
    # or a second such line later in the block could silently clobber a
    # real one via bare last-match-wins). More than one blank-preceded
    # candidate is ambiguous and refuses rather than guessing which is
    # real, same "never guess" rule `parse_plan_approval_block` already
    # applies to a missing/unverified title.
    plan_path_candidates = []
    i = title_abs + title_lines
    while i < bottom:
        l = lines[i]
        preceded_by_blank = i - 1 >= 0 and lines[i - 1].strip() == ''
        if preceded_by_blank:
            m = PLAN_PATH_FOOTER_RE.search(l)
            if m:
                plan_path_candidates.append(m.group(1))
                i += 1
                continue
            if PLAN_PATH_FOOTER_PREFIX_RE.search(l):
                # The path didn't fit next to the prefix — collect raw
                # (unspaced) fragments from the following lines until one
                # completes a ".md" path or something structural (a blank
                # line, chrome, a border) proves the footer ended without
                # one.
                frag = ''
                j = i + 1
                limit = min(bottom, i + 1 + _PLAN_PATH_MAX_WRAP_LINES)
                while j < limit:
                    cand = lines[j].strip()
                    if not cand or ' ' in cand or CHROME_RE.match(cand) \
                            or BOX_DRAWING_RUN_RE.search(cand):
                        break
                    frag += cand
                    j += 1
                    if frag.endswith('.md'):
                        break
                if frag.endswith('.md'):
                    plan_path_candidates.append(frag)
                    i = j
                    continue
        i += 1
    plan_path = (plan_path_candidates[0]
                 if len(plan_path_candidates) == 1 else None)

    return {
        'tool': 'ExitPlanMode',
        'kind': 'plan',
        'detail': None,
        'title': title_text,
        'options': options,
        'cursorIndex': int(cursor_m.group(1)),
        'planPath': plan_path,
    }


def parse_permission_or_plan_block(tail_lines):
    """`parse_permission_block(tail_lines)`, falling back to
    `parse_plan_approval_block(tail_lines)`.

    The two are mutually exclusive by construction (disjoint title regexes),
    so at most one of them ever returns non-None. One shared call site for
    both the dashboard feed reads and the /api/permission send path, so a
    future caller can't wire up one parser and forget the other.
    """
    return parse_permission_block(tail_lines) or parse_plan_approval_block(tail_lines)


def _selftest_parse():
    """Fixed fixtures from the 2026-09-04 herdr spike (throwaway claude-aptus
    tab): one single-select, one multi-select with checks + typed Other text,
    one review screen (must NOT parse), one plain permission prompt (must NOT
    parse). Run: python3 scripts/lib/classify_pane.py --selftest-parse."""
    single = '\n'.join([
        '────────────────────────────────────────',
        ' ☐ Test fruit',
        '',
        'Pick a test fruit',
        '',
        '❯ 1. Apple',
        '     Test option A',
        '  2. Banana',
        '     Test option B',
        '  3. Cherry',
        '     Test option C',
        '  4. Type something.',
        '────────────────────────────────────────',
        '  5. Chat about this',
        '',
        'Enter to select · ↑/↓ to navigate · Esc to cancel',
    ])
    multi = '\n'.join([
        '────────────────────────────────────────',
        '←  ☒ Test ships  ✔ Submit  →',
        '',
        'Pick test ships',
        '',
        '  1. [✔] Canoe',
        '  Test option A',
        '  2. [ ] Kayak',
        '  Test option B',
        '❯ 3. [✔] spike-ship-raft1',
        '     Submit',
        '────────────────────────────────────────',
        '  4. Chat about this',
    ])
    review = '\n'.join([
        'Review your answers',
        '',
        ' ● Pick test ships',
        '   → Canoe, spike-ship-raft1',
        '',
        'Ready to submit your answers?',
        '',
        '❯ 1. Submit answers',
        '  2. Cancel',
    ])
    permission = '\n'.join([
        'Do you want to proceed?',
        '',
        '❯ 1. Yes',
        '  2. No',
    ])
    # Q3 of a multi-question turn: a SPENT review screen from Q2 lingers in
    # scrollback above the open box — must still parse (2026-09-05 panel-gone
    # bug). Includes a prose line above the box for the context check.
    third = '\n'.join([
        'Review your answers',
        '',
        ' ● Pick colors',
        '   → Red',
        '',
        'Ready to submit your answers?',
        '',
        '❯ 1. Submit answers',
        '  2. Cancel',
        'I checked the manifest — two red flags, pick how to proceed.',
        '────────────────────────────────────────',
        ' ☐ Fruit Q',
        '',
        'Pick a fruit',
        '',
        '❯ 1. Apple',
        '     Crisp red fruit',
        '  2. Banana',
        '     Long yellow fruit',
        '  3. Type something.',
        '────────────────────────────────────────',
        '  4. Chat about this',
        '',
        'Enter to select · ↑/↓ to navigate · Esc to cancel',
    ])
    cases = [
        ('single', single.splitlines(), {
            'title': 'Test fruit', 'question': 'Pick a test fruit',
            'multi': False, 'cursorIndex': 1, 'otherIndex': 4,
            'labels': ['Apple', 'Banana', 'Cherry', 'Type something.'],
            'descs': ['Test option A', 'Test option B', 'Test option C', ''],
            'context': '',
        }),
        ('multi', multi.splitlines(), {
            'title': 'Test ships', 'question': 'Pick test ships',
            'multi': True, 'cursorIndex': 3, 'otherIndex': 3,
            'labels': ['Canoe', 'Kayak', 'spike-ship-raft1'],
            'descs': ['Test option A', 'Test option B', ''],
            'context': '',
        }),
        ('review', review.splitlines(), None),
        ('permission', permission.splitlines(), None),
        ('third', third.splitlines(), {
            'title': 'Fruit Q', 'question': 'Pick a fruit',
            'multi': False, 'cursorIndex': 1, 'otherIndex': 3,
            'labels': ['Apple', 'Banana', 'Type something.'],
            'descs': ['Crisp red fruit', 'Long yellow fruit', ''],
            'context': 'I checked the manifest — two red flags, pick how to proceed.',
        }),
    ]
    fail = 0
    for name, tail, want in cases:
        got = parse_question_block(tail)
        if want is None:
            if got is not None:
                print(f'FAIL {name}: expected None, got {got!r}');
                fail = 1
            else:
                print(f'PASS {name} -> None')
            continue
        if got is None:
            print(f'FAIL {name}: expected a question, got None');
            fail = 1
            continue
        got_labels = [o['label'] for o in got['options']]
        got_descs = [o['desc'] for o in got['options']]
        bad = [k for k in ('title', 'question', 'multi', 'cursorIndex',
                           'otherIndex', 'context') if got[k] != want[k]]
        if got_labels != want['labels']:
            bad.append(f"labels {got_labels!r}")
        if got_descs != want['descs']:
            bad.append(f"descs {got_descs!r}")
        if bad:
            print(f'FAIL {name}: {bad} (got {got!r})');
            fail = 1
        else:
            print(f'PASS {name} -> {got["title"]!r} multi={got["multi"]}')
    # The multi fixture's Other row must read checked (typed + enter).
    got = parse_question_block(multi.splitlines())
    other = next(o for o in got['options'] if o['other'])
    if not other['checked']:
        print('FAIL multi-other: expected checked Other row');
        fail = 1
    else:
        print('PASS multi-other checked')

    # ── parse_permission_block: same GATE_PERMISSION_PROMPT shape as
    # scripts/tests/test_classify_pane.py, plus a 2-option variant, plus the
    # two None cases the brief calls out (an AskUserQuestion box; a
    # permission-worded box with no `⏺ Tool(...)` receipt above it).
    permission_3opt = '\n'.join([
        '⏺ Bash(rm -rf /tmp/aptusfit-maestro-sim.lock)',
        '  ⎿  Running…',
        '',
        'Do you want to proceed?',
        '❯ 1. Yes',
        "  2. Yes, and don't ask again for rm commands in /tmp",
        '  3. No, tell Claude what to do differently (esc)',
    ])
    permission_2opt = '\n'.join([
        '⏺ Write(scripts/foo.py)',
        '  ⎿  (no content)',
        '',
        'Do you want to proceed?',
        '❯ 1. Yes',
        '  2. No',
    ])
    permission_no_receipt = '\n'.join([
        'Do you want to proceed?',
        '❯ 1. Yes',
        '  2. No',
    ])
    # Real capture, pane wB:p3K, 2026-09-19 (agentbar-permission-edit-boxes
    # brief) — an Edit/Update box: bordered "Edit file"/path header, a
    # bordered 2-line diff excerpt, then the edit-flavored title wording and
    # the "for this session" (not "don't ask again") allow-always label.
    permission_edit_box = '\n'.join([
        '⏺ Update(.claude/chief-mode)',
        '',
        '────────────────────────────────────────',
        ' Edit file',
        ' .claude/chief-mode',
        '╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌',
        ' 1  on 2026-09-15T04:21:16+00:00 84ac01f3-…',
        ' 2 +',
        '╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌',
        ' Do you want to make this edit to chief-mode?',
        ' ❯ 1. Yes',
        "   2. Yes, and allow Claude to edit files in this project's .claude folder for this session",
        '   3. No',
        '',
        ' Esc to cancel · Tab to amend',
    ])
    # Synthetic: same shape, but the diff excerpt runs past
    # PERMISSION_DIFF_EXCERPT_MAX_LINES (20) — proves the cap and the
    # truncation note, not just the happy 2-line case above.
    long_diff_rows = [f' {n} +some line {n}' for n in range(1, 26)]  # 25 lines
    permission_edit_box_long_diff = '\n'.join([
        '⏺ Write(scripts/long.py)',
        '',
        '────────────────────────────────────────',
        ' Create file',
        ' scripts/long.py',
        '╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌',
        *long_diff_rows,
        '╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌',
        ' Do you want to make this edit to long.py?',
        ' ❯ 1. Yes',
        '   2. No',
    ])
    # Regression, QA-caught 2026-09-19: an edit TO this very file, whose diff
    # excerpt edits a border-constant string literal — the excerpt's own
    # content contains a run of box-drawing chars that must NOT be miscounted
    # as a real border (that bug emptied the diff to nothing, no warning).
    permission_edit_box_diff_has_border_lookalike = '\n'.join([
        '⏺ Update(scripts/lib/classify_pane.py)',
        '',
        '────────────────────────────────────────',
        ' Edit file',
        ' scripts/lib/classify_pane.py',
        '╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌',
        " 10  BORDER = '────────────────────────────────────────'",
        " 11 +BORDER2 = '────────────────────────────────────────'",
        '╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌',
        ' Do you want to make this edit to classify_pane.py?',
        ' ❯ 1. Yes',
        '   2. No',
    ])
    # Regression, QA-caught 2026-09-19: a diff excerpt containing a literal
    # ☐/☒ glyph (this file's own TITLE_GLYPH_RE line) must not be mistaken
    # for a DIFFERENT prompt's ballot-box title and drop the whole block to
    # None — the wall check must stay off once inside this box's own border.
    permission_edit_box_diff_has_wall_lookalike = '\n'.join([
        '⏺ Update(scripts/lib/classify_pane.py)',
        '',
        '────────────────────────────────────────',
        ' Edit file',
        ' scripts/lib/classify_pane.py',
        '╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌',
        " 487  TITLE_GLYPH_RE = re.compile(r'[☐☒]')",
        ' 488 +# a comment change nearby',
        '╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌',
        ' Do you want to make this edit to classify_pane.py?',
        ' ❯ 1. Yes',
        '   2. No',
    ])
    # No verified capture or fixture for "Do you want to create <file>?" —
    # confirms it's structurally impossible to match today (PERMISSION_
    # TITLE_RE has no such alternative), not just untested.
    permission_create_box_unverified = '\n'.join([
        '⏺ Write(scripts/new.py)',
        '',
        'Do you want to create scripts/new.py?',
        '❯ 1. Yes',
        '  2. No',
    ])
    # Real capture, throwaway panes wB:p3X/wB:p3Y, 2026-09-20
    # (dashboard-plan-approval brief): the ExitPlanMode plan-approval box,
    # reproduced 4 times, byte-identical wording every time.
    plan_approval_box = '\n'.join([
        'Claude has written up a plan and is ready to execute. Would you '
        'like to proceed?',
        '',
        '❯ 1. Yes, and use auto mode',
        '  2. Yes, manually approve edits',
        '  3. Tell Claude what to change',
        '     shift+tab to approve with this feedback',
        '',
        'ctrl+g to edit in Vim · ~/.claude/plans/dapper-strolling-sprout.md',
    ])
    perm_cases = [
        ('perm-3opt', permission_3opt.splitlines(), {
            'tool': 'Bash', 'detail': 'rm -rf /tmp/aptusfit-maestro-sim.lock',
            'title': 'Do you want to proceed?', 'cursorIndex': 1,
            'labels': ['Yes', "Yes, and don't ask again for rm commands in /tmp",
                       'No, tell Claude what to do differently (esc)'],
        }),
        ('perm-2opt', permission_2opt.splitlines(), {
            'tool': 'Write', 'detail': 'scripts/foo.py',
            'title': 'Do you want to proceed?', 'cursorIndex': 1,
            'labels': ['Yes', 'No'],
        }),
        ('perm-askuserquestion (must stay None)', single.splitlines(), None),
        ('perm-no-receipt (must stay None)', permission_no_receipt.splitlines(), None),
        ('perm-edit-box', permission_edit_box.splitlines(), {
            'tool': 'Update',
            'detail': '.claude/chief-mode\n'
                      ' 1  on 2026-09-15T04:21:16+00:00 84ac01f3-…\n 2 +',
            'title': 'Do you want to make this edit to chief-mode?',
            'cursorIndex': 1,
            'labels': ['Yes',
                       "Yes, and allow Claude to edit files in this "
                       "project's .claude folder for this session", 'No'],
        }),
        ('perm-edit-box-long-diff (truncation)',
         permission_edit_box_long_diff.splitlines(), {
            'tool': 'Write',
            'detail': 'scripts/long.py\n' + '\n'.join(long_diff_rows[:20])
                      + '\n… (5 more line(s) truncated)',
            'title': 'Do you want to make this edit to long.py?',
            'cursorIndex': 1,
            'labels': ['Yes', 'No'],
        }),
        ('perm-edit-box-diff-border-lookalike (QA regression)',
         permission_edit_box_diff_has_border_lookalike.splitlines(), {
            'tool': 'Update',
            'detail': "scripts/lib/classify_pane.py\n"
                      " 10  BORDER = '────────────────────────────────────────'\n"
                      " 11 +BORDER2 = '────────────────────────────────────────'",
            'title': 'Do you want to make this edit to classify_pane.py?',
            'cursorIndex': 1,
            'labels': ['Yes', 'No'],
        }),
        ('perm-edit-box-diff-wall-lookalike (QA regression)',
         permission_edit_box_diff_has_wall_lookalike.splitlines(), {
            'tool': 'Update',
            'detail': "scripts/lib/classify_pane.py\n"
                      " 487  TITLE_GLYPH_RE = re.compile(r'[☐☒]')\n"
                      " 488 +# a comment change nearby",
            'title': 'Do you want to make this edit to classify_pane.py?',
            'cursorIndex': 1,
            'labels': ['Yes', 'No'],
        }),
        ('perm-create-box-unverified (must stay None)',
         permission_create_box_unverified.splitlines(), None),
        ('perm-must-not-parse-plan-approval-box (mutual exclusion)',
         plan_approval_box.splitlines(), None),
    ]
    for name, tail, want in perm_cases:
        got = parse_permission_block(tail)
        if want is None:
            if got is not None:
                print(f'FAIL {name}: expected None, got {got!r}');
                fail = 1
            else:
                print(f'PASS {name} -> None')
            continue
        if got is None:
            print(f'FAIL {name}: expected a permission block, got None');
            fail = 1
            continue
        got_labels = [o['label'] for o in got['options']]
        bad = [k for k in ('tool', 'detail', 'title', 'cursorIndex')
               if got[k] != want[k]]
        if got_labels != want['labels']:
            bad.append(f"labels {got_labels!r}")
        if bad:
            print(f'FAIL {name}: {bad} (got {got!r})');
            fail = 1
        else:
            print(f'PASS {name} -> {got["title"]!r} tool={got["tool"]!r}')

    # ── parse_plan_approval_block: the real capture above, a variant with
    # the planPath footer absent (must read None, not a guess), and the two
    # mutual-exclusion regressions in the OTHER direction (a plain
    # permission box / an AskUserQuestion box must never parse as a plan).
    plan_approval_box_no_path = '\n'.join(plan_approval_box.splitlines()[:-2])
    # QA-caught 2026-09-20 (dashboard-plan-box-wrapped brief follow-up): the
    # footer's path-continuation scan must be structurally anchored (blank-
    # line-preceded) and refuse on ambiguity, or a coincidental line
    # elsewhere in the block can fabricate a planPath out of nothing, or
    # clobber a real one. Option 2's own label happens to read exactly like
    # the bare footer prefix — never blank-preceded, since it directly
    # follows option 1 — so it must be ignored, not mined for a path.
    plan_approval_box_fabricated_path = '\n'.join([
        'Claude has written up a plan and is ready to execute. Would you '
        'like to proceed?',
        '',
        '❯ 1. Yes, and use auto mode',
        '  2. ctrl+g to edit in Vim ·',
        'NotAPlanPathAtAll.md',
    ])
    # A real, correctly-formatted footer followed by a second, unrelated
    # blank-preceded line that also matches the prefix and wraps to ".md" —
    # must refuse rather than pick either (last-match-wins would silently
    # discard the real path).
    plan_approval_box_clobbered_path = '\n'.join([
        'Claude has written up a plan and is ready to execute. Would you '
        'like to proceed?',
        '',
        '❯ 1. Yes, and use auto mode',
        '  2. Yes, manually approve edits',
        '  3. Tell Claude what to change',
        '',
        'ctrl+g to edit in Vim · ~/.claude/plans/real-path.md',
        '',
        'ctrl+g to edit in Vim ·',
        'notes.md',
    ])
    plan_cases = [
        ('plan-approval-box', plan_approval_box.splitlines(), {
            'tool': 'ExitPlanMode', 'kind': 'plan', 'detail': None,
            'title': 'Claude has written up a plan and is ready to '
                     'execute. Would you like to proceed?',
            'cursorIndex': 1,
            'planPath': '~/.claude/plans/dapper-strolling-sprout.md',
            'labels': ['Yes, and use auto mode', 'Yes, manually approve edits',
                       'Tell Claude what to change'],
        }),
        ('plan-approval-box-no-plan-path (footer absent -> None, not a guess)',
         plan_approval_box_no_path.splitlines(), {
            'tool': 'ExitPlanMode', 'kind': 'plan', 'detail': None,
            'title': 'Claude has written up a plan and is ready to '
                     'execute. Would you like to proceed?',
            'cursorIndex': 1, 'planPath': None,
            'labels': ['Yes, and use auto mode', 'Yes, manually approve edits',
                       'Tell Claude what to change'],
        }),
        ('plan-approval-must-not-parse-plain-permission (mutual exclusion)',
         permission_3opt.splitlines(), None),
        ('plan-approval-must-not-parse-askuserquestion (mutual exclusion)',
         single.splitlines(), None),
        ('plan-approval-fabricated-path (option label reads like the '
         'footer prefix but is never blank-preceded -> planPath None, '
         'not fabricated)',
         plan_approval_box_fabricated_path.splitlines(), {
            'tool': 'ExitPlanMode', 'kind': 'plan', 'detail': None,
            'title': 'Claude has written up a plan and is ready to '
                     'execute. Would you like to proceed?',
            'cursorIndex': 1, 'planPath': None,
            'labels': ['Yes, and use auto mode',
                       'ctrl+g to edit in Vim ·'],
        }),
        ('plan-approval-clobbered-path (two blank-preceded footer-shaped '
         'lines -> ambiguous, planPath None, never last-match-wins)',
         plan_approval_box_clobbered_path.splitlines(), {
            'tool': 'ExitPlanMode', 'kind': 'plan', 'detail': None,
            'title': 'Claude has written up a plan and is ready to '
                     'execute. Would you like to proceed?',
            'cursorIndex': 1, 'planPath': None,
            'labels': ['Yes, and use auto mode', 'Yes, manually approve edits',
                       'Tell Claude what to change'],
        }),
    ]
    for name, tail, want in plan_cases:
        got = parse_plan_approval_block(tail)
        if want is None:
            if got is not None:
                print(f'FAIL {name}: expected None, got {got!r}');
                fail = 1
            else:
                print(f'PASS {name} -> None')
            continue
        if got is None:
            print(f'FAIL {name}: expected a plan-approval block, got None');
            fail = 1
            continue
        got_labels = [o['label'] for o in got['options']]
        bad = [k for k in ('tool', 'kind', 'detail', 'title', 'cursorIndex',
                           'planPath') if got[k] != want[k]]
        if got_labels != want['labels']:
            bad.append(f"labels {got_labels!r}")
        if bad:
            print(f'FAIL {name}: {bad} (got {got!r})');
            fail = 1
        else:
            print(f'PASS {name} -> {got["title"]!r} planPath={got["planPath"]!r}')

    # ── question_cursor_on_exit: real captures (dashboard-answer-
    # stray-enter brief, 2026-09-20, AgentBar QA session c7db27d6's own
    # reproduction pane) — a multi-select with the cursor parked on its
    # `❯    Submit` exit row, and the SAME form fresh with the cursor on
    # option 1 (must read False — a real numbered row, which
    # parse_question_block already parses in full).
    cursor_on_submit = '\n'.join([
        '────────────────────────────────────────────────────────────────────────────────────────',
        '←  ☒ How to finish  ☐ Record findings  ✔ Submit  →',
        '',
        'Three findings currently exist only in this conversation. Which '
        'should I write up as durable records before anything else?',
        '',
        '  1. [ ] 8 red tests on the shipping line',
        '       desc one',
        '  2. [✔] Plan-settings silent data loss',
        '       desc two',
        '  3. [✔] Stale lint baseline in CLAUDE.md',
        '       desc three',
        '  4. [✔] Deliver run cost / fragility',
        '       desc four',
        '  5. [ ] Type something',
        '❯    Submit',
        '────────────────────────────────────────────────────────────────────────────────────────',
        '  6. Chat about this',
        '',
        'Enter to select · ↑/↓ to navigate · Esc to cancel',
    ])
    cursor_on_opt1 = '\n'.join([
        '────────────────────────────────────────────────────────────────────────────────────────',
        '←  ☒ How to finish  ☐ Record findings  ✔ Submit  →',
        '',
        'Three findings currently exist only in this conversation. Which '
        'should I write up as durable records before anything else?',
        '',
        '❯ 1. [ ] 8 red tests on the shipping line',
        '       desc one',
        '  2. [ ] Plan-settings silent data loss',
        '       desc two',
        '  3. [ ] Stale lint baseline in CLAUDE.md',
        '       desc three',
        '  4. [ ] Deliver run cost / fragility',
        '       desc four',
        '  5. [ ] Type something',
        '     Submit',
        '────────────────────────────────────────────────────────────────────────────────────────',
        '  6. Chat about this',
        '',
        'Enter to select · ↑/↓ to navigate · Esc to cancel',
    ])
    # Admission-gate parity case (QA2 finding, dashboard-answer-stray-enter
    # brief follow-up): a ballot-box title + a Submit-cursor row, but NO
    # real numbered option rows at all — must read False, same as
    # `parse_question_block`'s own `len(options) < 2` gate would refuse
    # this as "not really a question block" rather than a stray match.
    no_options = '\n'.join([
        '────────────────────────────────────────',
        ' ☐ Empty-ish box',
        '',
        'Nothing has any real option rows below.',
        '',
        '❯    Submit',
        '────────────────────────────────────────',
        '',
        'Enter to select · ↑/↓ to navigate · Esc to cancel',
    ])
    exit_cases = [
        ('cursor-on-submit (real capture)', cursor_on_submit.splitlines(), True),
        ('cursor-on-opt1 (same form, must read False — a real numbered '
         'row, not the exit row)', cursor_on_opt1.splitlines(), False),
        ('plain permission box (must stay False — no ballot-box title)',
         permission_3opt.splitlines(), False),
        ('review screen (must stay False — different wording, "Submit '
         'answers" not bare "Submit")', review.splitlines(), False),
        ('ballot-box title + Submit-cursor row but no numbered options '
         '(must stay False — admission-gate parity with '
         'parse_question_block)', no_options.splitlines(), False),
    ]
    for name, tail, want in exit_cases:
        got = question_cursor_on_exit(tail)
        if got != want:
            print(f'FAIL {name}: expected {want!r}, got {got!r}');
            fail = 1
        else:
            print(f'PASS {name} -> {got!r}')
    # cursor_on_opt1 must still parse in FULL via parse_question_block —
    # proves the two functions agree on "open" and never both return a
    # false negative for the same screen.
    got_q = parse_question_block(cursor_on_opt1.splitlines())
    if got_q is None or got_q['cursorIndex'] != 1:
        print(f'FAIL cursor-on-opt1 still parses via parse_question_block: '
              f'got {got_q!r}');
        fail = 1
    else:
        print('PASS cursor-on-opt1 still parses via parse_question_block '
              f'-> cursorIndex={got_q["cursorIndex"]!r}')
    return fail


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == '--selftest-parse':
        sys.exit(_selftest_parse())
    main()
