#!/usr/bin/env python3
"""Send a message to an OpenCode or Codex row (Phase 4 of OpenCode/Codex support).

Same rules as a Claude pane send (the server checks them first, in
`_handle_reach_action`): one line, <= 8000 chars, no control characters, a
FRESH pane read, refused while a prompt / question / permission box is open,
`needsConfirm` while busy (then state "queued"), audited, never retried. This
module adds what is specific to these two tools:

  * only a row with fresh exact status (`message_gate.is_tui_row`) and a status
    entry that still names THIS pane;
  * no leading `/` (a Claude-only shortcut, and a slash popup eats Enter) and no
    leading `!` (OpenCode and Codex run it as a shell command);
  * OpenCode: the plugin inside that OpenCode process calls its own session
    prompt API (`POST /session/<id>/prompt_async`, job relay `tui_jobs.py`).
    A default OpenCode TUI has no listening port, and no keystroke is involved,
    so a prompt that appeared meanwhile cannot swallow the text;
  * Codex: typed into the herdr pane in two steps — text first, a fresh read
    proves it sits in the composer and no prompt is open, then Enter, then a
    read proves the composer emptied. Text stuck in the composer, or a step
    that failed part-way, is "NOT SUBMITTED" / "mid-sequence" (the clients
    treat both as uncertain: never a second send).

The message is a plain user prompt for the tool; nothing here gives it any
authority beyond that. `submit_job`, `pane_io` are injected (tests use fakes).
"""
import re
import threading
import time

import opencode_answer
import other_tui_screens
import tui_jobs

OPENCODE, CODEX = "opencode", "codex"
SEND_LEAD_CHARS = ("/", "!")
#: Enough of the text to recognise it in a composer that wraps or scrolls.
COMPOSER_MATCH_CHARS = 48
SETTLE_SEC = 0.4
AFTER_ENTER_SEC = 2.0
READ_LINES = 60
#: The plugin reported it can run a prompt (agentbar-status.js, marker v2).
OUTDATED_PLUGIN = ("refused: the AgentBar OpenCode plugin in that terminal is out of date — "
                   "re-run the integration installer and restart OpenCode")
NON_EMPTY_COMPOSER = ("refused: the Codex composer already holds unsent text — sending would "
                      "submit it too. Clear or send it in the terminal first")
MAYBE_SENT = ("the request was handed to OpenCode but its answer never came back — the "
              "message may or may not have arrived; check the session before re-sending")

_inflight = set()
_inflight_lock = threading.Lock()
#: (tool, session, text) -> monotonic time of the last send attempt. The same
#: line to the same session again within this window is a double click or a
#: client retry, never a second intent: refused ("was just sent").
DUPLICATE_WINDOW_SEC = 10.0
#: An UNCERTAIN attempt (no answer, or a failure part-way) may still be running
#: or have landed: keep blocking the same text for much longer.
UNCERTAIN_WINDOW_SEC = 90.0
_recent = {}  # (tool, session, text) -> monotonic time it may be sent again


def refused(text):
    """Nothing was sent (`typed: false` puts the text back in the client's box)."""
    return {"ok": False, "error": text, "typed": False}


def leading_char_refusal(text):
    if text[:1] in SEND_LEAD_CHARS:
        return refused("refused: a message starting with '" + text[:1] + "' is a "
                       "command in " + "OpenCode / Codex — type it in the terminal instead")
    return None


def _entry_refusal(entry, raw_pane_id):
    if entry is None:
        return refused("refused: this session's status feed is not fresh — nothing sent")
    if entry.get("paneId") and entry["paneId"] != raw_pane_id:
        return refused("refused: that session runs in another pane")
    if entry.get("status") == "blocked" or entry.get("prompt"):
        return refused("refused: that session is waiting on you (a question or permission "
                       "prompt) — answer it first")
    return None


def prompt_refusal(lines):
    """A fresh screen read shows an open prompt: refused, nothing typed."""
    kind = other_tui_screens.prompt_open(lines)
    if kind:
        return refused(f"refused: a {kind} prompt is open on that pane — a message "
                       "could answer it. Answer it in the terminal instead")
    return None


def check(agent, raw_pane_id, text, lines, fresh_entries):
    """(entry, refusal): every gate that applies before busy/confirm."""
    refusal = leading_char_refusal(text) or prompt_refusal(lines)
    if refusal:
        return None, refusal
    tool, session_id = agent.get("agentKind"), agent.get("tuiSessionId")
    entry = next((e for e in fresh_entries
                  if e["tool"] == tool and e["sessionId"] == session_id), None)
    refusal = _entry_refusal(entry, raw_pane_id)
    return (None if refusal else entry), refusal


def _guarded(key, text, run, clock=time.monotonic):
    """Run one send under the per-session slot. Refused while another send to
    that session runs, or when the same text went to it moments ago (a double
    click or client retry, never a second intent). The attempt is remembered so
    an uncertain outcome (never retried) blocks a duplicate too; a refusal that
    provably sent nothing (`typed: false`) forgets it, so the user can fix the
    cause and send again at once."""
    now = clock()
    recent_key = key + (text,)
    with _inflight_lock:
        for old in [k for k, until in _recent.items() if now >= until]:
            del _recent[old]
        if key in _inflight or recent_key in _recent:
            return refused("refused: that message was just sent to this session (or another send "
                           "is still running) — not sending it twice")
        _inflight.add(key)
        _recent[recent_key] = now + DUPLICATE_WINDOW_SEC
    result = None
    try:
        result = run()
        return result
    finally:
        with _inflight_lock:
            _inflight.discard(key)
            if result is not None and result.get("typed") is False:
                _recent.pop(recent_key, None)
            elif result is None or not result.get("ok"):
                _recent[recent_key] = clock() + UNCERTAIN_WINDOW_SEC


