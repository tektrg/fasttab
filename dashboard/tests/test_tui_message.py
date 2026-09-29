#!/usr/bin/env python3
"""Direct-run tests for messaging an OpenCode / Codex row (Phase 4):
message_gate.is_tui_row, tui_message (checks + OpenCode job + Codex pane
typing, all against fakes), the job queue's picked-up flag, and
POST /api/session/message end to end with fake pane I/O. Never a real session.
Hostile text is the inert sentinel only, asserted to arrive as literal text."""
import importlib.util
import os
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DASHBOARD_ROOT = os.path.dirname(HERE)
_tmp = tempfile.mkdtemp(prefix="tui-message-test-")
os.environ["CHIEF_DASHBOARD_CONFIG_HOME"] = os.path.join(_tmp, "config")
os.environ["CHIEF_DASHBOARD_STATE_HOME"] = os.path.join(_tmp, "state")
os.environ["CHIEF_DASHBOARD_MACHINES"] = "{}"
os.environ["CHIEF_HERDR_BIN"] = os.path.join(_tmp, "no-such-herdr")
os.environ["AGENTBAR_PERSONAS_FILE"] = os.path.join(_tmp, "no-personas.json")
sys.path.insert(0, os.path.join(DASHBOARD_ROOT, "server", "lib"))
import message_gate  # noqa: E402
import tui_jobs  # noqa: E402
import tui_message  # noqa: E402

