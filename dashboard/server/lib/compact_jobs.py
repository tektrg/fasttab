#!/usr/bin/env python3
"""/compact with a temporary Sonnet switch: one background job per row.

Endpoints (contract: `.claude/compact-api-contract.md`, copied into
dashboard/AGENTS.md "Compact on Sonnet"):
  POST /api/session/compact {rowId, actor, instructions?, followUp?}
       202 {ok, job} | 409 {ok:false, error:"job-active", job} | 400/404
  GET  /api/session/compact?rowId=   -> {ok, job | null}
  GET  /api/session/compact/<jobId>  -> {ok, job} | 404

Sequence (states): waitingIdle -> switchingModel -> compacting ->
restoringModel -> sendingFollowUp -> done | failed.

How Claude Code is driven (live probe 2026-11-22, Claude Code 2.1.330 —
facts copied into AGENTS.md because the probe file is gitignored):
  - `/model` is typed with `herdr pane run` (text + its own Enter, which
    opens the picker). NEVER a second Enter after it: Enter while the picker
    is open SAVES the highlighted row as the global default model.
  - Inside the picker only arrows and `s` are sent. `s` = "use this session
    only". Digits and Enter both save the global default. Rows are matched by
    their text (label / description), never by row number; row 1 "Default
    (recommended)" mentions the current model and is never the target.
  - `Switch model?` (cache-warm confirm) is answered with `1` only after a
    re-read shows `❯ 1. Yes, switch to <the model we chose>`.
  - Success = the last `Set model to <model> for this session only` line.
  - A custom/pinned model (ANTHROPIC_MODEL, e.g. `trung/claude-opus-5-5`)
    has no standard picker row: no switch, compact on the current model.
  - Compaction is done when the transcript gets a NEW `system /
    compact_boundary` line (fallback: the screen's `⎿  Compacted` line after
    our `/compact` echo). `Compacting conversation…` = still running.

Pure + testable: every side effect comes in through `PaneIO` (pane read,
`pane run`, send-keys, the dashboard's reliable message send, transcript
tail) and the injected clock/sleep/spawn, so tests drive a fake TUI.
"""

import json
import os
import re
import sys
import threading
import time
import uuid

import classify_pane
import chief_dashboard_actions as session_actions

COMPACT_PATH = "/api/session/compact"

WAITING_IDLE = "waitingIdle"
SWITCHING = "switchingModel"
COMPACTING = "compacting"
RESTORING = "restoringModel"
FOLLOW_UP = "sendingFollowUp"
DONE = "done"
FAILED = "failed"
TERMINAL_STATES = (DONE, FAILED)

#: Busy agent: how long the job waits for an idle, empty prompt (owner: 10 min).
IDLE_TIMEOUT_SEC = 600
#: Between steps the prompt is normally idle at once; this is the safety net.
STEP_IDLE_TIMEOUT_SEC = 60
#: Restore budget: it is the one step that undoes a change, so after a
#: compact timeout or an ssh outage it waits for the pane to stop being busy
#: and retries (backing off) for up to 10 min before `modelRestored: false`.
RESTORE_BUDGET_SEC = 600
RESTORE_BACKOFF_SEC = 5.0
RESTORE_BACKOFF_MAX_SEC = 60.0
COMPACT_TIMEOUT_SEC = 300
POLL_SEC = 2.0
#: Picker/dialog screen changes land within a second (probe: no delay needed).
PICKER_WAIT_SEC = 8.0
PICKER_POLL_SEC = 0.4
NAV_ATTEMPTS = 3
#: Reads inside a picker step are retried this many times (an ssh hiccup must
#: not abandon an open picker).
PICKER_READ_ATTEMPTS = 3
#: How long a job waits for the row's send lock (a plain Send already typing).
ROW_LOCK_WAIT_SEC = 30.0
#: How long typing /model waits for the pane's picker lock (an /api/answer or
#: /api/permission keystroke being typed holds it).
PICKER_LOCK_WAIT_SEC = 15.0
#: Restart recovery never sends a blind Esc (the agent may be mid-turn, where
#: Esc stops Claude): it re-reads, backing off, for up to this long.
RECOVERY_READ_BUDGET_SEC = 120
RECOVERY_BACKOFF_SEC = 1.0
RECOVERY_BACKOFF_MAX_SEC = 15.0
#: GET ?rowId= shows a finished job this long (contract: 30 min).
RECENT_FINISHED_SEC = 30 * 60
#: Finished jobs are dropped from the state file after a day.
KEEP_FINISHED_SEC = 24 * 3600

TARGET_FAMILY = "Sonnet"
ALREADY_SONNET_SKIP = "already on Sonnet"
CUSTOM_MODEL_SKIP = "custom model: compacting on current model"
USER_TYPED_ERROR = "you typed into the session"
RESTARTED_ERROR = "dashboard restarted"

_JOB_ID_RE = re.compile(r"^cj-[0-9a-f]{16}$")

# ---------------------------------------------------------------- screen

_ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
_RULE_RE = re.compile(r"^\s*─{5,}")
_BUSY_FOOTER = "esc to interrupt"
_SPINNER_COMPACTING = "Compacting conversation"
_STATUSLINE_MODEL_RE = re.compile(r"\[([^\[\]]+)\]\s+\d{1,3}%\s+context\b")
_PICKER_TITLE = "Select model"
_PICKER_FOOTER = "s to use this session only"
_DIALOG_TITLE = "Switch model?"
_DIALOG_FOOTER = "Enter to confirm"
_DIALOG_YES_RE = re.compile(r"^\s*❯\s*1\.\s+Yes, switch to\s+(?P<model>.+?)\s*$")
_ROW_RE = re.compile(
    r"^\s*(?P<cur>❯)?\s*(?P<num>\d+)\.\s+(?P<label>\S.*?)(?:\s{2,}(?P<desc>\S.*?))?\s*$")
