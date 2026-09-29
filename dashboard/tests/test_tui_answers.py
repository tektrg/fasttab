#!/usr/bin/env python3
"""Direct-run tests for tui_answers.py: the OpenCode / Codex prompt views on
rows, the plugin's `request` ingest, answer dispatch, and the Codex keystroke
path against a FAKE pane (never a real session, never a real herdr).
Hostile text uses the inert sentinel only."""
import os
import sys

DASHBOARD = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(DASHBOARD, "server", "lib"))
PANES = os.path.join(DASHBOARD, "tests", "fixtures", "panes")

import codex_pane_answer as cpa  # noqa: E402
import tui_answers  # noqa: E402
import tui_status_events as tse  # noqa: E402

SENTINEL = "$(echo INJECTED)"
fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def screen(name):
    return open(os.path.join(PANES, name)).read().splitlines()


class Clock:
    now = 1_790_000_000.0

    def __call__(self):
        return self.now


clock = Clock()
store = tse.TuiStatusStore(clock=clock, pid_alive=lambda pid: True)

PERMISSION_REQ = {"id": "per_abc1", "kind": "permission", "permission": "bash",
                  "patterns": ["ls *"], "always": ["ls *"], "detail": f"ls {SENTINEL}"}
QUESTION_REQ = {"id": "que_abc1", "kind": "question", "questions": [
    {"question": "Which db?", "header": "DB", "multiple": False, "custom": True,
     "options": [{"label": "sqlite", "description": "file"}, {"label": "pg"}]}]}


def oc_event(event, request=None, **extra):
    body = {"tool": "opencode", "event": event, "sessionId": "ses_1", "pid": 4242, "cwd": "/scratch/proj",
            "paneId": "w1:p9", "serverUrl": "http://127.0.0.1:4999"}
    if request:
        body["request"] = request
    body.update(extra)
    return store.ingest(body)


print("ingest: the plugin's request is kept, bounded, and cleared")
oc_event("permission.asked", PERMISSION_REQ, title="bash")
entry = store.entry_for("opencode", "ses_1")
check("permission request stored", (entry["prompt"], entry["request"]["id"], entry["request"]["always"]),
      ("permission", "per_abc1", ["ls *"]))
oc_event("permission.replied", requestId="per_other")
check("a reply for another id keeps it", store.entry_for("opencode", "ses_1")["request"] is not None, True)
oc_event("permission.replied", requestId="per_abc1")
entry = store.entry_for("opencode", "ses_1")
check("its own reply clears it", (entry["request"], entry["status"]), (None, "working"))
oc_event("permission.v2.asked", {**PERMISSION_REQ, "id": "per_v2"})
check("v2 event family is understood", store.entry_for("opencode", "ses_1")["request"]["id"], "per_v2")
oc_event("session.idle")
check("idle clears a stale request", store.entry_for("opencode", "ses_1")["request"], None)
oc_event("question.asked", QUESTION_REQ)
check("question request stored", store.entry_for("opencode", "ses_1")["request"]["questions"][0]["options"][0],
      {"label": "sqlite", "description": "file"})
oc_event("question.asked", {"id": "bad id!", "kind": "question", "questions": []})
check("malformed request -> none offered", store.entry_for("opencode", "ses_1")["request"], None)
oc_event("question.asked", {"id": "que_x", "kind": "question", "questions": [{"nope": 1}]})
check("question without text -> none offered", store.entry_for("opencode", "ses_1")["request"], None)
oc_event("permission.asked", {**PERMISSION_REQ, "patterns": ["x" * 5000] * 50})
check("lists and strings are bounded", (len(store.entry_for("opencode", "ses_1")["request"]["patterns"]),
                                        len(store.entry_for("opencode", "ses_1")["request"]["patterns"][0])), (20, 300))

print("views: hookRequest shape on the row")
oc_event("permission.asked", PERMISSION_REQ, title="bash")
entries = store.fresh_entries()
view = tui_answers.request_view(entries[0], clock.now, {})
check("opencode permission view", (view["requestId"], view["kind"], view["tool"], view["toolName"]),
      ("tuioc-per_abc1", "permission", "opencode", "bash"))
check("permission detail + one 'always' suggestion",
      (view["permission"]["detail"], view["permission"]["suggestions"]),
      (f"ls {SENTINEL}", [{"index": 0, "label": "Always allow ls *"}]))
