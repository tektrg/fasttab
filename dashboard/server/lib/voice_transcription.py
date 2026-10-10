"""Voice-note transcription: phone uploads audio (audio_attachments.py), the
Mac transcribes it with SpeechToDo's CLI (Gemini cloud engine), the phone
polls for text.

  POST /api/transcribe {id}   start (or restart a failed) job -> {ok,id,state:"pending"}
  GET  /api/transcribe/<id>   -> {ok,id,state:"pending"|"done"|"failed",text?,error?}

Design:
- `Transcriber.transcribe(audio_path, timeout_sec) -> text` is the seam; tests
  inject a fake. The real one drives the SpeechToDo CLI in a throwaway
  workspace (deleted after), in its own process group so a timeout kills the
  whole tree.
- Jobs run on a 2-worker pool; results live in memory AND in
  `<id>.transcript.json` next to the audio (survives a dashboard restart,
  swept with the audio by image_attachments.sweep_expired).
- The Gemini key is read from a 0600 file (never an argument, never logged,
  never returned); it reaches the CLI only through the child's environment.
- Every error the phone sees is a fixed plain-English sentence.
"""
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
from concurrent.futures import ThreadPoolExecutor

import audio_attachments
import image_attachments

MAX_TEXT_CHARS = 8000
MAX_CONCURRENT_JOBS = 2
MIN_TIMEOUT_SEC = 60
MAX_TIMEOUT_SEC = 600
#: Compressed speech is never slower than ~24 kbit/s, so size / this bounds
#: the recording length from above.
_MIN_BYTES_PER_SEC = 3000

KEY_MISSING_MESSAGE = "Transcription isn't set up on the Mac (missing Gemini key)"
NO_SPEECH_MESSAGE = "No speech detected"
TIMEOUT_MESSAGE = "Transcription took too long. Try a shorter recording."
GENERIC_FAILURE_MESSAGE = "Transcription failed. Try again."
QUOTA_MESSAGE = "The transcription service is out of quota right now. Try again later."
INTERRUPTED_MESSAGE = "Transcription was interrupted. Try again."
NOT_FOUND_MESSAGE = "That recording wasn't found. It may have expired. Record it again."

DEFAULT_NODE_PATH = "/Users/trungluong/.nvm/versions/node/v24.20.0/bin/node"
DEFAULT_CLI_PATH = "/Users/trungluong/01_Project/speechtodo/src/apps/cli/dist/index.js"
#: Where the SpeechToDo desktop app leaves the Gemini key (0600, raw key).
DEFAULT_KEY_FILE = os.path.expanduser(
    "~/Library/Application Support/SpeechToDo Dev/gemini-key.runtime")

_MOBILE_MARKER_SUFFIX = ".speechtodo-owner-pending.json"
_RESULT_SUFFIX = ".transcript.json"
_QUOTA_HINTS = ("resource_exhausted", "quota")


class TranscribeError(Exception):
    """A failure whose message is safe to show the user as-is."""


# ---------------------------------------------------------------- normalizing

_LEADING_COMMAND_RE = re.compile(r"^[\s/!]+")


def normalize_transcript(raw):
    """Text safe to send as a chat message ("" when nothing is left).

    Control chars and newlines/tabs become single spaces, a leading `/` or
    `!` is dropped (so speech can never become a slash/shell command), and
    the result is cut to MAX_TEXT_CHARS at a word boundary."""
    cleaned = []
    for ch in str(raw or ""):
        category = unicodedata.category(ch)
        if ch.isspace() or category in ("Zl", "Zp"):
            cleaned.append(" ")
        elif category in ("Cc", "Cf", "Cs"):
            continue
        else:
            cleaned.append(ch)
    text = " ".join("".join(cleaned).split())
    text = _LEADING_COMMAND_RE.sub("", text)
    if len(text) > MAX_TEXT_CHARS:
        cut = text[:MAX_TEXT_CHARS]
        if text[MAX_TEXT_CHARS] != " " and " " in cut:
            cut = cut.rsplit(" ", 1)[0]
        text = cut.rstrip()
    return text


