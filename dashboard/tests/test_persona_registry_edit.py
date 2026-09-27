#!/usr/bin/env python3
"""Direct-run tests for Jev persona routing P4: GET /api/personas/suggestions
(persona_suggestions.py), GET /api/personas/registry + POST /api/personas
(persona_registry_edit.py), and the server's localhost/JSON gates.

SAFETY: HOME, the registry file and the Claude projects dir all live in a
fresh temp dir; the real ~/.config/agentbar/personas.json is never read or
written, no server is started, nothing is POSTed anywhere. The only hostile
input is the inert sentinel `$(echo INJECTED)`."""
import importlib.util
import json
import os
import stat
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DASHBOARD_ROOT = os.path.dirname(HERE)

FAKE_HOME = os.path.realpath(tempfile.mkdtemp(prefix="persona-registry-edit-home-"))
os.environ["HOME"] = FAKE_HOME
os.environ["AGENT_TREE_FILE"] = os.path.join(FAKE_HOME, "agent-tree.json")
REGISTRY_FILE = os.path.join(FAKE_HOME, ".config", "agentbar", "personas.json")
os.environ["AGENTBAR_PERSONAS_FILE"] = REGISTRY_FILE
PROJECTS_DIR = os.path.join(FAKE_HOME, ".claude", "projects")
os.environ["CLAUDE_PROJECTS_DIR"] = PROJECTS_DIR
os.environ.setdefault("CHIEF_DASHBOARD_MACHINES", "{}")

sys.path.insert(0, os.path.join(DASHBOARD_ROOT, "server", "lib"))
import persona_registry_edit as edit  # noqa: E402
import persona_suggestions as sugg  # noqa: E402
import personas  # noqa: E402

SENTINEL = "$(echo INJECTED)"
fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def home(*parts):
    return os.path.join(FAKE_HOME, *parts)


def make_repo(rel, agents_md=None, claude_md=None):
    path = home(rel)
    os.makedirs(os.path.join(path, ".git"), exist_ok=True)
    if agents_md is not None:
        with open(os.path.join(path, "AGENTS.md"), "w") as f:
            f.write(agents_md)
    if claude_md is not None:
        with open(os.path.join(path, "CLAUDE.md"), "w") as f:
            f.write(claude_md)
    return path


def make_worktree(main_repo, name):
    path = os.path.join(main_repo, ".claude", "worktrees", name)
    os.makedirs(os.path.join(main_repo, ".git", "worktrees", name), exist_ok=True)
    os.makedirs(path, exist_ok=True)
    with open(os.path.join(path, ".git"), "w") as f:
        f.write(f"gitdir: {main_repo}/.git/worktrees/{name}\n")
    return path


_transcript_counter = [0]


def transcript(cwd, age_days=0.0):
    _transcript_counter[0] += 1
    folder = os.path.join(PROJECTS_DIR, f"proj-{_transcript_counter[0] % 3}")
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, f"session-{_transcript_counter[0]}.jsonl")
    with open(path, "w") as f:
        f.write(json.dumps({"type": "summary"}) + "\n")
        f.write(json.dumps({"type": "user", "cwd": cwd}) + "\n")
    mtime = time.time() - age_days * 86400
    os.utime(path, (mtime, mtime))


def folder_snapshot(root):
    """Every file under `root` with its mtime + size — proof nothing wrote there."""
    snap = {}
    for dirpath, _, files in os.walk(root):
        for name in files:
            p = os.path.join(dirpath, name)
            st = os.stat(p)
            snap[p] = (st.st_mtime_ns, st.st_size)
    return snap


# ── fixture ──
app = make_repo("01_Project/app", agents_md=(
    "<!-- generated -->\n# App — the product\n\nShips the app to\nusers every week.\n\n## Build\nmore\n"))
