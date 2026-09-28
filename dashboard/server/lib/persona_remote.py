"""Personas on the remote (tailscale) listener: list + opt-in start.

The phone messages a persona's running main session through the normal
`POST /api/session/message` rules, and may START one only when its
registry entry has `"remoteStart": true` (default false; editable through
`POST /api/personas`'s `edit`, localhost only). The remote listener has
already required auth and refused a foreign Origin
(`Handler._reject_foreign_write`), and the server applies the JSON
Content-Type gate before calling in here.

- `remote_personas()` — `GET /api/personas` on the remote listener:
  `[{name, description, idleStart, offline, mainRowId, remoteStart}]` for
  every OFFERED persona. No address/folder/instructions/routing hints:
  paths never leave this Mac. `mainRowId` is a row id the phone already
  sees in `/api/state`.
- `start_persona_remote(body)` — `POST /api/persona/start` there. Stricter
  than localhost: only `persona`/`text`/`fresh`/`confirm` keys (no
  free-form folder/command/args — the registry decides those), `confirm`
  must be `true` (the phone's explicit second press), and any persona not
  opted in gets the same wording as an unknown name, so the phone can't
  probe which names exist. Then hands the SAME registry snapshot to
  `persona_start.start_persona` (no re-read between check and start)."""
import persona_start
import personas

REMOTE_START_KEYS = {"persona", "text", "fresh", "confirm"}
REMOTE_ROW_KEYS = ("name", "description", "idleStart", "offline", "mainRowId")


def _remote_startable(registry):
    """{address: persona} offered AND opted in to remote start."""
    return {addr: p for addr, p in personas.offered_personas(registry).items()
            if p.get("remoteStart") is True}


def remote_personas(registry=None, personas_state=None):
    """The phone's persona list: the local `/api/personas` rows, trimmed."""
    registry = registry if registry is not None else personas.load_registry()
    rows = personas_state if personas_state is not None else personas.get_personas_state()
    startable = {p["name"] for p in _remote_startable(registry).values()}
    return [dict({k: row.get(k) for k in REMOTE_ROW_KEYS},
                 remoteStart=row.get("name") in startable)
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
    name = body.get("persona")
    if isinstance(name, str) and name.strip():
        names = {p["name"] for p in _remote_startable(registry).values()}
        if name not in names:
            return {"ok": False, "error": f"unknown persona {name!r}"}
    deps.registry = registry  # pin the snapshot the check above used
    start_body = {k: v for k, v in body.items() if k != "confirm"}
    return persona_start.start_persona(start_body, deps)