def timeout_for_size(size_bytes):
    """Per-job time budget derived from the recording's size, 60 s - 10 min."""
    estimated_audio_sec = size_bytes / _MIN_BYTES_PER_SEC
    return int(max(MIN_TIMEOUT_SEC, min(MAX_TIMEOUT_SEC, 60 + 2 * estimated_audio_sec)))


# ---------------------------------------------------------------- settings/key

def load_settings(config_path=None):
    """The `transcribe` block of agent-dashboard's config.json ({} if absent).
    Keys: geminiKeyFile, nodePath, cliPath."""
    if config_path is None:
        import dashboard_config
        config_path = dashboard_config.CONFIG_PATH
    try:
        with open(config_path) as f:
            block = (json.load(f) or {}).get("transcribe")
    except (OSError, ValueError, AttributeError):
        return {}
    return block if isinstance(block, dict) else {}


def read_gemini_key(settings, environ=None):
    """The Gemini key (str) or None. Order: config geminiKeyFile, env
    GEMINI_KEY_FILE, the SpeechToDo desktop app's key file, env GOOGLE_API_KEY."""
    environ = os.environ if environ is None else environ
    candidates = [settings.get("geminiKeyFile"), environ.get("GEMINI_KEY_FILE"), DEFAULT_KEY_FILE]
    for candidate in candidates:
        if not isinstance(candidate, str) or not candidate.strip():
            continue
        try:
            with open(os.path.expanduser(candidate)) as f:
                key = f.read(512).strip()
        except OSError:
            continue
        if key and not any(c.isspace() for c in key):
            return key
    env_key = (environ.get("GOOGLE_API_KEY") or "").strip()
    return env_key or None


def _scrub(text, secrets):
    for secret in secrets:
        if secret:
            text = text.replace(secret, "***")
    return text


# ---------------------------------------------------------------- transcribers