def _sent(was_busy):
    if was_busy:
        return {"ok": True, "state": "queued",
                "reason": "queued — lands when the current turn ends. Do not re-send — this send is logged"}
    return {"ok": True, "state": "message sent", "reason": "delivered to the session"}


# ── OpenCode ────────────────────────────────────────────────────────────────

def opencode_prompt_job(entry, text):
    """(pid, method, path, body) of the one request that submits `text`."""
    return (entry["pid"], "POST", f"/session/{entry['sessionId']}/prompt_async",
            {"parts": [{"type": "text", "text": text}]})


def send_opencode(entry, text, was_busy, submit_job=None, pid_owned=None):
    if not (entry.get("relay") and entry.get("canMessage")):
        return refused(OUTDATED_PLUGIN)
    if not (pid_owned or opencode_answer.pid_owned_by_me)(entry.get("pid")):
        return refused("refused: the OpenCode process is gone")
    def run():
        pid, method, path, body = opencode_prompt_job(entry, text)
        try:
            status, _ = (submit_job or tui_jobs.QUEUE.submit)(pid, method, path, body)
        except tui_jobs.JobNotPickedUp:
            return refused("refused: the OpenCode plugin did not pick the message up "
                           "— nothing was sent")
        except TimeoutError:
            return {"ok": False, "error": MAYBE_SENT}
        except ValueError as e:
            return refused(f"refused: {e}")
        if 200 <= status < 300:
            return _sent(was_busy)
        if 400 <= status < 500:
            return refused(f"refused: OpenCode did not accept the message (HTTP {status}) — nothing was sent")
        return {"ok": False, "error": MAYBE_SENT}

    return _guarded((OPENCODE, entry["sessionId"]), text, run)


# ── Codex ───────────────────────────────────────────────────────────────────

_COMPOSER_RE = re.compile(r"^\s*›")


EMPTY_COMPOSER_RE = re.compile(r"^\s*›\s*(Ask Codex to do anything.*)?$")


def _live_composer(lines):
    bottom = [l for l in lines if l.strip()][-12:]
    composer = [l for l in bottom if _COMPOSER_RE.match(l)]
    return composer[-1] if composer else None


def composer_is_empty(lines):
    """The live composer shows Codex's placeholder (nothing typed): a draft the
    user left there would be submitted together with our text."""
    composer = _live_composer(lines)
    return composer is not None and bool(EMPTY_COMPOSER_RE.match(composer))


def composer_holds(lines, text):
    """Does the live composer (the last `›` line near the bottom) hold our text?"""
    composer = _live_composer(lines)
    if composer is None or EMPTY_COMPOSER_RE.match(composer):
        return False
    needle = " ".join(text.split())[:COMPOSER_MATCH_CHARS]
    return needle in " ".join(composer.split())


def send_codex(entry, raw_pane_id, text, lines, was_busy, pane_io,
               settle_sec=SETTLE_SEC, after_enter_sec=AFTER_ENTER_SEC, sleep=time.sleep):
    """Type into the pane. `pane_io`: send_text(pane, text), send_keys(pane, key),
    read_pane(pane, n) -> lines."""
    if not entry.get("paneId"):
        return refused("refused: Codex did not report its pane — cannot be sure where to type")
    if other_tui_screens.codex_state(lines) not in (other_tui_screens.WAITING, other_tui_screens.ACTIVE):
        return refused("refused: the pane does not show the Codex composer right now")
    if not composer_is_empty(lines):
        return refused(NON_EMPTY_COMPOSER)

    def run():
        # The screen the caller read may be older than a send that just
        # finished: look again inside the claim before typing anything.
        try:
            fresh = pane_io["read_pane"](raw_pane_id, READ_LINES)
        except Exception as e:  # noqa: BLE001 — nothing typed yet
            return refused(f"refused: could not read the pane — {e}")
        if other_tui_screens.prompt_open(fresh):
            return refused("refused: a prompt opened on that pane — answer it in the terminal first")
        if not composer_is_empty(fresh):
            return refused(NON_EMPTY_COMPOSER)
        try:
            pane_io["send_text"](raw_pane_id, text)
            sleep(settle_sec)
            typed_lines = pane_io["read_pane"](raw_pane_id, READ_LINES)
        except Exception as e:  # noqa: BLE001 — herdr trouble mid-way: text may be typed
            return {"ok": False, "error": f"message send failed mid-sequence — {e}"}
        if not composer_holds(typed_lines, text) or other_tui_screens.prompt_open(typed_lines):
            return {"ok": False, "error": "NOT SUBMITTED — the text is not (only) in the composer, "
                                          "so Enter was not pressed"}
        try:
            pane_io["send_keys"](raw_pane_id, "enter")
            sleep(after_enter_sec)
            after = pane_io["read_pane"](raw_pane_id, READ_LINES)
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "error": f"message send failed mid-sequence — {e}"}
        if composer_holds(after, text):
            return {"ok": False, "error": "NOT SUBMITTED — the text is stuck in the composer"}
        return _sent(was_busy)

    return _guarded((CODEX, entry["sessionId"]), text, run)


def deliver(raw_pane_id, text, lines, was_busy, entry, pane_io):
    """The reply dict for a checked send (see `check`)."""
    if entry["tool"] == OPENCODE:
        return send_opencode(entry, text, was_busy)
    return send_codex(entry, raw_pane_id, text, lines, was_busy, pane_io)