FIXTURES = os.path.join(HERE, "fixtures", "panes")
SENTINEL = "$(echo INJECTED)"
fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def fixture(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as f:
        return f.read().splitlines()


def row(kind, source, **extra):
    return dict({"source": "herdr", "agentKind": kind, "hasHookData": True, "statusSource": source,
                 "tuiSessionId": "ses_1" if kind == "opencode" else "cx-1", "paneId": "w1:p1",
                 "rowId": f"row-{kind}", "label": kind, "machine": "local"}, **extra)


def entry(tool, **extra):
    return dict({"tool": tool, "sessionId": "ses_1" if tool == "opencode" else "cx-1", "pid": 4242,
                 "paneId": "w1:p1", "status": "idle", "prompt": None, "relay": True, "canMessage": True},
                **extra)


print("== message_gate.is_tui_row ==")
check("opencode + plugin status", message_gate.is_tui_row(row("opencode", "opencode-plugin")), True)
check("codex + hook status", message_gate.is_tui_row(row("codex", "codex-hook")), True)
check("codex + rollout status", message_gate.is_tui_row(row("codex", "codex-rollout")), True)
check("opencode with a codex source: not", message_gate.is_tui_row(row("opencode", "codex-hook")), False)
check("best-guess row (no statusSource): not", message_gate.is_tui_row(row("codex", None, hasHookData=False)), False)
check("no session id: not", message_gate.is_tui_row(row("codex", "codex-hook", tuiSessionId=None)), False)
check("claude row: not a tui row", message_gate.is_tui_row(row("claude", None)), False)
check("eligible rows pass the blind gate", message_gate.blind_agent_refusal(row("opencode", "opencode-plugin")), None)
check("best-guess opencode row stays refused",
      (message_gate.blind_agent_refusal(row("opencode", None, hasHookData=False)) or "")[:8], "refused:")
check("mismatched source stays refused",
      (message_gate.blind_agent_refusal(row("opencode", "codex-hook")) or "")[:8], "refused:")

print("\n== tui_message.check ==")
quiet = fixture("codex_idle.txt")
oc_idle = fixture("opencode_idle.txt")
oc_row, cx_row = row("opencode", "opencode-plugin"), row("codex", "codex-hook")
oc_entry, cx_entry = entry("opencode"), entry("codex")


def run_check(agent, text, lines, entries):
    return tui_message.check(agent, "w1:p1", text, lines, entries)


for lead in ("/compact", "/clear", "!ls", f"!{SENTINEL}"):
    got, why = run_check(oc_row, lead, oc_idle, [oc_entry])
    check(f"leading char refused: {lead[:12]!r}", (got, why["typed"], why["error"][:8]), (None, False, "refused:"))
got, why = run_check(oc_row, f"hello {SENTINEL}", oc_idle, [oc_entry])
check("sentinel inside a normal message: allowed", (got is oc_entry, why), (True, None))
got, why = run_check(oc_row, "hi", fixture("opencode_question.txt"), [oc_entry])
check("OpenCode question picker open: refused", (got, "question prompt" in why["error"]), (None, True))
got, why = run_check(cx_row, "hi", fixture("codex_permission.txt"), [cx_entry])
check("Codex permission box open: refused", (got, "permission prompt" in why["error"]), (None, True))
got, why = run_check(oc_row, "hi", oc_idle, [])
check("no fresh status entry: refused", (got, why["typed"]), (None, False))
got, why = run_check(oc_row, "hi", oc_idle, [entry("opencode", sessionId="ses_other")])
check("entry for another session: refused", got, None)
got, why = run_check(oc_row, "hi", oc_idle, [entry("opencode", paneId="w9:p9")])
check("entry names another pane: refused", (got, "another pane" in why["error"]), (None, True))
got, why = run_check(oc_row, "hi", oc_idle, [entry("opencode", status="blocked", prompt="question")])
check("status entry says a prompt is pending: refused", (got, "waiting on you" in why["error"]), (None, True))
got, why = run_check(oc_row, "hi", oc_idle, [entry("opencode", paneId=None)])
check("entry without a pane (matched by folder): allowed", (got is not None, why), (True, None))

print("\n== job queue: picked up or not ==")
queue = tui_jobs.JobQueue()
try:
    queue.submit(4242, "POST", "/session/ses_1/prompt_async", {"parts": []}, timeout=0.2)
    check("unclaimed job times out", "returned", "JobNotPickedUp")
except tui_jobs.JobNotPickedUp:
    check("unclaimed job -> JobNotPickedUp (provably not run)", True, True)
import threading  # noqa: E402
box = {}


def submit_claimed():
    try:
        queue.submit(4242, "POST", "/session/ses_1/prompt_async", {"parts": []}, timeout=1.0)
    except Exception as e:  # noqa: BLE001
        box["err"] = e


worker = threading.Thread(target=submit_claimed)
worker.start()
claimed = queue.wait(4242, 2)
worker.join(3)
check("claimed but never answered -> plain TimeoutError (outcome unknown)",
      (claimed is not None, type(box.get("err")) is TimeoutError), (True, True))

print("\n== OpenCode delivery ==")
jobs = []


def fake_submit(status):
    def submit(pid, method, path, body):
        jobs.append((pid, method, path, body))
        return status, None
    return submit


def raise_(exc):
    def submit(*a):
        raise exc
    return submit


owned = lambda pid: True  # noqa: E731


def send_oc(*args, **kwargs):
    tui_message._recent.clear()  # each check below is a separate user intent
    return tui_message.send_opencode(*args, **kwargs)
text = f"reply with pong {SENTINEL}"
res = send_oc(oc_entry, text, False, submit_job=fake_submit(204), pid_owned=owned)
check("204 -> sent", (res["ok"], res["state"]), (True, "message sent"))
check("job: pid, route and a body carrying ONLY the literal text", jobs[-1],
      (4242, "POST", "/session/ses_1/prompt_async", {"parts": [{"type": "text", "text": text}]}))
res = send_oc(oc_entry, "x", True, submit_job=fake_submit(204), pid_owned=owned)
check("busy send -> queued", res["state"], "queued")
res = send_oc(oc_entry, "x", False, submit_job=fake_submit(404), pid_owned=owned)
check("404 -> refused, nothing sent", (res["ok"], res["typed"]), (False, False))
res = send_oc(oc_entry, "x", False, submit_job=fake_submit(500), pid_owned=owned)
check("500 -> uncertain (no typed:false, 'may or may not')", ("typed" in res, "may or may not" in res["error"]), (False, True))
res = send_oc(oc_entry, "x", False, submit_job=raise_(TimeoutError("late")), pid_owned=owned)
check("claimed-then-silent -> uncertain", ("typed" in res, "may or may not" in res["error"]), (False, True))
res = send_oc(oc_entry, "x", False, submit_job=raise_(tui_jobs.JobNotPickedUp("no")), pid_owned=owned)
check("never picked up -> refused (typed false)", res["typed"], False)
before = len(jobs)
res = send_oc(entry("opencode", canMessage=False), "x", False,
                                submit_job=fake_submit(204), pid_owned=owned)
check("old plugin (cannot message): refused, no job", (res["typed"], len(jobs) - before), (False, 0))
res = send_oc(entry("opencode", relay=False), "x", False, submit_job=fake_submit(204), pid_owned=owned)
check("no relay: refused", res["typed"], False)
res = send_oc(oc_entry, "x", False, submit_job=fake_submit(204), pid_owned=lambda pid: False)
check("pid not alive / not ours: refused", res["typed"], False)
inner = {}


def reentrant(pid, method, path, body):
    inner["res"] = tui_message.send_opencode(oc_entry, "second", False, submit_job=fake_submit(204), pid_owned=owned)
    return 204, None


send_oc(oc_entry, "first", False, submit_job=reentrant, pid_owned=owned)
check("second send to a session already in flight: refused", inner["res"]["typed"], False)
res = send_oc(oc_entry, "after", False, submit_job=fake_submit(204), pid_owned=owned)
check("in-flight claim released afterwards", res["ok"], True)
tui_message._recent.clear()
first = tui_message.send_opencode(oc_entry, "same line", False, submit_job=fake_submit(204), pid_owned=owned)
again = tui_message.send_opencode(oc_entry, "same line", False, submit_job=fake_submit(204), pid_owned=owned)
other = tui_message.send_opencode(oc_entry, "another line", False, submit_job=fake_submit(204), pid_owned=owned)
check("same text to the same session moments later (double click): refused, typed false",
      (first["ok"], again["ok"], again["typed"], other["ok"]), (True, False, False, True))
tui_message._recent.clear()
tui_message.send_opencode(oc_entry, "uncertain one", False, submit_job=fake_submit(500), pid_owned=owned)
again = tui_message.send_opencode(oc_entry, "uncertain one", False, submit_job=fake_submit(204), pid_owned=owned)
check("an uncertain send is never repeated within the window", (again["ok"], again["typed"]), (False, False))
import time as _t
until = max(tui_message._recent.values())
check("uncertain attempt blocks the same text for far longer than a double click",
      until - _t.monotonic() > tui_message.DUPLICATE_WINDOW_SEC, True)
tui_message._recent.clear()
tui_message.send_opencode(oc_entry, "refused one", False, submit_job=fake_submit(404), pid_owned=owned)
again = tui_message.send_opencode(oc_entry, "refused one", False, submit_job=fake_submit(204), pid_owned=owned)
check("a refusal that sent nothing does not block the corrected retry", again["ok"], True)


print("\n== Codex pane typing ==")
class FakePane:
    """Composer state machine: send-text fills it, enter submits (or not)."""

    def __init__(self, submit_works=True, fail_on=None, prompt_after_type=False, text_hidden=False):
        self.draft = ""
        self.log = []
        self.submit_works = submit_works
        self.fail_on = fail_on
        self.prompt_after_type = prompt_after_type
        self.text_hidden = text_hidden

    def send_text(self, pane, text):
        self.log.append(("text", pane, text))
        if self.fail_on == "text":
            raise RuntimeError("herdr down")
        self.draft = text

    def send_keys(self, pane, key):
        self.log.append(("key", pane, key))
        if self.fail_on == "key":
            raise RuntimeError("herdr down")
        if self.submit_works:
            self.draft = ""

    def read_pane(self, pane, n):
        if self.prompt_after_type and self.draft:
            return fixture("codex_permission.txt")
        shown = "" if self.text_hidden else self.draft
        return ["• earlier output", "", f"› {shown}" if shown else "› Ask Codex to do anything", "",
                "  gpt-5.6-sol low · /tmp/x"]

    def io(self):
        return {"send_text": self.send_text, "send_keys": self.send_keys, "read_pane": self.read_pane}


def codex_send(pane, msg, busy=False, lines=None):
    tui_message._recent.clear()
    return tui_message.send_codex(cx_entry, "w1:p1", msg, lines or pane.read_pane("w1:p1", 60), busy, pane.io(),
                                  settle_sec=0, after_enter_sec=0, sleep=lambda s: None)


pane = FakePane()
res = codex_send(pane, f"pong {SENTINEL}")
check("submits: ok", (res["ok"], res["state"]), (True, "message sent"))
check("typed the literal text once, then Enter once",
      pane.log, [("text", "w1:p1", f"pong {SENTINEL}"), ("key", "w1:p1", "enter")])
check("busy -> queued", codex_send(FakePane(), "x", busy=True)["state"], "queued")
pane = FakePane(submit_works=False)
res = codex_send(pane, "stuck text")
check("text stuck in the composer -> NOT SUBMITTED (uncertain), no second Enter",
      (res["ok"], res["error"][:13], [k for k in pane.log if k[0] == "key"]),
      (False, "NOT SUBMITTED", [("key", "w1:p1", "enter")]))
pane = FakePane(text_hidden=True)
res = codex_send(pane, "invisible")
check("text never seen in the composer -> Enter NOT pressed",
      (res["error"][:13], [k for k in pane.log if k[0] == "key"]), ("NOT SUBMITTED", []))
pane = FakePane(prompt_after_type=True)
res = codex_send(pane, "prompt appeared meanwhile")
check("a prompt opened while typing -> Enter NOT pressed", (res["ok"], [k for k in pane.log if k[0] == "key"]), (False, []))
res = codex_send(FakePane(fail_on="text"), "x")
check("herdr fails typing -> mid-sequence (uncertain)", ("typed" in res, "mid-sequence" in res["error"]), (False, True))
res = codex_send(FakePane(fail_on="key"), "x")
check("herdr fails on Enter -> mid-sequence (uncertain)", ("typed" in res, "mid-sequence" in res["error"]), (False, True))
pane = FakePane()
res = codex_send(pane, "x", lines=["› half typed by the user", "", "  gpt-5.6-sol low · /tmp"])
check("user's unsent draft in the composer -> refused, nothing typed", (res["typed"], pane.log), (False, []))
pane = FakePane()
res = codex_send(pane, "x", lines=["some shell", "$ "])
check("pane is not the Codex composer -> refused, nothing typed", (res["typed"], pane.log), (False, []))
res = tui_message.send_codex(entry("codex", paneId=None), "w1:p1", "x", quiet, False, FakePane().io())
check("Codex did not report its pane -> refused", res["typed"], False)
inner = {}
pane = FakePane()
orig_send_text = pane.send_text


def reentrant_text(p, t):
    orig_send_text(p, t)
    tui_message._recent.pop((tui_message.CODEX, "cx-1", "second"), None)
    inner["res"] = tui_message.send_codex(cx_entry, "w1:p1", "second", quiet, False, FakePane().io(),
                                          settle_sec=0, after_enter_sec=0, sleep=lambda s: None)


pane.send_text = reentrant_text
codex_send(pane, "first")
check("second Codex send during the first: refused", inner["res"]["typed"], False)

class DraftAppearsPane(FakePane):
    """The composer is empty for the caller's read and holds a draft by the re-read inside the claim."""

    def __init__(self):
        super().__init__()
        self.reads = 0

    def read_pane(self, pane, n):
        self.reads += 1
        if self.reads >= 1:
            return ["› half typed elsewhere", "", "  gpt"]
        return super().read_pane(pane, n)


pane = DraftAppearsPane()
tui_message._recent.clear()
res = tui_message.send_codex(cx_entry, "w1:p1", "late draft", quiet, False, pane.io(),
                             settle_sec=0, after_enter_sec=0, sleep=lambda s: None)
check("composer got a draft after the caller's read: refused inside the claim, nothing typed",
      (res["typed"], pane.log), (False, []))

print("\n== POST /api/session/message end to end (fake pane I/O, fake plugin) ==")
_spec = importlib.util.spec_from_file_location(
    "chief_dashboard_server_tui_message_test", os.path.join(DASHBOARD_ROOT, "server", "chief-dashboard-server.py"))
_srv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_srv)
import tui_status_events  # noqa: E402