class SpeechToDoCliTranscriber:
    """Runs `speechtodo process-pending --provider gemini` on one file."""

    def __init__(self, node_path=None, cli_path=None, settings=None, environ=None, log=None):
        settings = settings if settings is not None else load_settings()
        self.node_path = settings.get("nodePath") or node_path or DEFAULT_NODE_PATH
        self.cli_path = settings.get("cliPath") or cli_path or DEFAULT_CLI_PATH
        self._settings = settings
        self._environ = environ
        self._log = log or (lambda line: print(line, file=sys.stderr))

    def transcribe(self, audio_path, timeout_sec):
        key = read_gemini_key(self._settings, self._environ)
        if not key:
            raise TranscribeError(KEY_MISSING_MESSAGE)
        if not (os.path.isfile(self.node_path) and os.path.isfile(self.cli_path)):
            raise TranscribeError("Transcription isn't set up on the Mac (SpeechToDo CLI not found)")
        workspace = tempfile.mkdtemp(prefix="voice-transcribe-")
        try:
            return self._run(audio_path, workspace, key, timeout_sec)
        finally:
            shutil.rmtree(workspace, ignore_errors=True)

    def _run(self, audio_path, workspace, key, timeout_sec):
        self._cli(["init", "--workspace", workspace], key, 60, workspace)
        ext = os.path.splitext(audio_path)[1] or ".m4a"
        copied = os.path.join(workspace, "voice" + ext)
        shutil.copyfile(audio_path, copied)
        marker = {"version": 1, "audioFileName": os.path.basename(copied),
                  "sizeBytes": os.path.getsize(copied), "recordedAtIso": "2026-01-01T00:00:00Z"}
        with open(copied + _MOBILE_MARKER_SUFFIX, "w") as f:
            json.dump(marker, f)
        output = self._cli(["process-pending", "--provider", "gemini", "--workspace", workspace],
                           key, timeout_sec, workspace,
                           ready=lambda: self._read_transcript(workspace) is not None)
        text = self._read_transcript(workspace)
        if text is None:
            self._log(f"voice-transcribe: no transcript produced: {_scrub(output, [key])[-300:]!r}")
            raise TranscribeError(self._failure_message(output))
        return text

    @staticmethod
    def _failure_message(output):
        lowered = output.lower()
        return QUOTA_MESSAGE if any(h in lowered for h in _QUOTA_HINTS) else GENERIC_FAILURE_MESSAGE

    def _cli(self, args, key, timeout_sec, workspace, ready=None):
        """Run the CLI in its own process group; returns its output text.

        The real CLI writes the transcript and then lingers for minutes with
        an open handle, so when `ready()` turns true the group is killed
        right away instead of waiting for it to exit."""
        env = {"PATH": f"{os.path.dirname(self.node_path)}:/usr/bin:/bin",
               "HOME": os.path.expanduser("~"), "GOOGLE_API_KEY": key,
               "TMPDIR": tempfile.gettempdir()}
        output_path = os.path.join(workspace, ".cli-output.log")
        with open(output_path, "w") as sink:
            proc = subprocess.Popen(
                [self.node_path, self.cli_path] + args, env=env, stdin=subprocess.DEVNULL,
                stdout=sink, stderr=subprocess.STDOUT, start_new_session=True, text=True)
            deadline = time.monotonic() + timeout_sec
            timed_out = False
            ready_seen = False
            while proc.poll() is None:
                if ready is not None and ready():
                    ready_seen = True
                    break
                if time.monotonic() >= deadline:
                    timed_out = True
                    break
                time.sleep(0.2)
            if proc.poll() is None:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except OSError:
                    pass
            proc.wait()
        with open(output_path, errors="replace") as f:
            output = f.read()
        if timed_out:
            raise TranscribeError(TIMEOUT_MESSAGE)
        if proc.returncode != 0 and not ready_seen:
            self._log(f"voice-transcribe: cli exited {proc.returncode}: {_scrub(output, [key])[-300:]!r}")
            raise TranscribeError(self._failure_message(output))
        return output

    @staticmethod
    def _read_transcript(workspace):
        outputs = os.path.join(workspace, ".speechtodo", "outputs")
        try:
            item_dirs = sorted(os.listdir(outputs))
        except OSError:
            return None
        for item_dir in item_dirs:
            try:
                with open(os.path.join(outputs, item_dir, "transcript.json")) as f:
                    segments = (json.load(f) or {}).get("segments")
            except (OSError, ValueError):
                continue
            if isinstance(segments, list):
                return " ".join(str(s.get("text") or "") for s in segments if isinstance(s, dict))
        return None


# ---------------------------------------------------------------- jobs

