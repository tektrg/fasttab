#!/usr/bin/env python3
"""Precision of the parked-on-background and not-logged-in reads (QA pass on 7799cc5).

The first cut of WAITING_ON_BACKGROUND / NEEDS_LOGIN was too broad, and every
false positive is a NEW silent blind spot (a dead or finished worker that stops
alerting). Each case below is a shape that read wrongly and must now fail toward
the old, alerting verdicts:

  * a finished worker whose only background job is a dev-server SHELL
  * a stale `… still running` on an old done line above a newer finished turn
  * a prose bullet that merely looks like a done line
  * Claude exited to a shell with its old footer still in scrollback
  * a `Not logged in` line a tool printed (cat/Read of a test fixture), and a
    login banner that is stale after the person ran /login
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
    [Sonnet 5] 78% context | git:main wt:x
"""

print("HIGH-2. parked read must not over-match")
check("a dev-server SHELL alone is not a background wait (finished worker)",
      state(f"⏺ Shipped.\n✻ Baked for 2m 49s · done 3:34 PM\n{COMPOSER}  ⏵⏵ auto mode on · 1 shell · ← 1 agent\n"),
      "WAITING")
check("...nor 'N shells' with a plain footer",
      state(f"⏺ Shipped.\n✻ Baked for 2m 49s · done 3:34 PM\n{COMPOSER}  ⏵⏵ auto mode on · 2 shells\n"),
      "WAITING")
check("a monitor in the footer still counts (control)",
      state(f"⏺ Watching.\n✻ Baked for 2m 49s · done 3:34 PM\n{COMPOSER}  ⏵⏵ auto mode on · 1 shell, 1 monitor\n"),
      "WAITING_ON_BACKGROUND")
STALE_DONE = f"""\
✻ Brewed for 44m 20s · done 3:12 PM · 1 monitor still running
⏺ The monitor fired; PR is merged and CI is green.
✻ Baked for 2m 49s · done 4:01 PM
{COMPOSER}  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent
"""
check("an OLD 'still running' done line above a newer finished turn is stale",
      state(STALE_DONE), "WAITING")
STALE_DONE_NO_FOOTER = f"""\
✻ Brewed for 44m 20s · done 3:12 PM · 1 monitor still running
⏺ The monitor fired; PR is merged and CI is green.
✻ Baked for 2m 49s · done 4:01 PM
{COMPOSER}"""
check("...also when the pane has no mode footer at all",
      state(STALE_DONE_NO_FOOTER), "WAITING")
FOOTER_DROPPED_MONITOR = f"""\
✻ Brewed for 44m 20s · done 3:12 PM · 1 monitor still running
{COMPOSER}  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent
"""
check("a footer that no longer counts a monitor outranks the done line's tail",
      state(FOOTER_DROPPED_MONITOR), "WAITING")
PROSE_BULLET = f"""\
- Waiting for CI · done · 1 monitor still running
✻ Baked for 2m 49s · done 3:34 PM
{COMPOSER}  ⏵⏵ auto mode on (shift+tab to cycle)
"""
check("a prose bullet shaped like a done line does not park the pane",
      state(PROSE_BULLET), "WAITING")
PROSE_BULLET_ALONE = f"""\
  Status:
- Waiting for CI · done · 1 monitor still running
{COMPOSER}"""
check("...even when it is the only such line (no glyph, no duration)",
      state(PROSE_BULLET_ALONE), "UNKNOWN")
EXITED_TO_SHELL = f"""\
⏺ Watching.
✻ Brewed for 44m 20s · done 3:12 PM · 1 monitor still running
{COMPOSER}  ⏵⏵ auto mode on · 1 monitor · ← 1 agent
Goodbye!
user@host aptusfit % ls
README.md
user@host aptusfit %
"""
check("Claude exited to a shell: the old footer in scrollback is not a live wait",
      state(EXITED_TO_SHELL), "WAITING")  # the old verdict (done marker), not parked
EXITED_STARSHIP = f"""\
✻ Brewed for 44m 20s · done 3:12 PM · 1 monitor still running
{COMPOSER}  ⏵⏵ auto mode on · 1 monitor · ← 1 agent
$ exit
❯
"""
check("...also when the shell prompt is itself a ❯",
      state(EXITED_STARSHIP), "WAITING")
