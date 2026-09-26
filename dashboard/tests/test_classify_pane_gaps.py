#!/usr/bin/env python3
"""Screen-classifier gaps found by the Jev shadow mismatch review (2026-09-20).

Source: memory/Areas/delivery-ops/202609201540-jev-shadow-mismatch-review-1.md.
Every fixture below is REAL pane text kept by `jev-shadow.py --keep-text`
(redacted: paths/ids masked), trimmed to the last ~15 lines. A synthetic
"monitor-ish" line would have passed against a classifier that never saw the
shapes Claude Code and OpenCode actually draw.

  1. Turn ended but a Monitor / background agent is still running: the worker
     is parked ON PURPOSE. It used to read WAITING (= "turn ended, nobody
     picked it up"), which is exactly how a healthy P5 worker was flagged
     `stalled` (nudge-9ebb613e, 2026-09-20).
  2. "Not logged in · Run /login" read as an ordinary idle pane (7 Air panes).
  3. API-error banners must read CRASHED (the errored state), never idle.
  4. Pickers/dialogs on hookless (second-Mac) panes must read from the screen
     alone.
  5. "No call" rows: OpenCode panes (57% of them) and a done-line whose verb
     carries a non-ASCII letter ("Sautéed") read UNKNOWN.
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


RULE = "─" * 76
COMPOSER = f"""\
{RULE}
❯
{RULE}
    [Sonnet 5] 78% context | git:rc/v1.1.0-manual-2026-09-20 wt:fe-rc-v…
"""

# ── 1. Parked on background work (real: w6:p12, the P5 worker) ──────────────
print("1. TURN ENDED, MONITOR STILL RUNNING -> WAITING_ON_BACKGROUND")
P5_MONITOR = f"""\
⏺ Round 1 confirmed the P5 bug still reproduces (^20$ assertion failed).
  Waiting on the trace monitor to capture the underlying resolved-gym data
  during the isolated retry now in progress — will report the mechanism once
  it fires.
⏺ Waiting on the trace monitor and flow retry; will resume once either
  fires.
✻ Brewed for 44m 20s · done 3:12 PM · 1 monitor still running
                                 7% until auto-compact · /model sonnet[1m]
{COMPOSER}  ⏵⏵ auto mode on · 1 shell, 1 monitor · ← 1 agent
"""
check("the false-alarm P5 pane (done line + footer say a monitor runs)",
      state(P5_MONITOR), "WAITING_ON_BACKGROUND")

FOOTER_ONLY = f"""\
⏺ Monitor(P5 hypothesis verdict or fix commit on rc branch)
  ⎿  Monitor started · task bumqyg57n · timeout 1800s
⏺ The redirect landed. The worker stopped its simulator run.
{COMPOSER}  ⏵⏵ auto mode on · 2 monitors · ← 1 agent
"""
check("footer alone ('2 monitors') is enough — no spinner, no done line",
      state(FOOTER_ONLY), "WAITING_ON_BACKGROUND")

BG_AGENT_WAIT = f"""\
⏺ Agent(QA pass 1: diff correctness review)
  ⎿  Backgrounded agent (↓ to manage · ctrl+o to expand)
⏺ QA pass 1 is running in the background.
✻ Waiting for 1 background agent to finish
{COMPOSER}  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent
"""
check("'Waiting for 1 background agent to finish' with no agent line",
      state(BG_AGENT_WAIT), "WAITING_ON_BACKGROUND")

# Negatives — the state must not leak onto panes that are NOT parked.
NO_BACKGROUND = f"""\
  Shipped: 50b1410 (shared hook, 11 new tests).
