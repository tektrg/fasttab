"""App plugin events from sandboxed apps (Parklet for Mac): POST /api/hooks/event.

A sandboxed app can't run the person's commands (no ~/.config/theindie, no node, no herdr), so it
POSTs each plugin event here (IndieLibKit spec/plugins/README.md, "HTTP event sink"). This server
runs as the person, so it acts as a normal spec host for those events: every ENABLED plugin with a
hook for the event runs with the event JSON on stdin (agent-relay then types a line into the
watching agent's pane).

Safety (the request comes from another process, so it is untrusted input):
- loopback main listener only (never the tailscale remote listener, never another address);
- only the ids-only events, each checked against its spec schema (hand-coded here, stdlib only):
  unknown keys, wrong types or unknown events = 400;
- every id and tag must match `^[A-Za-z0-9._/:-]{1,128}$` before anything is delivered;
- plugins run with an argv list (never a shell), event data only on stdin, in their own process
  group, killed (TERM, then KILL after 2 s) at the manifest's timeoutSec;
- a plugin runs only when plugins-enabled.json holds the sha256 of its current plugin.json bytes.
Every run is logged to <config root>/logs/plugin-runs.jsonl with `app` = the sending app.
"""
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import threading
import time
from datetime import datetime, timezone

PATH = "/api/hooks/event"
KILL_GRACE_SEC = 2
STDERR_TAIL = 2000
MAX_TAGS = 200
MAX_PATH_LEN = 1024

SAFE_ID = re.compile(r"^[A-Za-z0-9._/:-]{1,128}$")
TAG = re.compile(r"^[a-z0-9_-]+(/[a-z0-9_-]+)*$")
APP = re.compile(r"^[a-z0-9-]{1,40}$")
OCCURRED_AT = re.compile(r"^[0-9T:.+Z-]{1,40}$")
PLUGIN_ID = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
HOOK_NAME = re.compile(r"^[a-z]+(\.[a-z]+)+$")
KINDS = {"note", "checklist", "link", "photo", "voice", "file"}
ORIGINS = {"local", "sync", "shared"}
CHANGES = {"content", "checklist", "attachments"}
TAG_SOURCES = {"processing", "ai", "frontmatter", "user", "sync"}
LOOPBACK = {"127.0.0.1", "::1", "::ffff:127.0.0.1"}

# Per event: (required item keys, optional item keys, required extra top keys, optional extra top keys)
_ENVELOPE = {"event", "v", "app", "eventId", "occurredAt", "item"}
_EVENTS = {
    "entry.created": ({"id", "kind", "tags", "origin", "hasSecrets"}, set(), set(), {"paths"}),
    "entry.updated": ({"id", "kind", "tags", "origin"}, set(), {"changed"}, {"paths"}),
    "comment.added": ({"id", "kind", "tags", "origin"}, set(), {"comment"}, {"paths"}),
    "reminder.due": ({"id", "kind", "tags"}, set(), {"reminder"}, {"paths"}),
    # ids-only shape (Parklet): paths may hold the library only; SpeechToDo's file paths are refused.
    "item.tags.added": ({"id", "tags"}, {"kind", "origin"}, {"added", "paths"}, {"source"}),
}


class Invalid(ValueError):
    pass


def _need(cond, why):
    if not cond:
        raise Invalid(why)


def _keys(obj, required, optional, where):
    _need(isinstance(obj, dict), f"{where} must be an object")
    missing = required - obj.keys()
    _need(not missing, f"{where}: missing {sorted(missing)}")
    extra = obj.keys() - required - optional
    _need(not extra, f"{where}: unknown keys {sorted(extra)}")


def _str(value, pattern, where):
    _need(isinstance(value, str) and pattern.match(value) is not None, f"{where}: bad value")


def _tags(value, where, min_items=0):
    _need(isinstance(value, list) and min_items <= len(value) <= MAX_TAGS, f"{where}: bad list")
    for tag in value:
        _need(isinstance(tag, str) and len(tag) <= 100 and TAG.match(tag) and SAFE_ID.match(tag),
              f"{where}: bad tag")


