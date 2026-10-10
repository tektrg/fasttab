#!/usr/bin/env python3
"""Voice notes: POST /api/attachments/audio, POST /api/transcribe,
GET /api/transcribe/<id> (server/lib/audio_attachments.py +
voice_transcription.py + the server wiring, real HTTP on a throwaway port).

SAFETY: temp attachments/config/state dirs, no network, no real key: the
CLI is a fake shell script, the job transcriber a fake class. Hostile input
is the inert sentinel `$(echo INJECTED)` only.
"""
import importlib.util
import json
import os
import stat
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
DASHBOARD_ROOT = os.path.dirname(HERE)
_tmp = tempfile.mkdtemp(prefix="voice-test-")
ATTACH_DIR = os.path.join(_tmp, "attachments")
os.environ["AGENTBAR_ATTACHMENTS_DIR"] = ATTACH_DIR
os.environ["CHIEF_DASHBOARD_CONFIG_HOME"] = os.path.join(_tmp, "config")
os.environ["CHIEF_DASHBOARD_STATE_HOME"] = os.path.join(_tmp, "state")
os.environ["CHIEF_DASHBOARD_MACHINES"] = "{}"
os.environ["CHIEF_HERDR_BIN"] = os.path.join(_tmp, "no-such-herdr")
os.environ["AGENTBAR_PERSONAS_FILE"] = os.path.join(_tmp, "no-personas.json")
sys.path.insert(0, os.path.join(DASHBOARD_ROOT, "server", "lib"))
import audio_attachments as aa  # noqa: E402
import voice_transcription as vt  # noqa: E402

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


SENTINEL = "$(echo INJECTED)"
M4A = b"\x00\x00\x00\x20ftypM4A " + b"\x00" * 64
WEBM = b"\x1a\x45\xdf\xa3" + b"\x00" * 64
OGG = b"OggS" + b"\x00" * 64
WAV = b"RIFF\x00\x00\x00\x00WAVE" + b"\x00" * 64
MP3_ID3 = b"ID3\x04" + b"\x00" * 64
MP3_FRAME = b"\xff\xfb\x90\x00" + b"\x00" * 64
AAC_ADTS = b"\xff\xf1\x50\x80" + b"\x00" * 64
KEY = "AIzaFAKEKEY000000000000000000000000001"


def wait_state(jobs, audio_id, want, secs=10):
    end = time.time() + secs
    while time.time() < end:
        payload, _ = jobs.status(audio_id)
        if payload.get("state") == want:
            return payload
        time.sleep(0.02)
    return jobs.status(audio_id)[0]


print("== normalization ==")
check("newlines/tabs collapse", vt.normalize_transcript("a\n\nb\t c\r\nd"), "a b c d")
check("control chars stripped", vt.normalize_transcript("he\x00l\x07lo​ world"), "hello world")
check("trimmed", vt.normalize_transcript("  hi  "), "hi")
check("leading slash stripped", vt.normalize_transcript("/clear everything"), "clear everything")
check("leading bang stripped", vt.normalize_transcript("!rm thing"), "rm thing")
check("stacked guards stripped", vt.normalize_transcript(" / ! /x"), "x")
check("inner slash kept", vt.normalize_transcript("a/b and c!"), "a/b and c!")
check("only guard -> empty", vt.normalize_transcript("/ !"), "")
long_text = ("word " * 3000).strip()
out = vt.normalize_transcript(long_text)
check("cap 8000", len(out) <= 8000, True)
check("cut at word boundary", out.endswith("word") and not out.endswith("wor"), True)
mid = "x" * 7995 + " abcdefghij"
check("never cuts a word in half", vt.normalize_transcript(mid), "x" * 7995)
check("sentinel text stays inert text", vt.normalize_transcript(SENTINEL), SENTINEL)

print("\n== timeout derivation ==")
check("small file -> floor", vt.timeout_for_size(1_000), 60)
check("huge file -> 10 min cap", vt.timeout_for_size(25 * 1024 * 1024), 600)
check("monotonic", vt.timeout_for_size(600_000) < vt.timeout_for_size(1_200_000), True)

print("\n== sniffing + store_audio ==")
for label, blob, want in [("m4a", M4A, "mp4"), ("webm", WEBM, "webm"), ("ogg", OGG, "ogg"),
                          ("wav", WAV, "wav"), ("mp3 id3", MP3_ID3, "mp3"),
                          ("mp3 frame", MP3_FRAME, "mp3"), ("aac adts", AAC_ADTS, "aac")]:
    check(f"sniff {label}", aa.sniff_container(blob), want)