✻ Baked for 2m 49s · done 3:34 PM
{COMPOSER}  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent
"""
check("'← 1 agent' alone (the main-agent hint) is NOT a background job",
      state(NO_BACKGROUND), "WAITING")

PROSE_MONITOR = f"""\
⏺ I removed the second monitor and the shell wrapper; 2 monitors were redundant.
✻ Baked for 2m 49s · done 3:34 PM
{COMPOSER}  ⏵⏵ auto mode on (shift+tab to cycle)
"""
check("prose that says '2 monitors' is NOT a footer",
      state(PROSE_MONITOR), "WAITING")

LIVE_WITH_MONITOR = f"""\
⏺ Skill(aptus-release)
· Sock-hopping… (14s · ↓ 253 tokens · thinking with low effort)
{COMPOSER}  ⏵⏵ auto mode on · 1 monitor · ← 1 agent
"""
check("a live spinner still wins: ACTIVE, not WAITING_ON_BACKGROUND",
      state(LIVE_WITH_MONITOR), "ACTIVE")

CRASH_WITH_MONITOR = f"""\
⏺ API Error: Server error mid-response. The response above may be incomplete.
✻ Sautéed for 28m 43s · done 3:23 PM
{COMPOSER}  ⏵⏵ auto mode on · 1 monitor · ← 1 agent
"""
check("a crash is never hidden behind a running monitor",
      state(CRASH_WITH_MONITOR), "CRASHED")

# ── 2. Not logged in ─────────────────────────────────────────────────────────
print("\n2. 'Not logged in' -> NEEDS_LOGIN")
LOGGED_OUT_BOTTOM = f"""\
⏺ Monitor(5-minute timer before next progress check)
  ⎿  Monitor started · task bn9ney4dc · timeout 300s
⏺ Watching.
✻ Crunched for 23s · done Saturday 7:25 PM
                      Jump to bottom (click) ↓
                                        Not logged in · Run /login
{COMPOSER}  ⏵⏵ auto mode on (shift+tab to cycle) · ← 2 agents
"""
check("bottom status line (real: Air fb-prv-gym)",
      state(LOGGED_OUT_BOTTOM), "NEEDS_LOGIN")

LOGGED_OUT_INLINE = f"""\
  should I build the doctor subcommand now, or just log this to memory?
❯ don't refer the doctor, how to enforce. will hook works?
  ⎿  Not logged in · Please run /login
     · Run in another terminal: security unlock-keychain
✻ Crunched for 0s · done 11:01 AM
                              new task? /clear to save 113k tokens
{COMPOSER}  ⏵⏵ auto mode on · ← 2 agents
"""
check("inline reply to a message (real: Air fix-coach-env)",
      state(LOGGED_OUT_INLINE), "NEEDS_LOGIN")

STALE_LOGIN = f"""\
  ⎿  Not logged in · Please run /login
⏺ Logged back in; re-ran the suite. All 41 tests pass.
✻ Cooked for 5m 3s · done 3:13 PM
{COMPOSER}  ⏵⏵ auto mode on (shift+tab to cycle)
"""
check("a recovered session (work printed AFTER the error) is not logged out",
      state(STALE_LOGIN), "WAITING")

QUOTED_LOGIN = f"""\
⏺ Shared blind spot: 7 Air panes show "Not logged in · Run /login" at the
  bottom; both checks call them idle_done.
