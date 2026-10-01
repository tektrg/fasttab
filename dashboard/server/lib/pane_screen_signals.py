#!/usr/bin/env python3
"""Screen signals the pane classifier reads beyond spinner / prompt / crash.

Split out of classify_pane.py (already past the file-size limit). Pure text in,
answers out — no herdr, no I/O. Every shape here was measured on REAL pane text
kept by the Jev shadow loop (memory/Areas/delivery-ops/
202609201540-jev-shadow-mismatch-review-1.md), not guessed:

  * PARKED ON BACKGROUND WORK — the turn ended but a Monitor / background shell
    / background agent is still running. Claude Code says so in its composer
    footer (`⏵⏵ auto mode on · 1 shell, 1 monitor · ← 1 agent`), on the done
    line (`… · done 3:12 PM · 1 monitor still running`) and, for agents, on a
    `✻ Waiting for 1 background agent to finish` line. A worker in this state
    is waiting ON PURPOSE. Reading it as "turn ended" is what flagged a healthy
    worker `stalled` (nudge-9ebb613e, 2026-09-20).
  * NOT LOGGED IN — the session cannot answer any message until a person runs
    /login (7 second-Mac panes, read as idle by both classifiers).
  * OPENCODE — a different TUI (prompt box closed by `╹▀▀▀…`, footer with
    `ctrl+p commands`, `esc interrupt` while a turn runs). 57% of the "no call"
    rows were OpenCode panes.

Also holds `resolve_state`, the ONE precedence rule for a pane's hook state vs
its screen read.
"""
import hashlib
import os
import re

from other_tui_screens import codex_state, opencode_state, prompt_open  # noqa: F401 (re-exported)

#: What the screen classifier can return. Kept here so consumers (liveness,
#: dashboard, watchers) import names instead of retyping strings.
ACTIVE = "ACTIVE"
WAITING = "WAITING"
WAITING_ON_BACKGROUND = "WAITING_ON_BACKGROUND"
NEEDS_HUMAN = "NEEDS_HUMAN"
NEEDS_LOGIN = "NEEDS_LOGIN"
CRASHED = "CRASHED"
UNKNOWN = "UNKNOWN"

# ── Parked on background work ────────────────────────────────────────────────
#: How many of the last non-blank lines count as "the composer" when looking for
#: the input box. The composer is rule / `❯` / rule / status line / mode footer
#: (5 lines) plus the occasional hint line.
COMPOSER_LOOKBACK = 8
#: How far above the composer a done / "Waiting for" status line may sit.
STATUS_LINE_LOOKBACK = 12
#: Lines that may follow the input box's closing rule: status line + mode footer
#: (+ one hint). More than this means something else is drawn UNDER the box —
#: e.g. Claude exited to a shell — and the box is scrollback, not a live UI.
MAX_LINES_UNDER_BOX = 3

_RULE_RE = re.compile(r'^\s*─{5,}')
_PROMPT_LINE_RE = re.compile(r'^\s*❯')
#: A shell prompt drawn under a (now dead) Claude box.
_SHELL_PROMPT_RE = re.compile(r'^\s*(?:[$%#❯>]|\S+@\S+.*[$%#]\s*$)')

#: The mode footer, e.g. `⏵⏵ auto mode on · 1 shell, 1 monitor · ← 1 agent`.
#: Anchored on the `⏵⏵` glyph so prose can never match.
_FOOTER_LINE_RE = re.compile(r'^\s*⏵⏵')
#: What in a footer means "the turn is waiting on something": a Monitor or a
#: background agent/task. Deliberately NOT `N shell(s)` — a finished worker that
#: left a dev server / Metro running shows `1 shell` forever, and `← N agents`
#: is the main-agent hint present on idle panes too.
_FOOTER_WAITING_RE = re.compile(
    r'\b\d+\s+(?:monitors?|background\s+(?:tasks?|agents?))\b')
