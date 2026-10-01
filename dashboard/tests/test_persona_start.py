#!/usr/bin/env python3
"""Direct-run tests for POST /api/persona/start (server/lib/persona_start.py
+ the server's `_handle_local_json_post`) — Jev persona routing P3.

SAFETY: everything outside the module is faked — the registry (a temp
file), herdr (`FakeHerdr` records calls, never runs anything), the home
dir, `~/.claude/projects`, the instructions dir, the live agent roster
and the clock. No herdr, claude or dashboard server is ever started.
Hostile strings are inert sentinels (`echo INJECTED`) and are only ever
parsed with `shlex.split`, never executed."""
import importlib.util
import json
import os
import shlex
import stat
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DASHBOARD_ROOT = os.path.dirname(HERE)

FAKE_HOME = tempfile.mkdtemp(prefix="persona-start-test-home-")
os.environ["HOME"] = FAKE_HOME
os.environ["AGENT_TREE_FILE"] = os.path.join(FAKE_HOME, "agent-tree.json")
os.environ["AGENTBAR_PERSONAS_FILE"] = os.path.join(FAKE_HOME, "personas.json")
os.environ["CHIEF_DASHBOARD_CONFIG_HOME"] = os.path.join(FAKE_HOME, "config")
os.environ["CHIEF_DASHBOARD_STATE_HOME"] = os.path.join(FAKE_HOME, "state")
os.environ["CHIEF_DASHBOARD_MACHINES"] = "{}"
os.environ["CHIEF_HERDR_BIN"] = os.path.join(FAKE_HOME, "no-such-herdr")
FAKE_PROJECTS_DIR = os.path.join(FAKE_HOME, "claude-projects")
os.environ["CLAUDE_PROJECTS_DIR"] = FAKE_PROJECTS_DIR

sys.path.insert(0, os.path.join(DASHBOARD_ROOT, "server", "lib"))
import personas  # noqa: E402
import persona_start as ps  # noqa: E402

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


# ── fakes ──

class FakeHerdr:
    """Records every herdr call; optionally fails one step."""

    def __init__(self, fail_at=None, on_pane_run=None, close_fails=False, tab_id="t9",
                 prepare=None):
        self.calls = []
        self.machine = "local"
        self.prepare = prepare  # remote prep outcome: exception to raise, or None
        self.fail_at = fail_at
        self.on_pane_run = on_pane_run
        self.close_fails = close_fails
        self.tab_id = tab_id

    def _maybe_fail(self, step):
        if self.fail_at == step:
            raise ps.herdr_transport.HerdrError(f"fake {step} failure")

    def for_machine(self, machine):
        self.machine = machine
        return self

    def prepare_remote(self, folder, filename, instructions):
        self.calls.append(("prepare_remote", folder, filename, instructions))
        if self.prepare is not None:
            raise self.prepare
        return f"/Users/remote/prompts/{filename}", folder.replace("~", "/Users/remote", 1)

    def tab_create(self, folder, label, env):
        self.calls.append(("tab_create", folder, label, dict(env)))
        self._maybe_fail("tab_create")
        return self.tab_id, "w1:p42"

    def wait_shell_ready(self, pane_id):
        self.calls.append(("wait_shell_ready", pane_id))
        self._maybe_fail("wait_shell_ready")

    def pane_run(self, pane_id, command):
        self.calls.append(("pane_run", pane_id, command))
        if self.on_pane_run:
            self.on_pane_run()
        self._maybe_fail("pane_run")

    def tab_close(self, tab_id):
        self.calls.append(("tab_close", tab_id))
        if self.close_fails:
            raise ps.herdr_transport.HerdrError("fake close failure")

    def steps(self):
        return [c[0] for c in self.calls]

    def tab_env(self):
        creates = [c for c in self.calls if c[0] == "tab_create"]
        return creates[-1][3] if creates else None

    def command(self):
        runs = [c for c in self.calls if c[0] == "pane_run"]
        return runs[-1][2] if runs else None


class FakeClock:
    def __init__(self, now=1_800_000_000.0):
        self.now = now

    def __call__(self):
        return self.now


def make_folder(name):
    path = os.path.join(FAKE_HOME, "personas", name)
    os.makedirs(path, exist_ok=True)
    return path


ECHO_DIR = make_folder("test-echo")
SCRIPT_DIR = make_folder("script-one")
HIDDEN_DIR = make_folder("hidden-one")
MISSING_DIR = os.path.join(FAKE_HOME, "personas", "never-created")


