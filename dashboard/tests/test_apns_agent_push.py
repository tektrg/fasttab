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
           "identity": None, "detail": "x", "questionPreview": {"question": text}}
    row.update(extra)
    return row


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
pusher.observe(state([agent(working=True)]))
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
pusher.observe(state([agent(working=True)]))
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

print("ALL PASS" if not FAILED else f"{len(FAILED)} FAILED")
sys.exit(1 if FAILED else 0)