#: The turn-end line: `✻ Brewed for 44m 20s · done 3:12 PM · 1 monitor still running`.
#: A symbol glyph (never a `-`/`*`/`•` list bullet), a one-word verb, `for` and a
#: duration — so a prose bullet "- Waiting for CI · done · 1 monitor still
#: running" is not one. Unicode verb letters ("Sautéed"), like DONE_SPINNER_RE.
_DONE_LINE_RE = re.compile(
    r'^[^\w\s\-*+•#>|]\s*[A-ZÀ-Ý][^\W\d_]*\s+for\s+(?:\d+h\s*)?(?:\d+m\s*)?\d+s\b')
_STILL_RUNNING_RE = re.compile(
    r'·\s*\d+\s+(?:monitors?|background\s+\w+)\s+still\s+running\b')
#: `✻ Waiting for 1 background agent to finish` — a status line, glyph-led.
_BACKGROUND_WAIT_RE = re.compile(
    r'^\s*[^\w\s\-*+•#>|]\s+Waiting for \d+ background (?:agents?|tasks?|shells?)\b',
    re.IGNORECASE)
_WORK_OUTPUT_RE = re.compile(r'^\s*⏺')


def _box_close_index(content):
    """Index (into `content`) of the LIVE input box's closing rule, or None.

    The live composer is `rule / ❯ … / rule` with at most MAX_LINES_UNDER_BOX
    lines (status + footer) beneath it and no shell prompt among them. A bare
    shell prompt, or a Claude that exited to one, has no such box at the bottom.
    """
    close = None
    for i in range(len(content) - 1, max(-1, len(content) - COMPOSER_LOOKBACK - 1), -1):
        if _RULE_RE.match(content[i]):
            close = i
            break
    if close is None or len(content) - 1 - close > MAX_LINES_UNDER_BOX:
        return None
    if any(_SHELL_PROMPT_RE.match(l) for l in content[close + 1:]):
        return None
    prompt = None
    for i in range(close - 1, max(-1, close - COMPOSER_LOOKBACK), -1):
        if _PROMPT_LINE_RE.match(content[i]):
            prompt = i
            break
    if prompt is None:
        return None
    if not any(_RULE_RE.match(content[i]) for i in range(prompt - 1, -1, -1)
               if prompt - i <= 4):
        return None
    return close


def background_work_open(tail_lines):
    """Is the turn parked on a still-running Monitor / background task/agent?

    Only ever asked of a pane the positional contest found NOT active, NOT
    crashed and NOT asking — so a live spinner, a crash banner and an open
    prompt all keep outranking it. Fails toward False (= the old verdicts, which
    alert): it needs the LIVE Claude composer at the bottom, and then

      * the LAST mode-footer line counting a monitor / background agent says yes
        (it is redrawn every frame, so it is the only non-stale statement);
      * else a `✻ Waiting for N background agent` line, or — only when there is
        no footer at all — the LAST turn-end line saying `… still running`
        (older done lines never count) with no `⏺` output after it.
    """
    content = [l.strip() for l in tail_lines if l.strip()]
    close = _box_close_index(content)
    if close is None:
        return False
    footers = [l for l in content[close + 1:] if _FOOTER_LINE_RE.match(l)]
    if footers and _FOOTER_WAITING_RE.search(footers[-1]):
        return True
    window = content[max(0, close - STATUS_LINE_LOOKBACK):close]
    for i in range(len(window) - 1, -1, -1):
        line = window[i]
        if _WORK_OUTPUT_RE.match(line):
            return False  # work drawn after (or instead of) any status line
        if _BACKGROUND_WAIT_RE.match(line):
            return True
        if _DONE_LINE_RE.match(line):
            # A footer that no longer counts a monitor outranks the done line's
            # `… still running` (printed once, at turn end, never updated).
            return bool(_STILL_RUNNING_RE.search(line)) and not footers
    return False