def persona_entry(name, **overrides):
    entry = {"name": name, "description": f"{name} does test things.",
             "routesWhen": [], "notFor": [], "extraInstructions": "",
             "idle": "resume", "resumeWithinDays": 3, "start": "in-place"}
    entry.update(overrides)
    return entry


def write_registry(extra_personas=None, hidden=()):
    reg = {"personas": {
        f"local:{ECHO_DIR}": persona_entry("test-echo", extraInstructions="Echo the message back."),
        f"local:{SCRIPT_DIR}": persona_entry("script-one", start="script", startScript="run.sh"),
        f"local:{HIDDEN_DIR}": persona_entry("hidden-one"),
        f"local:{MISSING_DIR}": persona_entry("missing-folder"),
        "local:~/draft": persona_entry("draft-one", description=""),
        "air-m1:~/remote": persona_entry("remote-one"),
    }, "hidden": [f"local:{HIDDEN_DIR}", *hidden]}
    reg["personas"].update(extra_personas or {})
    path = os.path.join(FAKE_HOME, f"registry-{len(os.listdir(FAKE_HOME))}.json")
    with open(path, "w") as f:
        json.dump(reg, f)
    return personas.load_registry(path)


REGISTRY = write_registry()
ECHO_RESOLVED = personas._resolve_path(ECHO_DIR)
INSTRUCTIONS_DIR = os.path.join(FAKE_HOME, "state", "persona-prompts")


def transcript(session_id, mtime, folder=ECHO_RESOLVED, projects_dir=FAKE_PROJECTS_DIR):
    project_dir = os.path.join(projects_dir, ps.encode_project_dir(folder))
    os.makedirs(project_dir, exist_ok=True)
    path = os.path.join(project_dir, session_id + ".jsonl")
    with open(path, "w") as f:
        f.write("{}\n")
    os.utime(path, (mtime, mtime))
    return path


def start(body, *, herdr=None, clock=None, monotonic=None, registry=REGISTRY, agent_rows=(),
          projects_dir=None, guard=None):
    """`clock` is the wall clock (transcript ages), `monotonic` the guard's."""
    herdr = herdr if herdr is not None else FakeHerdr()
    deps = ps.StartDeps(registry=registry, agent_rows=list(agent_rows), herdr=herdr,
                        wall_clock_fn=clock or FakeClock(),
                        monotonic_fn=monotonic or FakeClock(1000.0),
                        guard=guard or ps.StartGuard(),
                        projects_dir=projects_dir or os.path.join(FAKE_HOME, "empty-projects"),
                        instructions_dir=INSTRUCTIONS_DIR)
    return ps.start_persona(body, deps), herdr


def argv_of(command):
    """The typed line's words (parse only; `$PERSONA_MESSAGE` stays
    literal — it is what the shell expands to the message)."""
    return shlex.split(command)


MESSAGE_WORD = "${" + ps.MESSAGE_ENV_VAR + ":?}"


SENTINEL_SUBST = "$(echo INJECTED)"
SENTINEL_QUOTE = "'; echo INJECTED #"
SENTINEL_BACKTICK = "`echo INJECTED`"

# ─────────────────────────────────────────────────────────────────────────
print("== happy path: fresh start, shape of the typed command ==")
result, herdr = start({"persona": "test-echo", "text": "who are you"})
check("ok", result, {"ok": True, "paneId": "w1:p42", "machine": "local", "mode": "started"})
check("herdr steps in order", herdr.steps(), ["tab_create", "wait_shell_ready", "pane_run"])
check("tab created in the persona folder, labelled with its name, message in its env",
      herdr.calls[0], ("tab_create", ECHO_RESOLVED, "test-echo",
                       {ps.MESSAGE_ENV_VAR: "who are you"}))
argv = argv_of(herdr.command())
check("argv[0] is claude", argv[0], ps.CLAUDE_BIN)
check("no --resume / --continue on a fresh start",
      [a for a in argv if a in ("--resume", "--continue", "-c", "-r")], [])
check("-- then the message variable end the line", argv[-2:], ["--", MESSAGE_WORD])
check("the line ends with '--' then the double-quoted variable (one argv element)",
      herdr.command().endswith("'--' \"" + MESSAGE_WORD + "\""), True)
check("every other word is single-quoted",
      all(w.startswith("'") for w in herdr.command().split(" ")[:-1]), True)