oc_event("question.asked", QUESTION_REQ)
view = tui_answers.request_view(store.fresh_entries()[0], clock.now, {})
check("opencode question view", (view["requestId"], view["kind"], view["questions"][0]["multiSelect"],
                                 [o["label"] for o in view["questions"][0]["options"]]),
      ("tuioc-que_abc1", "question", False, ["sqlite", "pg"]))
oc_event("question.asked", {**QUESTION_REQ, "questions": [{**QUESTION_REQ["questions"][0], "options": []}]})
check("text-only question has no card (nothing to render)", tui_answers.request_view(store.fresh_entries()[0], clock.now, {}), None)

rows = [{"agentKind": "opencode", "tuiSessionId": "ses_1", "tuiPrompt": "question", "paneId": "w1:p9"},
        {"agentKind": "opencode", "tuiSessionId": "ses_1", "tuiPrompt": None, "paneId": "w1:p8"},
        {"agentKind": "codex", "tuiSessionId": "nope", "tuiPrompt": "permission", "paneId": "w1:p7"}]
oc_event("question.asked", QUESTION_REQ)
tui_answers.attach_requests(rows, store.fresh_entries(), clock.now, hold_views={})
check("only the matching pending row gets hookRequest", [bool(r.get("hookRequest")) for r in rows], [True, False, False])

print("codex: held request wins; keystroke request only with pane + command")
codex_body = {"tool": "codex", "event": "PermissionRequest", "sessionId": "cx-1", "pid": 4343,
              "cwd": "/scratch/work", "paneId": "w1:p16", "title": "Bash: touch scratch-marker-2.txt",
              "detail": "touch scratch-marker-2.txt"}
store.ingest(codex_body)
cx = [e for e in store.fresh_entries() if e["tool"] == "codex"][0]
kx = tui_answers.request_view(cx, clock.now, {})
check("keystroke view", (kx["kind"], kx["tool"], kx["viaPane"], kx["permission"]["suggestions"],
                         kx["requestId"].startswith("tuikx-"), kx["requestId"].endswith("-cx-1")), ("permission", "codex", True, [], True, True))
held = {"requestId": "tuicx1-aa", "kind": "permission", "tool": "codex"}
check("a held hook request outranks it", tui_answers.request_view(cx, clock.now, {"cx-1": held}), held)
store.ingest({**codex_body, "sessionId": "cx-2", "paneId": None})
cx2 = [e for e in store.fresh_entries() if e["sessionId"] == "cx-2"][0]
check("no pane -> no keystroke card", tui_answers.request_view(cx2, clock.now, {}), None)
store.ingest({**codex_body, "sessionId": "cx-3", "detail": None})
cx3 = [e for e in store.fresh_entries() if e["sessionId"] == "cx-3"][0]
check("no command text -> no keystroke card", tui_answers.request_view(cx3, clock.now, {}), None)
check("owns() ids", [tui_answers.owns(i) for i in ("tuioc-x", "tuikx-a-b", "tuicx1-aa", "hp1-aa", None)],
      [True, True, True, False, False])


print("dispatch: unknown / stale ids are refused")
res, status = tui_answers.answer("tuioc-per_zzz", {"behavior": "allow"}, store=store)
check("unknown opencode id -> 409", (status, res["ok"]), (409, False))
res, status = tui_answers.answer("tuikx-deadbeef-cx-1", {"behavior": "allow"}, store=store)
check("keystroke id with a changed command hash -> 409", (status, res["ok"]), (409, False))
check("not ours -> 404", tui_answers.answer("hp1-x", {}, store=store)[1], 404)

print("keystroke path against a fake pane")


class FakePane:
    def __init__(self, frames, panes=("w1:p16",)):
        self.frames, self.panes, self.sent, self.reads = list(frames), set(panes), [], 0

    def read(self, pane_id, lines):
        self.reads += 1
        return self.frames[min(self.reads - 1, len(self.frames) - 1)]

    def io(self):
        return {"read_pane": self.read, "send_keys": lambda pane, *keys: self.sent.append((pane, keys)),
                "list_panes": lambda: self.panes, "settle_sec": 0, "sleep": lambda s: None}


OPEN, IDLE = screen("codex_permission.txt"), screen("codex_idle.txt")
ENTRY = {"paneId": "w1:p16", "detail": "touch scratch-marker-2.txt"}