store = tui_status_events.TuiStatusStore(pid_alive=lambda pid: True)
_srv.tui_status_events.STORE = store
_srv._enrich_agents_for_actions = lambda state, agents: None
_srv._own_pane_cached = lambda ids: None
_srv.time.sleep = lambda s: None
_srv.STORE.log_session_action = lambda *a, **k: audit.append((a, k))
audit = []


def ingest(tool, session, **extra):
    payload = dict({"tool": tool, "pid": 4242, "cwd": "/scratch", "paneId": "w1:p1", "sessionId": session,
                    "relay": True, "messages": True}, **extra)
    return store.ingest(payload)


ingest("opencode", "ses_1", event="session.idle")
ingest("codex", "cx-1", event="SessionStart")
ingest("codex", "cx-1", event="Stop")
screens = {"w1:p1": oc_idle}
_srv._read_pane_now = lambda pane_id, read_lines=None, parser=None, machine="local": (screens[pane_id], None)
AGENTS = [row("opencode", "opencode-plugin", agentSession="oc-row", paneId="w1:p1", hookState="idle"),
          row("codex", "codex-hook", agentSession="cx-row", paneId="w1:p2", hookState="idle")]
_srv.get_full_state = lambda: {"computed": {"agents": AGENTS}}
submitted = []
_srv.tui_message.tui_jobs.QUEUE.submit = lambda pid, method, path, body, **k: submitted.append((pid, path, body)) or (204, None)
_srv.tui_message.opencode_answer.pid_owned_by_me = lambda pid: True
ingest("codex", "cx-1", event="Stop", paneId="w1:p2")
typed = FakePane()
_srv._TUI_PANE_IO.update(typed.io())
screens["w1:p2"] = fixture("codex_idle.txt")
typed.read_pane = lambda pane, n: ["› Ask Codex to do anything", "", "  gpt"] if not typed.draft else [f"› {typed.draft}", "", " gpt"]
_srv._TUI_PANE_IO["read_pane"] = lambda pane, n: typed.read_pane(pane, n)
_srv._TUI_PANE_IO["send_keys"] = lambda pane, key: typed.send_keys(pane, key)
_srv._TUI_PANE_IO["send_text"] = lambda pane, t: typed.send_text(pane, t)

