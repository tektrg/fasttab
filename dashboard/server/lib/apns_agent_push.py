"""Agent events -> APNs AGENT_MESSAGE pushes to the iOS app (see apns_push.py
for the payload contract).

  event "question"  a needs-you row appears (kind question / blocked: a picker,
                    an on-screen permission box, a wrap_up ask). Body = the
                    question text.
  event "finished"  an agent goes working -> idle (turn over). Body = the
                    transcript's last assistant message (local Claude
                    sessions), else the screen's last line.

Rules:
  * one push per (agent, event, turn): the turn is identified by the text
    (question text / last message), so a row flapping in and out of needs-you,
    or working <-> idle with no new message, never re-pushes;
  * "finished" also has a per-agent cooldown (FINISHED_COOLDOWN_SEC);
  * an agent with a hook-held permission prompt (`hookRequest`) is skipped —
    apns_permission_push already alerted for it — only while
    PERMISSION_PUSH_ENABLED; when that is off it gets the question push;
  * the first observation after start only primes memory (no burst of pushes
    for state that existed before a server restart);
  * no APNs config or no device -> nothing is computed or sent.

Driven by start_observer(): one daemon thread polling get_full_state every
OBSERVE_INTERVAL_SEC. Sends run off-thread (apns_fan_out); feeds never wait.
"""
import hashlib
import sys
import threading
import time

import apns_fan_out
import apns_permission_push
import chief_dashboard_store
import session_transcript
import transcript_pending_question

CATEGORY_MESSAGE = "AGENT_MESSAGE"
EVENT_QUESTION = "question"
EVENT_FINISHED = "finished"
BODY_MAX_CHARS = 240
FINISHED_COOLDOWN_SEC = 60
#: Working this long without asking = a new turn, so the same text may push
#: again. A blip is not a turn: an agent held on a hook question reads as
#: "working" (hook spinner) between passes, and used to re-push the question.
NEW_TURN_WORKING_SEC = 15
OBSERVE_INTERVAL_SEC = 5
#: Remembered (agent, event, turn) keys; oldest dropped past this size.
SEEN_MAX = 1000
QUESTION_KINDS = ("question", "blocked")


def _digest(text):
    return hashlib.sha1(str(text or "").encode("utf-8", "replace")).hexdigest()[:12]


def question_text(row):
    """The question a needs-you row asks, most specific source first."""
    for source, field in (("questionPreview", "question"), ("transcriptQuestion", "question"),
                          ("wrapUpQuestion", "ask"), ("question", "question")):
        value = row.get(source)
        if isinstance(value, dict) and isinstance(value.get(field), str) and value[field].strip():
            return value[field]
    return row.get("detail") or "Waiting for your answer"


def is_working(agent):
    """Same state word the board shows (derived:state)."""
    return chief_dashboard_store.derived_values_for_agent(agent)["derived:state"] == "working"


def local_last_message(session_id):
    """Last assistant text of a local Claude transcript, or None."""
    if not session_id or not session_transcript.is_safe_session_id(session_id):
        return None
    path = session_transcript.find_local_transcript(session_id, transcript_pending_question.PROJECTS_ROOT)
    if not path:
        return None

    def read_window(window):
        tail = transcript_pending_question.read_regular_tail(path, window)
        return None if tail is None else (tail[0], tail[1])
    return session_transcript.latest_message_from_tail(read_window)["latestMessage"]


def message_alert(event, agent_key, label, body, turn):
    return {"aps": {"alert": {"title": label, "subtitle": "Asked a question" if event == EVENT_QUESTION
                              else "Finished", "body": body},
                    "sound": "default", "category": CATEGORY_MESSAGE, "thread-id": label},
            "event": event, "agent": label, "agentKey": agent_key, "sessionId": agent_key
            if agent_key and not str(agent_key).startswith("pane:") else None,
            "summary": body, "turn": turn, "path": apns_fan_out.agent_path(agent_key)}