_CURRENTLY_RE = re.compile(r"\(currently ([^)]+)\)")
_SET_MODEL_RE = re.compile(
    r"(?:Set model to\s+(?P<model>.+?)\s+(?P<how>for this session only|and saved as your default)"
    r"|Kept model as\s+(?P<kept>.+?)\s*$)")
_COMPACT_ECHO_RE = re.compile(r"^\s*❯\s*/compact\b")
_COMPACTED_RE = re.compile(r"^\s*⎿?\s*Compacted\b")
_RESULT_RE = re.compile(r"^\s*⎿\s*(?P<text>\S.*?)\s*$")
_COMPACT_ERROR_RE = re.compile(r"^\s*⎿?\s*(Error[^\n]*compact[^\n]*)", re.IGNORECASE)
#: Lines allowed under the input box's closing rule: status line + mode
#: footer (+ a hint). Mirrors pane_screen_signals.MAX_LINES_UNDER_BOX + 1.
_MAX_LINES_UNDER_BOX = 4
#: Bottom lines the picker/dialog footer must sit in to count as OPEN (a
#: closed picker's frame left in scrollback must never read as open).
_BOTTOM_LINES = 8
#: A brand-new session draws a dim suggestion in its EMPTY prompt, e.g.
#: `❯ Try "fix lint errors"`. herdr reads plain text (no dim attribute), so
#: it would read as typed and stall `waitingIdle`. Conservative: the whole
#: box is exactly `Try "<one line>"` — anything after the quote is typed.
_PLACEHOLDER_RE = re.compile(r'^Try "[^"\n]{1,200}"$')


def strip_ansi(text):
    return _ANSI_RE.sub("", text or "")


def _clean(lines):
    return [strip_ansi(l).rstrip() for l in (lines or [])]


def _nonblank_tail(lines, n):
    out = [l for l in _clean(lines) if l.strip()]
    return out[-n:]


def _input_box(lines):
    """(start, end, text) of the live input box at the bottom, else None.

    Claude draws `rule / ❯ <text> [continuation lines] / rule` with the
    status line and mode footer under it. `text` is what sits in the box
    ('' when empty)."""
    clean = _clean(lines)
    idx = [i for i, l in enumerate(clean) if l.strip()]
    if not idx:
        return None
    close = None
    for k in range(len(idx) - 1, max(-1, len(idx) - 2 - _MAX_LINES_UNDER_BOX), -1):
        if _RULE_RE.match(clean[idx[k]]):
            close = k
            break
    if close is None:
        return None
    top = None
    for k in range(close - 1, max(-1, close - 12), -1):
        if _RULE_RE.match(clean[idx[k]]):
            top = k
            break
    if top is None:
        return None
    body = [clean[idx[k]] for k in range(top + 1, close)]
    if not body or not body[0].lstrip().startswith("❯"):
        return None
    first = body[0].lstrip()[1:].strip()
    rest = [b.strip() for b in body[1:]]
    text = "\n".join([first] + rest).strip()
    if _PLACEHOLDER_RE.match(text):
        text = ""   # the dim new-session hint, not something typed
    return idx[top], idx[close], text


def composer_text(lines):
    """Text in the live input box ('' = empty), or None when no box is drawn."""
    box = _input_box(lines)
    return None if box is None else box[2]


def picker_open(lines):
    return any(_PICKER_FOOTER in l for l in _nonblank_tail(lines, _BOTTOM_LINES))


def switch_dialog_open(lines):
    tail = _nonblank_tail(lines, _BOTTOM_LINES + 4)
    return (any(l.strip() == _DIALOG_TITLE for l in tail)
            and any(_DIALOG_FOOTER in l for l in tail))


def dialog_yes_model(lines):
    """`<model>` from the dialog's highlighted `❯ 1. Yes, switch to <model>`."""
    for l in _nonblank_tail(lines, _BOTTOM_LINES + 4):
        m = _DIALOG_YES_RE.match(l)
        if m:
            return m.group("model")
    return None


def is_busy(lines):
    """Mid-turn or compacting: the busy footer, or a live spinner."""
    if any(_BUSY_FOOTER in l for l in _nonblank_tail(lines, 6)):
        return True
    try:
        state, _sig = classify_pane.classify("\n".join(_clean(lines)))
    except Exception:
        state = None
    return state == "ACTIVE"


def prompt_open(lines):
    """A picker, dialog, question or permission box is up (never type then)."""
    if picker_open(lines) or switch_dialog_open(lines):
        return True
    clean = _clean(lines)
    try:
        if classify_pane.parse_question_block(clean[-100:]) is not None:
            return True
        state, _sig = classify_pane.classify("\n".join(clean))
    except Exception:
        state = None
    return state in ("NEEDS_HUMAN", "NEEDS_LOGIN")


def prompt_reading(lines):
    """'idle' (box drawn and empty, nothing running, nothing open), 'typed'
    (idle but the box holds text), 'busy', 'prompt', or 'unknown'."""
    if prompt_open(lines):
        return "prompt"
    if is_busy(lines):
        return "busy"
    text = composer_text(lines)
    if text is None:
        return "unknown"
    return "typed" if text else "idle"


def statusline_model(lines):
    """`Opus 5.5` from the status line `[Opus 5.5] 4% context`, else None."""
    found = None
    for l in _clean(lines):
        for m in _STATUSLINE_MODEL_RE.finditer(l):
            found = m.group(1).strip()
    return found


def model_family(display):
    """`Sonnet 5.5` -> `Sonnet`."""
    return (display or "").strip().split(" ")[0] if display else None


