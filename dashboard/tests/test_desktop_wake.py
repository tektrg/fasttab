#!/usr/bin/env python3
"""Direct-run tests for desktop_wake.py (message a SLEEPING Claude Desktop
session: confirm, open its deep link, poll its inbox, deliver) and its
server wiring (`POST /api/session/message` on an ended row, board rows
marked `messageVia: "wake"`).

SAFETY: `open` and the inbox send are always fakes — no Claude.app is ever
opened and no real session socket is touched. Temp board db. Hostile text
uses the inert sentinel only.
"""
import importlib.util
import os
import sys
import tempfile

DASHBOARD_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_state_tmp = tempfile.TemporaryDirectory()
os.environ["CHIEF_DASHBOARD_STATE_HOME"] = _state_tmp.name  # never the live board db
os.environ["CHIEF_DASHBOARD_CONFIG_HOME"] = _state_tmp.name
os.environ["CHIEF_DASHBOARD_MACHINES"] = "{}"
sys.path.insert(0, os.path.join(DASHBOARD_DIR, "server", "lib"))

import desktop_wake  # noqa: E402
import session_inbox  # noqa: E402

fails = []
CLI_ID = "sess-sleepy-1"
DESKTOP_ID = "local_8711df12-aaaa"
URL = f"claude://code/continue?session={DESKTOP_ID}"
SLEEPING = {"desktopSessionId": DESKTOP_ID, "cliSessionId": CLI_ID, "label": "desk",
            "cwd": "/x", "lastActiveTs": 1.0, "openUrl": URL}
SENTINEL_TEXT = "please run $(echo INJECTED)"


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


class FakeClock:
    def __init__(self):
        self.t = 0.0

    def now(self):
        return self.t

    def sleep(self, sec):
        self.t += sec


def scripted_send(results):
    calls = []

    def send(session_id, text):
        calls.append((session_id, text))
        return results.pop(0) if len(results) > 1 else results[0]
    return send, calls


NOT_RUNNING = {"delivered": False, "maybeDelivered": False, "error": session_inbox.NOT_RUNNING}
OK = {"delivered": True, "maybeDelivered": True, "error": None}


def run(results, confirm=True, opened=True, text="ship it", sleeping=SLEEPING):
    clock, urls = FakeClock(), []
    send, calls = scripted_send(list(results))
    result = desktop_wake.deliver_to_sleeping(
        sleeping, text, confirm, open_url=lambda u: urls.append(u) or opened,
        send=send, sleep=clock.sleep, clock=clock.now, wait_sec=5, poll_sec=0.5)
    return result, urls, calls


print("== find_sleeping / annotate ==")
check("matches by cliSessionId", desktop_wake.find_sleeping(CLI_ID, [SLEEPING]), SLEEPING)
check("unknown row -> None", desktop_wake.find_sleeping("other", [SLEEPING]), None)
check("None row id -> None", desktop_wake.find_sleeping(None, [SLEEPING]), None)
check("link not Claude's own shape -> None",
      desktop_wake.find_sleeping(CLI_ID, [dict(SLEEPING, openUrl="https://evil.test/x")]), None)
check("desktop id with a newline -> None",
      desktop_wake.find_sleeping(CLI_ID, [dict(SLEEPING, desktopSessionId=DESKTOP_ID + "\n",
                                               openUrl=URL + "\n")]), None)
rows = [{"rowId": CLI_ID, "status": "ended", "derived": {"label": "desk"}},
        {"rowId": CLI_ID, "status": "live", "derived": {}},
        {"rowId": "gone", "status": "ended", "derived": {}}]
desktop_wake.annotate_wakeable_rows(rows, [SLEEPING])
check("ended sleeping row marked wake",
      (rows[0]["derived"].get("messageVia"), rows[0]["derived"].get("openUrl")), ("wake", URL))
check("live row untouched", rows[1]["derived"], {})
check("other ended row untouched", rows[2]["derived"], {})

print("== deliver_to_sleeping ==")
result, urls, calls = run([OK], confirm=False)
check("no confirm -> needsConfirm, nothing opened or sent",
      (result.get("needsConfirm"), result.get("reason"), urls, calls),
      (True, desktop_wake.WAKE_CONFIRM, [], []))
result, urls, calls = run([OK], text="/compact")
check("slash command refused before opening",
      (result.get("error"), result.get("typed"), urls), (session_inbox.SLASH_REFUSED, False, []))
result, urls, calls = run([NOT_RUNNING, NOT_RUNNING, OK], text=SENTINEL_TEXT)
check("woken on the 3rd poll -> sent", (result.get("ok"), result.get("state")), (True, "message sent"))
check("opened the session's own link once", urls, [URL])
check("text passed through verbatim, by session id",
      calls[-1], (CLI_ID, SENTINEL_TEXT))
check("reason says it woke the session", result.get("reason"), desktop_wake.WOKE_NOTE)
result, urls, calls = run([NOT_RUNNING])
check("never wakes -> timeout, typed:false",
      (result.get("error"), result.get("typed")), (desktop_wake.WAKE_TIMEOUT, False))
check("polled about wait/poll times", 10 <= len(calls) <= 12, True)
result, urls, calls = run([OK], opened=False)
check("open failed -> refused, nothing sent",
      (result.get("error"), result.get("typed"), calls), (desktop_wake.OPEN_FAILED, False, []))
result, urls, calls = run([{"delivered": False, "maybeDelivered": True,
                            "error": session_inbox.MAYBE_SENT}, OK])
check("may-have-arrived -> stop, no retry, no typed:false",
      (result.get("error"), "typed" in result, len(calls)), (session_inbox.MAYBE_SENT, False, 1))
result, urls, calls = run([{"delivered": False, "maybeDelivered": False,
                            "error": session_inbox.PROMPT_PENDING}])
check("woke into a pending prompt -> refused at once",
      (result.get("error"), result.get("typed"), len(calls)),
      (session_inbox.PROMPT_PENDING, False, 1))

print("== server: POST /api/session/message on an ended sleeping row ==")
_spec = importlib.util.spec_from_file_location(
    "chief_dashboard_server_wake_test",
    os.path.join(DASHBOARD_DIR, "server", "chief-dashboard-server.py"))
_srv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_srv)
_srv.get_full_state = lambda: {"computed": {"agents": [], "sleepingSessions": [SLEEPING]},
                               "feeds": {}}
logged = []
_srv.STORE.log_session_action = lambda *a, **k: logged.append((a, k))
opened, sent = [], []
_srv.desktop_wake.open_desktop_url = lambda u: opened.append(u) or True
session_inbox.send_message = lambda sid, text: sent.append((sid, text)) or OK

result = _srv.handle_session_action("message", {"rowId": CLI_ID, "actor": "po", "text": "hi"})
check("first send asks to confirm the wake", result.get("needsConfirm"), True)
check("nothing opened before the confirm", opened, [])
result = _srv.handle_session_action("message", {"rowId": CLI_ID, "actor": "po", "text": "hi",
                                                "confirm": True})
check("confirmed -> woken + sent", (result.get("ok"), opened, sent), (True, [URL], [(CLI_ID, "hi")]))
check("audited as a sent message",
      [(a[0], a[1], k.get("status")) for a, k in logged], [(CLI_ID, "message", "sent")])
result = _srv.handle_session_action("message", {"rowId": "nobody", "actor": "po", "text": "hi"})
check("unknown ended row still refused as not live", "is not live" in result.get("error", ""), True)

print()
if fails:
    print(f"FAIL: {len(fails)} failure(s)")
    for f in fails:
        print("  - " + f)
    sys.exit(1)
print("PASS: all desktop wake checks")