res = _srv.handle_session_action("message", {"rowId": "oc-row", "actor": "po", "text": f"hi {SENTINEL}"})
check("OpenCode row: sent through the plugin job", (res["ok"], submitted[-1][1]), (True, "/session/ses_1/prompt_async"))
check("OpenCode: message body is the literal text",
      submitted[-1][2]["parts"][0]["text"], f"hi {SENTINEL}")
check("OpenCode: audited as sent", [(a[1], k.get("status")) for a, k in audit][-1], ("message", "sent"))
n = len(submitted)
res = _srv.handle_session_action("message", {"rowId": "oc-row", "actor": "po", "text": "/compact"})
check("OpenCode: /compact refused before any job", (res["typed"], len(submitted) - n), (False, 0))
screens["w1:p1"] = fixture("opencode_working.txt")
res = _srv.handle_session_action("message", {"rowId": "oc-row", "actor": "po", "text": "later"})
check("OpenCode busy: needsConfirm, no job", (res.get("needsConfirm"), len(submitted) - n), (True, 0))
res = _srv.handle_session_action("message", {"rowId": "oc-row", "actor": "po", "text": "later", "confirm": True})
check("OpenCode busy + confirm: queued and audited",
      (res["state"], [(k.get("status")) for a, k in audit][-1]), ("queued", "queued"))
