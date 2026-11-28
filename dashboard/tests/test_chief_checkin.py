#!/usr/bin/env python3
"""Direct-run tests for chief_checkin.py (schedule, pace, overdue, wake
decision, transcript heartbeat). Pure: fixed clock, fixed timezone."""
import json
import os
import sys
import tempfile
from datetime import datetime, timedelta, timezone

LIB = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib")
sys.path.insert(0, LIB)

import chief_checkin as cc  # noqa: E402

fails = []
TZ = timezone(timedelta(hours=7))  # Vietnam, no DST


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def ts(y, mo, d, h, mi=0):
    return datetime(y, mo, d, h, mi, tzinfo=TZ).timestamp()


def hm(t):
    return datetime.fromtimestamp(t, TZ).strftime("%a %H:%M") if t else None


DIGITAL = cc.parse_cron("7 8-19/2 * * 1-6")

print("parse_cron")
check("digital", DIGITAL, {"intervalMin": 120, "anchorMin": 487, "windowStartMin": 480,
                           "windowEndMin": 1199, "days": [1, 2, 3, 4, 5, 6]})
check("hourly all day", cc.parse_cron("0 * * * *")["intervalMin"], 60)
check("once a day", cc.parse_cron("30 9 * * *")["intervalMin"], 1440)
check("sunday as 0", cc.parse_cron("0 9 * * 0")["days"], [7])
check("list days", cc.parse_cron("0 9 * * 1,3,5")["days"], [1, 3, 5])
for bad in ["", "7 8-19/2 1 * *", "*/5 * * * *", "7 19-8 * * *", "7 8-19/2 * * 1-9", "x y z a b"]:
    try:
        cc.parse_cron(bad)
        check(f"rejects {bad!r}", "accepted", "ScheduleError")
    except cc.ScheduleError:
        check(f"rejects {bad!r}", True, True)

print("describe")
check("steady", cc.describe(DIGITAL, "steady", False), "every 2h, 08:07-19:59, Mon-Sat")
check("rush", cc.describe(DIGITAL, "rush", False), "every 1h, 08:07-19:59, Mon-Sat")
check("pace-out", cc.describe(DIGITAL, "pace-out", False), "every 4h, 08:07-19:59, Mon-Sat")
check("quiet", cc.describe(DIGITAL, "quiet", False), "quiet: no check-ins")
check("sleep on", cc.describe(DIGITAL, "steady", True), "every 2h, around the clock")
check("none", cc.describe(None, "steady", False), "no schedule")

# 2026-11-28 is a Saturday; 11-29 Sunday; 11-30 Monday.
print("evaluate: slots + pace")
e = cc.evaluate(ts(2026, 11, 28, 9, 0), DIGITAL, heartbeat_ts=ts(2026, 11, 28, 8, 30), tz=TZ)
check("09:00 Sat after 08:30 check-in: ok", e["state"], "ok")
check("  next 10:07", hm(e["nextDueAt"]), "Sat 10:07")
check("  due slot 08:07", hm(e["dueAt"]), "Sat 08:07")
e = cc.evaluate(ts(2026, 11, 28, 10, 12), DIGITAL, heartbeat_ts=ts(2026, 11, 28, 8, 30), tz=TZ)
check("10:12 no check-in since 08:30: due", (e["state"], e["overdueSec"]), ("due", 0))
e = cc.evaluate(ts(2026, 11, 28, 10, 47), DIGITAL, heartbeat_ts=ts(2026, 11, 28, 8, 30), tz=TZ)
check("10:47: overdue 40m", (e["state"], e["overdueSec"]), ("overdue", 2400))
e = cc.evaluate(ts(2026, 11, 28, 10, 47), DIGITAL, heartbeat_ts=ts(2026, 11, 28, 9, 50), tz=TZ)
check("check-in 17m early counts for the slot", e["state"], "ok")
e = cc.evaluate(ts(2026, 11, 28, 10, 47), DIGITAL, heartbeat_ts=ts(2026, 11, 28, 9, 0), tz=TZ)
check("check-in 67m early does not", e["state"], "overdue")
e = cc.evaluate(ts(2026, 11, 28, 10, 30), DIGITAL, pace="rush", heartbeat_ts=ts(2026, 11, 28, 10, 8), tz=TZ)
check("rush: next 11:07", hm(e["nextDueAt"]), "Sat 11:07")
e = cc.evaluate(ts(2026, 11, 28, 10, 30), DIGITAL, pace="pace-out", heartbeat_ts=None, tz=TZ)
check("pace-out: slots 08:07,12:07 -> 10:30 has current slot 08:07, overdue", (hm(e["dueAt"]), e["state"]),
      ("Sat 08:07", "overdue"))
check("pace-out: next 12:07", hm(e["nextDueAt"]), "Sat 12:07")
e = cc.evaluate(ts(2026, 11, 28, 10, 30), DIGITAL, pace="quiet", tz=TZ)
check("quiet: no due, no next", (e["state"], e["dueAt"], e["nextDueAt"]), ("quiet", None, None))