def parse_model_picker(lines):
    """The open /model picker -> {"rows": [...], "cursor": index | None}, or
    None when it is not open. Row: {label, desc, checked, cursor, default,
    standard, model, family}. `model` (standard rows) is the description's
    first segment (`Opus 5.5`) — how rows are matched, never by number."""
    if not picker_open(lines):
        return None
    clean = _clean(lines)
    footer = max(i for i, l in enumerate(clean) if _PICKER_FOOTER in l)
    titles = [i for i, l in enumerate(clean[:footer]) if l.strip() == _PICKER_TITLE]
    if not titles:
        return None
    rows = []
    for line in clean[titles[-1] + 1:footer]:
        checked = "✔" in line
        m = _ROW_RE.match(line.replace("✔", " "))
        if not m:
            continue
        label = m.group("label").strip()
        desc = (m.group("desc") or "").strip()
        family = label.split(" ")[0]
        default = label.lower().startswith("default")
        standard = (not default and bool(desc)
                    and re.match(re.escape(family) + r"\s+\d", desc) is not None)
        rows.append({
            "label": label, "desc": desc, "checked": checked,
            "cursor": bool(m.group("cur")), "default": default,
            "standard": standard,
            "model": desc.split(" · ")[0].strip() if standard else None,
            "family": family if standard else None,
        })
    if not rows:
        return None
    cursor = next((i for i, r in enumerate(rows) if r["cursor"]), None)
    return {"rows": rows, "cursor": cursor}


def current_model(picker):
    """(row index of the live model's standard row | None, display | None).

    ✔ marks the session's live model. ✔ on "Default" -> its `(currently X)`
    standard row (Default itself is never selected). No ✔, or ✔ on a row
    that is not a standard model row -> custom: (None, display)."""
    rows = picker["rows"]
    checked = next((i for i, r in enumerate(rows) if r["checked"]), None)
    if checked is None:
        return None, None
    row = rows[checked]
    if row["standard"]:
        return checked, row["model"]
    if row["default"]:
        m = _CURRENTLY_RE.search(row["desc"])
        name = m.group(1).strip() if m else None
        idx = next((i for i, r in enumerate(rows)
                    if r["standard"] and name and r["model"] == name), None)
        return idx, name
    return None, row["label"]


def last_model_line(lines):
    """The last `Set model to … for this session only|and saved…` or
    `Kept model as …` line -> {"model", "sessionOnly", "saved", "kept"}."""
    found = None
    for l in _clean(lines):
        m = _SET_MODEL_RE.search(l.replace("`", ""))
        if not m:
            continue
        if m.group("kept"):
            found = {"model": m.group("kept").strip(), "sessionOnly": False,
                     "saved": False, "kept": True}
        else:
            how = m.group("how")
            found = {"model": m.group("model").strip(),
                     "sessionOnly": how == "for this session only",
                     "saved": how.startswith("and saved"), "kept": False}
    return found


def _above_box(lines):
    clean = _clean(lines)
    box = _input_box(lines)
    return clean[:box[0]] if box else clean


def compacting(lines):
    return any(_SPINNER_COMPACTING in l for l in _nonblank_tail(lines, 12))


def screen_compacted(lines):
    """`⎿  Compacted` under the LAST `❯ /compact` echo (the live box excluded)."""
    above = _above_box(lines)
    echoes = [i for i, l in enumerate(above) if _COMPACT_ECHO_RE.match(l)]
    if not echoes:
        return False
    return any(_COMPACTED_RE.match(l) for l in above[echoes[-1] + 1:])


def screen_compact_error(lines):
    """Why the LAST `❯ /compact` did not compact, else None: its first `⎿`
    result line when that is not `Compacted` (live 2026-11-22: `⎿  Not
    enough messages to compact.` — no compact_boundary is written, so without
    this the job waited the full 5 min), or an `Error … compact …` line."""
    above = _above_box(lines)
    echoes = [i for i, l in enumerate(above) if _COMPACT_ECHO_RE.match(l)]
    if not echoes:
        return None
    for l in above[echoes[-1] + 1:]:
        m = _RESULT_RE.match(l)
        if m:
            return None if _COMPACTED_RE.match(l) else m.group("text")
        m = _COMPACT_ERROR_RE.match(l)
        if m:
            return m.group(1).strip()
    return None


def compact_boundary_ids(tail_bytes):
    """Identities (uuid, else timestamp) of `system/compact_boundary` lines
    in a transcript tail. None when the tail could not be read."""
    if tail_bytes is None:
        return None
    if isinstance(tail_bytes, bytes):
        tail_bytes = tail_bytes.decode("utf-8", "replace")
    ids = set()
    for line in tail_bytes.split("\n"):
        if "compact_boundary" not in line:
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            continue  # the window's first line can be cut
        if (isinstance(entry, dict) and entry.get("type") == "system"
                and entry.get("subtype") == "compact_boundary"):
            ident = entry.get("uuid") or entry.get("timestamp")
            if ident:
                ids.add(str(ident))
    return ids


# ---------------------------------------------------------------- request

def validate_request(body):
    """POST body -> (fields, None) or (None, reason). Text follows the Send
    message rules (`validate_message_text`): one line each, so the client
    flattens followUp newlines to spaces before sending."""
    if not isinstance(body, dict):
        return None, "body must be a JSON object"
    row_id = body.get("rowId")
    if not isinstance(row_id, str) or not row_id.strip():
        return None, "missing rowId"
    actor = body.get("actor")
    if not isinstance(actor, str):
        return None, "missing actor"
    fields = {"rowId": row_id.strip(), "actor": actor,
              "instructions": None, "followUp": None}
    for key in ("instructions", "followUp"):
        value = body.get(key)
        if value is None:
            continue
        if not isinstance(value, str):
            return None, f"{key} must be a string"
        value = value.replace("\t", " ").strip()
        if not value:
            continue
        probe = ("/compact " + value) if key == "instructions" else value
        ok, cleaned = session_actions.validate_message_text(probe)
        if not ok:
            return None, f"{key}: {cleaned}"
        fields[key] = cleaned[len("/compact "):] if key == "instructions" else cleaned
    return fields, None