check("a bare footer line with no composer box above it is not parked",
      state("some output\n  ⏵⏵ auto mode on · 1 monitor · ← 1 agent\n"), "UNKNOWN")

print("\nLOW-7. 'Not logged in' must be a LIVE banner")
FIXTURE_VIA_CAT = f"""\
⏺ Bash(cat tests/fixtures/logged_out.txt)
  ⎿  Not logged in · Run /login
✻ Baked for 2m 49s · done 3:34 PM
{COMPOSER}  ⏵⏵ auto mode on (shift+tab to cycle)
"""
check("a fixture printed by a tool (cat) is not a login wall",
      state(FIXTURE_VIA_CAT), "WAITING")
FIXTURE_BARE = f"""\
⏺ Bash(cat tests/fixtures/logged_out.txt)
  ⎿  header
Not logged in · Run /login
✻ Baked for 2m 49s · done 3:34 PM
{COMPOSER}  ⏵⏵ auto mode on (shift+tab to cycle)
"""
check("a shallow bare fixture line (no ⏺ after it) is not a login wall",
      state(FIXTURE_BARE), "WAITING")
AFTER_LOGIN = f"""\
  ⎿  Not logged in · Please run /login
❯ /login
  ⎿  Login successful
✻ Baked for 2m 49s · done 3:34 PM
{COMPOSER}  ⏵⏵ auto mode on (shift+tab to cycle)
"""
check("after the person ran /login the stale banner no longer blocks",
      state(AFTER_LOGIN), "WAITING")
OLD_BANNER = "  ⎿  Not logged in · Please run /login\n" + "\n".join(
    f"  scrollback line {i}" for i in range(30)) + f"\n✻ Baked for 2m 49s · done 3:34 PM\n{COMPOSER}"
check("a banner far up the scrollback is not live",
      state(OLD_BANNER), "WAITING")
REAL_INLINE = f"""\
❯ what next
  ⎿  Not logged in · Please run /login
✻ Crunched for 0s · done 11:01 AM
{COMPOSER}  ⏵⏵ auto mode on · ← 2 agents
"""
check("control: the real inline reply banner still reads NEEDS_LOGIN",
      state(REAL_INLINE), "NEEDS_LOGIN")
REAL_BOTTOM = f"""\
⏺ Watching.
✻ Crunched for 23s · done Saturday 7:25 PM
                                        Not logged in · Run /login
{COMPOSER}  ⏵⏵ auto mode on (shift+tab to cycle) · ← 2 agents
"""
check("control: the real bottom status-line banner still reads NEEDS_LOGIN",
      state(REAL_BOTTOM), "NEEDS_LOGIN")

print("\nLOW-2. logged-out variants that read as idle")
INVALID_KEY = f"""\
❯ what next
  ⎿  Invalid API key · Please run /login
✻ Crunched for 0s · done 11:01 AM
{COMPOSER}  ⏵⏵ auto mode on (shift+tab to cycle)
"""
check("`Invalid API key · Please run /login` reads NEEDS_LOGIN",
      state(INVALID_KEY), "NEEDS_LOGIN")
WRAPPED_SPACE = f"""\
❯ what next
  ⎿  Not logged in · Please run
     /login
✻ Crunched for 0s · done 11:01 AM
{COMPOSER}  ⏵⏵ auto mode on (shift+tab to cycle)
"""
check("a banner hard-wrapped at a space (narrow pane) reads NEEDS_LOGIN",
      state(WRAPPED_SPACE), "NEEDS_LOGIN")
WRAPPED_MID_WORD = f"""\
❯ what next
  ⎿  Not logged in · Please ru
n /login
✻ Crunched for 0s · done 11:01 AM
{COMPOSER}  ⏵⏵ auto mode on (shift+tab to cycle)
"""
check("...or hard-wrapped mid-word",
      state(WRAPPED_MID_WORD), "NEEDS_LOGIN")
QUOTED_WRAPPED = f"""\
⏺ The status line should show Not logged in · Please run
  /login when the token expires, so I added a check for it.
✻ Crunched for 0s · done 11:01 AM
{COMPOSER}  ⏵⏵ auto mode on (shift+tab to cycle)
"""
check("control: prose that wraps onto a /login line is not a login wall",
      state(QUOTED_WRAPPED), "WAITING")

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("All parked/login precision checks passed.")
