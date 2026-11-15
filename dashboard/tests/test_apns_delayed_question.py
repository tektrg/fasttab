#!/usr/bin/env python3
"""apns_delayed_question: delayed needs-you push — fake clock, fake send,
temp store. SAFETY: no APNs, no network, never the real dashboard or store.
Run: python3 tests/test_apns_delayed_question.py"""
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "server", "lib"))
import apns_delayed_question as d  # noqa: E402

FAILED = []
TMP = tempfile.mkdtemp(prefix="apns-delay-test-")


def check(label, got, want):
    ok = got == want
    print(f"  {'PASS' if ok else 'FAIL'}  {label}" + ("" if ok else f": got {got!r}, want {want!r}"))
    if not ok:
        FAILED.append(label)


class Clock:
    def __init__(self, now=1000.0):
        self.now = now

    def __call__(self):
        return self.now


def wait(key="s1", text="Which DB?"):
    return {key: {"payload": {"summary": text, "agentKey": key}, "collapseId": f"question-{key}"}}


def make(store=None, clock=None, delay=1200, **kw):
    clock = clock or Clock()
    sent = []
    sched = d.DelayedQuestionScheduler(store if store is not None else d.MemoryStore(),
                                       send=lambda p, c: sent.append((p, c)), clock=clock,
                                       delay_sec=delay, log=lambda m: None, **kw)
    return sched, sent, clock


def run(sched, clock, open_waits, seconds, step=5):
    end = clock.now + seconds
    while clock.now < end:
        clock.now += step
        sched.observe(open_waits)


print("setting")
check("default 20 min", d.DEFAULT_DELAY_SEC, 1200)
check("delay_from with nothing set", d.delay_from(env={}), 1200.0)
check("env override", d.delay_from(env={d.DELAY_ENV: "60"}), 60.0)
cfg = os.path.join(TMP, "apns.json")
with open(cfg, "w") as f:
    json.dump({"questionDelaySec": 300}, f)
check("apns.json questionDelaySec", d.delay_from(env={}, apns_config_path=cfg), 300.0)
check("env beats config", d.delay_from(env={d.DELAY_ENV: "60"}, apns_config_path=cfg), 60.0)
check("junk env falls back", d.delay_from(env={d.DELAY_ENV: "soon"}), 1200.0)
check("dry run flag", (d.dry_run_from({d.DRY_RUN_ENV: "1"}), d.dry_run_from({})), (True, False))
with open(cfg, "w") as f:
    json.dump({"questionPushDryRun": True}, f)
check("dry run via apns.json", d.dry_run_from({}, apns_config_path=cfg), True)

print("fires once after the delay")
sched, sent, clock = make()
sched.observe(wait())
run(sched, clock, wait(), 1195)
check("not before the delay", sent, [])
run(sched, clock, wait(), 10)
check("one push at the delay", len(sent), 1)
check("payload + collapse id", sent[0], ({"summary": "Which DB?", "agentKey": "s1"}, "question-s1"))
run(sched, clock, wait(), 3600)
check("never repeats while still open", len(sent), 1)

print("answered before the delay -> dropped")
sched, sent, clock = make()
sched.observe(wait())
run(sched, clock, wait(), 600)
run(sched, clock, {}, 1200)
check("no push", sent, [])
check("wait forgotten", sched.waits, {})

print("gone at fire time (inside grace) -> no push then")
sched, sent, clock = make(delay=60)
sched.observe(wait())
run(sched, clock, wait(), 55)
clock.now += 10
sched.observe({})
check("absent snapshot never fires", sent, [])

print("new question restarts the timer")
sched, sent, clock = make()
sched.observe(wait())
run(sched, clock, wait(), 900)
run(sched, clock, {}, 30)  # answered: agent works, row gone past the grace
run(sched, clock, wait(text="Next one?"), 900)
check("not after 1800s total (timer restarted)", sent, [])
run(sched, clock, wait(text="Next one?"), 310)
check("fires 1200s after the new question", [p["summary"] for p, _ in sent], ["Next one?"])

print("blip inside the grace keeps the same wait")
sched, sent, clock = make()
sched.observe(wait())
run(sched, clock, wait(), 600)
run(sched, clock, {}, 10)
run(sched, clock, wait(), 600)
check("one push, on the original timer", len(sent), 1)