def validate(event):
    """Return the event unchanged when it is an accepted ids-only event, else raise Invalid."""
    _need(isinstance(event, dict), "body must be a JSON object")
    name = event.get("event")
    _need(isinstance(name, str) and name in _EVENTS, "unsupported event")
    item_req, item_opt, top_req, top_opt = _EVENTS[name]
    _keys(event, _ENVELOPE | top_req, top_opt, "event")
    _need(event["v"] == 1 and type(event["v"]) is int, "v must be 1")
    _str(event["app"], APP, "app")
    _str(event["eventId"], SAFE_ID, "eventId")
    _str(event["occurredAt"], OCCURRED_AT, "occurredAt")
    item = event["item"]
    _keys(item, item_req, item_opt, "item")
    _str(item["id"], SAFE_ID, "item.id")
    _tags(item["tags"], "item.tags")
    if "kind" in item:
        _need(item["kind"] in KINDS, "item.kind: bad value")
    if "origin" in item:
        _need(item["origin"] in ORIGINS, "item.origin: bad value")
    if "hasSecrets" in item:
        _need(type(item["hasSecrets"]) is bool, "item.hasSecrets must be a boolean")
    if "paths" in event:
        paths = event["paths"]
        _keys(paths, {"library"}, set(), "paths")
        lib = paths["library"]
        _need(isinstance(lib, str) and lib.startswith("/") and len(lib) <= MAX_PATH_LEN
              and not any(ord(c) < 32 or ord(c) == 127 for c in lib), "paths.library: bad value")
    if name == "entry.updated":
        changed = event["changed"]
        _need(isinstance(changed, list) and changed and all(c in CHANGES for c in changed), "changed: bad value")
    elif name == "comment.added":
        comment = event["comment"]
        _keys(comment, {"id", "byMe"}, set(), "comment")
        _str(comment["id"], SAFE_ID, "comment.id")
        _need(type(comment["byMe"]) is bool, "comment.byMe must be a boolean")
    elif name == "reminder.due":
        reminder = event["reminder"]
        _keys(reminder, {"dueAt"}, set(), "reminder")
        _str(reminder["dueAt"], OCCURRED_AT, "reminder.dueAt")
    elif name == "item.tags.added":
        _tags(event["added"], "added", min_items=1)
        if "source" in event:
            _need(event["source"] in TAG_SOURCES, "source: bad value")
    return event


# ---- Host (spec/plugins/README.md "Delivery") ---------------------------------------------------

def config_root(env=None):
    env = os.environ if env is None else env
    configured = (env.get("THEINDIE_CONFIG_DIR") or "").strip()
    return configured or os.path.join(env.get("HOME") or os.path.expanduser("~"), ".config", "theindie")


def _iso_now():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _manifest(folder, name):
    """(manifest dict, sha256) for a valid plugin.json whose id is the folder name, else None."""
    try:
        with open(os.path.join(folder, "plugin.json"), "rb") as f:
            raw = f.read()
        data = json.loads(raw)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or data.get("id") != name or not PLUGIN_ID.match(name):
        return None
    if data.get("version") != 1 or not isinstance(data.get("hooks"), dict) or not data["hooks"]:
        return None
    for hook_name, hook in data["hooks"].items():
        if not HOOK_NAME.match(hook_name) or not isinstance(hook, dict):
            return None
        run = hook.get("run")
        if run is not None and not (
                (isinstance(run, str) and run) or
                (isinstance(run, list) and run and all(isinstance(a, str) and a for a in run))):
            return None
        timeout = hook.get("timeoutSec", 30)
        if type(timeout) is not int or not 1 <= timeout <= 300:
            return None
        if run is None and not isinstance(hook.get("post"), str):
            return None
    return data, hashlib.sha256(raw).hexdigest()


def _enabled(root):
    try:
        with open(os.path.join(root, "plugins-enabled.json")) as f:
            data = json.load(f)
        enabled = data.get("enabled") if isinstance(data, dict) else None
    except (OSError, ValueError):
        return {}  # missing or corrupt = nothing enabled (fail closed)
    if not isinstance(enabled, dict):
        return {}
    return {k: v.get("sha256") for k, v in enabled.items() if isinstance(v, dict)}


def targets(event_name, root):
    """[(plugin id, folder, hook)] for enabled plugins with a hook for this event, sorted by id."""
    plugins = os.path.join(root, "plugins")
    try:
        names = sorted(os.listdir(plugins))
    except OSError:
        return []
    consent = _enabled(root)
    out = []
    for name in names:
        folder = os.path.join(plugins, name)
        if name.startswith(".") or not os.path.isdir(folder):
            continue
        parsed = _manifest(folder, name)
        if parsed is None:
            continue
        manifest, sha = parsed
        hook = manifest["hooks"].get(event_name)
        if hook is not None and consent.get(name) == sha:
            out.append((name, folder, hook))
    return out