class TranscriptionJobs:
    """In-memory job table backed by `<id>.transcript.json` files."""

    def __init__(self, transcriber, directory=None, max_concurrent=MAX_CONCURRENT_JOBS):
        self._transcriber = transcriber
        self._directory = directory
        self._lock = threading.Lock()
        self._jobs = {}  # id -> {"state", "text"?, "error"?}
        self._pool = ThreadPoolExecutor(max_workers=max_concurrent, thread_name_prefix="voice-job")

    @property
    def directory(self):
        return self._directory or image_attachments.ATTACHMENTS_DIR

    def _result_path(self, audio_id):
        return os.path.join(self.directory, audio_id + _RESULT_SUFFIX)

    def _persist(self, audio_id, record):
        try:
            image_attachments.ensure_private_dir(self.directory)
            path = self._result_path(audio_id)
            tmp = f"{path}.tmp"
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                json.dump(record, f)
            os.replace(tmp, path)
        except OSError as e:
            print(f"voice-transcribe: could not save result: {e.__class__.__name__}", file=sys.stderr)

    def _set(self, audio_id, record):
        with self._lock:
            self._jobs[audio_id] = record
        self._persist(audio_id, record)

    def start(self, audio_id):
        """Queue a job. (payload, http_status); never blocks on the work."""
        audio_path = audio_attachments.find_audio(audio_id, self.directory)
        if audio_path is None:
            return {"ok": False, "error": NOT_FOUND_MESSAGE}, 404
        with self._lock:
            current = self._jobs.get(audio_id)
            if current and current["state"] in ("pending", "done"):
                return {"ok": True, "id": audio_id, "state": current["state"]}, 200
            self._jobs[audio_id] = {"state": "pending"}
        self._persist(audio_id, {"state": "pending"})
        self._pool.submit(self._run, audio_id, audio_path)
        return {"ok": True, "id": audio_id, "state": "pending"}, 200

    def _run(self, audio_id, audio_path):
        try:
            timeout_sec = timeout_for_size(os.path.getsize(audio_path))
            text = normalize_transcript(self._transcriber.transcribe(audio_path, timeout_sec))
            record = ({"state": "done", "text": text} if text
                      else {"state": "failed", "error": NO_SPEECH_MESSAGE})
        except TranscribeError as e:
            record = {"state": "failed", "error": str(e)}
        except Exception as e:  # never leak internals to the phone
            print(f"voice-transcribe: job crashed: {e.__class__.__name__}", file=sys.stderr)
            record = {"state": "failed", "error": GENERIC_FAILURE_MESSAGE}
        self._set(audio_id, record)

    def status(self, audio_id):
        """(payload, http_status) for GET /api/transcribe/<id>."""
        if not image_attachments.ID_RE.match(audio_id or ""):
            return {"ok": False, "error": NOT_FOUND_MESSAGE}, 404
        with self._lock:
            record = self._jobs.get(audio_id)
        if record is None:
            record = self._load_from_disk(audio_id)
        if record is None:
            return {"ok": False, "error": NOT_FOUND_MESSAGE}, 404
        return {"ok": True, "id": audio_id, **record}, 200

    def _load_from_disk(self, audio_id):
        """A result from before a restart. A job that was still pending then
        can never finish now: report it failed so the phone can retry."""
        try:
            with open(self._result_path(audio_id)) as f:
                record = json.load(f)
        except (OSError, ValueError):
            return None
        state = record.get("state") if isinstance(record, dict) else None
        if state == "done" and isinstance(record.get("text"), str):
            loaded = {"state": "done", "text": record["text"]}
        elif state == "failed" and isinstance(record.get("error"), str):
            loaded = {"state": "failed", "error": record["error"]}
        elif state == "pending":
            loaded = {"state": "failed", "error": INTERRUPTED_MESSAGE}
        else:
            return None
        with self._lock:
            # Don't clobber a job that started between our read and now.
            return self._jobs.setdefault(audio_id, loaded)


# ---------------------------------------------------------------- routes

TRANSCRIBE_PATH = "/api/transcribe"
_JOBS = None
_JOBS_LOCK = threading.Lock()


def get_jobs():
    global _JOBS
    with _JOBS_LOCK:
        if _JOBS is None:
            _JOBS = TranscriptionJobs(SpeechToDoCliTranscriber())
        return _JOBS


def handle_get(path, jobs=None):
    """(payload, status) for GET /api/transcribe/<id>, else None."""
    if not path.startswith(TRANSCRIBE_PATH + "/"):
        return None
    return (jobs or get_jobs()).status(path[len(TRANSCRIBE_PATH) + 1:])


def handle_post(path, read_body, jobs=None):
    """(payload, status) for POST /api/transcribe, else None."""
    if path != TRANSCRIBE_PATH:
        return None
    try:
        body = read_body()
    except ValueError:
        return {"ok": False, "error": "Bad request."}, 400
    audio_id = body.get("id") if isinstance(body, dict) else None
    if not isinstance(audio_id, str):
        return {"ok": False, "error": "Bad request."}, 400
    return (jobs or get_jobs()).start(audio_id)