check("sniff junk", aa.sniff_container(b"hello world, not audio"), None)
payload, status = aa.store_audio(M4A, "audio/mp4; codecs=mp4a.40.2")
check("m4a stored (codecs param stripped)", (status, payload.get("ok")), (200, True))
stored_id = payload["id"]
path = aa.find_audio(stored_id)
check("stored as .m4a under attachments dir", os.path.dirname(path) == ATTACH_DIR and path.endswith(".m4a"), True)
check("file mode 0600", oct(os.stat(path).st_mode & 0o777), "0o600")
check("dir mode 0700", oct(os.stat(ATTACH_DIR).st_mode & 0o777), "0o700")
for ctype in ["audio/mp4", "audio/x-m4a", "audio/webm", "audio/ogg", "audio/mpeg", "audio/wav", "audio/aac"]:
    check(f"type allowed {ctype}", aa.store_audio(M4A, ctype)[1], 200)
check("video/mp4 refused", aa.store_audio(M4A, "video/mp4")[1], 415)
check("image/png refused", aa.store_audio(M4A, "image/png")[1], 415)
check("missing type refused", aa.store_audio(M4A, None)[1], 415)
check("sentinel content-type refused, not run", aa.store_audio(M4A, "audio/mp4" + SENTINEL)[1], 415)
check("bytes not audio refused", aa.store_audio(b"just text " + SENTINEL.encode(), "audio/mp4")[1], 415)
check("empty refused", aa.store_audio(b"", "audio/mp4")[1], 400)
check("over 25 MB refused", aa.store_audio(M4A + b"\x00" * aa.MAX_AUDIO_BYTES, "audio/mp4")[1], 413)
check("find_audio rejects bad ids", [aa.find_audio(x) for x in
      ["../etc/passwd", "ABC", "a" * 31, "g" * 32, SENTINEL, None, 5]], [None] * 7)
check("find_audio unknown valid id", aa.find_audio("0" * 32), None)

print("\n== job state machine ==")


class FakeTranscriber:
    def __init__(self, result="hello there", delay=0.0, fail=None):
        self.result, self.delay, self.fail = result, delay, fail
        self.calls = 0
        self.timeouts = []
        self.active = 0
        self.max_active = 0
        self.gate = None
        self._lock = threading.Lock()

    def transcribe(self, audio_path, timeout_sec):
        with self._lock:
            self.calls += 1
            self.active += 1
            self.max_active = max(self.max_active, self.active)
        self.timeouts.append(timeout_sec)
        try:
            if self.gate:
                self.gate.wait(10)
            time.sleep(self.delay)
            if self.fail:
                raise self.fail
            return self.result
        finally:
            with self._lock:
                self.active -= 1


def new_audio():
    return aa.store_audio(M4A, "audio/mp4")[0]["id"]


fake = FakeTranscriber("  /hello\nthere  ")
jobs = vt.TranscriptionJobs(fake)
check("unknown valid id -> 404", jobs.start("0" * 32)[1], 404)
check("bad id on status -> 404", jobs.status("../x")[1], 404)
check("status of never-started id -> 404", jobs.status(new_audio())[1], 404)
audio_id = new_audio()
first = jobs.start(audio_id)
check("start returns pending", first, ({"ok": True, "id": audio_id, "state": "pending"}, 200))
done = wait_state(jobs, audio_id, "done")
check("done + normalized text", (done["state"], done.get("text")), ("done", "hello there"))
check("restart of done job does not re-run", (jobs.start(audio_id)[0]["state"], fake.calls), ("done", 1))
result_file = os.path.join(ATTACH_DIR, audio_id + ".transcript.json")
check("result persisted 0600", oct(os.stat(result_file).st_mode & 0o777), "0o600")

jobs_after_restart = vt.TranscriptionJobs(FakeTranscriber("never"))
reloaded = jobs_after_restart.status(audio_id)[0]
check("done job survives restart", (reloaded["state"], reloaded.get("text")), ("done", "hello there"))

empty_id = new_audio()
empty_jobs = vt.TranscriptionJobs(FakeTranscriber("  \n "))
empty_jobs.start(empty_id)
empty = wait_state(empty_jobs, empty_id, "failed")
check("empty transcript -> No speech detected", empty.get("error"), "No speech detected")