check("the message itself is never typed", "who are you" in herdr.command(), False)
prompt_flags = [a for a in argv if a.startswith("--append-system-prompt-file=")]
check("exactly one --append-system-prompt-file=<path>", len(prompt_flags), 1)
check("no inline --append-system-prompt", "--append-system-prompt" in argv, False)
prompt_path = prompt_flags[0].split("=", 1)[1]
check("instructions file lives in the dashboard-owned dir",
      os.path.dirname(prompt_path), INSTRUCTIONS_DIR)
with open(prompt_path) as f:
    written = f.read()
check("instructions name the persona", 'You are the persona "test-echo"' in written, True)
check("instructions list known (offered) personas only",
      "Known personas: missing-folder, remote-one, script-one, test-echo." in written, True)
check("instructions end with the persona's extra block",
      written.rstrip().endswith("Echo the message back."), True)
check("file is 0600", stat.S_IMODE(os.stat(prompt_path).st_mode), 0o600)
check("dir is 0700", stat.S_IMODE(os.stat(INSTRUCTIONS_DIR).st_mode), 0o700)
check("no newline in the typed line", "\n" in herdr.command(), False)

print("\n== hostile text: goes only into the tab env, verbatim; never into the typed line ==")
for label, hostile in (("command substitution", SENTINEL_SUBST),
                       ("quote break-out", SENTINEL_QUOTE),
                       ("backticks", SENTINEL_BACKTICK),
                       ("zsh =word expansion", "=echo INJECTED")):
    result, herdr = start({"persona": "test-echo", "text": f"{hostile} there"})
    check(f"{label}: accepted", result.get("ok"), True)
    check(f"{label}: env holds it verbatim",
          herdr.tab_env(), {ps.MESSAGE_ENV_VAR: f"{hostile} there"})
    check(f"{label}: typed line doesn't contain it",
          "INJECTED" in herdr.command(), False)

print("\n== a message that starts with '-' is the prompt, never a claude flag ==")
result, herdr = start({"persona": "test-echo", "text": "--dangerously-skip-permissions now"})
argv = argv_of(herdr.command())
check("accepted", result.get("ok"), True)
check("the message variable comes after --", argv[-2:], ["--", MESSAGE_WORD])
check("the flag-looking text is not on the typed line",
      "--dangerously-skip-permissions" in herdr.command(), False)
check("…it reaches claude as the prompt, via the env",
      herdr.tab_env(), {ps.MESSAGE_ENV_VAR: "--dangerously-skip-permissions now"})

print("\n== terminal control characters in text are refused before any herdr call ==")
for label, hostile in (("ctrl-C", "\x03echo INJECTED"), ("ctrl-U", "\x15echo INJECTED"),
                       ("ESC", "\x1b[2Jecho INJECTED"), ("DEL", "ab\x7fecho INJECTED"),
                       ("C1 CSI", "ab\x9becho INJECTED"), ("NUL", "ab\x00echo INJECTED")):
    result, herdr = start({"persona": "test-echo", "text": f"hello {hostile}"})
    check(f"{label}: refused", result.get("ok"), False)
    check(f"{label}: reason names a control character",
          "control character" in (result.get("error") or ""), True)
    check(f"{label}: herdr never called", herdr.calls, [])

print("\n== a tab in text becomes a space (same rule as Send message / AgentBar) ==")
result, herdr = start({"persona": "test-echo", "text": "col a\tcol b"})
check("tab text accepted", result.get("ok"), True)
check("the tab reached claude as a space",
      herdr.tab_env(), {ps.MESSAGE_ENV_VAR: "col a col b"})

print("\n== the shared Send-message rules apply to text ==")
for label, text, needle in (("newline", "line one\nline two", "newline"),
                            ("carriage return", "a\rb", "newline"),
                            ("over 8000 chars", "x" * 8001, "limit 8000"),
                            ("slash command", "/help", "slash"),
                            ("blank", "   ", "empty")):
    result, herdr = start({"persona": "test-echo", "text": text})
    check(f"{label}: refused", (result.get("ok"), needle in (result.get("error") or "")),
          (False, True))
    check(f"{label}: herdr never called", herdr.calls, [])
result, _ = start({"persona": "test-echo", "text": "x" * 8000})
check("exactly 8000 chars is fine", result.get("ok"), True)

