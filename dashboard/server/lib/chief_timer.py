#!/usr/bin/env python3
"""The dashboard's chief check-in TIMER (rollout item 13): per chief, the
heartbeat (last completed check-in), the schedule state, and the wake.

ONE OWNER. `ChiefTimer` is the only writer of `chief-checkins.json` (state
dir) and the only sender of wake messages; it runs one tick at a time
(`_tick_lock`), so two ticks can never wake the same chief twice. Status
math is chief_checkin.evaluate / decide_wake (pure, tested headless).

Per chief (`<project>/<name>` key) the store keeps:
    settings  : {"pace", "sleepCheckins"}   - set from AgentBar
    heartbeat : {"at", "startedAt", "source"} - "transcript" | "pass"
    cursor    : transcript read position     - chief_checkin.read_transcript_heartbeats
    wake      : {"dueAt", "attempts", "lastAttemptAt", "result", "reason"}
                result: sending | delivered | failed | deferred

SINGLE-FLIGHT ACROSS A CRASH: the wake record is written as `sending`
BEFORE the message goes out, so a dashboard that dies mid-send never sends
that slot again on restart (a lost wake is shown, a double wake can't
happen).

WAKE IS OPT-IN PER CHIEF (`config.yaml` `wake: on`). Default off: the
dashboard tracks + shows the check-in (next / last / overdue) but sends
nothing — Digital keeps its own cron until rollout item 15 switches it.
"""
import json
import os
import tempfile
import threading
import time

import chief_checkin

STATE_FILE_NAME = "chief-checkins.json"
TICK_SEC = 60
#: A marked check-in with no turn end after this long is not "running".
RUNNING_MAX_SEC = 3 * 3600
#: Wake sender result: {"ok": bool, "error"/"reason": str}.


def _atomic_write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".chief-checkins.")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=1, sort_keys=True)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


