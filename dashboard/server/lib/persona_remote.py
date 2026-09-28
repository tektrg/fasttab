"""Persona start from the remote (tailscale) listener — opt-in per persona.

A persona is startable from the phone only when its registry entry has
`"remoteStart": true` (default false; editable through `POST
/api/personas`'s `edit`, localhost only). Everything else stays as
`persona_start` does it: the remote listener has already required auth
and refused a foreign Origin (`Handler._reject_foreign_write`), and the
server applies the JSON Content-Type gate before calling in here.

- `remote_personas()` — `GET /api/personas` on the remote listener:
  `[{name, description, idleStart}]` for offered `remoteStart` personas
  only. No address/folder/instructions: paths never leave this Mac.
- `start_persona_remote(body)` — `POST /api/persona/start` there: refuses
  any persona not opted in (same wording as an unknown name, so the phone
  can't probe which names exist), then hands the SAME registry snapshot to
  `persona_start.start_persona` (no re-read between the check and the
  start)."""
import persona_start
import personas


def _remote_startable(registry):
    """{address: persona} offered AND opted in to remote start."""
    return {addr: p for addr, p in personas.offered_personas(registry).items()
            if p.get("remoteStart") is True}


def remote_personas(registry=None, agent_rows=None):
    registry = registry if registry is not None else personas.load_registry()
    startable = _remote_startable(registry)
    if not startable:
        return []
    if agent_rows is None:
        agent_rows = persona_start.StartDeps().live_agent_rows()
    live_ids = {}
    result = []
    for persona in startable.values():
        machine = persona["machine"]
        if machine not in live_ids:
            live_ids[machine] = persona_start.live_session_ids_for_machine(agent_rows, machine)
        result.append({
            "name": persona["name"],
            "description": persona["description"],
            "idleStart": persona_start.idle_start_for(persona, live_ids[machine]),
        })
    return result


def start_persona_remote(body, deps=None):
    """Same reply contract as `persona_start.start_persona`."""
    deps = deps or persona_start.StartDeps()
    registry = deps.load_registry()
    name = body.get("persona") if isinstance(body, dict) else None
    if isinstance(name, str) and name.strip():
        names = {p["name"] for p in _remote_startable(registry).values()}
        if name not in names:
            return {"ok": False, "error": f"unknown persona {name!r}"}
    deps.registry = registry  # pin the snapshot the check above used
    return persona_start.start_persona(body, deps)