print("\n== control characters in the persona's instructions are refused ==")
bad_reg = write_registry({f"local:{make_folder('bad-instr')}": persona_entry(
    "bad-instr", extraInstructions="line\x1b[31mecho INJECTED")})
result, herdr = start({"persona": "bad-instr", "text": "hi"}, registry=bad_reg)
check("refused", (result.get("ok"), "instructions contain control character" in result.get("error", "")),
      (False, True))
check("herdr never called", herdr.calls, [])
multi_reg = write_registry({f"local:{make_folder('multi-line')}": persona_entry(
    "multi-line", extraInstructions="Line one.\n\tLine two.")})
result, _ = start({"persona": "multi-line", "text": "hi"}, registry=multi_reg)
check("newlines + tabs in instructions are fine (they go in the file)", result.get("ok"), True)

print("\n== malformed requests ==")
for label, body, needle in (("not an object", ["x"], "malformed"),
                            ("no persona", {"text": "hi"}, "missing persona"),
                            ("no text", {"persona": "test-echo"}, "missing text"),
                            ("fresh not a bool", {"persona": "test-echo", "text": "hi",
                                                  "fresh": "yes"}, "'fresh'")):
    result, herdr = start(body)
    check(f"{label}: refused with a clear reason",
          (result.get("ok"), needle in (result.get("error") or "")), (False, True))

print("\n== only an offered local in-place persona with a real folder can start ==")
for label, name, needle in (("not in the registry", "no-such-persona", "unknown persona"),
                            ("hidden", "hidden-one", "unknown persona"),
                            ("no saved description", "draft-one", "unknown persona"),
                            ("start:script", "script-one", "start:script"),
                            ("remote machine", "remote-one", "air-m1"),
                            ("folder missing on disk", "missing-folder", "doesn't exist")):
    result, herdr = start({"persona": name, "text": "hi"})
    check(f"{label}: refused", (result.get("ok"), needle in (result.get("error") or "")),
          (False, True))
    check(f"{label}: herdr never called", herdr.calls, [])

print("\n== start on another machine (runsOn / one-off override) ==")
import dashboard_config  # noqa: E402
_saved_machines = dashboard_config.MACHINES
dashboard_config.MACHINES = {"air-m1": {"label": "Air"}}
try:
    result, herdr = start({"persona": "test-echo", "text": "hi", "machine": "air-m1"})
    check("override: ok on Air", (result.get("ok"), result.get("machine")), (True, "air-m1"))
    check("override: herdr ran on Air", herdr.machine, "air-m1")
    check("override: prep, then tab, then run", herdr.steps(),
          ["prepare_remote", "tab_create", "wait_shell_ready", "pane_run"])
    prep = herdr.calls[0]
    check("folder sent home-relative so the Air's own home applies",
          prep[1], "~/" + os.path.relpath(ECHO_RESOLVED, os.path.realpath(FAKE_HOME)))
    check("instructions go to the Air (not written locally first)",
          "Echo the message back." in prep[3], True)
    check("tab opens in the Air's resolved folder", herdr.calls[1][1].startswith("/Users/remote/"), True)
    check("command points at the Air's instructions file",
          "/Users/remote/prompts/" in herdr.command(), True)
    check("pane id is namespaced to the Air", result.get("paneId"), "air-m1:w1:p42")
    check("remote start is fresh (remote history: slice 3)", result.get("mode"), "started")

    REG_AIR = write_registry({f"local:{make_folder('air-default')}":
                              persona_entry("air-default", runsOn="air-m1")})
    result, herdr = start({"persona": "air-default", "text": "hi"}, registry=REG_AIR)
    check("runsOn air-m1 starts there without an override", (result.get("ok"), herdr.machine),
          (True, "air-m1"))
    result, herdr = start({"persona": "air-default", "text": "hi", "machine": "local"},
                          registry=REG_AIR)
    check("override local beats runsOn", (result.get("ok"), herdr.machine), (True, "local"))

    unreachable = ps.herdr_transport.SshUnreachable("ssh trungs-air timed out")
    result, herdr = start({"persona": "test-echo", "text": "hi", "machine": "air-m1"},
                          herdr=FakeHerdr(prepare=unreachable))
    check("unreachable: refused, flagged, nothing opened",
          (result.get("ok"), result.get("unreachable"), herdr.steps()),
          (False, True, ["prepare_remote"]))
    check("unreachable: offers the other Mac for a one-press retry",
          result.get("retryOn"), {"id": "local", "label": dashboard_config.LOCAL_MACHINE_LABEL})
    check("unreachable: plain message, no ssh detail",
          ("Air is unreachable" in result["error"], "trungs-air" in result["error"]), (True, False))
    result, herdr = start({"persona": "test-echo", "text": "hi", "machine": "air-m1"},
                          herdr=FakeHerdr(prepare=ValueError("folder /x doesn't exist there")))
    check("folder missing on the Air: clear refusal, no tab",
          (result.get("ok"), "on Air" in result["error"], herdr.steps()),
          (False, True, ["prepare_remote"]))
    result, herdr = start({"persona": "test-echo", "text": "hi", "machine": "$(echo INJECTED)"})
    check("unknown/hostile machine refused before herdr",
          (result.get("ok"), herdr.calls, "INJECTED" in result["error"]), (False, [], False))