pane = FakePane([OPEN, IDLE])
res, status = cpa.answer(ENTRY, {"behavior": "allow"}, **pane.io())
check("allow: 'y' sent after the open prompt is confirmed", (status, pane.sent), (200, [("w1:p16", ("y",))]))
pane = FakePane([OPEN, IDLE])
res, status = cpa.answer(ENTRY, {"behavior": "deny"}, **pane.io())
check("deny: esc", (status, pane.sent), (200, [("w1:p16", ("esc",))]))
pane = FakePane([IDLE])
res, status = cpa.answer(ENTRY, {"behavior": "allow"}, **pane.io())
check("stale prompt (screen idle) -> 409 answered, no key", (status, pane.sent, "already answered" in res["error"]), (409, [], True))
pane = FakePane([OPEN, IDLE], panes=("w1:p1",))
res, status = cpa.answer(ENTRY, {"behavior": "allow"}, **pane.io())
check("pane gone from herdr -> refused, no key", (status, pane.sent), (409, []))
pane = FakePane([OPEN, IDLE])
res, status = cpa.answer(ENTRY, {"behavior": "allow", "paneId": "w1:p2"}, **pane.io())
check("wrong pane id from the row -> 400, no key", (status, pane.sent), (400, []))
pane = FakePane([OPEN, IDLE])
res, status = cpa.answer({**ENTRY, "paneId": None}, {"behavior": "allow"}, **pane.io())
check("entry without a pane -> 400", (status, pane.sent), (400, []))
pane = FakePane([OPEN, IDLE])
res, status = cpa.answer({**ENTRY, "detail": "rm scratch-other.txt"}, {"behavior": "allow"}, **pane.io())
check("different command on screen -> refused, no key", (status, pane.sent), (409, []))
pane = FakePane([OPEN, IDLE])
res, status = cpa.answer({**ENTRY, "detail": None}, {"behavior": "allow"}, **pane.io())
check("no command known -> refused", (status, pane.sent), (409, []))
pane = FakePane([OPEN, IDLE])
res, status = cpa.answer({**ENTRY, "detail": SENTINEL}, {"behavior": "allow"}, **pane.io())
check("sentinel command is only ever compared, never run", (status, pane.sent), (409, []))
pane = FakePane([OPEN, OPEN])
res, status = cpa.answer(ENTRY, {"behavior": "allow"}, **pane.io())
check("key did not land (prompt still open) -> 502", (status, len(pane.sent)), (502, 1))
pane = FakePane([OPEN, IDLE])
res, status = cpa.answer(ENTRY, {"behavior": "allow", "suggestionIndex": 0}, **pane.io())
check("'always allow' never sent by keystroke", (status, pane.sent), (400, []))
res, status = cpa.answer(ENTRY, {"behavior": "sure"}, **FakePane([OPEN, IDLE]).io())
check("bad behavior -> 400", status, 400)
pane = FakePane([screen("opencode_question.txt")])
res, status = cpa.answer(ENTRY, {"behavior": "allow"}, **pane.io())
check("an OpenCode question on the pane is not a Codex permission", (status, pane.sent), (409, []))
pane = FakePane([screen("codex_trust.txt"), IDLE])
res, status = cpa.answer(ENTRY, {"behavior": "allow"}, **pane.io())
check("a trust picker is not a permission", (status, pane.sent), (409, []))

print("through tui_answers with the fake pane wired in")
fake = FakePane([OPEN, IDLE])
tui_answers.PANE_IO.update(fake.io())
rows = [{"agentKind": "codex", "tuiSessionId": "cx-1", "tuiPrompt": "permission", "paneId": "w1:p16"}]
tui_answers.attach_requests(rows, store.fresh_entries(), clock.now, hold_views={})
request_id = rows[0]["hookRequest"]["requestId"]
res, status = tui_answers.answer(request_id, {"behavior": "deny"}, store=store)
check("answer by the id the row carried", (status, fake.sent), (200, [("w1:p16", ("esc",))]))

print("stale keystroke card: a newer screen reading shows no prompt")
for label, state, since, age, want in (
        ("screen says WAITING, read after the prompt began -> card dropped", "WAITING", 30, 10, False),
        ("screen read BEFORE the prompt began -> card kept", "WAITING", 5, 10, True),
        ("screen still shows a prompt -> card kept", "BLOCKED", 30, 10, True),
        ("no sweep age known -> card kept", "WAITING", 30, None, True)):
    stale_rows = [{"agentKind": "codex", "tuiSessionId": "cx-1", "tuiPrompt": "permission", "paneId": "w1:p16",
                   "screenState": state, "hookSinceSec": since}]
    tui_answers.attach_requests(stale_rows, store.fresh_entries(), clock.now, hold_views={}, screen_read_age=age)
    check(label, "hookRequest" in stale_rows[0], want)

if fails:
    print(f"\nFAIL: {len(fails)} failure(s)")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("\nPASS: all tui_answers checks")