✻ Cooked for 5m 3s · done 3:13 PM
{COMPOSER}  ⏵⏵ auto mode on (shift+tab to cycle)
"""
check("prose QUOTING the message is not a logged-out screen",
      state(QUOTED_LOGIN), "WAITING")

# ── 3. API errors ────────────────────────────────────────────────────────────
print("\n3. API ERROR BANNERS -> CRASHED (the errored state)")
for label, banner in [
    ("5xx mid-response (real: harness p20)",
     "⏺ API Error: Server error mid-response. The response above may be incomplete."),
    ("overloaded",
     '  ⎿  API Error (529 {"type":"error","error":{"type":"overloaded_error"}}) · Retrying in 8s'),
    ("usage limit", "  ⎿  You've hit your limit · resets 2pm (Asia/Saigon)"),
    ("out of credit", "  ⎿  Credit balance is too low to access the Anthropic API"),
    ("session limit", "  ⎿  Session limit reached ∙ resets 3pm"),
    ("weekly limit", "  ⎿  Weekly limit reached ∙ resets Sep 25, 9am"),
]:
    check(label, state(f"⏺ Doing work.\n{banner}\n✻ Cooked for 5m 3s · done 3:13 PM\n{COMPOSER}"),
          "CRASHED")
check("prose about limits is not a banner",
      state(f"⏺ Note: you've hit your limit of retries in the loop, so I stopped.\n"
            f"✻ Cooked for 5m 3s · done 3:13 PM\n{COMPOSER}"), "WAITING")

check("prose quoting 'Session limit reached' is not a banner",
      state(f"⏺ The banner reads Session limit reached when the quota is gone.\n"
            f"✻ Cooked for 5m 3s · done 3:13 PM\n{COMPOSER}"), "WAITING")

# ── 4. Pickers on hookless panes (screen only) ───────────────────────────────
print("\n4. OPEN PICKER / DIALOG, SCREEN ALONE -> NEEDS_HUMAN")
REAL_PICKER = f"""\
│ remaining work is roughly 150 lines. How do you want to finish
│ Layer 0?
❯ 1. Build it directly, then validate (Recommended)
     I write the fixture and migrate the one test in the worktree now.
  2. Re-run deliver's plan stage from scratch
     Honors the original instruction most literally.
  3. Stop here — just record the findings
     Bank the three discoveries as tracked items.
  4. Type something.
{RULE}
  5. Chat about this
Enter to select · Tab/Arrow keys to navigate · Esc to cancel
"""
check("AskUserQuestion picker (real: Air headless-test)", state(REAL_PICKER), "NEEDS_HUMAN")
CURSORLESS = REAL_PICKER.replace("❯ 1.", "  1.")
check("same picker with the cursor glyph lost from the capture",
      state(CURSORLESS), "NEEDS_HUMAN")
DIALOG = """\
⏺ Both fixes confirmed live.
 Restart dashboard now?
❯ 1. Yes
  2. No
Esc to cancel · Tab to amend
"""
check("yes/no dialog (real: harness p20)", state(DIALOG), "NEEDS_HUMAN")
AGENT_ABOVE_PICKER = "◯ general-purpose  Checking…  2m 1s · ↓ 8.9k tokens\n" + REAL_PICKER
check("a running sub-agent line above an open picker does not hide it",
      state(AGENT_ABOVE_PICKER), "NEEDS_HUMAN")

# ── 5. No-call rows ──────────────────────────────────────────────────────────
print("\n5. FORMERLY UNKNOWN SHAPES")
OPENCODE_BUSY = """\
     Private key stays on the Air; nothing secret crossed machines.
     ▣  Build · Muse Spark 1.3 Free · 4m 7s
  ┃
  ┃  reply downloaded
  ┃
  ┃  Build · Muse Spark 1.3 Free OpenCode Zen
  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
   ⬝⬝⬝⬝⬝⬝■■  esc interrupt                     88.9K (8%)  ctrl+p commands
"""
check("OpenCode mid-turn ('esc interrupt') reads ACTIVE",
      state(OPENCODE_BUSY), "ACTIVE")
OPENCODE_IDLE = """\
     Unresolved:
     - Implement now, or spec-only until Gateway key is ready?
     ▣  Build · Muse Spark 1.3 Free · 26.0s
  ┃
  ┃  add
  ┃
  ┃  Build · Muse Spark 1.3 Free OpenCode Zen
  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
   [PATH]/the-todo-  116.5K (11%) ctrl+p commands
   app
"""
check("OpenCode at its prompt (finished reply) reads WAITING",
      state(OPENCODE_IDLE), "WAITING")

SAUTEED = f"""\
  e. The sounds and the sticky peek.
✻ Sautéed for 2h 9m 3s · done 3:35 PM
{COMPOSER}  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent
"""
check("done line whose verb has a non-ASCII letter ('Sautéed') reads WAITING",
      state(SAUTEED), "WAITING")

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("All classify-pane gap checks passed.")
