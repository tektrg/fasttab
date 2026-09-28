#!/usr/bin/env python3
"""The persona registry's one writer: `POST /api/personas` and its read
side `GET /api/personas/registry` (Jev persona routing P4 — AgentBar
Settings > Personas).

WHAT IT WRITES
--------------
Only `personas.registry_path()` (`~/.config/agentbar/personas.json`,
override `AGENTBAR_PERSONAS_FILE`). Never a project folder: a folder is only
ever an address string here. Writes are atomic (temp file in the same
directory, fsync, `os.replace`) and serialized by one lock, so a reader
(`personas.load_registry`) sees the old file or the new one, never half.

The raw JSON is edited, not the normalized view: fields this module doesn't
know (and `start`/`startScript`, which Settings never edits — a script is a
command line) are kept verbatim. A registry file that isn't valid JSON is
never overwritten: every write is refused until it's fixed by hand.

ACTIONS (`{"action": …}`)
-------------------------
| action | fields | effect |
|---|---|---|
| `adopt` | `address` (must be a current suggestion), `persona` fields | new persona |
| `edit` | `persona` (name or address), `fields` | merge validated fields |
| `hide` | `address` (a suggestion or a persona) | add to `hidden` |
| `unhide` | `address` (in `hidden`) | remove from `hidden` |
| `remove` | `persona` (name or address) | delete the registry entry |
| `setGlobalInstructions` | `text` ("" = back to the default) | |

Every reply is `{"ok": true, "registry": <GET /api/personas/registry>}`
or `{"ok": false, "error": "<plain English>"}`. A persona saved with an
empty description stays unoffered (`personas.offered_personas`).
"""
import json
import math
import os
import re
import tempfile
import threading

import persona_suggestions
import personas

EDITABLE_FIELDS = ("name", "description", "routesWhen", "notFor",
                   "extraInstructions", "idle", "resumeWithinDays")
_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,39}")
_MAX_DESCRIPTION = 1000
_MAX_LIST_ITEMS = 20
_MAX_LIST_ITEM = 200
_MAX_INSTRUCTIONS = 8000
_MAX_RESUME_DAYS = 365
_ANY_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")
_CONTROL_EXCEPT_NEWLINE_TAB_RE = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")

_write_lock = threading.Lock()


class RegistryEditError(Exception):
    """A refusal shown to the user verbatim."""


# ── Read side ──

def registry_view(registry=None):
    """GET /api/personas/registry: every persona (hidden and undescribed
    ones too — Settings edits them), plus whether each is offered to Jev."""
    registry = registry or personas.load_registry()
    offered = personas.offered_personas(registry)
    hidden = registry.get("hidden") or []
    persona_addresses = set(registry["personas"])
    return {
        "ok": True,
        "globalInstructions": registry["globalInstructions"],
        "defaultGlobalInstructions": personas.DEFAULT_GLOBAL_INSTRUCTIONS,
        "personas": [{
            "address": addr, "name": p["name"], "description": p["description"],
            "routesWhen": p["routesWhen"], "notFor": p["notFor"],
            "extraInstructions": p["extraInstructions"], "idle": p["idle"],
            "resumeWithinDays": p["resumeWithinDays"], "start": p["start"],
            "hidden": addr in hidden, "offered": addr in offered,
        } for addr, p in registry["personas"].items()],
        "hiddenSuggestions": [a for a in hidden if a not in persona_addresses],
    }


# ── Validation ──

def _text(value, label, max_len, allow_multiline):
    if not isinstance(value, str):
        raise RegistryEditError(f"{label} must be text.")
    value = value.replace("\t", " ") if not allow_multiline else value
    pattern = _CONTROL_EXCEPT_NEWLINE_TAB_RE if allow_multiline else _ANY_CONTROL_RE
    if pattern.search(value):
        raise RegistryEditError(f"{label} contains control characters.")
    value = value.strip()
    if len(value) > max_len:
        raise RegistryEditError(f"{label} is longer than {max_len} characters.")
    return value


def _text_list(value, label):
    if not isinstance(value, list) or not all(isinstance(x, str) for x in value):
        raise RegistryEditError(f"{label} must be a list of text lines.")
    items = [_text(x, label, _MAX_LIST_ITEM, allow_multiline=False) for x in value]
    items = [x for x in items if x]
    if len(items) > _MAX_LIST_ITEMS:
        raise RegistryEditError(f"{label} has more than {_MAX_LIST_ITEMS} lines.")
    return items


def _validate_field(field, value):
    if field == "name":
        name = _text(value, "Name", 40, allow_multiline=False)
        if not _NAME_RE.fullmatch(name):
            raise RegistryEditError(
                "Name must be 1-40 letters, digits, '.', '_' or '-', starting with a letter or digit.")
        return name
    if field == "description":
        return _text(value, "Description", _MAX_DESCRIPTION, allow_multiline=True)
    if field in ("routesWhen", "notFor"):
        return _text_list(value, "Routes here" if field == "routesWhen" else "Not for")
    if field == "extraInstructions":
        return _text(value, "Extra instructions", _MAX_INSTRUCTIONS, allow_multiline=True)
    if field == "idle":
        if value not in personas.VALID_IDLE:
            raise RegistryEditError("When idle must be 'resume' or 'fresh'.")
        return value
    if field == "resumeWithinDays":
        if isinstance(value, bool) or not isinstance(value, (int, float)) or \
                not math.isfinite(value) or not 0 <= value <= _MAX_RESUME_DAYS:
            raise RegistryEditError(f"Resume within days must be a number from 0 to {_MAX_RESUME_DAYS}.")
        return int(value) if float(value).is_integer() else value
    raise RegistryEditError(f"'{field}' can't be edited here.")