screens["w1:p1"] = fixture("opencode_question.txt")
n = len(submitted)
res = _srv.handle_session_action("message", {"rowId": "oc-row", "actor": "po", "text": "hi"})
check("OpenCode question picker open: refused, no job", (res["ok"], len(submitted) - n), (False, 0))
screens["w1:p1"] = oc_idle
ingest("opencode", "ses_1", event="question.asked", request={"id": "que_1", "kind": "question", "questions": []})
res = _srv.handle_session_action("message", {"rowId": "oc-row", "actor": "po", "text": "hi"})
check("OpenCode hook state says blocked: refused, no job", (res["ok"], len(submitted) - n), (False, 0))
ingest("opencode", "ses_1", event="session.idle")

res = _srv.handle_session_action("message", {"rowId": "cx-row", "actor": "po", "text": f"codex {SENTINEL}"})
check("Codex row: typed and submitted", (res["ok"], typed.log[-2:]),
      (True, [("text", "w1:p2", f"codex {SENTINEL}"), ("key", "w1:p2", "enter")]))
typed.log.clear()
res = _srv.handle_session_action("message", {"rowId": "cx-row", "actor": "po", "text": "!ls"})
check("Codex: leading ! refused, nothing typed", (res["typed"], typed.log), (False, []))
screens["w1:p2"] = fixture("codex_permission.txt")
res = _srv.handle_session_action("message", {"rowId": "cx-row", "actor": "po", "text": "hi"})
check("Codex permission box: refused, nothing typed", (res["ok"], typed.log), (False, []))
AGENTS[1] = row("codex", None, agentSession="cx-row", paneId="w1:p2", hasHookData=False)
screens["w1:p2"] = fixture("codex_idle.txt")
res = _srv.handle_session_action("message", {"rowId": "cx-row", "actor": "po", "text": "hi"})
check("Codex best-guess row (no fresh status): still refused", (res["ok"], "invisible" in res["error"], typed.log), (False, True, []))
AGENTS[1] = row("codex", "codex-hook", agentSession="cx-row", paneId="w1:p2", hookState="idle")
store.clear()
res = _srv.handle_session_action("message", {"rowId": "cx-row", "actor": "po", "text": "hi"})
check("Codex status went stale since the state was built: refused, nothing typed",
      (res["ok"], res["typed"], typed.log), (False, False, []))
AGENTS[1] = row("codex", "codex-hook", agentSession="cx-row", paneId="w1:p2", hookState="idle", machine="air-m1")
res = _srv.handle_session_action("message", {"rowId": "cx-row", "actor": "po", "text": "hi"})
check("remote-machine row: refused before anything", (res["ok"], typed.log), (False, []))

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("All TUI message checks passed.")
