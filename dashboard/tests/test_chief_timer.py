#!/usr/bin/env python3
"""Direct-run tests for chief_timer.ChiefTimer (rollout items 13-14): a
chief is woken on schedule, once per slot, deferred mid-turn, caught up
once after a Mac sleep; settings change the schedule. Fake clock + fake
sender + temp state file; never a real session."""
import json
import os
import sys
import tempfile
import threading
from datetime import datetime, timedelta, timezone

LIB = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib")
sys.path.insert(0, LIB)

import chief_checkin as cc  # noqa: E402
import chief_timer  # noqa: E402

fails = []
TZ = timezone(timedelta(hours=7))


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def ts(d, h, mi=0):
    return datetime(2026, 11, d, h, mi, tzinfo=TZ).timestamp()


class Clock:
    def __init__(self, t):
        self.t = t

    def __call__(self):
        return self.t


def make_chief(**over):
    chief = {"key": "ssv-shared/digital", "name": "digital", "rowId": "cli-chief",
             "briefPath": "/p/brief.md", "session": {"desktopSessionId": "local_x"},
             "activity": "idle", "transcriptPath": None,
             "config": {"checkin_cron": "7 8-19/2 * * 1-6", "wake": "on"}}
    chief.update(over)
    return chief


def harness(chiefs, now, send_result=None):
    tmp = tempfile.mkdtemp()
    sent = []

    def send(row_id, text):
        sent.append((row_id, text))
        return send_result if send_result is not None else {"ok": True, "state": "message sent"}
    clock = Clock(now)
    timer = chief_timer.ChiefTimer(os.path.join(tmp, "chief-checkins.json"), lambda: chiefs, send,
                                   now=clock, tz=TZ, transcript_reader=lambda *a: ([], None))
    return timer, sent, clock, tmp


print("woken on schedule, once per slot")
chiefs = [make_chief()]
timer, sent, clock, tmp = harness(chiefs, ts(28, 10, 0))
v = timer.tick()["ssv-shared/digital"]
check("Sat 10:00, 08:07 slot current, no check-in -> one wake", len(sent), 1)
check("  woke for the 08:07 slot", datetime.fromtimestamp(v["lastWake"]["dueAt"], TZ).strftime("%H:%M"), "08:07")
check("  message carries the marker", sent[0][1].startswith(cc.WAKE_MARKER), True)
check("  sent to the chief's row", sent[0][0], "cli-chief")
check("  recorded delivered", v["lastWake"]["result"], "delivered")
timer.tick()
clock.t = ts(28, 10, 5)
timer.tick()
check("no second wake for the same slot (3 ticks)", len(sent), 1)
clock.t = ts(28, 10, 8)
timer.tick()
check("10:08: next slot -> one more wake", len(sent), 2)

print("heartbeat stops the wake")
timer, sent, clock, _ = harness([make_chief()], ts(28, 12, 0))
timer.record_heartbeat("ssv-shared/digital", at=ts(28, 11, 0), source="pass")
timer.tick()
check("12:00 with a check-in at 11:00 -> 10:07 slot covered, no wake", len(sent), 0)
clock.t = ts(28, 12, 8)
v = timer.tick()["ssv-shared/digital"]
check("12:08 with no check-in since 11:00 -> wake", len(sent), 1)
check("  lastCheckInSource pass", v["lastCheckInSource"], "pass")

print("mid-turn chief: defer, then wake once when idle")
chief = make_chief(activity="busy")
timer, sent, clock, _ = harness([chief], ts(28, 10, 10))
v = timer.tick()["ssv-shared/digital"]
check("busy -> nothing sent", len(sent), 0)
check("  shown as deferred", (v["lastWake"]["result"], v["lastWake"]["reason"]), ("deferred", "chief is mid-turn"))
clock.t = ts(28, 10, 11)
timer.tick()
check("still busy -> still nothing (no stacking)", len(sent), 0)
chief["activity"] = "idle"
clock.t = ts(28, 10, 20)
timer.tick()
timer.tick()
check("idle -> exactly one wake", len(sent), 1)

print("Mac asleep: catch up once, not N times")
timer, sent, clock, _ = harness([make_chief()], ts(30, 7, 50))
timer.record_heartbeat("ssv-shared/digital", at=ts(28, 18, 30))
timer.tick()
check("Mon 07:50 (before window): nothing", len(sent), 0)
clock.t = ts(30, 14, 50)  # slept through 08:07, 10:07, 12:07, 14:07
timer.tick()
timer.tick()
check("after wake-up: one wake (latest slot only)", len(sent), 1)