def _validated_fields(raw_fields, *, require_name):
    if not isinstance(raw_fields, dict):
        raise RegistryEditError("fields must be an object.")
    unknown = sorted(set(raw_fields) - set(EDITABLE_FIELDS))
    if unknown:
        raise RegistryEditError(f"Unknown or read-only field: {unknown[0]}.")
    fields = {k: _validate_field(k, v) for k, v in raw_fields.items()}
    if require_name and "name" not in fields:
        raise RegistryEditError("A persona needs a name.")
    return fields


# ── Raw file I/O ──

def _read_raw(path):
    if not os.path.exists(path):
        return {"personas": {}, "hidden": []}
    try:
        with open(path) as f:
            raw = json.load(f)
    except (OSError, ValueError) as e:
        raise RegistryEditError(
            f"personas.json can't be read ({e}). Fix or remove it by hand before editing here.")
    if not isinstance(raw, dict):
        raise RegistryEditError("personas.json isn't a JSON object. Fix it by hand before editing here.")
    if not isinstance(raw.get("personas", {}), dict) or not isinstance(raw.get("hidden", []), list):
        raise RegistryEditError("personas.json has an unexpected shape. Fix it by hand before editing here.")
    raw.setdefault("personas", {})
    raw.setdefault("hidden", [])
    return raw


def _write_raw_atomically(path, raw):
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, temp_path = tempfile.mkstemp(prefix=".personas-", suffix=".json.tmp", dir=directory)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(raw, f, indent=2, ensure_ascii=False)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(temp_path, 0o600)
        os.replace(temp_path, path)
    except BaseException:
        try:
            os.unlink(temp_path)
        except OSError:
            pass
        raise
    personas._last_good_by_path.pop(path, None)


# ── Lookups ──

def _find_address(raw, persona_ref):
    """A registry address from a persona name or address; never a path the
    registry doesn't already hold."""
    if not isinstance(persona_ref, str) or not persona_ref.strip():
        raise RegistryEditError("persona must be a persona name or address.")
    if persona_ref in raw["personas"]:
        return persona_ref
    matches = [a for a, p in raw["personas"].items()
               if isinstance(p, dict) and p.get("name") == persona_ref]
    if len(matches) == 1:
        return matches[0]
    if matches:
        raise RegistryEditError(f"Several personas are named {persona_ref}; use its address.")
    raise RegistryEditError(f"No persona named {persona_ref}.")


def _ensure_unique_name(raw, name, except_address=None):
    for addr, p in raw["personas"].items():
        if addr != except_address and isinstance(p, dict) and p.get("name") == name:
            raise RegistryEditError(f"Another persona is already named {name}.")


def _suggested_addresses():
    return {s["address"] for s in persona_suggestions.get_suggestions()}


# ── Actions ──

def _adopt(raw, body):
    address = body.get("address")
    if not isinstance(address, str) or address not in _suggested_addresses():
        raise RegistryEditError("That folder isn't a current suggestion. Refresh the list and try again.")
    fields = _validated_fields(body.get("persona") or {}, require_name=True)
    _ensure_unique_name(raw, fields["name"])
    entry = {"name": fields["name"], "description": "", "routesWhen": [], "notFor": [],
             "extraInstructions": "", "idle": "resume", "resumeWithinDays": 3,
             "start": "in-place"}
    entry.update(fields)
    raw["personas"][address] = entry


def _edit(raw, body):
    address = _find_address(raw, body.get("persona"))
    fields = _validated_fields(body.get("fields") or {}, require_name=False)
    if "name" in fields:
        _ensure_unique_name(raw, fields["name"], except_address=address)
    entry = raw["personas"][address]
    if not isinstance(entry, dict):
        raise RegistryEditError("That persona's entry is broken in personas.json. Fix it by hand.")
    entry.update(fields)


def _hide(raw, body):
    address = body.get("address")
    if not isinstance(address, str) or \
            (address not in raw["personas"] and address not in _suggested_addresses()):
        raise RegistryEditError("Only a suggestion or an existing persona can be hidden.")
    if address not in raw["hidden"]:
        raw["hidden"].append(address)


def _unhide(raw, body):
    address = body.get("address")
    if address not in raw["hidden"]:
        raise RegistryEditError("That address isn't hidden.")
    raw["hidden"] = [a for a in raw["hidden"] if a != address]


def _remove(raw, body):
    address = _find_address(raw, body.get("persona"))
    del raw["personas"][address]


def _set_global_instructions(raw, body):
    text = _text(body.get("text"), "Global instructions", _MAX_INSTRUCTIONS, allow_multiline=True)
    if text and text != personas.DEFAULT_GLOBAL_INSTRUCTIONS:
        raw["globalInstructions"] = text
    else:
        raw.pop("globalInstructions", None)  # the default follows future default changes


_ACTIONS = {"adopt": _adopt, "edit": _edit, "hide": _hide, "unhide": _unhide,
            "remove": _remove, "setGlobalInstructions": _set_global_instructions}


def apply_registry_action(body):
    """POST /api/personas. Always returns a reply dict (never raises for a
    refusal)."""
    if not isinstance(body, dict):
        return {"ok": False, "error": "The request must be a JSON object."}
    handler = _ACTIONS.get(body.get("action"))
    if handler is None:
        return {"ok": False, "error": f"Unknown action. Use one of: {', '.join(_ACTIONS)}."}
    path = personas.registry_path()
    try:
        with _write_lock:
            raw = _read_raw(path)
            handler(raw, body)
            _write_raw_atomically(path, raw)
    except RegistryEditError as e:
        return {"ok": False, "error": str(e)}
    except OSError as e:
        return {"ok": False, "error": f"Couldn't save personas.json: {e.strerror or e}"}
    return {"ok": True, "registry": registry_view()}