# ---------------------------------------------------------------- jobs

class PaneIO:
    """Every side effect one job may cause, bound to one pane.

    read() -> list[str]: a FRESH screen read (raises on failure).
    run_line(text): `herdr pane run` — text plus herdr's own Enter.
    keys(*keys): `herdr pane send-keys`.
    send_message(text) -> dict: the dashboard's reliable Send message path
        (`_handle_reach_action`), used for `/compact …` and the follow-up.
    transcript_tail() -> bytes | None: the session transcript's last window.
    """

    def __init__(self, read, run_line, keys, send_message, transcript_tail):
        self.read = read
        self.run_line = run_line
        self.keys = keys
        self.send_message = send_message
        self.transcript_tail = transcript_tail


#: The Job JSON clients see. `followUp` (QA 2026-11-22, additive) = the queued
#: message text, so a client can offer to resend it when `followUpSent` is false.
#: `inPicker` (QA2 2026-11-22, additive): the /model picker may be open — set
#: just before `/model` is typed, cleared only once a read confirms it closed.
#: Answers (/api/answer, /api/permission) are refused only while it is true.
_PUBLIC_KEYS = ("id", "rowId", "state", "originalModel", "switchSkipped",
                "skipReason", "compactOk", "modelRestored", "followUpSent",
                "error", "failedStep", "createdAt", "updatedAt", "followUp",
                "inPicker")
#: Saved in the 0600 state file only — what a restarted dashboard needs to
#: leave the picker and put the model back (never sent to clients).
#: `sSent`: the picker's session-only commit was pressed (the model may have
#: changed).
_PRIVATE_KEYS = ("instructions", "restoreModel", "sSent",
                 "paneKey", "machine", "rawPaneId", "sessionId", "actor")
_PANE_KEYS = ("paneKey", "machine", "rawPaneId", "sessionId")


def public_job(job):
    return None if job is None else {k: job.get(k) for k in _PUBLIC_KEYS}


def _saved_job(job):
    return {k: job.get(k) for k in _PUBLIC_KEYS + _PRIVATE_KEYS}


def _thread_spawn(fn):
    threading.Thread(target=fn, daemon=True, name="compact-job").start()


def _log(message):
    print(f"compact-jobs: {message}", file=sys.stderr)


class _Abort(Exception):
    """The user typed into the session: stop typing (restore still runs)."""


class _PickerBusy(Exception):
    """An answer keystroke held the pane's picker lock too long: /model was
    not typed."""


