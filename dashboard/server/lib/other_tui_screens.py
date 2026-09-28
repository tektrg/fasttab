#!/usr/bin/env python3
"""Screen reads for the non-Claude agent TUIs: OpenCode and Codex.

Pure text in, answers out. Every marker below was measured on a live pane
(OpenCode 1.18.30, Codex CLI 0.154.0-alpha, 2026-09-28) and is kept as a
fixture under tests/fixtures/panes/. Markers tagged GUESS were not seen live.

  OpenCode  prompt box bottom edge `╹▀▀▀…`; `esc interrupt` while a turn runs.
            Question picker (the box is REPLACED by it, so no `╹▀` edge):
            `↑↓ select  enter submit  esc dismiss`.
  Codex     composer `› …` + model footer; `• Working (50s • esc to
            interrupt)` while a turn runs. Pickers (directory-trust, and
            GUESS: command approval) are numbered rows with a `›` cursor:
            `› 1. Yes, continue`.

`prompt_open(tail)` says whether a permission box / question picker is up —
the gate for answering or messaging such a pane.
"""
import re

ACTIVE = "ACTIVE"
WAITING = "WAITING"
NEEDS_HUMAN = "NEEDS_HUMAN"

PROMPT_PERMISSION = "permission"
PROMPT_QUESTION = "question"

#: How many trailing non-blank lines count as "the live bottom of the screen".
BOTTOM_LOOKBACK = 8

# ── OpenCode ─────────────────────────────────────────────────────────────────
#: The bottom edge of OpenCode's prompt box. Claude Code never draws it.
OPENCODE_PROMPT_EDGE_RE = re.compile(r'^\s*╹▀{5,}')
OPENCODE_BUSY_RE = re.compile(r'\besc interrupt\b')
#: The question picker's key-hint footer (live).
_OPENCODE_QUESTION_RE = re.compile(r'↑↓\s*select\s+enter submit\s+esc dismiss')
#: GUESS (not sampled): the permission box's button row.
_OPENCODE_PERMISSION_RE = re.compile(r'\bAllow once\b.*\bAllow always\b.*\bReject\b')

# ── Codex ────────────────────────────────────────────────────────────────────
_CODEX_BUSY_RE = re.compile(r'^\s*•\s+Working\s+\(.*\besc to interrupt\)')
#: Only Codex draws these: its banner, its empty-composer placeholder.
_CODEX_MARK_RE = re.compile(r'>_ OpenAI Codex\b|^\s*›\s+Ask Codex to do anything\b')
_CODEX_COMPOSER_RE = re.compile(r'^\s*›\s')
#: A picker row with the cursor on it: `› 1. Yes, continue`.
_CODEX_CURSOR_OPTION_RE = re.compile(r'^\s*›\s*\d+\.\s+\S')
_CODEX_OPTION_RE = re.compile(r'^\s*(?:›\s*)?\d+\.\s+\S')
_CODEX_PICKER_HINT_RE = re.compile(r'\bPress enter to (?:continue|confirm)\b|\besc to cancel\b',
                                   re.IGNORECASE)
#: GUESS (not sampled): approval overlay wording.
_CODEX_PERMISSION_RE = re.compile(
    r'\bWould you like to (?:run|make|apply)\b|\bAllow (?:command|Codex)\b|\bYes, proceed\b',
    re.IGNORECASE)


def _bottom(tail_lines, n=BOTTOM_LOOKBACK):
    return [l for l in tail_lines if l.strip()][-n:]


def _opencode_prompt_open(tail_lines):
    bottom = _bottom(tail_lines)
    if any(_OPENCODE_QUESTION_RE.search(l) for l in bottom):
        return PROMPT_QUESTION
    if any(_OPENCODE_PERMISSION_RE.search(l) for l in bottom):
        return PROMPT_PERMISSION
    return None


def _codex_picker_bottom(tail_lines):
    """Bottom lines of an open Codex picker, or None (needs ≥2 numbered rows
    with one under the `›` cursor, and no composer below them)."""
    bottom = _bottom(tail_lines, 12)
    cursor = [i for i, l in enumerate(bottom) if _CODEX_CURSOR_OPTION_RE.match(l)]
    if not cursor:
        return None
    below = bottom[cursor[-1] + 1:]
    if any(_CODEX_COMPOSER_RE.match(l) for l in below):
        return None  # a numbered answer in scrollback above a live composer
    if sum(1 for l in bottom if _CODEX_OPTION_RE.match(l)) < 2:
        return None
    return bottom


def _codex_prompt_open(tail_lines):
    bottom = _codex_picker_bottom(tail_lines)
    if bottom is None:
        return None
    if any(_CODEX_PERMISSION_RE.search(l) for l in bottom):
        return PROMPT_PERMISSION
    return PROMPT_QUESTION


def prompt_open(tail_lines):
    """"permission" / "question" when an OpenCode or Codex prompt is open on
    screen, else None. Trust pickers count as "question" (a choice to make)."""
    return _opencode_prompt_open(tail_lines) or _codex_prompt_open(tail_lines)


def opencode_state(tail_lines):
    """ACTIVE / WAITING / NEEDS_HUMAN for an OpenCode pane, or None."""
    if _opencode_prompt_open(tail_lines):
        return NEEDS_HUMAN
    if not any(OPENCODE_PROMPT_EDGE_RE.match(l) for l in tail_lines):
        return None
    if any(OPENCODE_BUSY_RE.search(l) for l in tail_lines[-6:]):
        return ACTIVE
    return WAITING


def codex_state(tail_lines):
    """ACTIVE / WAITING / NEEDS_HUMAN for a Codex pane, or None if not one.

    A trust / approval picker counts even without the Codex banner (it is the
    first thing drawn, before any banner). Otherwise the pane must show a Codex
    mark, and the composer must sit at the bottom.
    """
    if _codex_prompt_open(tail_lines):
        return NEEDS_HUMAN
    bottom = _bottom(tail_lines)
    if any(_CODEX_BUSY_RE.match(l) for l in bottom):
        return ACTIVE
    if not any(_CODEX_MARK_RE.search(l) for l in tail_lines):
        return None
    if any(_CODEX_COMPOSER_RE.match(l) for l in bottom[-3:]):
        return WAITING
    return None
