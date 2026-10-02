"""Personas on the remote (tailscale) listener: list + start.

The phone messages a persona's running main session through the normal
`POST /api/session/message` rules, and may START any persona the
registry offers (`personas.offered_personas`: registered, not hidden, has
a saved description) — no per-persona opt-in (user decision 2026-09-28).
The registry itself stays editable only on localhost. The remote listener has
already required auth and refused a foreign Origin
(`Handler._reject_foreign_write`), and the server applies the JSON
Content-Type gate before calling in here.

- `remote_personas()` — `GET /api/personas` on the remote listener:
  `[{name, description, idleStart, offline, mainRowId, runsOn, machines}]`
  for every OFFERED persona (`machines` trimmed to `[{id, label}]` — the
  phone's start chips). No address/folder/instructions/routing hints:
  paths never leave this Mac. `mainRowId` is a row id the phone already
  sees in `/api/state`.
- `start_persona_remote(body)` — `POST /api/persona/start` there. Stricter
  than localhost: only `persona`/`text`/`fresh`/`machine`/`confirm` keys (no
  free-form folder/command/args — the registry decides those), `confirm`
  must be `true` (the phone's explicit second press). Then hands off to
  `persona_start.start_persona`, which refuses any name that isn't offered
  ("unknown persona", same wording for hidden/undescribed/unregistered),
  and strips folder/home paths from any refusal before the phone sees it."""
import os

import persona_start
import personas

REMOTE_START_KEYS = {"persona", "text", "fresh", "machine", "confirm"}
REMOTE_ROW_KEYS = ("name", "description", "idleStart", "offline", "mainRowId", "runsOn")


def remote_personas(personas_state=None):
    """The phone's persona list: the local `/api/personas` rows, trimmed."""
    rows = personas_state if personas_state is not None else personas.get_personas_state()
    return [dict({k: row.get(k) for k in REMOTE_ROW_KEYS},
                 machines=[{"id": m.get("id"), "label": m.get("label")}
                           for m in row.get("machines") or [] if isinstance(m, dict)])
            for row in rows]


def start_persona_remote(body, deps=None):
    """Same reply contract as `persona_start.start_persona`."""
    if not isinstance(body, dict):
        return {"ok": False, "error": "body must be a JSON object"}
    extra = sorted(set(body) - REMOTE_START_KEYS)
    if extra:
        return {"ok": False, "error": f"unexpected field(s) from the phone: {', '.join(extra)}"}
    if body.get("confirm") is not True:
        return {"ok": False, "error": "confirm the start first (confirm: true)"}
    deps = deps or persona_start.StartDeps()
    registry = deps.load_registry()
    deps.registry = registry  # the path scrub below matches what start used
    start_body = {k: v for k, v in body.items() if k != "confirm"}
    result = persona_start.start_persona(start_body, deps)
    if isinstance(result.get("error"), str):
        result = dict(result, error=_without_paths(result["error"], registry))
    return result


def _without_paths(text, registry):
    """A refusal as the phone may see it: no persona folder, no home path."""
    for persona in registry.get("personas", {}).values():
        for path in (persona.get("resolvedFolder"), persona.get("folder")):
            if path:
                text = text.replace(path, "its folder")
    home = os.path.expanduser("~")
    return text.replace(home + os.sep, "~" + os.sep)