tool = make_repo("01_Project/tool", claude_md="@~/shared.md\n\n# Tool\n\nCLI helpers.\n")
bare = make_repo("01_Project/bare")
adopted = make_repo("01_Project/adopted", agents_md="# Adopted\n\nAlready a persona.\n")
hidden_repo = make_repo("01_Project/hidden-one", agents_md="# Hidden\n\nhidden.\n")
old_repo = make_repo("01_Project/old", agents_md="# Old\n\nold.\n")
plain = home("notes")  # no git repo at all
os.makedirs(plain)
scratch = home("work", "scratchpad")
os.makedirs(scratch)
wt = make_worktree(app, "feature-x")
os.makedirs(os.path.join(app, "sub", "deep"))

transcript(app, 1)
transcript(os.path.join(app, "sub", "deep"), 2)
transcript(wt, 0.5)
transcript(tool, 3)
transcript(bare, 4)
transcript(adopted, 1)
transcript(hidden_repo, 1)
transcript(old_repo, 40)
transcript(plain, 5)
transcript(scratch, 1)
transcript("/private/tmp/some-run", 1)
transcript(FAKE_HOME, 1)
transcript(home("gone-folder"), 1)

os.makedirs(os.path.dirname(REGISTRY_FILE))
with open(REGISTRY_FILE, "w") as f:
    json.dump({"personas": {"local:~/01_Project/adopted": {
        "name": "adopted", "description": "Adopted repo.", "start": "script",
        "startScript": "scripts/launch.sh", "futureField": {"kept": True}}},
        "hidden": ["local:~/01_Project/hidden-one"]}, f)

project_snapshot = folder_snapshot(home("01_Project"))

print("== suggestions ==")
rows = sugg.get_suggestions()
by_address = {r["address"]: r for r in rows}
check("only the expected folders", sorted(by_address),
      sorted(["local:~/01_Project/app", "local:~/01_Project/tool",
              "local:~/01_Project/bare", "local:~/notes"]))
app_row = by_address.get("local:~/01_Project/app", {})
check("worktree + subfolder fold into the main repo (3 sessions)", app_row.get("sessionCount"), 3)
check("most recent first", rows[0]["address"], "local:~/01_Project/app")
check("lastActive = newest transcript (worktree, 0.5d)",
      abs(app_row.get("lastActive", 0) - (time.time() - 0.5 * 86400)) < 60, True)
check("draft: heading + first paragraph, comment skipped",
      app_row.get("draftDescription"), "App — the product — Ships the app to users every week.")
check("draft: CLAUDE.md fallback, @import skipped",
      by_address.get("local:~/01_Project/tool", {}).get("draftDescription"), "Tool — CLI helpers.")
check("draft: no instructions file -> empty",
      by_address.get("local:~/01_Project/bare", {}).get("draftDescription"), "")
check("folder in no repo stays itself", "local:~/notes" in by_address, True)
check("heading parser caps length",
      len(sugg._heading_and_first_paragraph("# T\n\n" + "x " * 1000)) <= 600, True)

print("\n== registry view ==")
view = edit.registry_view()
check("lists personas incl. start mode", [(p["name"], p["start"]) for p in view["personas"]],
      [("adopted", "script")])
check("hidden-only addresses listed separately", view["hiddenSuggestions"],
      ["local:~/01_Project/hidden-one"])
check("default global instructions exposed",
      view["globalInstructions"] == view["defaultGlobalInstructions"], True)

print("\n== adopt ==")
r = edit.apply_registry_action({"action": "adopt", "address": "local:~/01_Project/app",
                                "persona": {"name": "app-dev", "description": ""}})
check("adopt ok", r.get("ok"), True)
app_entry = next(p for p in r["registry"]["personas"] if p["name"] == "app-dev")
check("adopted with empty description is not offered", app_entry["offered"], False)
check("adopt defaults", (app_entry["idle"], app_entry["resumeWithinDays"], app_entry["start"]),
      ("resume", 3, "in-place"))
check("adopted folder no longer suggested",
      "local:~/01_Project/app" in {s["address"] for s in sugg.get_suggestions()}, False)
check("adopt refuses a non-suggestion path",
      edit.apply_registry_action({"action": "adopt", "address": "local:" + home("01_Project", "old"),
                                  "persona": {"name": "old"}}).get("ok"), False)
check("adopt refuses a sentinel address",
      edit.apply_registry_action({"action": "adopt", "address": SENTINEL,
                                  "persona": {"name": "x"}}).get("ok"), False)