print("independent agents")
sched, sent, clock = make()
both = {**wait("a"), **wait("b")}
sched.observe(both)
run(sched, clock, wait("a"), 1300)
check("only the one still open", [p["agentKey"] for p, _ in sent], ["a"])

print("restart recovery (JSON store)")
path = os.path.join(TMP, "pending.json")
store = d.JsonStore(path)
sched, sent, clock = make(store=store)
sched.observe({**wait("open"), **wait("closed"), **wait("done")})
run(sched, clock, {**wait("done"), **wait("open"), **wait("closed")}, 1300)
check("pre-crash push for all three", len(sent), 3)
sent.clear()
sched2, sent2, clock2 = make(store=d.JsonStore(path), clock=Clock(clock.now))
check("sent marks survived", all(w["sent"] for w in sched2.waits.values()), True)
run(sched2, clock2, wait("done"), 3600)
check("already-sent wait not re-sent after restart", sent2, [])

with open(path, "w") as f:
    json.dump({"version": 1, "waits": {
        "overdue": {"openedAt": 0, "dueAt": 1200, "sent": False, "lastSeen": 900,
                    "payload": {"summary": "Overdue?"}, "collapseId": "question-overdue"},
        "gone": {"openedAt": 0, "dueAt": 1200, "sent": False, "lastSeen": 900,
                 "payload": {"summary": "Gone?"}, "collapseId": "question-gone"},
        "warming": {"openedAt": 0, "dueAt": 99999, "sent": False, "lastSeen": 900,
                    "payload": {"summary": "Later?"}, "collapseId": "question-warming"}}}, f)
sched3, sent3, clock3 = make(store=d.JsonStore(path), clock=Clock(5000))
sched3.observe(wait("overdue"))
check("overdue + still open fires once at first look (live text)", [p["summary"] for p, _ in sent3], ["Which DB?"])
check("absent waits kept during startup grace (feeds warming)", sorted(sched3.waits), ["gone", "overdue", "warming"])
run(sched3, clock3, wait("overdue"), 120)
check("still exactly one", len(sent3), 1)
check("closed-while-down dropped after grace", sorted(sched3.waits), ["overdue"])
check("store matches", sorted(json.load(open(path))["waits"]), ["overdue"])

print("at-most-once: sent mark is on disk before the send runs")
path2 = os.path.join(TMP, "crash.json")
on_disk_at_send = []
clock4 = Clock()
sched4 = d.DelayedQuestionScheduler(
    d.JsonStore(path2), clock=clock4, delay_sec=0, log=lambda m: None,
    send=lambda p, c: on_disk_at_send.append(json.load(open(path2))["waits"]["s1"]["sent"]))
sched4.observe(wait())
check("store said sent=True when send ran", on_disk_at_send, [True])


class CrashingSend(Exception):
    pass


def crash(p, c):
    raise CrashingSend()


path3 = os.path.join(TMP, "crash2.json")
s5 = d.DelayedQuestionScheduler(d.JsonStore(path3), send=crash, clock=Clock(), delay_sec=0, log=lambda m: None)
try:
    s5.observe(wait())
except CrashingSend:
    pass
again = []
s6 = d.DelayedQuestionScheduler(d.JsonStore(path3), send=lambda p, c: again.append(p), clock=Clock(1010),
                                delay_sec=0, log=lambda m: None)
s6.observe(wait())
check("crash mid-send -> restart does not send again", again, [])

print("dry run logs, never sends")
logs = []
sched7 = d.DelayedQuestionScheduler(d.MemoryStore(), send=lambda p, c: FAILED.append("dry run sent"),
                                    clock=Clock(), delay_sec=0, dry_run=True, log=logs.append)
due = sched7.observe(wait())
check("due reported", due, ["s1"])
check("dry-run line logged", any("DRY RUN" in m for m in logs), True)

print("missing / corrupt store -> empty, no crash")
check("missing", d.JsonStore(os.path.join(TMP, "nope.json")).load(), {})
bad = os.path.join(TMP, "bad.json")
open(bad, "w").write("{not json")
check("corrupt", d.JsonStore(bad).load(), {})

print()
print("FAILED: " + ", ".join(FAILED) if FAILED else "all passed")
sys.exit(1 if FAILED else 0)