# ── Not logged in ────────────────────────────────────────────────────────────
#: The whole line is the message, optionally after a `⎿` result marker. Anchored
#: at both ends so prose QUOTING the message ("… show "Not logged in · Run
#: /login" at the bottom") can never match.
NOT_LOGGED_IN_RE = re.compile(
    r'^\s*(?:⎿\s*)?(?:Not logged in|Invalid API key)\s*[·•∙-]\s*(?:Please\s+)?run\s+/login\s*$',
    re.IGNORECASE)
#: Work printed after the error proves the session recovered (Claude Code draws
#: every assistant message and tool call with a `⏺` lead).
_WORK_LINE_RE = re.compile(r'^\s*⏺')
#: Evidence the person has since acted: a submitted `/login`, or its success line.
_LOGIN_ATTEMPT_RE = re.compile(r'^\s*[❯>]\s*/login\b|^\s*(?:⎿\s*)?Login successful', re.IGNORECASE)
#: How many non-blank lines from the bottom the banner may sit. It lives at the
#: bottom (status line) or right above the turn-end line + composer (~10 lines);
#: anything older is scrollback or a fixture that something printed.
LOGIN_BANNER_LOOKBACK = 14
#: A bare (no `⎿`) banner is the bottom status line, drawn deeply indented. A
#: shallow bare line is file / command output a tool printed.
_BARE_BANNER_MIN_INDENT = 8
#: `⏺ Bash(cat fixture)` — the line a tool RESULT (`⎿ …`) hangs under.
_TOOL_CALL_RE = re.compile(r'^\s*⏺\s+\w+\(')


def _is_tool_output_banner(tail_lines, i):
    """Is this banner line a tool's printed output rather than the session's error?"""
    line = tail_lines[i]
    if '⎿' not in line:
        return len(line) - len(line.lstrip()) < _BARE_BANNER_MIN_INDENT
    for j in range(i - 1, -1, -1):
        if tail_lines[j].strip():
            return bool(_TOOL_CALL_RE.match(tail_lines[j]))
    return False


def _banner_starts_at(tail_lines, i):
    """Does the login banner START on line `i`?

    On a narrow pane the terminal hard-wraps the banner over two lines, at a
    space or mid-word, so the whole-line anchor also gets one try against the
    line joined with the one below. Still anchored at both ends: prose quoting
    the message has more text around it and cannot match either way.
    """
    line = tail_lines[i]
    if NOT_LOGGED_IN_RE.match(line):
        return True
    if i + 1 >= len(tail_lines) or not tail_lines[i + 1].strip():
        return False
    head, rest = line.rstrip(), tail_lines[i + 1].strip()
    return any(NOT_LOGGED_IN_RE.match(head + sep + rest) for sep in (" ", ""))


def not_logged_in_index(tail_lines):
    """Index of the LAST live "Not logged in" line, or None.

    Live = near the bottom, not a tool's own output (a `cat`/Read of a test
    fixture), and with no work (`⏺`) or `/login` attempt drawn after it.
    """
    nonblank_seen = 0
    for i in range(len(tail_lines) - 1, -1, -1):
        line = tail_lines[i]
        if not line.strip():
            continue
        nonblank_seen += 1
        if nonblank_seen > LOGIN_BANNER_LOOKBACK:
            return None
        if _WORK_LINE_RE.match(line) or _LOGIN_ATTEMPT_RE.match(line):
            return None  # work / a login attempt drawn after (or instead of) any error
        if _banner_starts_at(tail_lines, i):
            return None if _is_tool_output_banner(tail_lines, i) else i
    return None


# ── OpenCode / Codex ─────────────────────────────────────────────────────────
#: Screen reads for the other agent TUIs live in other_tui_screens.py.


def other_tui_state(tail_lines):
    """OpenCode's or Codex's screen state, or None when the pane is neither."""
    return opencode_state(tail_lines) or codex_state(tail_lines)


# ── herdr agent_status as a fallback for non-Claude panes (P5) ───────────────
#: herdr's lifecycle word -> the screen state it stands in for. `unknown` is
#: absent on purpose: it is herdr saying it cannot tell either.
_SCREEN_STATE_BY_HERDR_STATUS = {
    "working": ACTIVE, "blocked": NEEDS_HUMAN, "idle": WAITING, "done": WAITING,
}
SCREEN_STATE_SOURCE_SCREEN = "screen"
SCREEN_STATE_SOURCE_HERDR = "herdr"