class AgentEventPusher:
    def __init__(self, fan_out=None, clock=time.time, last_message=local_last_message):
        self._fan_out = fan_out or apns_fan_out.ApnsFanOut()
        self._clock = clock
        self._last_message = last_message
        self._lock = threading.Lock()
        self._seen = {}
        self._working = {}
        self._working_since = {}
        self._last_finished_at = {}
        self._primed = False

    def tick(self, get_state):
        """One observer step; computes no state when no phone can be alerted."""
        if not self._fan_out.can_reach_device():
            self._primed = False  # re-prime when a device appears: no backlog burst
            return
        self.observe(get_state())

    def observe(self, state):
        """Diff one get_full_state() snapshot against the last; push news."""
        computed = (state or {}).get("computed") or {}
        agents = [a for a in computed.get("agents") or [] if isinstance(a, dict)]
        with self._lock:
            pushes = self._diff(agents, computed.get("needsYou") or [])
            primed, self._primed = self._primed, True
        if not primed:
            return
        for payload, collapse_id in pushes:
            print(f"apns: {payload.get('event')} push for {payload.get('agent')!r}", file=sys.stderr)
            self._fan_out.send(lambda p=payload: p, collapse_id)

    def _diff(self, agents, needs_you):
        by_session = {a["agentSession"]: a for a in agents if a.get("agentSession")}
        by_pane = {a["paneId"]: a for a in agents if a.get("paneId")}
        pushes = []
        held = set()
        asking = set()  # agents waiting on the user this pass: no "finished" for them
        for row in needs_you:
            if not isinstance(row, dict) or row.get("kind") not in QUESTION_KINDS:
                continue
            agent = by_session.get(row.get("identity")) or by_pane.get(row.get("paneId")) or {}
            key = chief_dashboard_store.resolve_agent_row_id(agent) if agent else None
            if apns_permission_push.PERMISSION_PUSH_ENABLED and (
                    row.get("hookRequest") or agent.get("hookRequest")):
                held.add(key)
                continue
            asking.add(key)
            # One question push per waiting episode, whatever the text: the hook
            # preview, the screen picker and the row detail word the same
            # question differently, and each used to hash to a new push.
            pushes += self._once(EVENT_QUESTION, key, row.get("label") or "Agent",
                                 question_text(row), episode=True)
        now = self._clock()
        working_now = {}
        for agent in agents:
            key = chief_dashboard_store.resolve_agent_row_id(agent)
            working_now[key] = is_working(agent)
            if working_now[key] and key not in asking:
                since = self._working_since.setdefault(key, now)
                if now - since >= NEW_TURN_WORKING_SEC:
                    self._forget_turns(key)  # a new turn: the same text may be news again
            else:
                self._working_since.pop(key, None)
            if (not self._working.get(key) or working_now[key] or key in held or key in asking
                    or (apns_permission_push.PERMISSION_PUSH_ENABLED and agent.get("hookRequest"))):
                continue
            if now - self._last_finished_at.get(key, float("-inf")) < FINISHED_COOLDOWN_SEC:
                continue
            body = (self._last_message(agent.get("agentSession"))
                    or screen_last_line(agent) or "Turn finished")
            sent = self._once(EVENT_FINISHED, key, agent.get("label") or "Agent", body)
            if sent:
                self._last_finished_at[key] = now
            pushes += sent
        self._working = working_now
        return pushes

    def _forget_turns(self, key):
        for seen_key in [k for k in self._seen if k[0] == key]:
            del self._seen[seen_key]

    def _once(self, event, key, label, text, episode=False):
        """`episode`: dedupe on (agent, event) alone until the agent works again."""
        body = apns_fan_out.one_line(text, BODY_MAX_CHARS)
        turn = _digest(text)
        seen_key = (key or label, event, "" if episode else turn)
        if seen_key in self._seen:
            return []
        self._seen[seen_key] = True
        while len(self._seen) > SEEN_MAX:
            self._seen.pop(next(iter(self._seen)))
        collapse_id = f"{event}-{_digest(key or label)}" + ("" if episode else f"-{turn}")
        return [(message_alert(event, key, label, body, turn), collapse_id)]


def screen_last_line(agent):
    signal = agent.get("screenSignal") or agent.get("hookReason")
    return None if not signal or signal.strip() == chief_dashboard_store.NO_SIGNAL_PLACEHOLDER else signal


def start_observer(get_state, stop_event, pusher=None, interval=OBSERVE_INTERVAL_SEC):
    """Daemon thread: pusher.observe(get_state()) every `interval` seconds."""
    pusher = pusher or PUSHER

    def loop():
        while not stop_event.wait(interval):
            try:
                pusher.tick(get_state)
            except Exception as e:  # noqa: BLE001 — never take the server down
                print(f"[apns] agent observer: {e}", file=sys.stderr)
    threading.Thread(target=loop, name="apns-agent-observer", daemon=True).start()


PUSHER = AgentEventPusher()
