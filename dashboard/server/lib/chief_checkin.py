#!/usr/bin/env python3
"""Chief check-in schedule math + heartbeat reading. Pure (no clock, no
filesystem) except `read_transcript_heartbeats`.

Chief redesign rollout item 13. The dashboard owns the check-in TIMER
(chief_timer.py); this module answers, for one chief at one instant:
when was its last check-in, when is the next one due, is it overdue, and
should the timer wake it now.

SCHEDULE
--------
A chief's base schedule comes from its `config.yaml` `checkin_cron`, a
small cron subset (5 fields; day-of-month and month must be `*`):
    minute  : one number                       (7)
    hour    : `A-B/S`, `A-B`, `*/S`, `*`, `H`  (8-19/2)
    dow     : `*`, `A-B`, `a,b,c` (0 or 7 = Sunday)
Digital's `7 8-19/2 * * 1-6` = 08:07, 10:07 ... 18:07, Monday-Saturday.
It is held as {intervalMin, anchorMin, windowStartMin, windowEndMin, days}.

PACE (set in AgentBar, stored by the dashboard)
------------------------------------------------
Multiplies the interval: rush x0.5, steady x1, pace-out x2, quiet = no
check-ins at all (no due, no overdue, no wakes). Slots restart from the
anchor each active day: anchor, anchor + paced, ... up to the window end.

SLEEP-TIME CHECK-INS (default off)
-----------------------------------
On = slots run around the clock, every day (anchor's minute-of-day modulo
the paced interval, then every paced interval). Off = only in the window,
only on the schedule's days.

STATE (one owner: `evaluate`)
------------------------------
`D` = the latest slot <= now. It is CURRENT while now - D < the paced
interval (after a Mac sleep or overnight, an older slot is history, never
caught up: catch up once, not N times).
    no-schedule | gone | quiet | ok | due | overdue
  * ok      : no current slot, or a check-in at/after D - EARLY_TOLERANCE
              (a chief that checked in a little early is not woken again).
  * due     : current slot missed, less than the grace ago (GRACE_SEC, or
              the chief's `checkin_grace_min`: a cron-driven chief whose
              scheduler fires late needs more).
  * overdue : current slot missed for the grace or more.
  A check-in covers a slot by its START (a pass may run an hour; one still
  running is not overdue).

HEARTBEAT = the chief's last COMPLETED check-in (its end time; its start
is kept too): a user line in its
transcript carrying a check-in marker (the timer's own `[Chief check-in]`,
plus the chief's `checkin_marker`, e.g. Digital's cron prompt
"7-Eleven fleet check-in") followed by the end of that turn (a
`stop_hook_summary` system line, or an assistant line with stop_reason
end_turn). Also: a `GET /api/chief/pass?chief=<key>` call (chief_timer).
"""
import json
import re
from datetime import datetime, timedelta

PACES = {"rush": 0.5, "steady": 1.0, "pace-out": 2.0, "quiet": None}
DEFAULT_PACE = "steady"
#: Never wake more often than this, whatever the pace.
MIN_INTERVAL_MIN = 15
#: A missed slot reads "due" for this long, then "overdue".
GRACE_SEC = 10 * 60
#: Max attempts per slot, and the wait before retrying a FAILED one.
MAX_WAKE_ATTEMPTS = 2
WAKE_RETRY_SEC = 10 * 60
#: The marker every timer wake message starts with.
WAKE_MARKER = "[Chief check-in]"
#: Only the first N chars of a user line are searched for a marker.
_MARKER_SCAN_CHARS = 400
_DAY_NAMES = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]


class ScheduleError(ValueError):
    pass


# ── schedule ───────────────────────────────────────────────────────────────