boom_id = new_audio()
boom = FakeTranscriber(fail=RuntimeError(f"/Users/x/secret/path {KEY} Traceback"))
boom_jobs = vt.TranscriptionJobs(boom)
boom_jobs.start(boom_id)
failed = wait_state(boom_jobs, boom_id, "failed")
check("crash -> plain error", failed.get("error"), vt.GENERIC_FAILURE_MESSAGE)
check("no path/key/trace in reply", any(s in json.dumps(failed) for s in (KEY, "/Users", "Traceback")), False)
boom.fail = None
boom.result = "second try works"
check("failed job restarts", boom_jobs.start(boom_id)[0]["state"], "pending")
check("restart succeeds", wait_state(boom_jobs, boom_id, "done").get("text"), "second try works")

pend_id = new_audio()
with open(os.path.join(ATTACH_DIR, pend_id + ".transcript.json"), "w") as f:
    json.dump({"state": "pending"}, f)
interrupted = vt.TranscriptionJobs(FakeTranscriber()).status(pend_id)[0]
check("pending-at-restart reports failed/interrupted",
      (interrupted["state"], interrupted.get("error")), ("failed", vt.INTERRUPTED_MESSAGE))

print("\n== concurrency cap ==")
slow = FakeTranscriber(delay=0.05)
slow.gate = threading.Event()
cap_jobs = vt.TranscriptionJobs(slow)
ids = [new_audio() for _ in range(5)]
for i in ids:
    cap_jobs.start(i)
time.sleep(0.4)
check("at most 2 running", slow.max_active, 2)
check("the rest wait as pending", sum(1 for i in ids if cap_jobs.status(i)[0]["state"] == "pending"), 5)
slow.gate.set()
check("all finish", all(wait_state(cap_jobs, i, "done")["state"] == "done" for i in ids), True)
check("never above 2", slow.max_active, 2)
check("timeout derived and passed", all(60 <= t <= 600 for t in slow.timeouts), True)

print("\n== CLI transcriber (fake node, no network) ==")
bin_dir = os.path.join(_tmp, "bin")
os.makedirs(bin_dir)
cli_file = os.path.join(bin_dir, "cli.js")
open(cli_file, "w").write("// fake cli entry\n")
key_file = os.path.join(_tmp, "gemini.key")
with open(key_file, "w") as f:
    f.write(KEY + "\n")
os.chmod(key_file, 0o600)
log_lines = []
pid_file = os.path.join(_tmp, "child.pid")
env_dump = os.path.join(_tmp, "env.dump")


def fake_node(name, body):
    p = os.path.join(bin_dir, name)
    with open(p, "w") as f:
        f.write("#!/bin/sh\n" + body)
    os.chmod(p, os.stat(p).st_mode | stat.S_IXUSR)
    return p


good_node = fake_node("node-good", f'''
sub="$2"
if [ "$sub" = init ]; then mkdir -p "$4/.speechtodo"; exit 0; fi
ws="$6"
echo "$GOOGLE_API_KEY" > "{env_dump}"
ls "$ws" > "{env_dump}.ls"
mkdir -p "$ws/.speechtodo/outputs/voice-1"
printf '{{"segments":[{{"text":"hello"}},{{"text":"this is a test"}}]}}' > "$ws/.speechtodo/outputs/voice-1/transcript.json"
echo done
''')
settings = {"geminiKeyFile": key_file, "nodePath": good_node, "cliPath": cli_file}
tr = vt.SpeechToDoCliTranscriber(settings=settings, environ={}, log=log_lines.append)
audio_path = aa.find_audio(new_audio())
check("cli transcriber returns joined segments", tr.transcribe(audio_path, 20), "hello this is a test")
check("key reached the child via env only", open(env_dump).read().strip(), KEY)
listing = open(env_dump + ".ls").read()
check("audio + marker were placed in the workspace",
      "voice.m4a" in listing and "voice.m4a.speechtodo-owner-pending.json" in listing, True)
leftovers = [n for n in os.listdir(tempfile.gettempdir()) if n.startswith("voice-transcribe-")]
check("temp workspace deleted", leftovers, [])

no_key = vt.SpeechToDoCliTranscriber(settings={"geminiKeyFile": os.path.join(_tmp, "nope"),
                                               "nodePath": good_node, "cliPath": cli_file},
                                     environ={"HOME": _tmp}, log=log_lines.append)
# The default desktop-app key file may exist on a dev Mac: pin it away.
real_default = vt.DEFAULT_KEY_FILE
vt.DEFAULT_KEY_FILE = os.path.join(_tmp, "no-default-key")
try:
    try:
        no_key.transcribe(audio_path, 20)
        check("missing key raises", False, True)
    except vt.TranscribeError as e:
        check("missing key message", str(e), "Transcription isn't set up on the Mac (missing Gemini key)")