print("evaluate: across the sleep window / weekend / Mac asleep")
e = cc.evaluate(ts(2026, 11, 28, 21, 0), DIGITAL, heartbeat_ts=ts(2026, 11, 28, 15, 0), tz=TZ)
check("Sat 21:00, missed 18:07 (> interval ago): history, not overdue", (e["state"], e["dueAt"]), ("ok", None))
check("  next = Monday 08:07 (Sunday off)", hm(e["nextDueAt"]), "Mon 08:07")
e = cc.evaluate(ts(2026, 11, 28, 21, 0), DIGITAL, sleep_checkins=True, heartbeat_ts=ts(2026, 11, 28, 15, 0), tz=TZ)
check("sleep on: Sat 20:07 slot is current -> overdue", (hm(e["dueAt"]), e["state"]), ("Sat 20:07", "overdue"))
check("  next 22:07", hm(e["nextDueAt"]), "Sat 22:07")
e = cc.evaluate(ts(2026, 11, 29, 3, 0), DIGITAL, sleep_checkins=True, heartbeat_ts=ts(2026, 11, 29, 2, 10), tz=TZ)
check("sleep on: Sunday 02:07 slot counted", (hm(e["dueAt"]), e["state"]), ("Sun 02:07", "ok"))
# Mac slept 08:00 -> 14:50: slots 08:07..14:07 all passed; only 14:07 is current.
e = cc.evaluate(ts(2026, 11, 30, 14, 50), DIGITAL, heartbeat_ts=ts(2026, 11, 28, 18, 30), tz=TZ)
check("after Mac sleep: only latest slot (14:07) is current", (hm(e["dueAt"]), e["state"]), ("Mon 14:07", "overdue"))

print("evaluate: start covers the slot; grace")
e = cc.evaluate(ts(2026, 11, 28, 11, 0), DIGITAL, heartbeat_ts=ts(2026, 11, 28, 8, 50),
                started_ts=ts(2026, 11, 28, 10, 25), tz=TZ)
check("check-in started 10:25, still running -> ok", e["state"], "ok")
e = cc.evaluate(ts(2026, 11, 28, 10, 20), DIGITAL, heartbeat_ts=ts(2026, 11, 28, 8, 50), tz=TZ)
check("10:20 default grace 10m -> overdue", e["state"], "overdue")
e = cc.evaluate(ts(2026, 11, 28, 10, 20), DIGITAL, heartbeat_ts=ts(2026, 11, 28, 8, 50), grace_sec=1800, tz=TZ)
check("10:20 grace 30m -> due", e["state"], "due")

print("evaluate: gone / no schedule")
check("gone", cc.evaluate(ts(2026, 11, 28, 10, 30), DIGITAL, chief_gone=True, tz=TZ)["state"], "gone")
check("no schedule", cc.evaluate(ts(2026, 11, 28, 10, 30), None, tz=TZ)["state"], "no-schedule")

print("decide_wake")
NOW = ts(2026, 11, 28, 10, 12)
due_ev = cc.evaluate(NOW, DIGITAL, heartbeat_ts=None, tz=TZ)
D = due_ev["dueAt"]
check("wake off -> none", cc.decide_wake(due_ev, wake_enabled=False, chief_activity="idle", wake_record=None, now_ts=NOW)[0], "none")
check("due + idle -> wake", cc.decide_wake(due_ev, wake_enabled=True, chief_activity="idle", wake_record=None, now_ts=NOW)[0], "wake")
check("due + sleeping -> wake", cc.decide_wake(due_ev, wake_enabled=True, chief_activity="sleeping", wake_record=None, now_ts=NOW)[0], "wake")
check("busy -> defer", cc.decide_wake(due_ev, wake_enabled=True, chief_activity="busy", wake_record=None, now_ts=NOW)[0], "defer")
check("waiting -> defer", cc.decide_wake(due_ev, wake_enabled=True, chief_activity="waiting", wake_record=None, now_ts=NOW)[0], "defer")
check("delivered this slot -> none", cc.decide_wake(due_ev, wake_enabled=True, chief_activity="idle",
      wake_record={"dueAt": D, "result": "delivered", "attempts": 1}, now_ts=NOW)[0], "none")
check("sending this slot (crash mid-send) -> none", cc.decide_wake(due_ev, wake_enabled=True, chief_activity="idle",
      wake_record={"dueAt": D, "result": "sending", "attempts": 1}, now_ts=NOW)[0], "none")
check("failed 2m ago -> none (retry wait)", cc.decide_wake(due_ev, wake_enabled=True, chief_activity="idle",
      wake_record={"dueAt": D, "result": "failed", "attempts": 1, "lastAttemptAt": NOW - 120}, now_ts=NOW)[0], "none")