finally:
    dashboard_config.MACHINES = _saved_machines

print("\n== resume vs fresh ==")
projects = os.path.join(FAKE_HOME, "projects-resume")
clock = FakeClock()
UUID_RECENT = "0f1e2d3c-4b5a-4968-8776-a5b4c3d2e1f0"
transcript("aaaaaaaa-0000-4000-8000-000000000000", clock.now - 2 * 86400, projects_dir=projects)
transcript(UUID_RECENT, clock.now - 3600, projects_dir=projects)
result, herdr = start({"persona": "test-echo", "text": "continue"}, clock=clock,
                      projects_dir=projects)
argv = argv_of(herdr.command())
check("recent conversation -> resumed", result.get("mode"), "resumed")
check("--resume <newest uuid>", argv[1:3], ["--resume", UUID_RECENT])
check("never --continue", "--continue" in argv, False)

result, herdr = start({"persona": "test-echo", "text": "new", "fresh": True}, clock=clock,
                      projects_dir=projects)
check("fresh:true -> started, no --resume",
      (result.get("mode"), "--resume" in argv_of(herdr.command())), ("started", False))

live_rows = [{"machine": "local", "agentSession": UUID_RECENT, "paneId": "w1:p7"}]
result, herdr = start({"persona": "test-echo", "text": "hi"}, clock=clock,
                      projects_dir=projects, agent_rows=live_rows)
check("newest conversation already live in a pane -> started fresh", result.get("mode"), "started")
remote_rows = [{"machine": "air-m1", "agentSession": UUID_RECENT}]
result, _ = start({"persona": "test-echo", "text": "hi"}, clock=clock,
                  projects_dir=projects, agent_rows=remote_rows)
check("same id live on ANOTHER machine doesn't block the resume", result.get("mode"), "resumed")

late_clock = FakeClock(clock.now + 3 * 86400)  # newest is now 3 days + 1h old
result, _ = start({"persona": "test-echo", "text": "hi"}, clock=late_clock, projects_dir=projects)
check("older than resumeWithinDays (3) -> started", result.get("mode"), "started")

fresh_reg = write_registry({f"local:{make_folder('fresh-idle')}": persona_entry(
    "fresh-idle", idle="fresh")})
transcript(UUID_RECENT, clock.now - 60, folder=personas._resolve_path(
    os.path.join(FAKE_HOME, "personas", "fresh-idle")), projects_dir=projects)
result, _ = start({"persona": "fresh-idle", "text": "hi"}, registry=fresh_reg, clock=clock,
                  projects_dir=projects)
check("idle: fresh never resumes", result.get("mode"), "started")

odd_projects = os.path.join(FAKE_HOME, "projects-odd")
transcript("not-a-uuid", clock.now - 60, projects_dir=odd_projects)
result, herdr = start({"persona": "test-echo", "text": "hi"}, clock=clock,
                      projects_dir=odd_projects)
check("a non-UUID transcript name is never resumed", result.get("mode"), "started")
transcript(UUID_RECENT, clock.now - 600, projects_dir=odd_projects)  # older than the odd file
result, herdr = start({"persona": "test-echo", "text": "hi"}, clock=clock,
                      projects_dir=odd_projects)
check("a newer non-UUID file doesn't hide a recent UUID conversation",
      argv_of(herdr.command())[1:3], ["--resume", UUID_RECENT])

print("\n== decide_resume + build_start_command unit edges ==")
echo_persona = ps.find_offered_persona_by_name(REGISTRY, "test-echo")[1]
check("exactly resumeWithinDays old still resumes",
      ps.decide_resume(echo_persona, (UUID_RECENT, 1000.0), now=1000.0 + 3 * 86400), UUID_RECENT)
