#!/usr/bin/env python3
"""Direct-run tests for Chief Dashboard v4 phase 8: context reading, message
+ compact backend. Pure functions + tmpdirs — no herdr, no panes, no network.

The parser cases use status-line shapes captured from live panes 2026-09-06;
a future upstream UI change must surface here as a FAIL, not as a silently
empty CONTEXT column.
"""
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib"))

import chief_dashboard_actions as act  # noqa: E402
import chief_dashboard_context as ctx  # noqa: E402
from chief_dashboard_store import BoardStore  # noqa: E402

fails = []


def check(label, got, want=True):
    ok = (got == want) if want is not True else bool(got)
    if not ok:
        fails.append(f"{label}: got {got!r}" + (f" want {want!r}" if want is not True else ""))
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


print("== parser: claude ==")
r = ctx.parse_context("some scrollback\n    [Sonnet 5] 18% context | git:main | +23/-0 | ~31 | pane:w8:pD")
check("claude pct", r["pct"], 18)
check("claude source", r["source"], "claude")
check("claude no tokens", r["tokensK"], None)
check("claude no countdown", r["autocompactPct"], None)

print("== parser: claude near the ceiling ==")
tail = ("old frame\n  87% context\nmore output\n  12% until auto-compact  ·  "
        "compact now")
r = ctx.parse_context(tail)
check("ceiling pct", r["pct"], 87)
check("ceiling countdown", r["autocompactPct"], 12)
check("ceiling source", r["source"], "claude")

print("== parser: opencode ==")
r = ctx.parse_context("right side status\n   /Users/trungluong/01_Project/markdown-lite-mac/hubble-source    248.8K (24%)  ctrl+p commands    • OpenCode 1.18.27")
check("opencode pct", r["pct"], 24)
check("opencode tokens", r["tokensK"], 248.8)
check("opencode source", r["source"], "opencode")
check("opencode no countdown", r["autocompactPct"], None)

print("== parser: last match wins; no match is all-None ==")
r = ctx.parse_context("  53% context\nscroll\n  29% context\n")
check("last frame wins", r["pct"], 29)
r = ctx.parse_context("plain shell prompt\n$ ")
check("no match pct", r["pct"], None)
check("no match tokens", r["tokensK"], None)
check("no match countdown", r["autocompactPct"], None)
check("no match source", r["source"], None)
check("empty tail", ctx.parse_context("")["pct"], None)
check("none tail", ctx.parse_context(None)["pct"], None)
r = ctx.parse_context("  12% until auto-compact\n")
check("countdown alone leaves pct None (never 0)", r["pct"], None)
check("countdown alone reads countdown", r["autocompactPct"], 12)

print("== message text validation ==")
ok, cleaned = act.validate_message_text("  continue with the next step  ")
check("stripped ok", (ok, cleaned), (True, "continue with the next step"))
ok, why = act.validate_message_text("   ")
check("empty refused", ok, False)
ok, why = act.validate_message_text("line one\nline two")
check("newline refused", ok, False)
check("newline says why", "submit key" in why, True)
ok, why = act.validate_message_text("/help")
check("other slash refused", ok, False)
check("other slash names the two-enter dance", "two-enter dance" in why, True)
# 2026-09-22: /compact and /clear are allowlisted through (proven to submit
# on a single Enter — see validate_message_text's docstring). Everything
# else starting with "/" still refuses, including near-miss commands, so
# the allowlist match must not be a bare startswith.
ok, cleaned = act.validate_message_text("/compact")
check("/compact alone accepted", (ok, cleaned), (True, "/compact"))
ok, cleaned = act.validate_message_text("/compact keep the oracle list")
check("/compact with instructions accepted",
      (ok, cleaned), (True, "/compact keep the oracle list"))
