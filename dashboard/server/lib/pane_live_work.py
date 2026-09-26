#!/usr/bin/env python3
"""Recognise a Claude Code pane that is doing work RIGHT NOW, from its text.

Pure text in, answers out - no herdr, no I/O. Split out of classify_pane.py
(already past the file-size limit) and shared by the classifier (is there a live
spinner?) and by `pane_liveness` (is that spinner actually ticking?).

WHY THIS EXISTS (false `stalled`, 2026-09-20)
---------------------------------------------
The classifier's only spinner rule was an ellipsis followed by a digit - `… (7m
31s`. Real Claude Code frames also draw:

  * progress text inside the parenthetical, hard-wrapped onto a second line -
    `✳ Running SessionStart hooks… (running SessionStart hooks… 1/3 · 2m 36s ·`
    then `↓ 143 tokens)`, which is what every auto-compaction ends with, and
    `✢ Sock-hopping… (Snapshotting uncommitted work...… 3/4 · 4m 25s ·`;
  * a bare `✽ Skedaddling…` in the spinner's first moments, before any counter.

Each read as a finished turn, `activeNow` was not True, and a transcript that is
legitimately quiet mid-turn (extended thinking writes nothing) made the shared
supervisor say "working, but unchanged for 49m" - a false `stalled`.

WHY A GLYPH-PRESENT SPINNER IS NOT ENOUGH ON ITS OWN
----------------------------------------------------
A killed session's pane keeps drawing its last frame forever, spinner included.
So `progress()` extracts what a LIVE spinner cannot help but change - the elapsed
timer and the token counter - and `pane_liveness` compares it across heartbeats:
present-and-changing is proof of life, present-and-identical is a corpse.
"""
import re

#: The glyphs Claude Code cycles through for its spinner. Deliberately excludes
#: `⏺` (an assistant message / tool bullet), `*`, `-` and `•` (list bullets).
SPINNER_GLYPHS = "·✢✳✶✷✸✻✽"

_GLYPH_LINE = rf"^\s*[{SPINNER_GLYPHS}]\s+\S"
_GLYPH_LINE_RE = re.compile(_GLYPH_LINE)

#: The original rule, kept verbatim: an ellipsis straight into a `(<digit>` timer
#: only ever appears on a spinner that is still running (a finished one says
#: "for <duration>", with no ellipsis).
COUNTER_SPINNER_RE = re.compile(r"…\s*\(\d")

#: `<glyph> <Verb or phrase>… (` - an ellipsis opening a parenthetical of ANY text.
_DETAIL_OPEN_RE = re.compile(rf"^\s*[{SPINNER_GLYPHS}]\s+\S[^\n]*…\s*\(")
#: A running timer / token readout somewhere in the (possibly wrapped) parenthetical.
_TIMER_OR_TOKENS_RE = re.compile(r"\b\d+s\b|↓\s*[\d.,]+k?\s*tokens")
#: A running spinner's parenthetical is a `·`-separated readout or ends in a token
#: count; a prose aside (`(took 4s)`, `(attempt 2 in 5s)`) has neither.
_READOUT_SEPARATOR_RE = re.compile(r"\s·(?:\s|$)|↓\s*[\d.,]+k?\s*tokens")
#: The spinner in its first moments: glyph, 1-4 words, ellipsis, nothing else.
_BARE_SPINNER_RE = re.compile(
    rf"^\s*[{SPINNER_GLYPHS.replace('·', '')}]\s+[A-Z][\w'’-]*(?:\s+[\w'’-]+){{0,3}}…\s*$")

#: `9m 58s`, `2h 3m 5s`, `46s` - the timer a live spinner ticks every second.
_ELAPSED_RE = re.compile(r"(?<![\w.])(?:(\d+)h\s*)?(?:(\d+)m\s*)?(\d+)s\b")
_TOKENS_RE = re.compile(r"↓\s*([\d.,]+k?)\s*tokens")
#: A subagent / background-workflow status line with its own live readout:
#: `◯ general-purpose (+2)  Grepping ... 4m 23s · ↓ 143.2k tokens`.
_AGENT_LINE_RE = re.compile(r"^\s*[◯⏺]\s+\S.*↓\s*[\d.,]+k?\s*tokens")


def _wrapped(tail_lines, i):
    """Line `i` joined with the line below it when the terminal hard-wrapped the
    spinner's parenthetical (the continuation starts with the token counter or a
    bare timer, never with a glyph or a bullet)."""
    line = tail_lines[i]
    if i + 1 < len(tail_lines):
        nxt = tail_lines[i + 1].strip()
        if nxt and not _GLYPH_LINE_RE.match(tail_lines[i + 1]) and (
                nxt.startswith("↓") or nxt.startswith("(") or _TIMER_OR_TOKENS_RE.match(nxt)):
            return f"{line.rstrip()} {nxt}"
    return line