def _resolve(command, folder, env):
    if command.startswith("/"):
        return command
    if "/" in command:
        return os.path.normpath(os.path.join(folder, command))
    return shutil.which(command, path=env.get("PATH") or "/usr/bin:/bin")


def run_hook(argv, folder, stdin_bytes, env, timeout_sec):
    """Run one hook without a shell. Returns (status, exitCode, durationMs, stderrTail)."""
    start = time.monotonic()
    ms = lambda: int((time.monotonic() - start) * 1000)  # noqa: E731
    exe = _resolve(argv[0], folder, env)
    if not exe or not os.access(exe, os.X_OK):
        return "failed", None, ms(), f"command not found: {argv[0]}"
    try:
        proc = subprocess.Popen([exe] + list(argv[1:]), cwd=folder, env=env, shell=False,
                                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                start_new_session=True)
    except OSError as e:
        return "failed", None, ms(), str(e)[-STDERR_TAIL:]
    timed_out = False
    try:
        _, err = proc.communicate(stdin_bytes, timeout=timeout_sec)
    except subprocess.TimeoutExpired:
        timed_out = True
        _kill_group(proc, signal.SIGTERM)
        try:
            _, err = proc.communicate(timeout=KILL_GRACE_SEC)
        except subprocess.TimeoutExpired:
            _kill_group(proc, signal.SIGKILL)
            _, err = proc.communicate()
    tail = (err or b"").decode("utf-8", "replace")[-STDERR_TAIL:]
    if timed_out:
        return "timeout", None, ms(), tail
    return ("ok" if proc.returncode == 0 else "failed"), proc.returncode, ms(), tail


def _kill_group(proc, sig):
    try:
        os.killpg(proc.pid, sig)
    except (ProcessLookupError, PermissionError):
        pass


_log_lock = threading.Lock()


def _log(root, record):
    path = os.path.join(root, "logs", "plugin-runs.jsonl")
    line = json.dumps(record, separators=(",", ":")) + "\n"
    with _log_lock:
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "a") as f:
                f.write(line)
        except OSError:
            pass


def deliver(event, root=None, env=None):
    """Run every enabled hook for a VALIDATED event; returns the logged records (sync; tests)."""
    base_env = dict(os.environ if env is None else env)
    root = root or config_root(base_env)
    body = json.dumps(event, separators=(",", ":")).encode()
    records = []
    for plugin_id, folder, hook in targets(event["event"], root):
        record = {"at": None, "app": event["app"], "pluginId": plugin_id, "event": event["event"],
                  "eventId": event["eventId"]}
        run = hook.get("run")
        if run is None:
            record.update(status="skipped", exitCode=None, durationMs=0, stderrTail="skipped: post not supported")
        else:
            argv = [run] if isinstance(run, str) else run
            run_env = dict(base_env, THEINDIE_EVENT=event["event"], THEINDIE_EVENT_VERSION=str(event["v"]),
                           THEINDIE_APP=event["app"], THEINDIE_PLUGIN_DIR=folder)
            status, code, duration, tail = run_hook(argv, folder, body, run_env, hook.get("timeoutSec", 30))
            record.update(status=status, exitCode=code, durationMs=duration, stderrTail=tail)
        record["at"] = _iso_now()
        _log(root, record)
        records.append(record)
    return records


def handle_post(path, read_raw_body, is_remote_listener, client_host, root=None, background=True):
    """Route POST /api/hooks/event. Returns (json, status) or None for other paths."""
    if path != PATH:
        return None
    if is_remote_listener or client_host not in LOOPBACK:
        return {"ok": False, "error": "loopback only"}, 403
    try:
        event = validate(json.loads(read_raw_body() or b"null"))
    except (ValueError, Invalid) as e:  # json errors are ValueErrors too
        return {"ok": False, "error": f"invalid event: {e}"[:200]}, 400
    root = root or config_root()
    count = len(targets(event["event"], root))
    if background:
        threading.Thread(target=deliver, args=(event, root), daemon=True, name="app-hook-event").start()
    else:
        deliver(event, root)
    return {"ok": True, "event": event["event"], "eventId": event["eventId"], "plugins": count}, 202