def screen_state_with_herdr_fallback(agent_kind, screen_state, herdr_status):
    """(screenState, source) for one pane. The screen classifier's answer
    stands whenever it has one. Only for a NON-Claude agent (OpenCode, …) whose
    screen reads UNKNOWN / nothing is herdr's own agent_status used — for
    Claude panes herdr's word is the default this dashboard exists to distrust
    (hook + screen cover them). source is None when neither has an answer."""
    if screen_state and screen_state != UNKNOWN:
        return screen_state, SCREEN_STATE_SOURCE_SCREEN
    fallback = _SCREEN_STATE_BY_HERDR_STATUS.get(herdr_status)
    if agent_kind and agent_kind != "claude" and fallback:
        return fallback, SCREEN_STATE_SOURCE_HERDR
    return screen_state, (SCREEN_STATE_SOURCE_SCREEN if screen_state else None)


# ── Hook vs screen precedence ────────────────────────────────────────────────
#: Screen reads that PROVE something is drawn right now that no hook event can
#: contradict: an open prompt, a login wall, a crash banner, a live spinner.
_SCREEN_OUTRANKS_HOOK = {
    NEEDS_HUMAN: "blocked",
    NEEDS_LOGIN: "blocked",  # a person must act; the screen column keeps the NEEDS_LOGIN detail
    CRASHED: "crashed",
    ACTIVE: "working",
}
#: Screen reads that prove the turn is over (or parked). They outrank a hook
#: `working` (which never expires) but never a hook `blocked` (fail open).
_SCREEN_TURN_OVER = {WAITING: "idle", WAITING_ON_BACKGROUND: "working"}


#: A hook `working` this recent (seconds since its last event; every tool run
#: refreshes it) is the freshest thing known and beats a screen that merely
#: LOOKS finished — a spinner-less mid-turn frame with an earlier done line
#: above it. Older than this it may be a reporter that died mid-turn (the hook
#: never expires on its own), so the screen's finished-turn read wins again.
HOOK_WORKING_FRESH_SEC = 90


def hook_working_is_fresh(hook_state, hook_age_sec):
    """Is the hook's `working` young enough to be the freshest word on the pane?
    ONE definition, used by resolve_state, the disagree rule and pane_liveness."""
    return (hook_state == "working" and hook_age_sec is not None
            and 0 <= hook_age_sec < HOOK_WORKING_FRESH_SEC)

#: A pane parked on its own monitor / background agent is believed "working" only
#: this long without real progress (the hook idle age resets on any tool run).
#: Same 2h as delivery_ops/supervisor.py BACKGROUND_WAIT_CEILING_SECONDS and the
#: watcher's --background-dwell-min - keep all three equal. Past it the frame may
#: be a dead session's last draw ("1 monitor" forever), so it stops reading green.
BACKGROUND_WAIT_CEILING_SEC = 2 * 60 * 60


def background_wait_expired(screen_state, hook_age_sec):
    """Parked on background work for longer than the ceiling? An unknown age
    (hookless pane) cannot be judged, so it is not expired."""
    return (screen_state == WAITING_ON_BACKGROUND and hook_age_sec is not None
            and hook_age_sec >= BACKGROUND_WAIT_CEILING_SEC)


