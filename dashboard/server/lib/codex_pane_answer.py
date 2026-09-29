#!/usr/bin/env python3
"""Answer an open Codex approval by keystroke into its herdr pane — the
fallback for a prompt no held hook owns (AgentBar was not connected when it
came up, so the hook let Codex draw its own prompt).

Keys measured live on codex 0.154 (2026-09-29, fixtures/panes/codex_permission.txt):
`y` = "Yes, proceed", `esc` = "No, and tell Codex what to do differently".
"Always allow" is never sent (its wording changes per command).

A key is sent ONLY when, read fresh from the pane just now:
  * the row's pane id is the one Codex's own hook reported for this session,
    and herdr still lists that pane;
  * `other_tui_screens.prompt_open` says a permission prompt is open;
  * the screen shows the exact command the hook reported (the whole command,
    or its first 120 chars when it was clipped).
Anything else is refused with the reason ("answered elsewhere" when the
prompt is simply gone). Then the screen is read again to confirm it closed.
`read_pane` / `send_keys` / `list_panes` are injected (the server supplies
herdr-backed ones; tests a fake pane).
"""
import time

import other_tui_screens

KEY_BY_BEHAVIOR = {"allow": "y", "deny": "esc"}
READ_LINES = 60
SETTLE_SEC = 1.5
CLIP = 120


class PaneRefused(Exception):
    def __init__(self, text, status=409):
        super().__init__(text)
        self.text, self.status = text, status


def command_visible(screen_lines, command):
    """The command the hook reported is on screen after a `$ ` prompt marker."""
    wanted = " ".join((command or "").split())
    if not wanted:
        return False
    wanted = wanted[:CLIP]
    return any(wanted in " ".join(line.split()) for line in screen_lines)


def answer(entry, body, *, read_pane, send_keys, list_panes, settle_sec=SETTLE_SEC,
           sleep=time.sleep):
    """(payload, http status) for `entry`: a fresh Codex status entry copy."""
    try:
        key = _key_for(body)
        pane_id = entry.get("paneId")
        if not pane_id:
            raise PaneRefused("Codex's pane is unknown (it did not run inside herdr).", 400)
        wanted_pane = body.get("paneId")
        if wanted_pane is not None and wanted_pane != pane_id:
            raise PaneRefused("That row's pane is not the one this Codex session runs in.", 400)
        if pane_id not in list_panes():
            raise PaneRefused("Codex's pane is gone.")
        screen = read_pane(pane_id, READ_LINES)
        if other_tui_screens.prompt_open(screen) != other_tui_screens.PROMPT_PERMISSION:
            raise PaneRefused("This prompt was already answered in Codex (nothing is open on the pane).")
        if not command_visible(screen, entry.get("detail")):
            raise PaneRefused("The prompt on the pane is not the one AgentBar showed; answer it in Codex.")
        send_keys(pane_id, key)
        sleep(settle_sec)
        if other_tui_screens.prompt_open(read_pane(pane_id, READ_LINES)) == other_tui_screens.PROMPT_PERMISSION:
            raise PaneRefused("The key did not land; the prompt is still open. Answer it in Codex.", 502)
        return {"ok": True, "state": "answered"}, 200
    except PaneRefused as e:
        return {"ok": False, "error": e.text}, e.status
    except Exception as e:  # noqa: BLE001 — herdr trouble: report, never crash the handler
        return {"ok": False, "error": f"could not reach the Codex pane: {e}"}, 502


def _key_for(body):
    if not isinstance(body, dict):
        raise PaneRefused("body must be a JSON object", 400)
    key = KEY_BY_BEHAVIOR.get(body.get("behavior"))
    if key is None:
        raise PaneRefused("behavior must be 'allow' or 'deny'", 400)
    if body.get("suggestionIndex") is not None:
        raise PaneRefused("'Always allow' is not offered for a prompt answered by keystroke", 400)
    return key