#: The prompt box's top edge - a live spinner is always drawn ABOVE it.
_INPUT_RULE_RE = re.compile(r"^\s*─{10,}")
#: The spinner sits at the left margin; a deeper indent is tool output or a list.
_SPINNER_MAX_INDENT = 2


def _is_anchored_above_prompt(tail_lines, i):
    """Is line `i` where a live spinner is drawn: at the left margin, with only
    chrome (progress bar, update notice, tips) between it and the prompt box?

    Bullets in a finished reply (`  · Loading…`, `· Fixed it… (took 4s)`) look
    like the looser spinner shapes but are followed by more message content
    (another glyph or `⏺` line) before the prompt box, or sit deeper in the tail
    with no box below at all.
    """
    line = tail_lines[i]
    if len(line) - len(line.lstrip()) > _SPINNER_MAX_INDENT:
        return False
    for below in tail_lines[i + 1:]:
        if _INPUT_RULE_RE.match(below):
            return True
        text = below.lstrip()
        if text.startswith("⏺") or (text[:1] in SPINNER_GLYPHS and text[:1]):
            return False
    return False


def is_live_spinner_line(tail_lines, i):
    """Does line `i` of the tail draw a spinner that is still running?"""
    line = tail_lines[i]
    if COUNTER_SPINNER_RE.search(line):
        return True
    if not _GLYPH_LINE_RE.match(line):
        return False
    if _BARE_SPINNER_RE.match(line):
        return _is_anchored_above_prompt(tail_lines, i)
    joined = _wrapped(tail_lines, i)
    return bool(_DETAIL_OPEN_RE.match(joined) and _TIMER_OR_TOKENS_RE.search(joined)
                and _READOUT_SEPARATOR_RE.search(joined.split("(", 1)[1])
                and _is_anchored_above_prompt(tail_lines, i))


def _last_match(pattern, text):
    """The LAST timer that is the spinner's own: it follows any `(timeout 120s
    hook 1/3 ·` configuration text, but is not a trailing `· thought for 1s)`
    annotation (a completed sub-step's duration, not the running clock)."""
    found = None
    for match in pattern.finditer(text):
        if not text[:match.start()].endswith("for "):
            found = match
    return found


def _to_seconds(match):
    hours, minutes, seconds = (int(g) if g else 0 for g in match.groups())
    return hours * 3600 + minutes * 60 + seconds


def progress(tail_lines):
    """What a running spinner cannot help but change, or None when the pane shows
    no readable counter.

    {"token": "9m 58s|↓23.1k", "elapsedSec": 598}

    `token` joins the main spinner's timer + token count with those of any
    subagent status lines, so a subagent still churning under a quiet main
    spinner still counts as movement. `elapsedSec` is the MAIN spinner's timer.
    """
    parts, elapsed = [], None
    for i in range(len(tail_lines) - 1, -1, -1):
        if is_live_spinner_line(tail_lines, i):
            joined = _wrapped(tail_lines, i)
            after_open = joined.split("(", 1)[1] if "(" in joined else joined
            timer = _last_match(_ELAPSED_RE, after_open)
            tokens = _TOKENS_RE.search(after_open)
            if timer or tokens:
                parts.append(f"{timer.group(0) if timer else ''}|"
                             f"{'↓' + tokens.group(1) if tokens else ''}")
                elapsed = _to_seconds(timer) if timer else None
            break
    for line in tail_lines:
        if _AGENT_LINE_RE.match(line):
            timer = _last_match(_ELAPSED_RE, line)
            tokens = _TOKENS_RE.search(line)
            parts.append(f"{timer.group(0) if timer else ''}|"
                         f"{'↓' + tokens.group(1) if tokens else ''}")
    if not parts:
        return None
    return {"token": ";".join(parts), "elapsedSec": elapsed}


def count_subagents(tail_lines):
    """How many sub-agent / background-workflow status lines (`◯ Explore  ...
    1m 38s · ↓ 81.4k tokens`) the pane draws right now. A count, not a verdict:
    the status panel outlives a killed session's frame, so callers weigh it
    against whether the screen still MOVES (pane_screen_signals.live_work_evidence)."""
    return sum(1 for line in tail_lines if _AGENT_LINE_RE.match(line))


def last_spinner_line(tail_lines):
    """The last running-spinner line (for evidence text), or None."""
    for i in range(len(tail_lines) - 1, -1, -1):
        if is_live_spinner_line(tail_lines, i):
            return _wrapped(tail_lines, i).strip()
    return None