def resolve_state(hook_state, screen_state, hook_age_sec=None):
    """One state word for a pane from its (possibly stale) hook and its screen.

    The hook is a pushed event and can be frozen (`idle` during a live spinner,
    `working` while a dialog is open, `blocked` over a correct crash read);
    the screen is what is drawn now. Positive screen evidence wins; where the
    screen cannot say (UNKNOWN / unreadable) the hook stands — including
    `blocked`, because under-reporting a human gate leaves a worker stopped
    forever. Returns a hook-vocabulary word (working / idle / blocked) plus
    `crashed`, or None when neither source has an opinion. A login wall reads
    `blocked` (a person must act); its screen column keeps NEEDS_LOGIN.

    A FRESH hook `working` (`hook_age_sec` under HOOK_WORKING_FRESH_SEC) beats a
    screen WAITING / WAITING_ON_BACKGROUND (the screen can't tell a spinner-less
    mid-turn frame from a finished one) but never a crash / dialog / login read.

    A disagreement is still SURFACED by the caller (the dashboard's
    `disagree` column); this only picks which word to display.
    """
    if screen_state in _SCREEN_OUTRANKS_HOOK:
        return _SCREEN_OUTRANKS_HOOK[screen_state]
    if (screen_state in _SCREEN_TURN_OVER
            and hook_working_is_fresh(hook_state, hook_age_sec)):
        return "working"
    if background_wait_expired(screen_state, hook_age_sec):
        # Past the ceiling the parked claim is no longer believed: a finished
        # turn, like WAITING (a hook `blocked` still stands, fail open).
        return hook_state if hook_state == "blocked" else "idle"
    if screen_state in _SCREEN_TURN_OVER and hook_state != "blocked":
        return _SCREEN_TURN_OVER[screen_state]
    return hook_state or None


# ── Background shells the footer claims ──────────────────────────────────────
_SHELLS_CLAIM_RE = re.compile(r'\b(\d+)\s+shells?\b')


def claimed_shells(tail_lines):
    """How many background shells the composer footer (else the turn-end line)
    says are still running, or None when it says nothing about shells.

    Evidence only, never a verdict: a finished worker that left a dev server up
    shows `1 shell` forever. It matters when set against reality - a footer that
    claims a shell under a session that has no shell process is exactly the dead
    background job that cost a worker 18 minutes on 2026-09-20.
    """
    content = [l.strip() for l in tail_lines if l.strip()]
    for line in reversed(content):
        if _FOOTER_LINE_RE.match(line) or _STILL_RUNNING_RE.search(line) or 'still running' in line:
            found = _SHELLS_CLAIM_RE.search(line)
            if found:
                return int(found.group(1))
            if _FOOTER_LINE_RE.match(line):
                return None  # the live footer is the freshest word; it names no shell
    return None


# ── Is this pane doing work RIGHT NOW? (shared live-work evidence) ───────────
#: A screen whose fingerprint has not changed for this long is not being drawn
#: to. Equal to pane_liveness.SPINNER_FROZEN_AFTER_SEC (5 heartbeats) - keep in step.
SCREEN_FROZEN_AFTER_SEC = float(os.environ.get("PANE_SPINNER_FROZEN_AFTER_SEC", 10 * 60))

#: Ceiling on everything below the fresh hook: activity that is real but silent
#: (a sub-agent, a scrolled-back stream) vouches for a `working` hook only while
#: the hook itself has spoken inside this window. Past it the pane is flagged,
#: with the evidence, instead of being trusted forever. Same 2h as the parked
#: ceiling above (one number for "how long may a worker be quiet on purpose").
LIVE_WORK_CEILING_SEC = BACKGROUND_WAIT_CEILING_SEC

#: What no amount of screen movement may vouch for: the pane is showing a real,
#: different state (an open prompt, a login wall, a crash banner).
_NEVER_VOUCHED = (NEEDS_HUMAN, NEEDS_LOGIN, CRASHED)


def screen_digest(text):
    """Whitespace-normalised fingerprint of a pane's text: a reflow is not new
    output, but a changed counter (`+5/-0`, `20 new messages`, a spinner timer) is."""
    return hashlib.sha256(" ".join((text or "").split()).encode()).hexdigest()[:16]


