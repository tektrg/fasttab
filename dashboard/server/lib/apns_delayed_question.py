"""Delayed "needs you" push: the phone is alerted only if a wait is still open
after `delay` (default 20 min), so a question the PO answers at the Mac
(AgentBar, Focus, terminal, Desktop) never reaches the phone.

  Wait       one agent (board row id) continuously waiting on the PO with a
             push-worthy reason (question / approval / login — see
             apns_agent_push). Identity = the agent's WAITING EPISODE, not the
             question text: the hook preview, the screen picker and the row
             detail word the same question differently, so a text hash would
             restart the timer on every rewording. A new question restarts the
             timer because answering ends the episode: the row leaves needs-you
             (agent works), and once it has been gone CLOSE_GRACE_SEC the wait
             is closed; the next question opens a fresh wait + fresh timer.
  Open?      decided ONLY from the live status snapshot (computed.needsYou),
             never from who answered: answered anywhere, parked, done, cleared
             or agent gone all look the same — the row is not there.
  Fire       at dueAt, only if the row is present in THIS snapshot. One push
             per wait, never repeated (the `sent` mark lives until close).

Persistence (`store_path`, JSON, atomic tmp+rename): every pending/sent wait,
so a server restart neither loses a timer nor re-sends. On load:
  * overdue + still open  -> fires once at the first observation;
  * closed while we were down -> dropped (absent past the grace);
  * absence is only counted from this process's start + STARTUP_GRACE_SEC,
    because feeds read `warming` (short needsYou) for ~45 s after a start.
At-most-once: the `sent` mark is written to disk BEFORE the send is handed to
APNs. A crash between the two loses that push instead of doubling it.

Pure: clock and send are injected; no thread, no network here.
"""
import json
import os
import sys
import tempfile

DEFAULT_DELAY_SEC = 20 * 60
#: Gone this long (no row in needs-you) = the wait is closed. Matches the
#: "working blip while a hook holds the question" tolerance in apns_agent_push.
CLOSE_GRACE_SEC = 15
#: After a (re)start nothing is closed for this long: feeds are still warming.
STARTUP_GRACE_SEC = 60
DELAY_ENV = "AGENTBAR_QUESTION_PUSH_DELAY_SEC"
DRY_RUN_ENV = "AGENTBAR_PUSH_DRY_RUN"
STORE_ENV = "AGENTBAR_PENDING_PUSH_FILE"
STORE_NAME = "apns-pending-questions.json"


def delay_from(env=None, apns_config_path=None):
    """Env override, else apns.json `questionDelaySec`, else 20 min."""
    env = os.environ if env is None else env
    for raw in (env.get(DELAY_ENV), _config_value(apns_config_path, "questionDelaySec")):
        try:
            if raw is not None and float(raw) >= 0:
                return float(raw)
        except (TypeError, ValueError):
            pass
    return float(DEFAULT_DELAY_SEC)


def _config_value(path, key):
    if not path:
        return None
    try:
        with open(path) as f:
            raw = json.load(f)
    except (OSError, ValueError):
        return None
    return raw.get(key) if isinstance(raw, dict) else None


def dry_run_from(env=None, apns_config_path=None):
    """Env AGENTBAR_PUSH_DRY_RUN=1, or apns.json `questionPushDryRun: true`
    (the production server is launched by scripts/restart.sh, no env hook)."""
    env = os.environ if env is None else env
    return (str(env.get(DRY_RUN_ENV, "")).strip().lower() in ("1", "true", "yes")
            or _config_value(apns_config_path, "questionPushDryRun") is True)


class JsonStore:
    def __init__(self, path):
        self.path = path

    def load(self):
        try:
            with open(self.path) as f:
                data = json.load(f)
        except (OSError, ValueError):
            return {}
        waits = data.get("waits") if isinstance(data, dict) else None
        return {k: v for k, v in (waits or {}).items() if isinstance(v, dict)}

    def save(self, waits):
        directory = os.path.dirname(self.path) or "."
        os.makedirs(directory, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".pending-", dir=directory)
        try:
            with os.fdopen(fd, "w") as f:
                json.dump({"version": 1, "waits": waits}, f, indent=1, sort_keys=True)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, self.path)
        except Exception:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise


class MemoryStore:
    """Test double / fallback: same contract as JsonStore, no disk."""
    def __init__(self, waits=None):
        self.waits = dict(waits or {})
        self.saves = 0

    def load(self):
        return json.loads(json.dumps(self.waits))

    def save(self, waits):
        self.saves += 1
        self.waits = json.loads(json.dumps(waits))


class DelayedQuestionScheduler:
    """observe(open_waits) once per status snapshot.

    open_waits: {agent_key: {"payload": dict, "collapseId": str}} — every
    push-worthy wait open in this snapshot. send(payload, collapse_id) is
    called at most once per wait."""

    def __init__(self, store, send, clock, delay_sec=DEFAULT_DELAY_SEC, dry_run=False, log=None,
                 close_grace_sec=CLOSE_GRACE_SEC, startup_grace_sec=STARTUP_GRACE_SEC):
        self._store = store
        self._send = send
        self._clock = clock
        self.delay_sec = float(delay_sec)
        self.dry_run = dry_run
        self._log = log or (lambda msg: print(msg, file=sys.stderr))
        self._close_grace = close_grace_sec
        self._startup_grace = startup_grace_sec
        self._started = clock()
        self.waits = store.load()

    def observe(self, open_waits):
        now = self._clock()
        changed = False
        for key, wait in open_waits.items():
            entry = self.waits.get(key)
            if entry is None:
                entry = self.waits[key] = {
                    "openedAt": now, "dueAt": now + self.delay_sec, "sent": False}
                self._log(f"apns-delay: wait opened for {key!r}, push due in {self.delay_sec:.0f}s")
                changed = True
            # lastSeen is kept in memory every pass but only written with other
            # changes: after a restart, absence counts from the startup grace.
            entry["lastSeen"] = now
            entry["payload"], entry["collapseId"] = wait["payload"], wait["collapseId"]
        close_floor = self._started + self._startup_grace
        for key in [k for k in self.waits if k not in open_waits]:
            entry = self.waits[key]
            if now >= max(float(entry.get("lastSeen", 0)) + self._close_grace, close_floor):
                del self.waits[key]
                changed = True
                if not entry.get("sent"):
                    self._log(f"apns-delay: wait closed for {key!r} before its push, dropped")
        due = [k for k in open_waits
               if not self.waits[k].get("sent") and now >= float(self.waits[k]["dueAt"])]
        for key in due:
            self.waits[key]["sent"] = True
            self.waits[key]["sentAt"] = now
        if changed or due:
            self._store.save(self.waits)  # sent marks hit disk BEFORE any send
        for key in due:
            entry = self.waits[key]
            if self.dry_run:
                self._log(f"apns-delay: DRY RUN push for {key!r} (no APNs send): "
                          f"{entry['payload'].get('summary')!r}")
            else:
                self._log(f"apns-delay: sending push for {key!r}")
                self._send(entry["payload"], entry["collapseId"])
        return due