class ChiefTimer:
    """`chiefs_provider()` -> [chief dict] (chief_roster.build_desktop_chiefs
    output, each also carrying `rowId` + `activity`: busy|waiting|idle|sleeping,
    and `transcriptPath`). `send(row_id, text)` -> result dict. `now` and
    `tz` are injectable for tests."""

    def __init__(self, state_path, chiefs_provider, send, *, now=time.time, tz=None,
                 transcript_reader=chief_checkin.read_transcript_heartbeats):
        self.state_path = state_path
        self._chiefs_provider = chiefs_provider
        self._send = send
        self._now = now
        self._tz = tz
        self._read_transcript = transcript_reader
        self._lock = threading.Lock()       # guards self._state
        self._tick_lock = threading.Lock()  # one tick at a time (single-flight)
        self._state = self._load()
        self._last_view = {}

    # ── store ──
    def _load(self):
        try:
            with open(self.state_path) as f:
                data = json.load(f)
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def _save(self):
        _atomic_write_json(self.state_path, self._state)

    def _entry(self, key):
        return self._state.setdefault(key, {})

    # ── settings (AgentBar) ──
    def settings_for(self, key):
        with self._lock:
            s = dict((self._state.get(key) or {}).get("settings") or {})
        return {"pace": s.get("pace") if s.get("pace") in chief_checkin.PACES else chief_checkin.DEFAULT_PACE,
                "sleepCheckins": bool(s.get("sleepCheckins", False))}

    def update_settings(self, key, pace=None, sleep_checkins=None):
        """Persist; returns (settings, error). Unknown pace -> error, nothing written."""
        if pace is not None and pace not in chief_checkin.PACES:
            return None, f"pace must be one of {', '.join(chief_checkin.PACES)}"
        if sleep_checkins is not None and not isinstance(sleep_checkins, bool):
            return None, "sleepCheckins must be true or false"
        with self._lock:
            settings = dict(self._entry(key).get("settings") or {})
            if pace is not None:
                settings["pace"] = pace
            if sleep_checkins is not None:
                settings["sleepCheckins"] = sleep_checkins
            self._entry(key)["settings"] = settings
            self._save()
        return self.settings_for(key), None

    # ── heartbeat ──
    def record_heartbeat(self, key, at=None, source="pass"):
        at = self._now() if at is None else at
        with self._lock:
            hb = self._entry(key).get("heartbeat") or {}
            if (hb.get("at") or 0) < at:
                self._entry(key)["heartbeat"] = {"at": at, "startedAt": at, "source": source}
                self._save()

    def _refresh_transcript_heartbeat(self, chief):
        path = chief.get("transcriptPath")
        if not path:
            return
        markers = [chief_checkin.WAKE_MARKER, (chief.get("config") or {}).get("checkin_marker")]
        with self._lock:
            cursor = (self._state.get(chief["key"]) or {}).get("cursor")
        try:
            completions, cursor = self._read_transcript(path, markers, cursor)
        except OSError:
            return
        with self._lock:
            entry = self._entry(chief["key"])
            changed = entry.get("cursor") != cursor
            entry["cursor"] = cursor
            hb = entry.get("heartbeat") or {}
            if completions:
                start, end = max(completions, key=lambda c: c[1])
                if end > (hb.get("at") or 0):
                    entry["heartbeat"] = {"at": end, "startedAt": start, "source": "transcript"}
                    changed = True
            if changed:
                self._save()

    # ── evaluate one chief (pure over stored state) ──
    def _schedule_of(self, chief):
        cron = (chief.get("config") or {}).get("checkin_cron")
        if not cron:
            return None, None
        try:
            return chief_checkin.parse_cron(cron), None
        except chief_checkin.ScheduleError as e:
            return None, str(e)

    def view(self, chief, now_ts=None):
        """The `checkIn` object AgentBar + the web UI show for one chief."""
        now_ts = self._now() if now_ts is None else now_ts
        key = chief["key"]
        settings = self.settings_for(key)
        schedule, schedule_error = self._schedule_of(chief)
        with self._lock:
            entry = dict(self._state.get(key) or {})
        hb = entry.get("heartbeat") or {}
        in_progress_since = (entry.get("cursor") or {}).get("pending")
        if in_progress_since and now_ts - in_progress_since > RUNNING_MAX_SEC:
            in_progress_since = None  # a turn that never ended (interrupted): not running
        ev = chief_checkin.evaluate(
            now_ts, schedule, pace=settings["pace"], sleep_checkins=settings["sleepCheckins"],
            heartbeat_ts=hb.get("at"),
            started_ts=max((t for t in (hb.get("startedAt"), in_progress_since) if t), default=None),
            chief_gone=not chief.get("session"), grace_sec=_grace_sec(chief), tz=self._tz)
        wake_enabled = _wake_enabled(chief)
        return {
            "chiefKey": key,
            "state": ev["state"],
            "lastCheckInAt": hb.get("at"),
            "lastCheckInSource": hb.get("source"),
            "checkInRunningSince": in_progress_since,
            "dueAt": ev["dueAt"],
            "nextDueAt": ev["nextDueAt"],
            "overdueSec": ev["overdueSec"],
            "pace": settings["pace"],
            "sleepCheckins": settings["sleepCheckins"],
            "schedule": chief_checkin.describe(schedule, settings["pace"], settings["sleepCheckins"]),
            "scheduleError": schedule_error,
            "wakeEnabled": wake_enabled,
            "lastWake": entry.get("wake"),
            "evaluatedAt": now_ts,
        }

    # ── tick ──
    def tick(self):
        """One pass over every chief: read heartbeats, then wake whoever is
        due. Returns {chiefKey: view}. Never raises (one chief's failure is
        recorded on that chief, not the others)."""
        if not self._tick_lock.acquire(blocking=False):
            return dict(self._last_view)
        try:
            views = {}
            for chief in self._chiefs_provider() or []:
                try:
                    views[chief["key"]] = self._tick_one(chief)
                except Exception as e:  # noqa: BLE001 - failure is state, per chief
                    views[chief["key"]] = {"chiefKey": chief.get("key"), "state": "error",
                                           "error": str(e)}
            self._last_view = views
            return views
        finally:
            self._tick_lock.release()

    def _tick_one(self, chief):
        key = chief["key"]
        self._refresh_transcript_heartbeat(chief)
        now_ts = self._now()
        v = self.view(chief, now_ts)
        ev = {"state": v["state"], "dueAt": v["dueAt"], "current": v["dueAt"] is not None}
        with self._lock:
            wake_record = dict((self._state.get(key) or {}).get("wake") or {})
        decision, reason = chief_checkin.decide_wake(
            ev, wake_enabled=v["wakeEnabled"], chief_activity=chief.get("activity") or "idle",
            wake_record=wake_record, now_ts=now_ts)
        if decision == "defer":
            self._set_wake(key, wake_record, v["dueAt"], "deferred", reason, count=False, now_ts=now_ts)
        elif decision == "wake":
            self._wake(chief, v["dueAt"], wake_record, now_ts)
        return self.view(chief)

    def _set_wake(self, key, prev, due, result, reason, *, count, now_ts):
        same_slot = prev.get("dueAt") == due
        attempts = (prev.get("attempts") or 0) if same_slot else 0
        record = {"dueAt": due, "attempts": attempts + (1 if count else 0),
                  "lastAttemptAt": now_ts if count else prev.get("lastAttemptAt") if same_slot else None,
                  "result": result, "reason": reason, "at": now_ts}
        with self._lock:
            self._entry(key)["wake"] = record
            self._save()
        return record

    def _wake(self, chief, due, prev, now_ts):
        key = chief["key"]
        record = self._set_wake(key, prev, due, "sending", "sending wake", count=True, now_ts=now_ts)
        text = chief_checkin.wake_text(due, chief.get("briefPath"), tz=self._tz)
        try:
            result = self._send(chief["rowId"], text) or {}
        except Exception as e:  # noqa: BLE001
            result = {"ok": False, "error": str(e)}
        ok = bool(result.get("ok"))
        reason = result.get("reason") or result.get("state") or result.get("error") or ""
        self._set_wake(key, record, due, "delivered" if ok else "failed", reason,
                       count=False, now_ts=now_ts)


def _grace_sec(chief):
    """`checkin_grace_min` from config.yaml (1-120), else the default."""
    raw = (chief.get("config") or {}).get("checkin_grace_min")
    try:
        minutes = int(raw)
    except (TypeError, ValueError):
        return chief_checkin.GRACE_SEC
    return max(1, min(120, minutes)) * 60


def _wake_enabled(chief):
    value = str((chief.get("config") or {}).get("wake") or "").strip().lower()
    return value in ("on", "true", "yes", "1")


def run_forever(timer, stop_event, interval=TICK_SEC):
    """The server's background thread body."""
    while not stop_event.is_set():
        try:
            timer.tick()
        except Exception:
            pass
        stop_event.wait(interval)