def stamp_screen_motion(entry, previous, now):
    """Add `changedAt` / `motionKnown` to a fresh paneScreen `entry` (in place).

    `changedAt` is when the entry's `digest` last differed from the sweep before;
    `motionKnown` is False on a pane's first look (one sample can never show a
    screen is NOT moving, so it is 'unknown', never 'moving' or 'frozen').
    `changeObserved` is True once this dashboard has SEEN the digest change
    (not just a first look): only then is `changedAt` a real "last drew
    something" time (screen_activity_sec), not "when the dashboard started".
    """
    digest = entry.get("digest")
    if isinstance(previous, dict) and previous.get("digest") is not None and digest is not None:
        entry["motionKnown"] = True
        same = previous["digest"] == digest and previous.get("changedAt") is not None
        entry["changedAt"] = previous["changedAt"] if same else now
        entry["changeObserved"] = bool(previous.get("changeObserved")) if same else True
    else:
        entry["motionKnown"] = False
        entry["changedAt"] = now
        entry["changeObserved"] = False
    return entry


def stamp_sweep_motion(screens, history, now, live_keys=()):
    """Stamp every entry of one sweep's `screens` from `history` (a dict the caller
    keeps for the life of the poll loop) and update it.

    History is separate from the published feed data on purpose: a pane whose read
    fails one sweep drops out of `screens`, and if the NEXT sweep compared against
    that gap it would read as a first look - re-trusting a dead pane's frame and
    restarting its frozen clock. Panes that are no longer live (`live_keys`, when
    given) are forgotten so a reused pane id does not inherit a stranger's clock.
    """
    for key, entry in screens.items():
        stamp_screen_motion(entry, history.get(key), now)
        history[key] = {"digest": entry.get("digest"), "changedAt": entry["changedAt"],
                        "changeObserved": entry["changeObserved"]}
    if live_keys:
        for key in [k for k in history if k not in live_keys]:
            del history[key]
    return screens


def screen_unchanged_sec(entry, now):
    """Seconds a paneScreen entry has read identically, or None when unknowable.

    Measured up to the entry's own read time (`ts`), not `now`: a feed that went
    quiet (broken, laptop asleep) keeps serving its last data, and counting the
    silence as "frozen" would make a screen that changed 20 s before the last
    read look dead. A broken feed has its own alert.
    """
    if not isinstance(entry, dict) or not entry.get("motionKnown"):
        return None
    changed_at = entry.get("changedAt")
    if not isinstance(changed_at, (int, float)):
        return None
    read_at = entry.get("ts")
    end = min(now, read_at) if isinstance(read_at, (int, float)) else now
    return max(0.0, end - changed_at)


def remembered_activity(history):
    """The activity clock of every pane in a sweep's motion `history` that has
    been SEEN changing: {key: {"changedAt", "changeObserved": True}}.

    Published beside the feed's screens, not inside them: a pane whose read
    failed this sweep keeps its last-change time (ranking must not drop it to
    "oldest" for one sweep) while its screen stays ABSENT - a stub screen entry
    would look like a successful read with stale content to the needs-you /
    question / permission readers and to the feed's own "none could be read"
    check. Only the clock survives a failed read, never the content."""
    return {key: {"changedAt": h["changedAt"], "changeObserved": True}
            for key, h in history.items()
            if h.get("changeObserved") and isinstance(h.get("changedAt"), (int, float))}


def screen_activity_sec(entry, now):
    """Seconds since this pane's screen last CHANGED, or None when no change has
    been seen yet (first look, or every look identical since the dashboard
    started). The activity clock for rows without hook data (remote panes):
    unknown sorts as oldest - after a restart an idle pane stays unknown until it
    draws something, rather than every pane looking active "at restart time".
    Granularity = one sweep (~15 s). Measured to `now`: activity only ages."""
    if not isinstance(entry, dict) or not entry.get("changeObserved"):
        return None
    changed_at = entry.get("changedAt")
    if not isinstance(changed_at, (int, float)):
        return None
    return max(0.0, now - changed_at)