print("wake off (default) -> tracked + shown, never sent")
timer, sent, clock, _ = harness([make_chief(config={"checkin_cron": "7 8-19/2 * * 1-6"})], ts(28, 10, 40))
v = timer.tick()["ssv-shared/digital"]
check("no send", len(sent), 0)
check("still overdue", (v["state"], v["wakeEnabled"]), ("overdue", False))

print("chief gone / no schedule / bad schedule")
timer, sent, clock, _ = harness([make_chief(session=None)], ts(28, 10, 40))
check("gone -> state gone, no send", (timer.tick()["ssv-shared/digital"]["state"], len(sent)), ("gone", 0))
timer, sent, clock, _ = harness([make_chief(config={"wake": "on"})], ts(28, 10, 40))
check("no cron -> no-schedule", timer.tick()["ssv-shared/digital"]["state"], "no-schedule")
timer, sent, clock, _ = harness([make_chief(config={"wake": "on", "checkin_cron": "nope"})], ts(28, 10, 40))
v = timer.tick()["ssv-shared/digital"]
check("bad cron -> no-schedule + error shown", (v["state"], bool(v["scheduleError"])), ("no-schedule", True))

print("failure is state; retry once after the wait")
timer, sent, clock, _ = harness([make_chief()], ts(28, 10, 10), send_result={"ok": False, "error": "NOT_LANDED"})
v = timer.tick()["ssv-shared/digital"]
check("failed recorded with reason", (v["lastWake"]["result"], v["lastWake"]["reason"]), ("failed", "NOT_LANDED"))
clock.t = ts(28, 10, 15)
timer.tick()
check("no retry before 10 min", len(sent), 1)
clock.t = ts(28, 10, 21)
timer.tick()
clock.t = ts(28, 10, 40)
timer.tick()
check("one retry, then gives up (2 attempts)", len(sent), 2)

print("crash mid-send: never sent twice")
timer, sent, clock, tmp = harness([make_chief()], ts(28, 10, 10))
state_path = os.path.join(tmp, "chief-checkins.json")
due = cc.evaluate(ts(28, 10, 10), cc.parse_cron("7 8-19/2 * * 1-6"), tz=TZ)["dueAt"]
with open(state_path, "w") as f:
    json.dump({"ssv-shared/digital": {"wake": {"dueAt": due, "attempts": 1, "result": "sending",
                                                "lastAttemptAt": ts(28, 10, 9)}}}, f)
timer2 = chief_timer.ChiefTimer(state_path, lambda: [make_chief()], lambda r, t: sent.append(r) or {"ok": True},
                                now=clock, tz=TZ, transcript_reader=lambda *a: ([], None))
clock.t = ts(28, 10, 40)
timer2.tick()
check("restart sees 'sending' -> no resend", len(sent), 0)

print("single-flight: concurrent ticks wake once")
gate = threading.Event()
sent = []


def slow_send(row_id, text):
    sent.append(row_id)
    gate.wait(2)
    return {"ok": True}


tmp = tempfile.mkdtemp()
clock = Clock(ts(28, 10, 10))
timer = chief_timer.ChiefTimer(os.path.join(tmp, "s.json"), lambda: [make_chief()], slow_send,
                               now=clock, tz=TZ, transcript_reader=lambda *a: ([], None))
threads = [threading.Thread(target=timer.tick) for _ in range(5)]
for t in threads:
    t.start()
gate.set()
for t in threads:
    t.join()
timer.tick()
check("5 concurrent ticks + 1 -> one send", len(sent), 1)

print("grace from config")
timer, sent, clock, _ = harness([make_chief(config={"checkin_cron": "7 8-19/2 * * 1-6", "checkin_grace_min": "30"})],
                                ts(28, 10, 25))
check("grace 30 -> due at 10:25", timer.tick()["ssv-shared/digital"]["state"], "due")
timer, sent, clock, _ = harness([make_chief(config={"checkin_cron": "7 8-19/2 * * 1-6", "checkin_grace_min": "x"})],
                                ts(28, 10, 25))
check("bad grace -> default 10 -> overdue", timer.tick()["ssv-shared/digital"]["state"], "overdue")