def parse_cron(expr):
    """Cron subset -> schedule dict. Raises ScheduleError on anything else."""
    fields = (expr or "").split()
    if len(fields) != 5:
        raise ScheduleError(f"expected 5 cron fields, got {len(fields)}: {expr!r}")
    minute_f, hour_f, dom_f, mon_f, dow_f = fields
    if dom_f != "*" or mon_f != "*":
        raise ScheduleError("day-of-month and month must be *")
    if not minute_f.isdigit() or not 0 <= int(minute_f) <= 59:
        raise ScheduleError(f"minute must be one number 0-59: {minute_f!r}")
    minute = int(minute_f)

    step = None
    hour_range = hour_f
    if "/" in hour_f:
        hour_range, step_s = hour_f.split("/", 1)
        if not step_s.isdigit() or not 1 <= int(step_s) <= 23:
            raise ScheduleError(f"bad hour step: {hour_f!r}")
        step = int(step_s)
    if hour_range == "*":
        start, end = 0, 23
    elif re.fullmatch(r"\d{1,2}-\d{1,2}", hour_range):
        start, end = (int(x) for x in hour_range.split("-"))
    elif re.fullmatch(r"\d{1,2}", hour_range) and step is None:
        start = end = int(hour_range)
    else:
        raise ScheduleError(f"unsupported hour field: {hour_f!r}")
    if not (0 <= start <= end <= 23):
        raise ScheduleError(f"hour range out of order: {hour_f!r}")
    if start == end and step is None:
        interval = 24 * 60
    else:
        interval = (step or 1) * 60

    days = _parse_dow(dow_f)
    return {"intervalMin": interval, "anchorMin": start * 60 + minute,
            "windowStartMin": start * 60, "windowEndMin": end * 60 + 59,
            "days": sorted(days)}


def _parse_dow(field):
    """ISO weekdays (1=Mon..7=Sun)."""
    if field == "*":
        return set(range(1, 8))
    out = set()
    for part in field.split(","):
        if re.fullmatch(r"\d-\d", part):
            a, b = (int(x) for x in part.split("-"))
            if a > b:
                raise ScheduleError(f"day range out of order: {part!r}")
            nums = range(a, b + 1)
        elif re.fullmatch(r"\d", part):
            nums = [int(part)]
        else:
            raise ScheduleError(f"unsupported day-of-week: {field!r}")
        for n in nums:
            if n > 7:
                raise ScheduleError(f"day-of-week out of range: {n}")
            out.add(7 if n == 0 else n)
    return out


def paced_interval_min(schedule, pace):
    mult = PACES.get(pace)
    if mult is None:
        return None
    return max(MIN_INTERVAL_MIN, int(round(schedule["intervalMin"] * mult)))


def describe(schedule, pace, sleep_checkins):
    """Plain-English schedule: "every 2h, 08:07-19:59, Mon-Sat"."""
    if not schedule:
        return "no schedule"
    paced = paced_interval_min(schedule, pace)
    if paced is None:
        return "quiet: no check-ins"
    every = f"{paced // 60}h" if paced % 60 == 0 else (
        f"{paced}m" if paced < 60 else f"{paced // 60}h{paced % 60:02d}")
    if sleep_checkins:
        return f"every {every}, around the clock"
    start = _hhmm(schedule["anchorMin"])
    end = _hhmm(schedule["windowEndMin"])
    return f"every {every}, {start}-{end}, {_describe_days(schedule['days'])}"


def _hhmm(minutes):
    return f"{minutes // 60:02d}:{minutes % 60:02d}"


def _describe_days(days):
    days = sorted(days)
    if days == list(range(1, 8)):
        return "every day"
    if days == list(range(days[0], days[-1] + 1)) and len(days) > 2:
        return f"{_DAY_NAMES[days[0] - 1]}-{_DAY_NAMES[days[-1] - 1]}"
    return ",".join(_DAY_NAMES[d - 1] for d in days)


def _day_slot_minutes(schedule, pace, sleep_checkins, iso_weekday):
    """Minutes-after-midnight of every slot on one day (sorted)."""
    paced = paced_interval_min(schedule, pace)
    if paced is None:
        return []
    if sleep_checkins:
        first = schedule["anchorMin"] % paced
        return list(range(first, 24 * 60, paced))
    if iso_weekday not in schedule["days"]:
        return []
    return list(range(schedule["anchorMin"], schedule["windowEndMin"] + 1, paced))