check("failed 11m ago -> wake (retry)", cc.decide_wake(due_ev, wake_enabled=True, chief_activity="idle",
      wake_record={"dueAt": D, "result": "failed", "attempts": 1, "lastAttemptAt": NOW - 660}, now_ts=NOW)[0], "wake")
check("failed twice -> gave up", cc.decide_wake(due_ev, wake_enabled=True, chief_activity="idle",
      wake_record={"dueAt": D, "result": "failed", "attempts": 2, "lastAttemptAt": NOW - 3000}, now_ts=NOW)[0], "none")
check("delivered for an OLDER slot -> wake", cc.decide_wake(due_ev, wake_enabled=True, chief_activity="idle",
      wake_record={"dueAt": D - 7200, "result": "delivered", "attempts": 1}, now_ts=NOW)[0], "wake")
ok_ev = cc.evaluate(ts(2026, 11, 28, 9, 0), DIGITAL, heartbeat_ts=ts(2026, 11, 28, 8, 30), tz=TZ)
check("ok -> none", cc.decide_wake(ok_ev, wake_enabled=True, chief_activity="idle", wake_record=None, now_ts=NOW)[0], "none")

print("wake_text")
text = cc.wake_text(D, "/x/brief.md", tz=TZ)
check("starts with marker", text.startswith(cc.WAKE_MARKER), True)
check("one line, no slash", ("\n" in text, text.startswith("/")), (False, False))
check("names due + brief", ("10:07" in text, "/x/brief.md" in text), (True, True))


print("transcript heartbeat")
def line(**kw):
    return json.dumps(kw)


lines = [
    line(type="user", timestamp="2026-11-28T01:25:48Z", message={"content": "hello"}),
    line(type="system", subtype="stop_hook_summary", timestamp="2026-11-28T01:26:00Z"),
    line(type="user", timestamp="2026-11-28T03:25:48Z", message={"content": "7-Eleven fleet check-in. Read brief"}),
    line(type="assistant", timestamp="2026-11-28T03:26:10Z", message={"stop_reason": "tool_use"}),
    line(type="user", timestamp="2026-11-28T03:26:11Z", message={"content": [{"type": "tool_result", "content": "x"}]}),
    line(type="system", subtype="stop_hook_summary", timestamp="2026-11-28T03:30:00Z"),
    line(type="user", timestamp="2026-11-28T05:25:00Z",
         message={"content": [{"type": "text", "text": "Another Claude session sent a message: [Chief check-in] due"}]}),
]
done, pending = cc.scan_lines(lines, [cc.WAKE_MARKER, "7-Eleven fleet check-in"])
check("one completed check-in: (start, turn end)",
      [tuple(datetime.fromtimestamp(t, timezone.utc).strftime("%H:%M") for t in c) for c in done], [("03:25", "03:30")])
check("second check-in still pending", pending is not None, True)
done2, pending2 = cc.scan_lines([line(type="assistant", timestamp="2026-11-28T05:40:00Z",
                                      message={"stop_reason": "end_turn"})], [cc.WAKE_MARKER], pending)
check("pending completes across calls (end_turn)",
      [datetime.fromtimestamp(c[1], timezone.utc).strftime("%H:%M") for c in done2], ["05:40"])
check("  nothing pending after", pending2, None)
check("garbage lines ignored", cc.scan_lines(["{", "[]", "null"], ["x"]), ([], None))

with tempfile.TemporaryDirectory() as tmp:
    path = os.path.join(tmp, "t.jsonl")
    with open(path, "w") as f:
        f.write("\n".join(lines[:6]) + "\n")
    done, cur = cc.read_transcript_heartbeats(path, ["7-Eleven fleet check-in"], None)
    check("file read: one completion", len(done), 1)
    done, cur2 = cc.read_transcript_heartbeats(path, ["7-Eleven fleet check-in"], cur)
    check("re-read with cursor: nothing new", (done, cur2["offset"]), ([], cur["offset"]))
    with open(path, "a") as f:
        f.write(lines[2] + "\n" + line(type="system", subtype="stop_hook_summary", timestamp="2026-11-28T07:00:00Z") + "\n"
                + '{"type":"user","partial')
    done, cur3 = cc.read_transcript_heartbeats(path, ["7-Eleven fleet check-in"], cur2)
    check("appended check-in found; partial last line left for later", len(done), 1)
    check("  offset stops before the partial line", cur3["offset"] < os.path.getsize(path), True)
    with open(path, "w") as f:
        f.write(lines[0] + "\n")
    done, cur4 = cc.read_transcript_heartbeats(path, ["x"], cur3)
    check("file shrank: restart, no crash", (done, cur4["offset"]), ([], os.path.getsize(path)))

if fails:
    print("\nFAILED:\n  " + "\n  ".join(fails))
    sys.exit(1)
print("\nAll chief_checkin tests passed.")