def live_work_evidence(hook_state, screen_state, hook_age_sec=None, *,
                       screen_unchanged_sec=None, subagents=0):
    """A short reason this pane is demonstrably doing work now, or None.

    THE one place "is a `working` hook believable?" is answered, for the disagree
    rule (and `pane_liveness` shares `hook_working_is_fresh`). Evidence, cheapest
    and strongest first:

      1. the hook itself spoke recently (every tool run refreshes it);
      2. the pane is parked on its own background agent / monitor (on purpose);
      3. a live spinner, a screen whose text CHANGED inside SCREEN_FROZEN_AFTER_SEC
         (counters, `+N/-M`, "N new messages", a sub-agent's ticking timer), or -
         on a pane's first look, before any motion is known - a sub-agent's
         status line on screen.

    Bounds, so nothing vouches forever (a killed session keeps drawing its last
    frame): a crash / prompt / login screen is never vouched for; past
    LIVE_WORK_CEILING_SEC of hook silence only (1) and a ticking spinner can
    still count; a screen frozen for SCREEN_FROZEN_AFTER_SEC is a frame, not a worker - a spinner glyph
    or a sub-agent line on it proves nothing.
    """
    if screen_state in _NEVER_VOUCHED:
        return None
    if hook_working_is_fresh(hook_state, hook_age_sec):
        return f"hook reported work {int(hook_age_sec)}s ago"
    past_ceiling = hook_age_sec is not None and hook_age_sec >= LIVE_WORK_CEILING_SEC
    if screen_state == WAITING_ON_BACKGROUND:
        return None if past_ceiling else "parked on background work"
    if screen_unchanged_sec is not None and screen_unchanged_sec >= SCREEN_FROZEN_AFTER_SEC:
        return None
    if screen_state == ACTIVE:
        # A ticking spinner is its own proof, hook age aside - but a spinner whose
        # motion is UNKNOWN past the ceiling is only a glyph.
        if past_ceiling and screen_unchanged_sec is None:
            return None
        return "live spinner on screen"
    if past_ceiling:
        return None
    if screen_unchanged_sec is not None:
        return f"screen changed {int(screen_unchanged_sec)}s ago"
    if subagents:
        return f"{subagents} sub-agent(s) running (first look)"
    return None


# ── hook vs herdr disagreement ───────────────────────────────────────────────
#: herdr's agent_status vocabulary folded onto the hook's: `done` (finished, not
#: yet looked at) and `idle` (nothing running) are the same fact.
_HERDR_TO_HOOK = {"done": "idle"}


def hook_vs_herdr_disagree(hook_state, herdr_status, screen_state, hook_age_sec=None, *,
                           screen_unchanged_sec=None, subagents=0):
    """Is a hook-vs-herdr split worth a human's attention?

    herdr's `agent_status` is a default, not a measurement (memory:
    herdr-agent-status-is-a-frozen-field) - it reads `done`/`idle` through a live
    turn, and even a non-null `last_completed_turn` can be days stale (wB:p2Y,
    2026-09-20). So herdr can never PROVE the pane idle; the split is only
    information when nothing shows the pane working. For a hook `working` that
    is `live_work_evidence` - the hook's own age, a spinner, a moving screen, a
    running sub-agent. Reporting a split that evidence contradicts wakes the
    chief (~200K tokens) to learn nothing (measured 2026-09-20: `hook=working
    herdr=done`, then `herdr=idle` on a pane streaming a reply with no spinner
    in view).

    A genuinely dead turn - hook `working` gone quiet, screen frozen, no
    sub-agent - still splits, and so does anything past LIVE_WORK_CEILING_SEC.
    """
    if not hook_state or not herdr_status:
        return False
    if hook_state == _HERDR_TO_HOOK.get(herdr_status, herdr_status):
        return False
    if hook_state == "working" and live_work_evidence(
            hook_state, screen_state, hook_age_sec,
            screen_unchanged_sec=screen_unchanged_sec, subagents=subagents):
        return False
    if hook_state == "idle" and screen_state in (WAITING, WAITING_ON_BACKGROUND):
        return False
    if hook_state == "blocked" and screen_state in (NEEDS_HUMAN, NEEDS_LOGIN):
        return False
    return True