def _slots_around(now_ts, schedule, pace, sleep_checkins, tz=None):
    """(latest slot ts <= now, earliest slot ts > now), either may be None
    (no slot within 8 days). Local wall-clock (`tz` for tests; None = this
    Mac's zone)."""
    now = datetime.fromtimestamp(now_ts, tz)
    midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    prev_ts = next_ts = None
    for back in range(0, 9):
        day = midnight - timedelta(days=back)
        mins = _day_slot_minutes(schedule, pace, sleep_checkins, day.isoweekday())
        cands = [(day + timedelta(minutes=m)).timestamp() for m in mins]
        cands = [c for c in cands if c <= now_ts]
        if cands:
            prev_ts = max(cands)
            break
    for fwd in range(0, 9):
        day = midnight + timedelta(days=fwd)
        mins = _day_slot_minutes(schedule, pace, sleep_checkins, day.isoweekday())
        cands = [(day + timedelta(minutes=m)).timestamp() for m in mins]
        cands = [c for c in cands if c > now_ts]
        if cands:
            next_ts = min(cands)
            break
    return prev_ts, next_ts


def early_tolerance_sec(paced_min):
    """A check-in this long before a slot still counts for it."""
    return min(30 * 60, paced_min * 60 // 4)


def evaluate(now_ts, schedule, *, pace=DEFAULT_PACE, sleep_checkins=False,
             heartbeat_ts=None, started_ts=None, chief_gone=False, grace_sec=GRACE_SEC, tz=None):
    """The ONE status owner for a chief's check-in. Returns
    {state, dueAt, nextDueAt, overdueSec, current, pacedIntervalMin}.

    `heartbeat_ts` = last COMPLETED check-in's end; `started_ts` = the
    latest check-in's START (completed or still running). A slot is covered
    by a check-in that STARTED in time — a pass can run an hour, and a
    running one is not overdue."""
    out = {"state": "ok", "dueAt": None, "nextDueAt": None, "overdueSec": 0,
           "current": False, "pacedIntervalMin": None}
    if chief_gone:
        out["state"] = "gone"
        return out
    if not schedule:
        out["state"] = "no-schedule"
        return out
    paced = paced_interval_min(schedule, pace)
    if paced is None:
        out["state"] = "quiet"
        return out
    out["pacedIntervalMin"] = paced
    prev_ts, next_ts = _slots_around(now_ts, schedule, pace, sleep_checkins, tz)
    out["nextDueAt"] = next_ts
    if prev_ts is None or now_ts - prev_ts >= paced * 60:
        return out  # no CURRENT slot: the last one is history
    out["dueAt"] = prev_ts
    out["current"] = True
    covered_by = max((t for t in (heartbeat_ts, started_ts) if t is not None), default=None)
    if covered_by is not None and covered_by >= prev_ts - early_tolerance_sec(paced):
        return out
    late = now_ts - prev_ts
    out["state"] = "due" if late < grace_sec else "overdue"
    out["overdueSec"] = int(late) if out["state"] == "overdue" else 0
    return out


def decide_wake(evaluation, *, wake_enabled, chief_activity, wake_record, now_ts):
    """("wake" | "defer" | "none", reason). Single-flight per slot: a slot
    gets at most MAX_WAKE_ATTEMPTS sends, a retry only after a FAILED one
    and WAKE_RETRY_SEC; once delivered, never again for that slot.
    `chief_activity`: "busy" (mid-turn) | "waiting" (a prompt is pending
    on the user) | "idle" | "sleeping"."""
    if not wake_enabled:
        return "none", "wake off (dashboard only tracks this chief)"
    if evaluation["state"] not in ("due", "overdue") or not evaluation["current"]:
        return "none", evaluation["state"]
    due = evaluation["dueAt"]
    rec = wake_record or {}
    if rec.get("dueAt") == due:
        if rec.get("result") in ("delivered", "sending"):
            return "none", f"already {rec.get('result')} for this slot"
        if (rec.get("attempts") or 0) >= MAX_WAKE_ATTEMPTS:
            return "none", "gave up on this slot"
        if now_ts - (rec.get("lastAttemptAt") or 0) < WAKE_RETRY_SEC:
            return "none", "waiting to retry"
    if chief_activity == "busy":
        return "defer", "chief is mid-turn"
    if chief_activity == "waiting":
        return "defer", "chief is waiting on you"
    return "wake", "due"


def wake_text(due_ts, brief_path, tz=None):
    """The one-line wake message (no slash command: the inbox refuses one)."""
    due = datetime.fromtimestamp(due_ts, tz).strftime("%H:%M")
    brief = f"re-read {brief_path}, " if brief_path else ""
    return (f"{WAKE_MARKER} Scheduled check-in (due {due}), sent by the agent dashboard timer. "
            f"Run your check-in pass now: {brief}refresh the roster, give each idle worker its "
            f"next step, verify done claims, then update the brief.")


# ── heartbeat from a transcript ────────────────────────────────────────────

def _iso_ts(value):
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _user_text(entry):
    if entry.get("type") != "user":
        return ""
    content = (entry.get("message") or {}).get("content")
    if isinstance(content, list):
        parts = [p.get("text", "") for p in content
                 if isinstance(p, dict) and p.get("type") == "text"]
        content = " ".join(parts)
    return content if isinstance(content, str) else ""


def _ends_turn(entry):
    if entry.get("type") == "system" and entry.get("subtype") == "stop_hook_summary":
        return True
    if entry.get("type") == "assistant":
        return (entry.get("message") or {}).get("stop_reason") == "end_turn"
    return False


def scan_lines(lines, markers, pending_ts=None):
    """Walk transcript lines (str) in order. Returns (completions,
    pending_ts): completion = (start ts, end ts) of a marked check-in turn.
    `pending_ts` carries a check-in that started but hasn't ended across
    calls (an in-progress check-in)."""
    markers = [m for m in markers if m]
    completions = []
    for line in lines:
        try:
            entry = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(entry, dict):
            continue
        text = _user_text(entry)
        if text:
            head = text[:_MARKER_SCAN_CHARS]
            if any(m in head for m in markers):
                pending_ts = _iso_ts(entry.get("timestamp")) or pending_ts
            continue
        if pending_ts is not None and _ends_turn(entry):
            completions.append((pending_ts, _iso_ts(entry.get("timestamp")) or pending_ts))
            pending_ts = None
    return completions, pending_ts


#: First read of a transcript: only its tail (bytes).
FIRST_READ_BYTES = 4 * 1024 * 1024


def read_transcript_heartbeats(path, markers, cursor, *, opener=open, size_of=None):
    """Incremental read of one transcript. `cursor` = {"path", "offset",
    "pending"} from the last call (or None). Returns (completions, cursor).
    A new path, or a file that shrank, restarts from the tail."""
    import os
    size = (size_of or (lambda p: os.stat(p).st_size))(path)
    cur = dict(cursor or {})
    if cur.get("path") != path or (cur.get("offset") or 0) > size:
        cur = {"path": path, "offset": max(0, size - FIRST_READ_BYTES), "pending": None,
               "skipPartial": size > FIRST_READ_BYTES}
    offset = cur["offset"]
    if offset >= size:
        return [], cur
    with opener(path, "rb") as f:
        f.seek(offset)
        data = f.read(size - offset)
    last_nl = data.rfind(b"\n")
    if last_nl < 0:
        return [], cur  # no complete line yet
    chunk = data[:last_nl + 1]
    lines = chunk.decode("utf-8", errors="replace").splitlines()
    if cur.pop("skipPartial", False) and lines:
        lines = lines[1:]  # a mid-file tail start cuts its first line
    completions, pending = scan_lines(lines, markers, cur.get("pending"))
    cur.update(offset=offset + len(chunk), pending=pending)
    return completions, cur
