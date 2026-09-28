#!/usr/bin/env python3
"""Direct-run tests for starting a persona from the remote (tailscale)
listener: the `remoteStart` registry flag (personas.py), its Settings edit
(persona_registry_edit.py), `persona_remote.py`, and the server routes.

SAFETY: temp registry + fake home; `persona_start.start_persona` is
replaced by a recorder, so herdr/claude never run. No server is bound
(FakeHandler); the real-socket path is in test_remote_listener_integration.py.
"""
import importlib.util
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DASHBOARD_ROOT = os.path.dirname(HERE)

FAKE_HOME = tempfile.mkdtemp(prefix="persona-remote-test-home-")
os.environ["HOME"] = FAKE_HOME
REGISTRY_FILE = os.path.join(FAKE_HOME, "personas.json")
os.environ["AGENTBAR_PERSONAS_FILE"] = REGISTRY_FILE
os.environ["AGENT_TREE_FILE"] = os.path.join(FAKE_HOME, "agent-tree.json")
os.environ["CHIEF_DASHBOARD_CONFIG_HOME"] = os.path.join(FAKE_HOME, "config")
os.environ["CHIEF_DASHBOARD_STATE_HOME"] = os.path.join(FAKE_HOME, "state")
os.environ["CHIEF_DASHBOARD_MACHINES"] = "{}"
os.environ["CHIEF_HERDR_BIN"] = os.path.join(FAKE_HOME, "no-such-herdr")
os.environ["CLAUDE_PROJECTS_DIR"] = os.path.join(FAKE_HOME, "claude-projects")

sys.path.insert(0, os.path.join(DASHBOARD_ROOT, "server", "lib"))
import personas  # noqa: E402
import persona_start  # noqa: E402
import persona_remote  # noqa: E402
import persona_registry_edit  # noqa: E402

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def folder(name):
    path = os.path.join(FAKE_HOME, "personas", name)
    os.makedirs(path, exist_ok=True)
    return path


PHONE_DIR, DESK_DIR, HIDDEN_DIR = folder("phone-ok"), folder("desk-only"), folder("hidden-phone")


def entry(name, **extra):
    return {"name": name, "description": f"{name} does test things.", **extra}


def write_registry(personas_map, hidden=()):
    with open(REGISTRY_FILE, "w") as f:
        json.dump({"personas": personas_map, "hidden": list(hidden)}, f)
    return personas.load_registry(REGISTRY_FILE)


REG = write_registry({
    f"local:{PHONE_DIR}": entry("phone-ok", remoteStart=True),
    f"local:{DESK_DIR}": entry("desk-only"),
    f"local:{HIDDEN_DIR}": entry("hidden-phone", remoteStart=True),
    "local:~/draft": {"name": "draft-phone", "description": "", "remoteStart": True},
    "local:~/bad-flag": entry("bad-flag", remoteStart="yes"),
}, hidden=[f"local:{HIDDEN_DIR}"])

print("== registry: remoteStart parsing ==")
by_name = {p["name"]: p for p in REG["personas"].values()}
check("remoteStart true is kept", by_name["phone-ok"]["remoteStart"], True)
check("absent remoteStart defaults to false", by_name["desk-only"]["remoteStart"], False)
check("a non-bool remoteStart skips the entry", "bad-flag" in by_name, False)

print("\n== remote GET /api/personas payload ==")
STATE_ROWS = [  # what personas.get_personas_state() returns locally
    {"name": "phone-ok", "address": f"local:{PHONE_DIR}", "description": "phone-ok does test things.",
     "routesWhen": ["x"], "notFor": [], "idle": "fresh", "start": "in-place", "offline": False,
     "mainRowId": "row-1", "sessionRowIds": ["row-1", "row-2"], "idleStart": "fresh"},
    {"name": "desk-only", "address": f"local:{DESK_DIR}", "description": "desk-only does test things.",
     "routesWhen": [], "notFor": [], "idle": "resume", "start": "in-place", "offline": False,
     "mainRowId": None, "sessionRowIds": [], "idleStart": "resume"},
]
listed = persona_remote.remote_personas(REG, personas_state=STATE_ROWS)
check("every offered persona is listed (messaging needs them all)",
      [p["name"] for p in listed], ["phone-ok", "desk-only"])
check("remoteStart marks the startable ones", [p["remoteStart"] for p in listed], [True, False])
check("only the phone's fields", sorted(listed[0]),
      ["description", "idleStart", "mainRowId", "name", "offline", "remoteStart"])
check("mainRowId carried", listed[0]["mainRowId"], "row-1")
check("no folder path leaks", FAKE_HOME in json.dumps(listed), False)
check("no personas -> []", persona_remote.remote_personas(REG, personas_state=[]), [])

