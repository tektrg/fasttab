#!/usr/bin/env python3
"""Direct-run tests for server/lib/personas.py's registry loading
(`load_registry` / `offered_personas`) — Jev persona routing P1. Fake
`~/.config/agentbar/personas.json` files only, never the real one; no
FEEDS/herdr involved (that's test_personas_api.py)."""
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib"))

# personas.py transitively imports chief_dashboard_feeds (machines config
# resolution) at module load — pin MACHINES to empty so this file's result
# never depends on whatever real ~/.config/agent-dashboard/config.json or
# legacy dashboard-machines.json happens to exist on the machine running it.
os.environ.setdefault("CHIEF_DASHBOARD_MACHINES", "{}")

import personas  # noqa: E402

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def write_registry(tmp_dir, obj_or_text):
    path = os.path.join(tmp_dir, "personas.json")
    with open(path, "w") as f:
        if isinstance(obj_or_text, str):
            f.write(obj_or_text)
        else:
            json.dump(obj_or_text, f)
    return path


def full_persona(**overrides):
    base = {
        "name": "chief-aptus",
        "description": "AptusFit product delivery front door.",
        "routesWhen": ["AptusFit product work"],
        "notFor": ["FastTab/AgentBar/dashboard code"],
        "extraInstructions": "",
        "idle": "resume",
        "resumeWithinDays": 3,
        "start": "in-place",
    }
    base.update(overrides)
    return base


print("== missing file -> empty registry, not an error ==")
with tempfile.TemporaryDirectory() as tmp:
    reg = personas.load_registry(os.path.join(tmp, "does-not-exist.json"))
    check("no personas", reg["personas"], {})
    check("no hidden", reg["hidden"], [])
    check("falls back to the brief's default global instructions",
          reg["globalInstructions"], personas.DEFAULT_GLOBAL_INSTRUCTIONS)

print("\n== malformed JSON -> empty registry, no crash ==")
with tempfile.TemporaryDirectory() as tmp:
    path = write_registry(tmp, "{not json")
    reg = personas.load_registry(path)
    check("no personas on a parse error", reg["personas"], {})

print("\n== top-level JSON is not an object -> empty registry, no crash ==")
with tempfile.TemporaryDirectory() as tmp:
    path = write_registry(tmp, "[1, 2, 3]")
    reg = personas.load_registry(path)
    check("no personas when top level is a list", reg["personas"], {})

print("\n== 'personas' value is not an object -> empty personas, no crash ==")
with tempfile.TemporaryDirectory() as tmp:
    path = write_registry(tmp, {"personas": "not-a-dict"})
    reg = personas.load_registry(path)
    check("no personas", reg["personas"], {})

print("\n== one invalid entry is skipped; the rest of the registry still loads ==")
with tempfile.TemporaryDirectory() as tmp:
    path = write_registry(tmp, {
        "personas": {
            "local:~/01_Project/AptusFit": full_persona(name="chief-aptus"),
            "local:~/broken-1": {"name": ""},                     # empty name
            "local:~/broken-2": full_persona(idle="sometimes"),   # bad enum
            "local:~/broken-3": full_persona(routesWhen="not-a-list"),
            "local:~/broken-4": full_persona(start="script"),     # no startScript
            "no-colon-address": full_persona(),                   # malformed address
            "local:~/broken-5": "not-an-object",
        },
    })
    reg = personas.load_registry(path)
    check("only the one valid entry survives",
          sorted(reg["personas"].keys()), ["local:~/01_Project/AptusFit"])

print("\n== a persona with no description is a VALID registry entry ... ==")
with tempfile.TemporaryDirectory() as tmp:
    path = write_registry(tmp, {
        "personas": {
            "local:~/01_Project/AptusFit": full_persona(description=""),
        },
    })
    reg = personas.load_registry(path)
    check("...still present in load_registry()",
          list(reg["personas"].keys()), ["local:~/01_Project/AptusFit"])
    check("...but never offered to Jev / /api/personas",
          personas.offered_personas(reg), {})

print("\n== 'hidden' excludes an otherwise-valid, described persona from offered ==")
with tempfile.TemporaryDirectory() as tmp:
    path = write_registry(tmp, {
        "personas": {
            "local:~/01_Project/AptusFit": full_persona(),
        },
        "hidden": ["local:~/01_Project/AptusFit"],
    })
    reg = personas.load_registry(path)
    check("still in the raw registry", "local:~/01_Project/AptusFit" in reg["personas"], True)
    check("not offered", personas.offered_personas(reg), {})

print("\n== a fully-valid entry normalizes exactly as configured ==")
with tempfile.TemporaryDirectory() as tmp:
    path = write_registry(tmp, {
        "personas": {
            "local:~/01_Project/AptusFit": full_persona(
                name="chief-aptus", description="AptusFit product delivery.",
                routesWhen=["AptusFit bugs", "AptusFit features"],
                notFor=["FastTab", "AgentBar"], idle="fresh",
                resumeWithinDays=7, start="in-place"),
        },
    })
    reg = personas.load_registry(path)
    p = reg["personas"]["local:~/01_Project/AptusFit"]
    check("name", p["name"], "chief-aptus")
    check("description", p["description"], "AptusFit product delivery.")
    check("routesWhen", p["routesWhen"], ["AptusFit bugs", "AptusFit features"])
    check("notFor", p["notFor"], ["FastTab", "AgentBar"])
    check("idle", p["idle"], "fresh")
    check("resumeWithinDays", p["resumeWithinDays"], 7)
    check("start", p["start"], "in-place")
    check("machine parsed from the address", p["machine"], "local")
    check("folder parsed from the address", p["folder"], "~/01_Project/AptusFit")
    check("offered (has a description)",
          list(personas.offered_personas(reg).keys()), ["local:~/01_Project/AptusFit"])

print("\n== start:script requires startScript; with one, it's valid ==")
with tempfile.TemporaryDirectory() as tmp:
    path = write_registry(tmp, {
        "personas": {
            "local:~/01_Project/AptusFit": full_persona(
                start="script", startScript="scripts/chief-register-pane.sh"),
        },
    })
    reg = personas.load_registry(path)
    check("loaded", list(reg["personas"].keys()), ["local:~/01_Project/AptusFit"])
    check("startScript carried through",
          reg["personas"]["local:~/01_Project/AptusFit"]["startScript"],
          "scripts/chief-register-pane.sh")

print("\n== custom globalInstructions is preserved; blank falls back to default ==")
with tempfile.TemporaryDirectory() as tmp:
    path = write_registry(tmp, {"globalInstructions": "Custom block.", "personas": {}})
    reg = personas.load_registry(path)
    check("custom text kept", reg["globalInstructions"], "Custom block.")

with tempfile.TemporaryDirectory() as tmp:
    path = write_registry(tmp, {"globalInstructions": "   ", "personas": {}})
    reg = personas.load_registry(path)
    check("blank falls back to the default",
          reg["globalInstructions"], personas.DEFAULT_GLOBAL_INSTRUCTIONS)

print("\n== registry_path() honors AGENTBAR_PERSONAS_FILE ==")
with tempfile.TemporaryDirectory() as tmp:
    fake_path = os.path.join(tmp, "custom-personas.json")
    os.environ["AGENTBAR_PERSONAS_FILE"] = fake_path
    try:
        check("registry_path() returns the override", personas.registry_path(), fake_path)
    finally:
        del os.environ["AGENTBAR_PERSONAS_FILE"]

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("All personas registry checks passed.")