print("multiple chiefs are independent")
a = make_chief()
b = make_chief(key="aaa/ops", rowId="cli-ops", config={"checkin_cron": "0 9 * * *", "wake": "on"})
timer, sent, clock, _ = harness([a, b], ts(28, 10, 10))
timer.tick()
check("both woken", sorted(r for r, _ in sent), ["cli-chief", "cli-ops"])

print("settings change the schedule (pace / quiet / sleep-time)")
timer, sent, clock, _ = harness([make_chief()], ts(28, 21, 0))
v = timer.view(make_chief())
check("default steady, sleep off", (v["pace"], v["sleepCheckins"], v["schedule"]),
      ("steady", False, "every 2h, 08:07-19:59, Mon-Sat"))
check("21:00 Sat -> next Mon 08:07", datetime.fromtimestamp(v["nextDueAt"], TZ).strftime("%a %H:%M"), "Mon 08:07")
settings, err = timer.update_settings("ssv-shared/digital", sleep_checkins=True)
v = timer.view(make_chief())
check("sleep on -> next 22:07", datetime.fromtimestamp(v["nextDueAt"], TZ).strftime("%a %H:%M"), "Sat 22:07")
timer.tick()
check("sleep on -> 20:07 slot current -> wake", len(sent), 1)
timer.update_settings("ssv-shared/digital", pace="rush")
check("rush -> hourly", timer.view(make_chief())["schedule"], "every 1h, around the clock")
timer.update_settings("ssv-shared/digital", pace="quiet")
clock.t = ts(28, 23, 30)
v = timer.tick()["ssv-shared/digital"]
check("quiet -> no wakes, no next", (v["state"], v["nextDueAt"], len(sent)), ("quiet", None, 1))
check("bad pace refused", timer.update_settings("ssv-shared/digital", pace="fast")[1] is not None, True)
check("bad sleep value refused", timer.update_settings("ssv-shared/digital", sleep_checkins="yes")[1] is not None, True)
reloaded = chief_timer.ChiefTimer(timer.state_path, lambda: [], lambda *a: None)
check("settings persist across restart", reloaded.settings_for("ssv-shared/digital"),
      {"pace": "quiet", "sleepCheckins": True})

print("check-in in progress (started, not ended) -> not overdue")
tmp = tempfile.mkdtemp()
tpath2 = os.path.join(tmp, "t2.jsonl")
with open(tpath2, "w") as f:
    f.write(json.dumps({"type": "user", "timestamp": "2026-11-28T03:25:00Z",
                        "message": {"content": "7-Eleven fleet check-in. Read"}}) + "\n")
clock = Clock(ts(28, 10, 50))
timer = chief_timer.ChiefTimer(os.path.join(tmp, "s.json"),
                               lambda: [make_chief(transcriptPath=tpath2, config={"checkin_cron": "7 8-19/2 * * 1-6",
                                        "checkin_marker": "7-Eleven fleet check-in", "wake": "on"})],
                               lambda r, t: {"ok": True}, now=clock, tz=TZ)
v = timer.tick()["ssv-shared/digital"]
check("running since 10:25 -> ok, shown running", (v["state"], bool(v["checkInRunningSince"])), ("ok", True))

print("transcript heartbeat feeds the timer")
tmp = tempfile.mkdtemp()
tpath = os.path.join(tmp, "t.jsonl")
with open(tpath, "w") as f:
    f.write(json.dumps({"type": "user", "timestamp": "2026-11-28T03:07:30Z",
                        "message": {"content": "[Chief check-in] Scheduled"}}) + "\n")
    f.write(json.dumps({"type": "system", "subtype": "stop_hook_summary",
                        "timestamp": "2026-11-28T03:12:00Z"}) + "\n")
sent = []
clock = Clock(ts(28, 10, 30))
timer = chief_timer.ChiefTimer(os.path.join(tmp, "s.json"), lambda: [make_chief(transcriptPath=tpath)],
                               lambda r, t: sent.append(r) or {"ok": True}, now=clock, tz=TZ)
v = timer.tick()["ssv-shared/digital"]
check("  startedAt kept", datetime.fromtimestamp(timer._state["ssv-shared/digital"]["heartbeat"]["startedAt"], TZ)
      .strftime("%H:%M:%S"), "10:07:30")
check("check-in 10:07-10:12 local -> ok, no wake",
      (v["state"], v["lastCheckInSource"], len(sent)), ("ok", "transcript", 0))

if fails:
    print("\nFAILED:\n  " + "\n  ".join(fails))
    sys.exit(1)
print("\nAll chief_timer tests passed.")