check("uppercase UUID refused", ps.decide_resume(
    echo_persona, (UUID_RECENT.upper(), 1000.0), now=1000.0), None)
try:
    ps.build_start_command("p.md", resume_session_id="x; echo INJECTED")
    check("non-UUID resume id raises", False, True)
except ValueError:
    check("non-UUID resume id raises", True, True)
try:
    ps.build_start_command("a\x03echo INJECTED.md")
    check("control char in the final line raises", False, True)
except ValueError:
    check("control char in the final line raises", True, True)

check("_single_quote round-trips an apostrophe", shlex.split(ps._single_quote("it's")), ["it's"])
check("_single_quote quotes even a bare =word", ps._single_quote("=echo"), "'=echo'")

print("\n== herdr failure after tab create closes the tab ==")
for step in ("wait_shell_ready", "pane_run"):
    herdr = FakeHerdr(fail_at=step)
    result, _ = start({"persona": "test-echo", "text": "hi"}, herdr=herdr)
    check(f"{step} fails: ok false", result.get("ok"), False)
    check(f"{step} fails: tab closed", herdr.calls[-1], ("tab_close", "t9"))
    check(f"{step} fails: error says so", "the new tab was closed" in result.get("error", ""), True)
herdr = FakeHerdr(fail_at="pane_run", close_fails=True)
result, _ = start({"persona": "test-echo", "text": "hi"}, herdr=herdr)
check("close also fails: still a clean {ok:false} naming the tab",
      (result.get("ok"), "closing the new tab t9 also failed" in result.get("error", "")),
      (False, True))
herdr = FakeHerdr(fail_at="pane_run", tab_id=None)
result, _ = start({"persona": "test-echo", "text": "hi"}, herdr=herdr)
check("no tab id: tells the user to close it by hand",
      "close the new tab by hand" in result.get("error", ""), True)
herdr = FakeHerdr(fail_at="tab_create")
result, _ = start({"persona": "test-echo", "text": "hi"}, herdr=herdr)
check("tab create fails: {ok:false}, nothing else attempted",
      (result.get("ok"), herdr.steps()), (False, ["tab_create"]))
check("tab create fails: plain herdr error, not a crash report",
      result.get("error", "").startswith("herdr couldn't open a tab"), True)


class ExplodingDeps(ps.StartDeps):
    def live_agent_rows(self):
        raise KeyError("computed")


result = ps.start_persona({"persona": "test-echo", "text": "hi"}, ExplodingDeps(
    registry=REGISTRY, herdr=FakeHerdr(), wall_clock_fn=FakeClock(), guard=ps.StartGuard(),
    instructions_dir=INSTRUCTIONS_DIR))
check("an unexpected exception becomes {ok:false}, never escapes",
      (result.get("ok"), result.get("error", "").startswith("persona start failed")), (False, True))

print("\n== double POST guard ==")
guard, clock = ps.StartGuard(), FakeClock(1000.0)  # the guard's monotonic clock
first, _ = start({"persona": "test-echo", "text": "hi"}, guard=guard, monotonic=clock)
second, herdr2 = start({"persona": "test-echo", "text": "hi"}, guard=guard, monotonic=clock)
check("first start ok", first.get("ok"), True)
check("an immediate second start is refused",
      (second.get("ok"), "was started" in second.get("error", "")), (False, True))
check("…without touching herdr", herdr2.calls, [])
other, _ = start({"persona": "multi-line", "text": "hi"}, guard=guard, monotonic=clock,
                 registry=multi_reg)
check("a different persona is not blocked", other.get("ok"), True)
clock.now += ps.START_COOLDOWN_SEC + 1
third, _ = start({"persona": "test-echo", "text": "hi"}, guard=guard, monotonic=clock)
check("after the cooldown it may start again", third.get("ok"), True)

guard, wall, mono = ps.StartGuard(), FakeClock(), FakeClock(1000.0)
start({"persona": "test-echo", "text": "hi"}, guard=guard, clock=wall, monotonic=mono)
wall.now -= 3600  # the wall clock steps back an hour (NTP, manual change)
mono.now += ps.START_COOLDOWN_SEC + 1
after_step, _ = start({"persona": "test-echo", "text": "hi"}, guard=guard, clock=wall,
                      monotonic=mono)