print("\n== remote start: opt-in gate ==")
calls = []
_real_start = persona_start.start_persona
persona_start.start_persona = lambda body, deps=None: calls.append((body, deps.registry)) or {"ok": True}
try:
    def remote_start(body):
        calls.clear()
        return persona_remote.start_persona_remote(body, persona_start.StartDeps(registry=REG))

    for name in ("desk-only", "hidden-phone", "draft-phone", "no-such-persona", " phone-ok"):
        result = remote_start({"persona": name, "text": "hi", "confirm": True})
        check(f"{name!r}: refused as unknown", (result["ok"], "unknown persona" in result["error"]),
              (False, True))
        check(f"{name!r}: start never called", calls, [])
    for label, body, needle in (
            ("no confirm", {"persona": "phone-ok", "text": "hi"}, "confirm"),
            ("confirm false", {"persona": "phone-ok", "text": "hi", "confirm": False}, "confirm"),
            ("confirm truthy non-bool", {"persona": "phone-ok", "text": "hi", "confirm": 1}, "confirm"),
            ("extra folder", {"persona": "phone-ok", "text": "hi", "confirm": True,
                              "folder": "/tmp"}, "unexpected field"),
            ("extra args", {"persona": "phone-ok", "text": "hi", "confirm": True,
                            "args": ["--dangerously-skip-permissions"]}, "unexpected field"),
            ("not an object", ["phone-ok"], "JSON object")):
        result = remote_start(body)
        check(f"{label}: refused", (result["ok"], needle in result["error"]), (False, True))
        check(f"{label}: start never called", calls, [])
    result = remote_start({"persona": "phone-ok", "text": "hi $(echo INJECTED)", "fresh": True,
                           "confirm": True})
    check("opted-in persona: handed to start_persona", result, {"ok": True})
    check("same body passed through, minus confirm", calls[0][0],
          {"persona": "phone-ok", "text": "hi $(echo INJECTED)", "fresh": True})
    check("start uses the same registry snapshot", calls[0][1], REG)
    result = remote_start({"text": "hi", "confirm": True})
    check("missing name falls through to the shared validation", len(calls), 1)
finally:
    persona_start.start_persona = _real_start

result = persona_remote.start_persona_remote({"persona": "phone-ok", "text": "a\nb", "confirm": True},
                                             persona_start.StartDeps(registry=REG))
check("the shared message rules still apply", (result["ok"], "newline" in result["error"]),
      (False, True))

print("\n== Settings edit: remoteStart is editable, bool only ==")
write_registry({f"local:{DESK_DIR}": entry("desk-only")})
result = persona_registry_edit.apply_registry_action(
    {"action": "edit", "persona": "desk-only", "fields": {"remoteStart": True}})
check("edit remoteStart: ok", result["ok"], True)
check("registry view shows it", result["registry"]["personas"][0]["remoteStart"], True)
with open(REGISTRY_FILE) as f:
    check("saved to personas.json", json.load(f)["personas"][f"local:{DESK_DIR}"]["remoteStart"], True)
result = persona_registry_edit.apply_registry_action(
    {"action": "edit", "persona": "desk-only", "fields": {"remoteStart": "true"}})
check("non-bool refused", result["ok"], False)

print("\n== server routes ==")
_spec = importlib.util.spec_from_file_location(
    "chief_dashboard_server_persona_remote_test",
    os.path.join(DASHBOARD_ROOT, "server", "chief-dashboard-server.py"))
_srv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_srv)


class FakeServer:
    def __init__(self, remote):
        self.remote_listener = remote


class FakeRfile:
    def __init__(self, raw):
        self.raw = raw

    def read(self, n):
        return self.raw[:n]


class FakeHandler(_srv.Handler):
    def __init__(self, headers, body=b"", remote=False, path="/"):  # noqa: no socket
        self.headers = dict(headers, **{"Content-Length": str(len(body))})
        self.rfile = FakeRfile(body)
        self.server = FakeServer(remote)
        self.path = path
        self.sent = None

    def _send_json(self, obj, status=200):
        self.sent = (obj, status)


local_calls, remote_calls = [], []
local_fn = lambda b: local_calls.append(b) or {"ok": True, "via": "local"}  # noqa: E731
remote_fn = lambda b: remote_calls.append(b) or {"ok": True, "via": "remote"}  # noqa: E731
body = json.dumps({"persona": "phone-ok", "text": "hi"}).encode()

h = FakeHandler({"Content-Type": "application/json"}, body, remote=True)
h._handle_local_json_post("/api/persona/start", local_fn, remote_fn)
check("remote listener + remote handler: remote handler answers", h.sent, ({"ok": True, "via": "remote"}, 200))
check("local handler not called remotely", local_calls, [])
h = FakeHandler({"Content-Type": "text/plain"}, body, remote=True)
remote_calls.clear()
h._handle_local_json_post("/api/persona/start", local_fn, remote_fn)
check("remote: JSON gate still applies (400, never called)", (h.sent[1], remote_calls), (400, []))
h = FakeHandler({"Content-Type": "application/json"}, body, remote=False)
h._handle_local_json_post("/api/persona/start", local_fn, remote_fn)
check("localhost: local handler answers (unchanged)", h.sent, ({"ok": True, "via": "local"}, 200))
h = FakeHandler({"Content-Type": "application/json"}, body, remote=True)
h._handle_local_json_post("/api/personas", local_fn)
check("registry edit stays localhost-only", h.sent[1], 403)

write_registry({f"local:{PHONE_DIR}": entry("phone-ok", remoteStart=True),
                f"local:{DESK_DIR}": entry("desk-only")})
_real_rows = persona_start.StartDeps.live_agent_rows
_real_state = _srv.personas.get_personas_state
persona_start.StartDeps.live_agent_rows = lambda self: []
_srv.personas.get_personas_state = lambda: [{"name": "local-view", "address": "local:/x"}]
try:
    h = FakeHandler({}, remote=True, path="/api/personas")
    h.do_GET()
    check("remote GET /api/personas: unauthenticated -> 401", h.sent[1], 401)
    h = FakeHandler({}, remote=True, path="/api/personas")
    h._remote_authenticated = lambda: True
    h.do_GET()
    check("remote GET /api/personas -> remote list", h.sent,
          ([{"name": "local-view", "description": None, "idleStart": None, "offline": None,
             "mainRowId": None, "remoteStart": False}], 200))
    h = FakeHandler({}, remote=False, path="/api/personas")
    h.do_GET()
    check("local GET /api/personas unchanged", h.sent[0][0]["name"], "local-view")
finally:
    persona_start.StartDeps.live_agent_rows = _real_rows
    _srv.personas.get_personas_state = _real_state

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("All persona remote start checks passed.")