check("adopt refuses a sentinel name",
      edit.apply_registry_action({"action": "adopt", "address": "local:~/01_Project/tool",
                                  "persona": {"name": SENTINEL}}).get("ok"), False)
check("adopt refuses a duplicate name",
      edit.apply_registry_action({"action": "adopt", "address": "local:~/01_Project/tool",
                                  "persona": {"name": "adopted"}}).get("ok"), False)
check("adopt refuses start/startScript fields",
      edit.apply_registry_action({"action": "adopt", "address": "local:~/01_Project/tool",
                                  "persona": {"name": "tool", "startScript": "x"}}).get("ok"), False)

print("\n== edit ==")
r = edit.apply_registry_action({"action": "edit", "persona": "app-dev", "fields": {
    "description": "  App product work.  ", "routesWhen": ["app bugs", "  ", "releases"],
    "notFor": ["tooling"], "extraInstructions": "Line 1\n\tLine 2", "idle": "fresh",
    "resumeWithinDays": 7}})
check("edit ok", r.get("ok"), True)
app_entry = next(p for p in r["registry"]["personas"] if p["name"] == "app-dev")
check("described persona is now offered", app_entry["offered"], True)
check("fields trimmed, blank list lines dropped",
      (app_entry["description"], app_entry["routesWhen"]), ("App product work.", ["app bugs", "releases"]))
check("multiline instructions kept", app_entry["extraInstructions"], "Line 1\n\tLine 2")
check("offered via /api/personas' filter too",
      "local:~/01_Project/app" in personas.offered_personas(personas.load_registry()), True)
for label, fields in [("bad idle", {"idle": "sometimes"}), ("NaN days", {"resumeWithinDays": float("nan")}),
                      ("bool days", {"resumeWithinDays": True}), ("negative days", {"resumeWithinDays": -1}),
                      ("control char", {"description": "a\x1bb"}), ("newline in list", {"notFor": ["a\nb"]}),
                      ("long description", {"description": "x" * 1001}), ("read-only start", {"start": "script"}),
                      ("empty name", {"name": " "})]:
    check(f"edit refuses {label}",
          edit.apply_registry_action({"action": "edit", "persona": "app-dev", "fields": fields}).get("ok"), False)
check("edit by address works",
      edit.apply_registry_action({"action": "edit", "persona": "local:~/01_Project/app",
                                  "fields": {"name": "app"}}).get("ok"), True)
check("edit refuses an unknown persona",
      edit.apply_registry_action({"action": "edit", "persona": "nope", "fields": {}}).get("ok"), False)
check("edit refuses renaming onto another persona",
      edit.apply_registry_action({"action": "edit", "persona": "app", "fields": {"name": "adopted"}}).get("ok"),
      False)
raw_adopted = json.load(open(REGISTRY_FILE))["personas"]["local:~/01_Project/adopted"]
check("unknown + script fields kept verbatim",
      (raw_adopted.get("startScript"), raw_adopted.get("futureField")), ("scripts/launch.sh", {"kept": True}))

print("\n== hide / unhide / remove ==")
check("hide a suggestion", edit.apply_registry_action({"action": "hide", "address": "local:~/notes"}).get("ok"), True)
check("hidden suggestion gone", "local:~/notes" in {s["address"] for s in sugg.get_suggestions()}, False)
check("hide refuses an arbitrary path",
      edit.apply_registry_action({"action": "hide", "address": "local:" + home("elsewhere")}).get("ok"), False)
check("unhide", edit.apply_registry_action({"action": "unhide", "address": "local:~/notes"}).get("ok"), True)
check("unhidden suggestion is back", "local:~/notes" in {s["address"] for s in sugg.get_suggestions()}, True)
check("unhide refuses a non-hidden address",
      edit.apply_registry_action({"action": "unhide", "address": "local:~/notes"}).get("ok"), False)
check("hide a persona -> not offered",
      (edit.apply_registry_action({"action": "hide", "address": "local:~/01_Project/app"}).get("ok"),
       "local:~/01_Project/app" in personas.offered_personas(personas.load_registry())), (True, False))