check("a backwards wall-clock step doesn't block starts (guard is monotonic)",
      after_step.get("ok"), True)

guard = ps.StartGuard()
nested = {}
reentrant = FakeHerdr(on_pane_run=lambda: nested.update(result=start(
    {"persona": "test-echo", "text": "hi"}, guard=guard)[0]))
outer, _ = start({"persona": "test-echo", "text": "hi"}, herdr=reentrant, guard=guard)
check("a start arriving while one is in flight is refused",
      (nested["result"].get("ok"), "already starting" in nested["result"].get("error", "")),
      (False, True))
check("…and the in-flight one still completes", outer.get("ok"), True)

guard = ps.StartGuard()
failed, _ = start({"persona": "test-echo", "text": "hi"}, herdr=FakeHerdr(fail_at="pane_run"),
                  guard=guard)
retry, _ = start({"persona": "test-echo", "text": "hi"}, guard=guard)
check("a FAILED start doesn't lock the persona out (retry allowed)",
      (failed.get("ok"), retry.get("ok")), (False, True))

print("\n== idleStart (GET /api/personas): cheap, cached, script/remote aware ==")
idle_projects = os.path.join(FAKE_HOME, "projects-idle")
ps._idle_start_scan_cache.clear()
t0, m0 = 1_900_000_000.0, 5000.0  # wall epoch (transcript ages), monotonic (cache TTL)
ttl = ps.IDLE_START_CACHE_TTL_SEC
check("no history -> fresh",
      ps.idle_start_for(echo_persona, set(), now=t0, monotonic_now=m0,
                        projects_dir=idle_projects), "fresh")
transcript(UUID_RECENT, t0, projects_dir=idle_projects)
check("within the cache TTL the old scan is reused",
      ps.idle_start_for(echo_persona, set(), now=t0 + 5, monotonic_now=m0 + 5,
                        projects_dir=idle_projects), "fresh")
check("after the TTL it rescans -> resume",
      ps.idle_start_for(echo_persona, set(), now=t0 + ttl + 1, monotonic_now=m0 + ttl + 1,
                        projects_dir=idle_projects), "resume")
check("a live copy of that conversation -> fresh",
      ps.idle_start_for(echo_persona, {UUID_RECENT}, now=t0 + ttl + 2,
                        monotonic_now=m0 + ttl + 2, projects_dir=idle_projects), "fresh")

ps._idle_start_scan_cache.clear()
step_projects = os.path.join(FAKE_HOME, "projects-idle-step")
ps.idle_start_for(echo_persona, set(), now=t0, monotonic_now=m0, projects_dir=step_projects)
transcript(UUID_RECENT, t0 - 7200, projects_dir=step_projects)
check("a backwards wall-clock step doesn't pin a stale scan (TTL is monotonic)",
      ps.idle_start_for(echo_persona, set(), now=t0 - 3600, monotonic_now=m0 + ttl + 1,
                        projects_dir=step_projects), "resume")
script_persona = {**echo_persona, "start": "script"}
remote_persona = {**echo_persona, "machine": "air-m1", "runsOn": "air-m1"}
check("start:script -> fresh (no scan)",
      ps.idle_start_for(script_persona, set(), now=t0, projects_dir=idle_projects), "fresh")
check("remote persona -> fresh (no scan)",
      ps.idle_start_for(remote_persona, set(), now=t0, projects_dir=idle_projects), "fresh")
check("projects dir defaults to the CLAUDE_PROJECTS_DIR override",
      ps.claude_projects_dir(), FAKE_PROJECTS_DIR)

print("\n== HerdrTabOps builds the right herdr argv (transport faked, nothing runs) ==")
recorded = []
_real_json, _real_text = ps.herdr_transport.herdr_cmd_json, ps.herdr_transport.herdr_cmd_text
ps.herdr_transport.herdr_cmd_json = lambda machine, argv, **kw: recorded.append(
    (machine, argv, kw["timeout"])) or {"result": {"tab": {"tab_id": "t1"},
                                                    "root_pane": {"pane_id": "w1:p1"}}}
ps.herdr_transport.herdr_cmd_text = lambda machine, argv, **kw: recorded.append(
    (machine, argv, kw["timeout"])) or ""
