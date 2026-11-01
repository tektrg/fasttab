"""apns_agent_push: question / finished pushes — dedupe, cooldown, path,
no-device no-op. Run: python3 tests/test_apns_agent_push.py"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "server", "lib"))
import apns_agent_push as agent_push  # noqa: E402
import apns_fan_out  # noqa: E402
import apns_permission_push as _pp  # noqa: E402
_pp.PERMISSION_PUSH_ENABLED = True  # held-agent skip is tested with the push on
agent_push.FINISHED_PUSH_ENABLED = True  # finished logic is tested with the push on (off in production)

FAILED = []


def check(label, got, want):
    ok = got == want
    print(f"  {'PASS' if ok else 'FAIL'}  {label}" + ("" if ok else f": got {got!r}, want {want!r}"))
    if not ok:
        FAILED.append(label)


class FakeFanOut:
    def __init__(self, reachable=True):
        self.reachable, self.sent = reachable, []

    def can_reach_device(self):
        return self.reachable

    def send(self, build, collapse_id, background=False):
        self.sent.append((build(), collapse_id))


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


def agent(session="s1", working=False, **extra):
    a = {"agentSession": session, "paneId": f"p-{session}", "label": f"agent-{session}",
         "machine": "local", "hasHookData": True, "hookState": "working" if working else "idle",
         "hookSinceSec": 1, "screenState": None, "screenSignal": "last line"}
    a.update(extra)
    return a


def state(agents, needs_you=()):
    return {"computed": {"agents": list(agents), "needsYou": list(needs_you)}}


def question_row(session="s1", text="Which DB?", **extra):
    row = {"kind": "question", "label": f"agent-{session}", "paneId": f"p-{session}",
           "identity": None, "detail": "x", "questionPreview": {"question": text},
           "waitReason": "question"}
    row.update(extra)
    return row


def work(pusher, clock, **extra):
    """A real turn: working across NEW_TURN_WORKING_SEC, not a one-pass blip."""
    pusher.observe(state([agent(working=True, **extra)]))
    clock.now += agent_push.NEW_TURN_WORKING_SEC + 1
    pusher.observe(state([agent(working=True, **extra)]))


def make(reachable=True, last_message="All done: tests pass"):
    fan, clock = FakeFanOut(reachable), Clock()
    pusher = agent_push.AgentEventPusher(fan_out=fan, clock=clock, last_message=lambda sid: last_message)
    return pusher, fan, clock


print("path helper")
check("path for session", apns_fan_out.agent_path("abc-1"), "/?agent=abc-1")
check("path encodes pane key", apns_fan_out.agent_path("pane:w1:p2"), "/?agent=pane%3Aw1%3Ap2")
check("path unknown", apns_fan_out.agent_path(None), "/")

print("no device -> no-op, state never computed")
pusher, fan, _ = make(reachable=False)
calls = []
pusher.tick(lambda: calls.append(1) or state([agent()], [question_row()]))
check("get_state not called", calls, [])
check("nothing sent", fan.sent, [])

print("first observation primes only")
pusher, fan, clock = make()
pusher.observe(state([agent()], [question_row()]))
check("no push for pre-existing question", fan.sent, [])

print("question: one push per turn, dedupe on flapping")
pusher, fan, clock = make()
pusher.observe(state([agent()]))
pusher.observe(state([agent()], [question_row()]))
check("one push", len(fan.sent), 1)
payload, collapse = fan.sent[0]
check("category", payload["aps"]["category"], "AGENT_MESSAGE")
check("event", payload["event"], "question")
check("body = question", payload["aps"]["alert"]["body"], "Which DB?")
check("path", payload["path"], "/?agent=s1")
check("agentKey", payload["agentKey"], "s1")
check("collapse id <= 64", len(collapse) <= 64, True)
pusher.observe(state([agent()]))
pusher.observe(state([agent()], [question_row()]))
check("flap: still one push", len(fan.sent), 1)
pusher.observe(state([agent()], [question_row(text="Another?")]))
check("reworded question, same wait: still one push", len(fan.sent), 1)
pusher.observe(state([agent(working=True)]))  # hook spinner blip while held
pusher.observe(state([agent()], [question_row()]))
check("working blip mid-question: still one push", len(fan.sent), 1)
work(pusher, clock)
pusher.observe(state([agent()], [question_row()]))
pushed = [p["event"] for p, _ in fan.sent]
check("same question in a new turn pushes again", pushed.count("question"), 2)

print("question skipped while a permission push owns the agent")
pusher, fan, _ = make()
pusher.observe(state([agent()]))
pusher.observe(state([agent()], [question_row(kind="blocked", hookRequest={"id": "hp1"})]))
check("no push", fan.sent, [])

print("body truncated to 240")
pusher, fan, _ = make()
pusher.observe(state([agent()]))
pusher.observe(state([agent()], [question_row(text="y" * 500)]))
check("240 chars", len(fan.sent[0][0]["summary"]), 240)

print("finished: working -> idle, cooldown, dedupe")
pusher, fan, clock = make()
pusher.observe(state([agent(working=True)]))
pusher.observe(state([agent()]))
check("one finished push", len(fan.sent), 1)
check("finished body = last message", fan.sent[0][0]["summary"], "All done: tests pass")
check("finished path", fan.sent[0][0]["path"], "/?agent=s1")
check("finished subtitle", fan.sent[0][0]["aps"]["alert"]["subtitle"], "Finished")
clock.now += 10
pusher.observe(state([agent(working=True)]))
pusher.observe(state([agent()]))
check("within cooldown: no push", len(fan.sent), 1)
clock.now += 61
work(pusher, clock)
pusher.observe(state([agent()]))
check("after cooldown: pushes", len(fan.sent), 2)
pusher.observe(state([agent()]))
check("staying idle: no push", len(fan.sent), 2)

print("finished skipped with an open permission prompt")
pusher, fan, _ = make()
pusher.observe(state([agent(working=True)]))
pusher.observe(state([agent(hookRequest={"id": "hp1"})]))
check("no push", fan.sent, [])

print("finished falls back to screen line")
pusher, fan, _ = make(last_message=None)
pusher.observe(state([agent(working=True)]))
pusher.observe(state([agent()]))
check("screen line body", fan.sent[0][0]["summary"], "last line")

print("permission push carries path + agentKey")
import apns_permission_push  # noqa: E402
alert = apns_permission_push.permission_alert("hp1", {"tool_name": "Bash", "tool_input": {"command": "ls"},
                                                      "cwd": "/x/chief", "session_id": "sess-9"})
check("permission path", alert["path"], "/?agent=sess-9")
check("permission agentKey", alert["agentKey"], "sess-9")
alert = apns_permission_push.permission_alert("hp2", {"tool_name": "Bash", "tool_input": {}, "cwd": "/x"})
check("permission path without session", alert["path"], "/")

print("agent stops working because it asks: one question push, no finished")
pusher, fan, clock = make()
pusher.observe(state([agent()]))
pusher.observe(state([agent(working=True)]))
pusher.observe(state([agent()], [question_row()]))
check("only the question", [p["event"] for p, _ in fan.sent], ["question"])

print("reasons: subtitle + userInfo reason + body")
def one_push(row, permission_push=True):
    _pp.PERMISSION_PUSH_ENABLED = permission_push
    try:
        pusher, fan, _ = make()
        pusher.observe(state([agent()]))
        pusher.observe(state([agent()], [row]))
        return fan.sent
    finally:
        _pp.PERMISSION_PUSH_ENABLED = True
sent = one_push(question_row())
check("question subtitle", sent[0][0]["aps"]["alert"]["subtitle"], "Asked a question")
check("question reason", (sent[0][0]["event"], sent[0][0]["reason"]), ("question", "question"))
sent = one_push(question_row(kind="blocked", questionPreview=None, waitReason="question",
                             wrapUpQuestion={"ask": "Ship it?"}))
check("wrap-up ask body", sent[0][0]["summary"], "Ship it?")
hook = {"kind": "permission", "permission": {"title": "Bash", "detail": "npm test"}}
sent = one_push(question_row(kind="blocked", questionPreview=None, hookRequest=hook,
                             waitReason="approval"), permission_push=False)
check("hook approval subtitle", sent[0][0]["aps"]["alert"]["subtitle"], "Needs approval")
check("hook approval body = command", sent[0][0]["summary"], "Bash: npm test")
check("approval event stays question", (sent[0][0]["event"], sent[0][0]["reason"]), ("question", "approval"))
sent = one_push(question_row(kind="blocked", questionPreview=None, waitReason="approval",
                             permission={"tool": "Bash", "detail": "rm build.log"}))
check("screen box body = tool + command", sent[0][0]["summary"], "Bash: rm build.log")
sent = one_push(question_row(kind="blocked", questionPreview=None, waitReason="approval", permission=None,
                             detail="Claude needs your permission to use Bash"))
check("notice approval body", sent[0][0]["summary"], "Claude needs your permission to use Bash")
sent = one_push(question_row(kind="blocked", questionPreview=None, waitReason="login",
                             detail="not logged in — run /login in this pane"))
check("login subtitle", (sent[0][0]["aps"]["alert"]["subtitle"], sent[0][0]["reason"]), ("Needs login", "login"))
sent = one_push(question_row(kind="blocked", questionPreview=None, waitReason=None,
                             detail="Claude is waiting for your input"))
check("idle nudge: no push", sent, [])

print("idle nudge after a turn: finished push, not a question")
pusher, fan, _ = make()
pusher.observe(state([agent(working=True)]))
pusher.observe(state([agent()], [question_row(kind="blocked", questionPreview=None, waitReason=None,
                                              detail="Claude is waiting for your input")]))
check("only finished", [(p["event"], p["reason"]) for p, _ in fan.sent], [("finished", None)])

print("finished pushes are off by default")
import importlib  # noqa: E402
check("default off", importlib.reload(agent_push).FINISHED_PUSH_ENABLED, False)
pusher, fan, _ = make()
pusher.observe(state([agent(working=True)]))
pusher.observe(state([agent()]))
check("no finished push", fan.sent, [])

print("ALL PASS" if not FAILED else f"{len(FAILED)} FAILED")
sys.exit(1 if FAILED else 0)
