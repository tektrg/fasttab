#!/usr/bin/env python3
"""Phase 8 (v4 reach): parse the context-window reading off a pane's screen.

Pure module — `re` only, no subprocesses, no imports beyond it. The pane
screen feed already reads every pane's 100-line tail every 15s; the status
line carrying the reading is inside that tail, so parsing it costs nothing
(a per-pane subprocess here would add ~37 reads a minute for data already
held).

Formats, both verified live 2026-09-06 inside the tail the feed reads:
  Claude   `18% context`            -> pct=18, source="claude"
  Claude   `12% until auto-compact` -> autocompactPct=12 (the REAL proximity
                                      signal — "% context" is NOT compaction
                                      proximity: measured 2026-09-02, a pane
                                      at 29% was auto-compacting while one at
                                      53% showed no countdown)
  opencode `144.8K (14%)`           -> tokensK=144.8, pct=14, source="opencode"
  Codex    none — its footer (0.154 alpha) shows model + cwd only, no
           context reading; Codex context % needs the rollout file instead.

Take the LAST match in the tail — the status line is at the bottom and older
frames scroll above it. No match -> every field None. NEVER coerce to 0: a 0
sorts as "most headroom" and would hide the pane that most needs compacting
(same rule as derived:memory in phase 5).
"""

import re

#: `18% context` (Claude's status line). `\s+context` keeps `12% until
#: auto-compact` out — that line feeds autocompactPct, not pct.
_CLAUDE_PCT_RE = re.compile(r"(\d{1,3})%\s+context\b")

#: `12% until auto-compact` — the countdown Claude prints only when it is
#: genuinely close to the ceiling. Coexists with the `% context` line.
_AUTOCOMPACT_RE = re.compile(r"(\d{1,3})%\s+until auto-compact\b")

#: `144.8K (14%)` (opencode's status line). The `)` is optional: a narrow
#: pane cuts it (`15.3K (1% ctrl+p`, live 2026-09-28); the `%` still ends
#: the digits, so the number is whole.
_OPENCODE_RE = re.compile(r"(\d+(?:\.\d+)?)K\s+\((\d{1,3})%\)?")


def parse_context(tail_text):
    """Parse the context reading from a pane screen tail.

    Returns {"pct", "tokensK", "autocompactPct", "source"}. All None on no
    match — callers render that as `—`, never 0.
    """
    out = {"pct": None, "tokensK": None, "autocompactPct": None,
           "source": None}
    if not tail_text:
        return out
    # Candidates across all three patterns, ranked by position: the status
    # line is the LAST thing drawn, so the last match in the tail wins —
    # even across formats (a restarted agent of a different vendor leaves
    # the old vendor's line in scrollback).
    cands = []  # (end_pos, source, pct, tokensK)
    for m in _CLAUDE_PCT_RE.finditer(tail_text):
        cands.append((m.end(), "claude", int(m.group(1)), None))
    for m in _OPENCODE_RE.finditer(tail_text):
        cands.append((m.end(), "opencode", int(m.group(2)),
                      float(m.group(1))))
    if cands:
        _, source, pct, tokens_k = max(cands, key=lambda c: c[0])
        out["source"] = source
        out["pct"] = pct
        out["tokensK"] = tokens_k
    auto = None
    for m in _AUTOCOMPACT_RE.finditer(tail_text):
        auto = int(m.group(1))
    out["autocompactPct"] = auto
    return out