try:
    ops = ps.HerdrTabOps()
    check("tab_create returns (tab id, pane id)",
          ops.tab_create("/fake-folder", "test-echo", {"PERSONA_MESSAGE": "hi there"}), ("t1", "w1:p1"))
    check("tab_create argv: cwd, label, no-focus, --env NAME=value",
          recorded[-1][:2], ("local", ["tab", "create", "--cwd", "/fake-folder", "--label", "test-echo",
                                       "--no-focus", "--env", "PERSONA_MESSAGE=hi there"]))
    ops.wait_shell_ready("w1:p1")
    check("wait_shell_ready argv", recorded[-1][1],
          ["pane", "wait-output", "w1:p1", "--regex", r"\S", "--source", "visible",
           "--timeout", str(ps.SHELL_READY_TIMEOUT_MS)])
    shell_wait_budget = recorded[-1][2]
    ops.tab_close("t1")
    check("tab_close uses its own short budget", recorded[-1][1:], (["tab", "close", "t1"],
                                                                     ps.TAB_CLOSE_TIMEOUT_SEC))
    total = (ps.HERDR_CALL_TIMEOUT_SEC + shell_wait_budget + ps.HERDR_CALL_TIMEOUT_SEC
             + ps.TAB_CLOSE_TIMEOUT_SEC)
    check("worst case (create + wait + run + close) stays under AgentBar's 30s", total < 30, True)
    # Live run 2026-09-26 (load ~34): a new tab's zsh took up to 8.2s to draw
    # its prompt and the old 8s wait refused a real start. Keep ~2x that.
    check("shell wait allows a slow zsh under load (>= 15s)",
          ps.SHELL_READY_TIMEOUT_MS >= 15000, True)
    ops.tab_create("/fake-folder", "x", {"PERSONA_MESSAGE": "a=b=c"})
    check("a message with '=' is one --env argument, split only by herdr at the first '='",
          recorded[-1][1][-2:], ["--env", "PERSONA_MESSAGE=a=b=c"])
    ps.herdr_transport.herdr_cmd_json = lambda machine, argv, **kw: ["not", "an", "object"]
    try:
        ops.tab_create("/fake-folder", "x", {})
        check("a non-object herdr reply raises RuntimeError", False, True)
    except RuntimeError:
        check("a non-object herdr reply raises RuntimeError", True, True)
finally:
    ps.herdr_transport.herdr_cmd_json, ps.herdr_transport.herdr_cmd_text = _real_json, _real_text

print("\n== server route: localhost only, JSON only ==")
_spec = importlib.util.spec_from_file_location(
    "chief_dashboard_server_persona_start_test",
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
    def __init__(self, headers, body=b"", remote=False):  # noqa: no super().__init__ (no socket)
        self.headers = dict(headers, **{"Content-Length": str(len(body))})
        self.rfile = FakeRfile(body)
        self.server = FakeServer(remote)
        self.sent = None

    def _send_json(self, obj, status=200):
        self.sent = (obj, status)


seen_bodies = []
_real_start = _srv.persona_start.start_persona
_srv.persona_start.start_persona = lambda body: seen_bodies.append(body) or {"ok": True}
try:
    body = json.dumps({"persona": "test-echo", "text": "hi"}).encode()
    h = FakeHandler({"Content-Type": "application/json"}, body, remote=True)
    h._handle_local_json_post("/api/persona/start", _srv.persona_start.start_persona)
    check("remote listener: 403", h.sent[1], 403)
    check("remote listener: says localhost-only", "localhost-only" in h.sent[0]["error"], True)
    check("remote listener: start never called", seen_bodies, [])

    h = FakeHandler({"Content-Type": "text/plain"}, body)
    h._handle_local_json_post("/api/persona/start", _srv.persona_start.start_persona)
    check("wrong Content-Type: 400, start never called", (h.sent[1], seen_bodies), (400, []))

    h = FakeHandler({"Content-Type": "application/json"}, b"{not json")
    h._handle_local_json_post("/api/persona/start", _srv.persona_start.start_persona)
    check("bad JSON: {ok:false} (200), start never called",
          (h.sent[0]["ok"], h.sent[1], seen_bodies), (False, 200, []))

    h = FakeHandler({"Content-Type": "application/json; charset=utf-8"}, body)
    h._handle_local_json_post("/api/persona/start", _srv.persona_start.start_persona)
    check("local + JSON: handed to start_persona", seen_bodies, [{"persona": "test-echo", "text": "hi"}])
    check("local + JSON: its reply is sent as-is", h.sent, ({"ok": True}, 200))
finally:
    _srv.persona_start.start_persona = _real_start

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("All persona start checks passed.")