finally:
    vt.DEFAULT_KEY_FILE = real_default

leaky_node = fake_node("node-leaky", f'''
if [ "$2" = init ]; then exit 0; fi
echo "boom $GOOGLE_API_KEY at /Users/someone/secret Traceback (most recent call last)" >&2
exit 1
''')
leaky = vt.SpeechToDoCliTranscriber(settings={**settings, "nodePath": leaky_node}, environ={},
                                    log=log_lines.append)
try:
    leaky.transcribe(audio_path, 20)
    check("cli failure raises", False, True)
except vt.TranscribeError as e:
    check("cli failure -> generic plain error", str(e), vt.GENERIC_FAILURE_MESSAGE)
check("key never in any log line", any(KEY in line for line in log_lines), False)
check("scrubbed marker used in log", any("***" in line for line in log_lines), True)

quota_node = fake_node("node-quota", '''
if [ "$2" = init ]; then exit 0; fi
echo "RESOURCE_EXHAUSTED: spend cap" >&2
exit 1
''')
try:
    vt.SpeechToDoCliTranscriber(settings={**settings, "nodePath": quota_node}, environ={},
                                log=log_lines.append).transcribe(audio_path, 20)
except vt.TranscribeError as e:
    check("quota failure -> quota message", str(e), vt.QUOTA_MESSAGE)

slow_node = fake_node("node-slow", f'''
if [ "$2" = init ]; then exit 0; fi
sleep 300 &
echo $! > "{pid_file}"
wait
''')
started = time.time()
try:
    vt.SpeechToDoCliTranscriber(settings={**settings, "nodePath": slow_node}, environ={},
                                log=log_lines.append).transcribe(audio_path, 1)
    check("timeout raises", False, True)
except vt.TranscribeError as e:
    check("timeout message", str(e), vt.TIMEOUT_MESSAGE)
check("timeout returned promptly", time.time() - started < 15, True)
time.sleep(0.3)
child_pid = int(open(pid_file).read().strip())
try:
    os.kill(child_pid, 0)
    still_alive = True
except OSError:
    still_alive = False
check("timeout killed the whole process group", still_alive, False)

lingering_node = fake_node("node-lingering", f'''
if [ "$2" = init ]; then exit 0; fi
ws="$6"
mkdir -p "$ws/.speechtodo/outputs/voice-1"
printf '{{"segments":[{{"text":"lingered ok"}}]}}' > "$ws/.speechtodo/outputs/voice-1/transcript.json"
sleep 300 &
echo $! > "{pid_file}.linger"
wait
''')
started = time.time()
lingered = vt.SpeechToDoCliTranscriber(settings={**settings, "nodePath": lingering_node}, environ={},
                                       log=log_lines.append).transcribe(audio_path, 60)
check("transcript read without waiting for a lingering CLI", lingered, "lingered ok")
check("returned promptly", time.time() - started < 15, True)
time.sleep(0.3)
try:
    os.kill(int(open(pid_file + ".linger").read().strip()), 0)
    linger_alive = True
except OSError:
    linger_alive = False
check("lingering CLI group killed", linger_alive, False)

check("key read from config file", vt.read_gemini_key({"geminiKeyFile": key_file}, {}), KEY)
vt.DEFAULT_KEY_FILE = os.path.join(_tmp, "no-default-key")
check("key from GOOGLE_API_KEY env as last resort",
      vt.read_gemini_key({"geminiKeyFile": os.path.join(_tmp, "nope")}, {"GOOGLE_API_KEY": "k"}), "k")
check("no key anywhere -> None", vt.read_gemini_key({}, {}), None)
vt.DEFAULT_KEY_FILE = real_default

print("\n== pass-2 QA: failure wording, restart, leftovers, Vietnamese ==")
for label, text, want in (
        ("bad key", "[GoogleGenerativeAI Error]: API key not valid. Please pass a valid API key.", vt.KEY_REJECTED_MESSAGE),
        ("rate limit", "429 Too Many Requests", vt.QUOTA_MESSAGE),
        ("offline", "TypeError: fetch failed ... ENOTFOUND generativelanguage.googleapis.com", vt.OFFLINE_MESSAGE),
        ("unknown", "something odd", vt.GENERIC_FAILURE_MESSAGE)):
    check(f"cli output {label} -> fixed sentence", vt.SpeechToDoCliTranscriber._failure_message(text), want)