ok, cleaned = act.validate_message_text("/clear")
check("/clear accepted", (ok, cleaned), (True, "/clear"))
ok, why = act.validate_message_text("/compact2")
check("/compact2 still refused (not a bare startswith match)", ok, False)
ok, why = act.validate_message_text("/compactfoo")
check("/compactfoo still refused", ok, False)
ok, why = act.validate_message_text("/clearfoo")
check("/clearfoo still refused (not a bare startswith match)", ok, False)
ok, why = act.validate_message_text("/compacting")
check("/compacting still refused", ok, False)
ok, cleaned = act.validate_message_text("  /compact  ")
check("/compact strips surrounding whitespace and is accepted",
      (ok, cleaned), (True, "/compact"))
ok, why = act.validate_message_text("x" * 2001)
check("paste refused", ok, False)
ok, _ = act.validate_message_text("x" * 2000)
check("2000 chars allowed", ok, True)

print("== is_allowed_slash_command (used by the server's stuck-retry fallback) ==")
check("/compact bare", act.is_allowed_slash_command("/compact"), True)
check("/compact with args", act.is_allowed_slash_command("/compact keep it"),
      True)
check("/clear bare", act.is_allowed_slash_command("/clear"), True)
check("/compact2 not allowed", act.is_allowed_slash_command("/compact2"),
      False)
check("/clearfoo not allowed", act.is_allowed_slash_command("/clearfoo"),
      False)
check("/clear with args not allowed (bare only)",
      act.is_allowed_slash_command("/clear now"), False)
check("other command not allowed", act.is_allowed_slash_command("/help"),
      False)

print("== input-box detector ==")
stuck = ["some output", "❯ /compact keep the oracle list"]
check("stuck claude box", act.input_box_still_holds(stuck, "/compact"), True)
landed = ["❯ /compact keep the oracle list", "", "Compacting…",
          "Summarizing conversation…", "❯ ", "there is much output here",
          "pushing the old prompt line out of the window", "more",
          "still more", "and more", "nearly there", "working…",
          "tools running", "output streaming"]
check("landed box drained", act.input_box_still_holds(landed, "/compact"),
      False)
# Fail-closed edge, documented: a prompt line still inside the window reads
# stuck (a retry is safe; a false "landed" is what phase 8 forbids).
check("prompt still visible reads stuck",
      act.input_box_still_holds(landed[:4], "/compact"), True)
# The 2026-09-06 field fix: the LAST prompt line is the box. A transcript
# echo above a drained (empty) box is submitted, not stuck — the old
# any-match rule cried NOT SUBMITTED here and skipped the log, inviting a
# double-send.
echo_above = ["❯ /compact", "Compacting conversation… (33s)",
              "████████████░░░░ 31%", "❯ ",
              "    [Sonnet 5] 10% context | git:main"]
check("echo above empty box is drained",
      act.input_box_still_holds(echo_above, "/compact"), False)
queued = ["working…", "❯ Press up to edit queued messages"]
check("queued-messages box is NOT stuck (accepted, will deliver)",
      act.input_box_still_holds(queued, "anything"), False)
check("queued indicator detected",
      act.pane_reports_queued(queued), True)
check("no indicator, not queued",
      act.pane_reports_queued(["output", "❯ "]), False)
check("empty tail, not queued", act.pane_reports_queued([]), False)
check("stuck text plus queue hint still reads stuck (fail closed)",
      act.input_box_still_holds(
          ["❯ Press up to edit queued messages", "❯ my exact text"],
          "my exact text"), True)
check("text above, queue hint last: accepted into the queue",
      act.input_box_still_holds(
          ["❯ my exact text", "❯ Press up to edit queued messages"],
          "my exact text"), False)
check("no prompt line", act.input_box_still_holds(["output", "more"],
                                                  "hello"), False)
check("empty text never stuck", act.input_box_still_holds(stuck, ""), False)
check("old scrollback out of window",
      act.input_box_still_holds(["❯ hello"] + ["filler"] * 20, "hello"),
      False)