class CompactJobs:
    """Job table: a lock, an in-memory dict, one worker thread per job, a
    0600 state file. Single-flight per rowId; one send lock per row, held by
    a job's worker for its whole run and by every plain Send to that row
    (the dashboard server takes it), so a Send can never type into the
    /model picker a job just opened."""

    def __init__(self, state_path=None, clock=time.time, sleep=time.sleep,
                 spawn=_thread_spawn):
        self._state_path = state_path
        self._clock = clock
        self._sleep = sleep
        self._spawn = spawn
        self._lock = threading.Lock()
        self._jobs = {}
        self._row_locks = {}
        self._picker_locks = {}
        self._interrupted = []   # (job, was_in_picker, needs_restore) from _load
        self._load()

    # -- persistence

    def _load(self):
        if not self._state_path:
            return
        try:
            with open(self._state_path) as f:
                data = json.load(f)
        except (OSError, ValueError):
            return
        changed = False
        for raw in (data.get("jobs") if isinstance(data, dict) else None) or []:
            if not isinstance(raw, dict) or not _JOB_ID_RE.match(str(raw.get("id", ""))):
                continue
            job = {k: raw.get(k) for k in _PUBLIC_KEYS + _PRIVATE_KEYS}
            job["switchSkipped"] = bool(job.get("switchSkipped"))
            job["inPicker"] = bool(job.get("inPicker"))
            if job.get("state") not in TERMINAL_STATES:
                # Its worker died with the old process. A queued follow-up
                # reads NOT sent (never auto-sent after a restart; the text
                # stays for a client resend).
                if job.get("error") is None:
                    job["error"] = RESTARTED_ERROR
                    job["failedStep"] = job.get("state")
                needs_restore = bool(job.get("sSent")) and job.get("modelRestored") is not True
                if job.get("followUp") and job.get("followUpSent") is not True:
                    job["followUpSent"] = False
                if job["inPicker"] or needs_restore:
                    # Recovery is due: the job stays ACTIVE (`restoringModel`)
                    # from this load on, before any request is served, so
                    # single-flight + the send refusals hold until
                    # `recover()`'s worker finishes it. (Marked only when the
                    # worker took the row lock, a new job could start in the
                    # gap, read "already on Sonnet" and leave it there.)
                    job["state"] = RESTORING
                    if needs_restore:
                        job["modelRestored"] = None
                    self._interrupted.append((job, job["inPicker"], needs_restore))
                else:
                    job["state"] = FAILED
                job["updatedAt"] = self._clock()
                changed = True
            self._jobs[job["id"]] = job
        if changed:
            self._save()

    def _save(self):
        if not self._state_path:
            return
        now = self._clock()
        with self._lock:
            jobs = [_saved_job(j) for j in self._jobs.values()
                    if j["state"] not in TERMINAL_STATES
                    or now - (j.get("updatedAt") or 0) < KEEP_FINISHED_SEC]
        try:
            os.makedirs(os.path.dirname(self._state_path), exist_ok=True)
            tmp = f"{self._state_path}.tmp"
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                json.dump({"jobs": jobs}, f)
            os.chmod(tmp, 0o600)
            os.replace(tmp, self._state_path)
        except OSError as e:
            _log(f"could not save state: {e.__class__.__name__}")

    def recover(self, io_for_job):
        """After a restart: for each job the old process left mid-run (kept
        active as `restoringModel` by `_load`), leave the picker if it may be
        open — Esc ONLY after a read shows it; an unreadable pane is re-read
        with backoff (RECOVERY_READ_BUDGET_SEC), never a blind Esc, since the
        agent may be mid-turn — and if Sonnet may have been committed, put
        the model back (same 10 min restore budget). `io_for_job(job)` ->
        PaneIO, or None when the pane can't be reached (the job then ends
        failed with `modelRestored: false`). Never sends the follow-up. MUST
        be called once, at server start, after construction: until then the
        interrupted jobs hold their rows."""
        pending, self._interrupted = self._interrupted, []
        for job, was_in_picker, needs_restore in pending:
            try:
                io = io_for_job(job)
            except Exception as e:
                _log(f"job {job['id']}: no pane I/O after restart: {e!r}")
                io = None
            runner = _Runner(self, job, io)
            if io is None:
                runner._finish()
                continue
            self._spawn(lambda r=runner, p=was_in_picker, n=needs_restore: r.recover(p, n))

    # -- table

    def _active_for(self, row_id):
        for job in self._jobs.values():
            if job["rowId"] == row_id and job["state"] not in TERMINAL_STATES:
                return job
        return None

    def active_for_row(self, row_id):
        with self._lock:
            return public_job(self._active_for(row_id))

    def active_for_pane(self, pane_key):
        """The active job driving this (namespaced) pane, public shape."""
        with self._lock:
            for job in self._jobs.values():
                if (pane_key and job.get("paneKey") == pane_key
                        and job["state"] not in TERMINAL_STATES):
                    return public_job(job)
        return None

    def row_lock(self, row_id):
        with self._lock:
            lock = self._row_locks.get(row_id)
            if lock is None:
                lock = self._row_locks[row_id] = threading.Lock()
            return lock

    def picker_lock(self, pane_key):
        """One lock per (namespaced) pane, held by a job from just before it
        sets `inPicker` and types /model until it has left the picker, and by
        the dashboard while it types an answer/permission keystroke — so an
        answer can never land in a picker that opens mid-answer."""
        with self._lock:
            lock = self._picker_locks.get(pane_key)
            if lock is None:
                lock = self._picker_locks[pane_key] = threading.Lock()
            return lock

    def start(self, fields, io, pane=None):
        """Create + spawn a job. (payload, http_status). `pane`: {paneKey,
        machine, rawPaneId, sessionId}, saved so a restart can reach it."""
        now = self._clock()
        with self._lock:
            active = self._active_for(fields["rowId"])
            if active is not None:
                return {"ok": False, "error": "job-active", "job": public_job(active)}, 409
            job = {
                "id": "cj-" + uuid.uuid4().hex[:16], "rowId": fields["rowId"],
                "state": WAITING_IDLE, "originalModel": None,
                "switchSkipped": False, "skipReason": None, "compactOk": None,
                "modelRestored": None, "followUpSent": None, "error": None,
                "failedStep": None, "createdAt": now, "updatedAt": now,
                "followUp": fields.get("followUp"),
                "instructions": fields.get("instructions"),
                "restoreModel": None, "sSent": False, "inPicker": False,  # inPicker: public
                "actor": fields.get("actor"),
            }
            for key in _PANE_KEYS:
                job[key] = (pane or {}).get(key)
            self._jobs[job["id"]] = job
            snapshot = public_job(job)
        self._save()
        runner = _Runner(self, job, io)
        self._spawn(runner.run)
        return {"ok": True, "job": snapshot}, 202

    def get(self, job_id):
        with self._lock:
            job = self._jobs.get(job_id or "")
            snapshot = public_job(job)
        if snapshot is None:
            return {"ok": False, "error": "unknown job"}, 404
        return {"ok": True, "job": snapshot}, 200

    def for_row(self, row_id):
        """Active job for the row, else the newest finished one < 30 min old."""
        now = self._clock()
        with self._lock:
            active = self._active_for(row_id)
            if active is None:
                done = [j for j in self._jobs.values()
                        if j["rowId"] == row_id
                        and now - (j.get("updatedAt") or 0) < RECENT_FINISHED_SEC]
                active = max(done, key=lambda j: j["createdAt"]) if done else None
            snapshot = public_job(active)
        return {"ok": True, "job": snapshot}, 200

    def update(self, job, **changes):
        with self._lock:
            job.update(changes)
            job["updatedAt"] = self._clock()
        self._save()