vi = "  Xin chào, tôi là Trung.\u200b Đây là bản ghi: ạ ệ ữ ơ \u0301  "
check("Vietnamese survives normalizing", vt.normalize_transcript(vi), "Xin chào, tôi là Trung. Đây là bản ghi: ạ ệ ữ ơ \u0301")
check("sentinel stays literal text", vt.normalize_transcript("/" + SENTINEL), SENTINEL)
# A done result on disk from before a restart is NOT transcribed again by a re-POST.
d_fake = FakeTranscriber("first")
d_jobs = vt.TranscriptionJobs(d_fake)
d_id = new_audio()
d_jobs.start(d_id)
wait_state(d_jobs, d_id, "done")
d_fake2 = FakeTranscriber("second")
d_jobs2 = vt.TranscriptionJobs(d_fake2)
check("re-POST after restart returns done, no second run",
      (d_jobs2.start(d_id)[0]["state"], d_fake2.calls), ("done", 0))
# Workspaces of a killed dashboard are swept; fresh ones are not.
root = tempfile.mkdtemp(prefix="ws-root-", dir=_tmp)
old_ws = os.path.join(root, "voice-transcribe-old")
new_ws = os.path.join(root, "voice-transcribe-new")
other = os.path.join(root, "someone-elses")
for p_ in (old_ws, new_ws, other):
    os.mkdir(p_)
os.utime(old_ws, (time.time() - 7200, time.time() - 7200))
os.utime(other, (time.time() - 7200, time.time() - 7200))
check("stale workspace swept", vt.sweep_stale_workspaces(root=root), 1)
check("fresh + foreign dirs kept", sorted(os.listdir(root)), ["someone-elses", "voice-transcribe-new"])

print("\n== HTTP wiring (both listeners) ==")
_spec = importlib.util.spec_from_file_location(
    "chief_dashboard_server_voice_test", os.path.join(DASHBOARD_ROOT, "server", "chief-dashboard-server.py"))
_srv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_srv)
http_fake = FakeTranscriber("sent from the phone")
vt._JOBS = vt.TranscriptionJobs(http_fake)
server = _srv.QuietThreadingHTTPServer(("127.0.0.1", 0), _srv.Handler)
server.remote_listener = False
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{server.server_address[1]}"


def call(method, route, data=None, ctype=None):
    headers = {"Content-Type": ctype} if ctype else {}
    req = urllib.request.Request(base + route, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


status, body = call("POST", "/api/attachments/audio", M4A + b"\x00" * (2 * 1024 * 1024), "audio/mp4;codecs=mp4a.40.2")
check(">1 MB audio accepted (own cap)", (status, body.get("ok")), (200, True))
http_id = body.get("id")
check("bad type -> 415", call("POST", "/api/attachments/audio", M4A, "text/plain")[0], 415)
check("sentinel type -> 415", call("POST", "/api/attachments/audio", M4A, "audio/mp4" + SENTINEL)[0], 415)
check("junk bytes -> 415", call("POST", "/api/attachments/audio", b"x" * 100, "audio/mp4")[0], 415)
try:
    over = call("POST", "/api/attachments/audio", M4A + b"\x00" * aa.MAX_AUDIO_BYTES, "audio/mp4")[0]
except (ConnectionError, urllib.error.URLError):
    over = 413  # refused unread; the server closed the socket mid-send
check("over 25 MB -> 413", over, 413)
check("transcribe unknown id -> 404", call("POST", "/api/transcribe",
      json.dumps({"id": "0" * 32}).encode(), "application/json")[0], 404)
check("transcribe bad id -> 404", call("POST", "/api/transcribe",
      json.dumps({"id": SENTINEL}).encode(), "application/json")[0], 404)
check("transcribe bad body -> 400", call("POST", "/api/transcribe", b"not json", "application/json")[0], 400)
check("transcribe pending", call("POST", "/api/transcribe",
      json.dumps({"id": http_id}).encode(), "application/json"), (200, {"ok": True, "id": http_id, "state": "pending"}))
end = time.time() + 10
final = (0, {})
while time.time() < end:
    final = call("GET", f"/api/transcribe/{http_id}")
    if final[1].get("state") != "pending":
        break
    time.sleep(0.05)
check("poll returns done text", (final[0], final[1].get("state"), final[1].get("text")),
      (200, "done", "sent from the phone"))
check("poll unknown id -> 404", call("GET", "/api/transcribe/" + "1" * 32)[0], 404)
check("poll bad id -> 404", call("GET", "/api/transcribe/not-an-id")[0], 404)
check("no INJECTED anywhere in listing",
      any("INJECTED" in n for n in os.listdir(ATTACH_DIR)), False)
server.shutdown()

print()
if fails:
    print(f"{len(fails)} FAILED:")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("ALL PASS")