check("alternate prompt mark (opencode's '›') also reads stuck",
      act.input_box_still_holds(["› /compact keep the oracle list"],
                                 "/compact"), True)
check("window boundary: 12th-from-end prompt line still in window",
      act.input_box_still_holds(["❯ hello"] + ["filler"] * 11, "hello"),
      True)
check("window boundary: 13th-from-end prompt line falls out",
      act.input_box_still_holds(["❯ hello"] + ["filler"] * 12, "hello"),
      False)

print("== store: derived:context + message/compact log ==")
tmp = tempfile.mkdtemp()
store = BoardStore(db_path=os.path.join(tmp, "b.db"),
                   schema_path=os.path.join(tmp, "s.json"))
props = [p["id"] for p in store.list_properties("session")]
check("CONTEXT property exists", "derived:context" in props, True)
t0 = time.time()
a = {"paneId": "w8:pC", "paneIdSanitized": "w8-pC", "label": "live-ctx",
     "agentSession": "sess-ctx", "hasHookData": True, "hookState": "idle",
     "contextPct": 42, "autocompactPct": None}
board = store.build_session_board([a], now_ts=t0)
row = next(r for r in board["rows"] if r["rowId"] == "sess-ctx")
check("values carry CONTEXT", row["values"].get("derived:context"), 42)
check("agent dict keeps countdown", row["derived"].get("autocompactPct"),
      None)
a2 = dict(a, agentSession="sess-non", contextPct=None)
board2 = store.build_session_board([a2], now_ts=t0 + 5)
row2 = next(r for r in board2["rows"] if r["rowId"] == "sess-non")
check("unknown reads None (renders —, never 0)",
      row2["values"].get("derived:context"), None)
check("message loggable", store.log_session_action(
    "sess-ctx", "message", "po", "continue")["action"], "message")
check("compact loggable", store.log_session_action(
    "sess-ctx", "compact", "po", "compact submitted")["action"], "compact")
check("message is not an ending", store.ended_annotation(
    {"action": "message", "actor": "po"}), None)
check("compact is not an ending", store.ended_annotation(
    {"action": "compact", "actor": "po"}), None)
store.log_session_action("sess-ctx", "stop", "po", "idle")
store.log_session_action("sess-ctx", "message", "po", "nudge")
check("stop survives a later message",
      store.last_ladder_action(["sess-ctx"])["sess-ctx"], "stop")

print()

print("== busy gate reads the fresh screen, not the lagging cache ==")
# The 2026-09-06 field finding: a pane running a 55s command reported the
# cached word `idle`, so the confirm was skipped and the endpoint claimed
# "the input box drained" for a message that had queued. The screen knew.
check("live ACTIVE beats a stale idle cache",
      act.resolve_busy("ACTIVE", "idle"), True)
check("live WAITING beats a stale working cache",
      act.resolve_busy("WAITING", "working"), False)
check("CRASHED is not mid-turn", act.resolve_busy("CRASHED", "working"),
      False)
# A parked pane's TURN ENDED and its composer is live (the classifier only says
# WAITING_ON_BACKGROUND with a live composer box), so a message submits at once.
check("parked on its own monitor/agent accepts input now: not mid-turn (no queued confirm)",
      act.resolve_busy("WAITING_ON_BACKGROUND", "idle"), False)
check("...even on a stale `working` cache",
      act.resolve_busy("WAITING_ON_BACKGROUND", "working"), False)
# Unreadable screen: the cache is all there is — believe it either way
# rather than inventing a verdict.
check("UNKNOWN falls back to the cache (working)",
      act.resolve_busy("UNKNOWN", "working"), True)
check("UNKNOWN falls back to the cache (idle)",
      act.resolve_busy("UNKNOWN", "idle"), False)
check("classifier failure falls back to the cache",
      act.resolve_busy(None, "working"), True)

if fails:
    print(f"{len(fails)} FAILURES")
    raise SystemExit(1)
print("all v4-phase-8 checks pass")
