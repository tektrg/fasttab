#!/usr/bin/env python3
"""OpenCode / Codex screen reads, against live pane captures.

Fixtures in tests/fixtures/panes/ were captured 2026-09-28 from throwaway
herdr panes (OpenCode 1.18.30, Codex CLI 0.154.0-alpha), paths anonymised.
Not sampled live: a permission box on either tool (both auto-allowed an
in-workspace write), a Codex question picker (Codex asked in plain prose).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "server", "lib"))

import chief_dashboard_context as ctx  # noqa: E402
import classify_pane  # noqa: E402
import other_tui_screens as tui  # noqa: E402

FIXTURES = os.path.join(HERE, "fixtures", "panes")
fails = []


def check(label, got, want):
    ok = got == want
    print(f"{'PASS' if ok else 'FAIL'}  {label}" + ("" if ok else f"  got={got!r} want={want!r}"))
    if not ok:
        fails.append(label)


def _text(name):
    with open(os.path.join(FIXTURES, name + ".txt"), encoding="utf-8") as f:
        return f.read()


def _lines(name):
    return _text(name).splitlines()


CASES = [
    # fixture,             classify(),     prompt_open()
    ("opencode_idle",       "WAITING",     None),
    ("opencode_working",    "ACTIVE",      None),
    ("opencode_idle_after", "WAITING",     None),
    ("opencode_question",   "NEEDS_HUMAN", "question"),
    ("codex_idle",          "WAITING",     None),
    ("codex_working",       "ACTIVE",      None),
    ("codex_idle_after",    "WAITING",     None),
    ("codex_trust",         "NEEDS_HUMAN", "question"),
]


for name, state, prompt in CASES:
    check(f"{name}: classify", classify_pane.classify(_text(name))[0], state)
    check(f"{name}: prompt_open", tui.prompt_open(_lines(name)), prompt)
    other = tui.codex_state if name.startswith("opencode") else tui.opencode_state
    check(f"{name}: not read as the other tool", other(_lines(name)), None)


shell = ["$ ls", "README.md", "$ "]
check("plain shell: not codex", tui.codex_state(shell), None)
check("plain shell: not opencode", tui.opencode_state(shell), None)
check("plain shell: no prompt", tui.prompt_open(shell), None)

# A numbered list in Codex's reply, then the live composer: not a picker.
reply = _lines("codex_idle_after")
reply[-3:-3] = ["› 1. Red", "  2. Green", "  3. Blue"]
check("codex numbered reply above composer: no prompt", tui.prompt_open(reply), None)
check("codex numbered reply above composer: WAITING", tui.codex_state(reply), "WAITING")

# GUESS shape (not sampled live): approval overlay with a `›` cursor row.
approval = ["  Would you like to run the following command?", "  $ echo INJECTED",
            "› 1. Yes, proceed", "  2. No, and tell Codex what to do differently",
            "  Press enter to confirm or esc to cancel"]
check("codex approval: permission", tui.prompt_open(approval), "permission")
check("codex approval: NEEDS_HUMAN", tui.codex_state(approval), "NEEDS_HUMAN")

# Narrow OpenCode pane drew `15.3K (1% ctrl+p` — no closing `)`.
r = ctx.parse_context(_text("opencode_idle_after"))
check("opencode context with cut paren", (r["pct"], r["tokensK"], r["source"]), (1, 15.3, "opencode"))
check("codex footer has no context reading",
      ctx.parse_context(_text("codex_idle_after"))["pct"], None)

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("All other-TUI screen checks passed.")