r = edit.apply_registry_action({"action": "remove", "persona": "adopted"})
check("remove", (r.get("ok"), [p["name"] for p in r["registry"]["personas"]]), (True, ["app"]))
check("removed folder is suggested again",
      "local:~/01_Project/adopted" in {s["address"] for s in sugg.get_suggestions()}, True)

print("\n== global instructions ==")
r = edit.apply_registry_action({"action": "setGlobalInstructions", "text": "Be brief.\nAlways."})
check("set", r["registry"]["globalInstructions"], "Be brief.\nAlways.")
r = edit.apply_registry_action({"action": "setGlobalInstructions", "text": ""})
check("empty resets to default", r["registry"]["globalInstructions"], personas.DEFAULT_GLOBAL_INSTRUCTIONS)
check("reset drops the key from the file", "globalInstructions" in json.load(open(REGISTRY_FILE)), False)
check("non-text refused", edit.apply_registry_action({"action": "setGlobalInstructions", "text": 3}).get("ok"),
      False)

print("\n== requests + file safety ==")
check("unknown action refused", edit.apply_registry_action({"action": "rm"}).get("ok"), False)
check("non-object body refused", edit.apply_registry_action(["adopt"]).get("ok"), False)
check("registry file is 0600", stat.S_IMODE(os.stat(REGISTRY_FILE).st_mode), 0o600)
check("no temp files left", [n for n in os.listdir(os.path.dirname(REGISTRY_FILE)) if n.endswith(".tmp")], [])
check("sentinel never reached the registry", "INJECTED" in open(REGISTRY_FILE).read(), False)
check("no project folder was touched", folder_snapshot(home("01_Project")), project_snapshot)
with open(REGISTRY_FILE, "w") as f:
    f.write("{broken")
r = edit.apply_registry_action({"action": "setGlobalInstructions", "text": "x"})
check("malformed file: write refused", r.get("ok"), False)
check("malformed file: left as is", open(REGISTRY_FILE).read(), "{broken")

print("\n== server routes: localhost only, JSON only ==")
_spec = importlib.util.spec_from_file_location(
    "chief_dashboard_server_registry_edit_test",
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
    def __init__(self, path, headers=None, body=b"", remote=False):  # noqa: no socket
        self.path = path
        self.headers = dict(headers or {}, **{"Content-Length": str(len(body))})
        self.rfile = FakeRfile(body)
        self.server = FakeServer(remote)
        self.sent = None

    def _send_json(self, obj, status=200):
        self.sent = (obj, status)

    def _note_agentbar_seen(self):
        pass

    def _remote_authenticated(self):
        return True

    def _reject_foreign_write(self):
        return False


seen = []
_real_apply = _srv.persona_registry_edit.apply_registry_action
_srv.persona_registry_edit.apply_registry_action = lambda body: seen.append(body) or {"ok": True}
try:
    body = json.dumps({"action": "hide", "address": "local:~/notes"}).encode()
    h = FakeHandler("/api/personas", {"Content-Type": "application/json"}, body, remote=True)
    h.do_POST()
    check("POST remote: 403, never applied", (h.sent[1], seen), (403, []))
    h = FakeHandler("/api/personas", {"Content-Type": "text/plain"}, body)
    h.do_POST()
    check("POST wrong Content-Type: 400, never applied", (h.sent[1], seen), (400, []))
    h = FakeHandler("/api/personas", {"Content-Type": "application/json"}, body)
    h.do_POST()
    check("POST local JSON: applied", (h.sent, seen), (({"ok": True}, 200), [json.loads(body)]))
finally:
    _srv.persona_registry_edit.apply_registry_action = _real_apply
for route in ("/api/personas/suggestions", "/api/personas/registry"):
    h = FakeHandler(route, remote=True)
    h.do_GET()
    check(f"GET {route} remote: 403", h.sent[1], 403)
h = FakeHandler("/api/personas/suggestions")
h.do_GET()
check("GET suggestions local: a list", isinstance(h.sent[0], list), True)

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("All persona registry edit checks passed.")