class _Runner:
    """One job's sequence. Every keystroke follows a fresh read; everything
    a restart needs (`sSent`, `restoreModel`, `inPicker`, the follow-up) lives
    in the job dict, saved on every change."""

    def __init__(self, table, job, io):
        self.t = table
        self.job = job
        self.io = io
        self.lines = None
        # This runner typed /model (or inherited an open picker after a
        # restart): a picker found open later is ours to Esc.
        self.picker_used = False
        # What the blind-Esc rule looks at (`blind_esc_allowed`): the last
        # SUCCESSFUL read ('picker' | 'busy' | 'other' | None = no read yet,
        # or an Esc went out since), and whether /model, an arrow, `s` or `1`
        # was typed after that read.
        self.last_screen = None
        self.typed_picker_keys = False

    # -- small helpers

    def now(self):
        return self.t._clock()

    def sleep(self, sec):
        self.t._sleep(sec)

    def set_state(self, state):
        self.t.update(self.job, state=state)

    def fail(self, step, message):
        """Record a failure; only the FIRST one is kept as `error`."""
        if self.job.get("error") is None:
            self.t.update(self.job, error=message, failedStep=step)

    def read(self):
        lines = self.io.read()
        if picker_open(lines) or switch_dialog_open(lines):
            self.last_screen = "picker"
        elif is_busy(lines):
            self.last_screen = "busy"
        else:
            self.last_screen = "other"
        self.typed_picker_keys = False
        return lines

    def read_retry(self):
        """A fresh read, retried (bounded) — used inside picker steps, where
        giving up on one ssh hiccup would leave the picker open."""
        error = None
        for attempt in range(PICKER_READ_ATTEMPTS):
            if attempt:
                self.sleep(PICKER_POLL_SEC)
            try:
                return self.read()
            except Exception as e:
                error = e
        raise error

    def read_patient(self):
        """Restart recovery's read: retried with backoff for up to
        RECOVERY_READ_BUDGET_SEC (recovery never Escs blind, so it waits for
        a read instead)."""
        deadline = self.now() + RECOVERY_READ_BUDGET_SEC
        backoff = RECOVERY_BACKOFF_SEC
        while True:
            try:
                return self.read()
            except Exception:
                if self.now() >= deadline:
                    raise
            self.sleep(min(backoff, max(0.0, deadline - self.now())))
            backoff = min(backoff * 2, RECOVERY_BACKOFF_MAX_SEC)

    def run_picker_line(self, text):
        """`pane run` of a picker-opening line (/model)."""
        self.typed_picker_keys = True
        self.io.run_line(text)

    def picker_keys(self, *keys):
        """send-keys inside the picker / confirm dialog (arrows, s, 1)."""
        self.typed_picker_keys = True
        self.io.keys(*keys)

    def blind_esc_allowed(self):
        """An Esc without a read showing the picker is sent only when the
        last successful read showed the picker, or /model / picker keys were
        typed after it — never when it showed a busy spinner (Esc at a busy
        prompt stops Claude's turn), and never right after another Esc."""
        if self.last_screen == "busy":
            return False
        return self.last_screen == "picker" or self.typed_picker_keys

    def _esc(self):
        self.last_screen = None
        self.typed_picker_keys = False
        try:
            self.io.keys("esc")
        except Exception as e:
            _log(f"job {self.job['id']}: esc failed: {e!r}")

    def _picker_closed(self):
        """A read confirmed no picker / dialog is open."""
        if self.job.get("inPicker"):
            self.t.update(self.job, inPicker=False)

    def wait_ready(self, step, timeout, abort_on_typed=True, record=True):
        """Poll until the prompt is idle and empty. True when ready; raises
        _Abort when the box holds text (the restore instead keeps waiting for
        the user to send or clear it); False on timeout (failure recorded
        unless `record` is False). A /model picker or `Switch model?` dialog
        this job left open is escaped, never waited on."""
        deadline = self.now() + timeout
        last = None
        while True:
            try:
                lines = self.read()
                last = prompt_reading(lines)
            except Exception as e:
                last = f"pane read failed: {e}"
                lines = None
            if last == "idle":
                self.lines = lines
                self._picker_closed()   # an idle prompt = no picker open
                return True
            if last == "typed" and abort_on_typed:
                self.fail(step, USER_TYPED_ERROR)
                raise _Abort()
            if (last == "prompt" and self.picker_used
                    and (picker_open(lines) or switch_dialog_open(lines))):
                self.escape_out()
            if self.now() >= deadline:
                if record:
                    mins = int(round(timeout / 60.0))
                    what = f"{mins} min" if mins >= 1 else f"{int(timeout)}s"
                    self.fail(step, f"agent did not reach an idle prompt within {what}"
                              + (f" ({last})" if last and last.startswith("pane read") else ""))
                return False
            self.sleep(POLL_SEC)

    def escape_out(self, patient=False):
        """Close the picker / confirm dialog without choosing anything.
        True once a read confirms none is open (then `inPicker` is cleared),
        False when that could not be confirmed (`inPicker` stays set).

        Esc goes out on a read that shows one open (twice for dialog ->
        picker). When the pane can't be read: ONE blind Esc, only if
        `blind_esc_allowed()` (we just typed picker keys, or the last read
        showed the picker) and no Esc was sent yet — Esc in the picker
        cancels ("Kept model as …"); at a busy prompt it would stop the turn;
        two in a row at an idle prompt could open Claude's rewind menu.
        `patient` (restart recovery): reads are retried with backoff
        (`read_patient`) and the runner has typed nothing, so no blind Esc."""
        sent = False
        for attempt in range(5):
            try:
                lines = self.read_patient() if patient else self.read_retry()
            except Exception:
                if not sent and self.blind_esc_allowed():
                    self._esc()
                    self.sleep(PICKER_POLL_SEC)
                return False
            if not (picker_open(lines) or switch_dialog_open(lines)):
                self._picker_closed()
                return True
            if attempt == 4:
                return False
            self._esc()
            sent = True
            self.sleep(PICKER_POLL_SEC)
        return False

    def _picker_key(self):
        return self.job.get("paneKey") or f"row:{self.job['rowId']}"

    def picker_phase(self, body):
        """Run `body` (types /model, works the picker) and ALWAYS leave the
        picker afterwards — result, refusal or exception alike. Holds the
        pane's picker lock throughout (an answer keystroke can't interleave);
        `inPicker` is set before /model and cleared only once a read confirms
        the picker closed (it stays set, refusing answers, when unconfirmed)."""
        lock = self.t.picker_lock(self._picker_key())
        if not lock.acquire(timeout=PICKER_LOCK_WAIT_SEC):
            raise _PickerBusy("an answer to the agent was still being typed")
        try:
            self.picker_used = True
            self.t.update(self.job, inPicker=True)
            try:
                return body()
            finally:
                self.escape_out()
        finally:
            lock.release()

    def open_picker(self):
        self.run_picker_line("/model")   # pane run's own Enter opens it; NO extra Enter
        deadline = self.now() + PICKER_WAIT_SEC
        while True:
            self.sleep(PICKER_POLL_SEC)
            picker = parse_model_picker(self.read_retry())
            if picker is not None:
                return picker
            if self.now() >= deadline:
                return None

    def commit_row(self, model):
        """Park the ❯ cursor on the standard row whose model is `model`
        (re-read after every move), press `s`, answer `Switch model?` with
        `1`, and confirm `Set model to <model> for this session only`.
        Returns None on success, else the reason. Must run inside
        `picker_phase` (which leaves the picker whatever happens)."""
        for _ in range(NAV_ATTEMPTS + 1):
            picker = parse_model_picker(self.read_retry())
            if picker is None:
                return "the model picker closed unexpectedly"
            target = next((i for i, r in enumerate(picker["rows"])
                           if r["standard"] and r["model"] == model), None)
            if target is None:
                return f"no {model} row in the model picker"
            cursor = picker["cursor"]
            if cursor is None:
                return "could not find the picker cursor"
            if cursor == target:
                break
            delta = target - cursor
            self.picker_keys(*(["down"] * delta if delta > 0 else ["up"] * -delta))
            self.sleep(PICKER_POLL_SEC)
        else:
            return "the picker cursor did not reach the target row"
        self.t.update(self.job, sSent=True)
        self.picker_keys("s")
        confirmed = False
        deadline = self.now() + PICKER_WAIT_SEC
        while True:
            self.sleep(PICKER_POLL_SEC)
            lines = self.read_retry()
            if switch_dialog_open(lines):
                if not confirmed:
                    yes = dialog_yes_model(lines)
                    if yes != model:
                        return f"unexpected confirm dialog ({yes or 'no Yes row'})"
                    self.picker_keys("1")
                    confirmed = True
            elif not picker_open(lines):
                line = last_model_line(lines)
                if line and line["model"] == model and line["sessionOnly"]:
                    return None
                if line and line["model"] == model and line["saved"]:
                    return f"{model} was saved as the global default (expected session only)"
            if self.now() >= deadline:
                return f"no 'Set model to {model} for this session only' confirmation"

    # -- steps

    def switch_to_sonnet(self):
        """'switched' | 'skipped' | 'failed'. Raises _Abort."""
        self.set_state(SWITCHING)
        if not self.wait_ready(SWITCHING, STEP_IDLE_TIMEOUT_SEC):
            return "failed"
        try:
            return self.picker_phase(self._switch_in_picker)
        except _Abort:
            raise
        except _PickerBusy as e:
            self.fail(SWITCHING, f"switch to Sonnet failed: {e}")
            return "failed"
        except Exception as e:
            self.fail(SWITCHING, f"switch to Sonnet failed: pane read failed: {e}")
            return "failed"

    def _switch_in_picker(self):
        picker = self.open_picker()
        if picker is None:
            self.fail(SWITCHING, "the model picker did not open")
            return "failed"
        idx, display = current_model(picker)
        if display:
            self.t.update(self.job, originalModel=display)
        if idx is None:
            self.t.update(self.job, switchSkipped=True, skipReason=CUSTOM_MODEL_SKIP)
            return "skipped"
        row = picker["rows"][idx]
        if row["family"] == TARGET_FAMILY:
            self.t.update(self.job, switchSkipped=True, skipReason=ALREADY_SONNET_SKIP)
            return "skipped"
        target = next((r for r in picker["rows"]
                       if r["standard"] and r["family"] == TARGET_FAMILY), None)
        if target is None:
            self.fail(SWITCHING, "no Sonnet row in the model picker")
            return "failed"
        self.t.update(self.job, restoreModel=row["model"])
        err = self.commit_row(target["model"])
        if err:
            self.fail(SWITCHING, "switch to Sonnet failed: " + err)
            return "failed"
        return "switched"

    def compact(self):
        self.set_state(COMPACTING)
        if not self.wait_ready(COMPACTING, STEP_IDLE_TIMEOUT_SEC):
            self.t.update(self.job, compactOk=False)
            return
        try:
            before = compact_boundary_ids(self.io.transcript_tail())
        except Exception:
            before = None
        instructions = self.job.get("instructions")
        text = "/compact" + (" " + instructions if instructions else "")
        result = self.io.send_message(text) or {}
        if not result.get("ok"):
            self.t.update(self.job, compactOk=False)
            self.fail(COMPACTING, "compact not sent: "
                      + str(result.get("error") or result.get("reason") or "refused"))
            return
        deadline = self.now() + COMPACT_TIMEOUT_SEC
        while self.now() < deadline:
            self.sleep(POLL_SEC)
            if before is not None:
                try:
                    after = compact_boundary_ids(self.io.transcript_tail())
                except Exception:
                    after = None
                if after and after - before:
                    self.t.update(self.job, compactOk=True)
                    return
            try:
                lines = self.read()
            except Exception:
                continue
            if compacting(lines) or is_busy(lines):
                continue
            if screen_compacted(lines):
                self.t.update(self.job, compactOk=True)
                return
            error = screen_compact_error(lines)
            if error:
                self.t.update(self.job, compactOk=False)
                self.fail(COMPACTING, "compact failed: " + error)
                return
        self.t.update(self.job, compactOk=False)
        self.fail(COMPACTING, "compaction did not finish within 5 min")

    def restore(self):
        """Put the remembered model back (session only). After a compact
        timeout or an ssh outage the pane may stay busy or unreadable for a
        while: wait for an idle prompt and retry, backing off, for up to
        RESTORE_BUDGET_SEC; only then `modelRestored: false`."""
        self.set_state(RESTORING)
        if not self.job.get("sSent"):
            # Nothing was committed in the picker: the model never changed.
            self.t.update(self.job, modelRestored=True)
            return
        target = self.job.get("restoreModel")
        if not target:
            self.t.update(self.job, modelRestored=False)
            self.fail(RESTORING, "no model remembered to restore")
            return
        deadline = self.now() + RESTORE_BUDGET_SEC
        backoff = RESTORE_BACKOFF_SEC
        while True:
            err = self._restore_once(target, deadline)
            if err is None:
                self.t.update(self.job, modelRestored=True)
                return
            if self.now() >= deadline:
                break
            self.sleep(min(backoff, max(0.0, deadline - self.now())))
            backoff = min(backoff * 2, RESTORE_BACKOFF_MAX_SEC)
        self.t.update(self.job, modelRestored=False)
        self.fail(RESTORING, f"restore to {target} failed within "
                             f"{RESTORE_BUDGET_SEC // 60} min: {err}")

    def _restore_once(self, target, deadline):
        """One attempt: None on success, else why."""
        if not self.wait_ready(RESTORING, max(0.0, deadline - self.now()),
                               abort_on_typed=False, record=False):
            return "the agent did not reach an idle, empty prompt"

        def body():
            if self.open_picker() is None:
                return "the model picker did not open"
            return self.commit_row(target)
        try:
            return self.picker_phase(body)
        except _PickerBusy as e:
            return str(e)
        except Exception as e:
            return f"pane read failed: {e}"

    def send_follow_up(self):
        self.set_state(FOLLOW_UP)
        if not self.wait_ready(FOLLOW_UP, STEP_IDLE_TIMEOUT_SEC):
            self.t.update(self.job, followUpSent=False)
            return
        result = self.io.send_message(self.job["followUp"]) or {}
        self.t.update(self.job, followUpSent=bool(result.get("ok")))
        if not result.get("ok"):
            self.fail(FOLLOW_UP, "follow-up not sent: "
                      + str(result.get("error") or result.get("reason") or "refused"))

    def _finish(self):
        """Never leave a flag null when its step was due: a follow-up that
        existed but did not go out reads `followUpSent: false`; a committed
        switch that was not undone reads `modelRestored: false`."""
        changes = {}
        if self.job.get("followUp") and self.job.get("followUpSent") is not True:
            changes["followUpSent"] = False
        if self.job.get("sSent") and self.job.get("modelRestored") is not True:
            changes["modelRestored"] = False
        if changes:
            self.t.update(self.job, **changes)
        self.set_state(FAILED if self.job.get("error") else DONE)

    def run(self):
        lock = self.t.row_lock(self.job["rowId"])
        if not lock.acquire(timeout=ROW_LOCK_WAIT_SEC):
            self.fail(WAITING_IDLE, "another send to this session was still running")
            self._finish()
            return
        try:
            self._run()
        finally:
            lock.release()

    def _run(self):
        reached_idle = False
        aborted = False
        switching_started = False
        try:
            if not self.wait_ready(WAITING_IDLE, IDLE_TIMEOUT_SEC):
                return
            reached_idle = True
            shown = statusline_model(self.lines)
            if shown:
                self.t.update(self.job, originalModel=shown)
            if model_family(shown) == TARGET_FAMILY:
                self.t.update(self.job, switchSkipped=True, skipReason=ALREADY_SONNET_SKIP)
                outcome = "skipped"
            else:
                switching_started = True
                outcome = self.switch_to_sonnet()
            if outcome != "failed":
                self.compact()
        except _Abort:
            aborted = True
        except Exception as e:  # never leave a job running forever
            _log(f"job {self.job['id']} crashed: {e!r}")
            self.fail(self.job.get("state"), f"internal error: {e.__class__.__name__}")
        finally:
            try:
                if switching_started and not self.job.get("switchSkipped"):
                    self.restore()
                if self.job.get("followUp") and reached_idle and not aborted:
                    try:
                        self.send_follow_up()
                    except _Abort:  # the user typed: never type over it
                        self.t.update(self.job, followUpSent=False)
            except Exception as e:
                _log(f"job {self.job['id']} crashed in cleanup: {e!r}")
                self.fail(self.job.get("state"), f"internal error: {e.__class__.__name__}")
            self._finish()

    def recover(self, was_in_picker, needs_restore):
        """Restart recovery for a job the old process left mid-run (see
        CompactJobs.recover). `_load` already made it active again
        (`restoringModel`, error "dashboard restarted"), so plain Sends and
        new jobs for the row stay refused until `_finish` here. The picker
        is escaped only on a read that shows it (patient reads, no blind
        Esc: this runner typed nothing, and the agent may be mid-turn)."""
        lock = self.t.row_lock(self.job["rowId"])
        if not lock.acquire(timeout=ROW_LOCK_WAIT_SEC):
            self._finish()
            return
        try:
            self.picker_used = True
            if was_in_picker:
                self.escape_out(patient=True)
            if needs_restore:
                self.restore()
        except Exception as e:
            _log(f"job {self.job['id']} recovery crashed: {e!r}")
        finally:
            lock.release()
            self._finish()


# ---------------------------------------------------------------- routes

def handle_get(path, qs, jobs):
    """(payload, status) for the two GET routes, else None."""
    if path == COMPACT_PATH:
        row_id = ((qs.get("rowId") or [""])[0] or "").strip()
        if not row_id:
            return {"ok": False, "error": "missing rowId"}, 400
        return jobs.for_row(row_id)
    if path.startswith(COMPACT_PATH + "/"):
        job_id = path[len(COMPACT_PATH) + 1:]
        if not _JOB_ID_RE.match(job_id):
            return {"ok": False, "error": "unknown job"}, 404
        return jobs.get(job_id)
    return None
