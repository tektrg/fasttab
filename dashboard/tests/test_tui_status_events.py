#!/usr/bin/env python3
"""OpenCode / Codex status events (server/lib/tui_status_events.py +
codex_rollout.py): ingest, herdr row matching, staleness decay, rollout
folding, Needs-You rows, the message gate, and the HTTP route.

SAFETY: no real session, no real ~/.codex — CODEX_HOME is a temp dir, pids
are faked, the route is called directly (no port bound).
"""
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DASHBOARD_ROOT = os.path.dirname(HERE)
_tmp = tempfile.mkdtemp(prefix="tui-status-test-")
os.environ["CODEX_HOME"] = os.path.join(_tmp, "codex")
os.environ["CHIEF_DASHBOARD_CONFIG_HOME"] = os.path.join(_tmp, "config")
os.environ["CHIEF_DASHBOARD_STATE_HOME"] = os.path.join(_tmp, "state")
os.environ["CHIEF_DASHBOARD_MACHINES"] = "{}"
os.environ["CHIEF_HERDR_BIN"] = os.path.join(_tmp, "no-such-herdr")
sys.path.insert(0, os.path.join(DASHBOARD_ROOT, "server", "lib"))
import codex_rollout  # noqa: E402
import message_gate  # noqa: E402
import tui_status_events as tse  # noqa: E402

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


class Clock:
    def __init__(self):
        self.now = 1_000_000.0

    def __call__(self):
        return self.now


ALIVE = {111, 222, 333}
clock = Clock()


def new_store():
    return tse.TuiStatusStore(clock=clock, pid_alive=lambda pid: pid in ALIVE)


def oc(event, **extra):
    return dict({"tool": "opencode", "event": event, "sessionId": "ses_oc1",
                 "pid": 111, "cwd": "/tmp/proj-oc", "paneId": "w1:p2",
                 "serverUrl": "http://127.0.0.1:50123"}, **extra)


def cx(event, **extra):
    return dict({"tool": "codex", "event": event, "sessionId": "cx-uuid-1",
                 "pid": 222, "cwd": "/tmp/proj-cx"}, **extra)


def only(store):
    entries = store.fresh_entries()
    return entries[0] if len(entries) == 1 else None


print("== ingest: OpenCode ==")
s = new_store()
check("session.status busy -> working", s.ingest(oc("session.status", statusType="busy"))[0]["state"], "working")
check("permission.asked -> blocked", s.ingest(oc("permission.asked", title="bash: ls"))[0]["state"], "blocked")
e = only(s)
check("prompt = permission", e and e["prompt"], "permission")
check("reason names the permission", e and e["reason"], "Permission: bash: ls")
check("source = opencode-plugin", e and e["source"], "opencode-plugin")
check("serverUrl kept (local only)", e and e["serverUrl"], "http://127.0.0.1:50123")
s.ingest(oc("permission.replied"))
check("permission.replied -> working, prompt cleared", (only(s)["status"], only(s)["prompt"]), ("working", None))
s.ingest(oc("question.asked", title="Pick one"))
check("question.asked -> blocked question", (only(s)["status"], only(s)["prompt"]), ("blocked", "question"))
s.ingest(oc("question.rejected"))
s.ingest(oc("session.idle"))
check("session.idle -> idle", only(s)["status"], "idle")
s.ingest(oc("message.updated", tokens={"input": 1000, "output": 500, "cache": {"read": 3500}},
            contextLimit=100000))
check("message.updated -> context 5.0%", only(s)["contextPercent"], 5.0)
check("message.updated does not change status", only(s)["status"], "idle")
s.ingest(oc("message.updated", tokens={"input": 9}, contextLimit=None))
check("no context limit -> percent kept, never guessed", only(s)["contextPercent"], 5.0)
check("remote serverUrl ignored",
      (s.ingest(oc("session.idle", serverUrl="http://evil.example:80")), only(s)["serverUrl"])[1],
      "http://127.0.0.1:50123")
s.ingest(oc("session.deleted"))
check("session.deleted -> dropped", s.fresh_entries(), [])

print("\n== ingest: validation ==")
s = new_store()
for label, body in (("not an object", ["x"]), ("unknown tool", oc("x", tool="gemini")),
                    ("bad session id", oc("session.idle", sessionId="../etc")),
                    ("missing event", oc(None))):
    check(f"{label}: 400", s.ingest(body)[1], 400)
check("unknown event: accepted, no status", (s.ingest(oc("tui.toast"))[1], s.fresh_entries()), (200, []))
sentinel = "$(echo INJECTED)"
s.ingest(oc("permission.asked", title=sentinel))
check("sentinel text stored verbatim as data", only(s)["reason"], "Permission: " + sentinel)

print("\n== ingest: Codex ==")
s = new_store()
s.ingest(cx("UserPromptSubmit"))
check("UserPromptSubmit -> working", only(s)["status"], "working")
s.ingest(cx("PermissionRequest", title="Bash: rm x"))
check("PermissionRequest -> blocked permission", (only(s)["status"], only(s)["prompt"]), ("blocked", "permission"))
s.ingest(cx("PostToolUse"))
check("PostToolUse -> working again", (only(s)["status"], only(s)["prompt"]), ("working", None))
s.ingest(cx("Stop", lastMessage="Done. Want me to also update the docs?"))
check("Stop ending in a question -> blocked question", (only(s)["status"], only(s)["prompt"]), ("blocked", "question"))
check("question reason carries the line", only(s)["reason"], "Question: Done. Want me to also update the docs?")
s.ingest(cx("Stop", lastMessage="All done."))
check("Stop without a question -> idle", (only(s)["status"], only(s)["prompt"]), ("idle", None))
s.ingest(cx("SessionEnd"))
check("SessionEnd -> dropped", s.fresh_entries(), [])

print("\n== staleness decay ==")
s = new_store()
s.ingest(oc("session.status", statusType="busy"))
clock.now += tse.STALE_AFTER_SEC - 1
check("under the stale limit: fresh", len(s.fresh_entries()), 1)
check("heartbeat touches that pid's sessions",
      s.ingest({"tool": "opencode", "event": "heartbeat", "pid": 111})[0]["sessions"], 1)
clock.now += tse.STALE_AFTER_SEC - 1
check("heartbeat kept it fresh", len(s.fresh_entries()), 1)
clock.now += 2
check("past the limit with no event: decays (dropped from the view)", s.fresh_entries(), [])
s = new_store()
s.ingest(oc("session.status", statusType="busy", pid=333))
ALIVE.discard(333)
check("dead pid: dropped at once", s.fresh_entries(), [])

print("\n== Codex rollout folding ==")
day = os.path.join(os.environ["CODEX_HOME"], "sessions", "2026", "09", "28")
os.makedirs(day)
rollout = os.path.join(day, "rollout-2026-09-28T10-00-00-cx-uuid-1.jsonl")


def write_rollout(lines, mtime):
    with open(rollout, "w") as f:
        f.write("not json at all\n")  # format drift: skipped, never fatal
        for line in lines:
            f.write(json.dumps(line) + "\n")
    os.utime(rollout, (mtime, mtime))


def ev(kind, **payload):
    return {"type": "event_msg", "payload": dict({"type": kind}, **payload)}


token = ev("token_count", info={"last_token_usage": {"total_tokens": 129200},
                                "model_context_window": 258400})
check("parse: started, no complete -> working",
      codex_rollout.parse_lines([json.dumps(ev("task_started"))])["status"], "working")
check("parse: unknown shapes tolerated",
      codex_rollout.parse_lines(['{"type":"event_msg","payload":"x"}', "[]", json.dumps(
          ev("token_count", info={"last_token_usage": "?"}))]),
      {"status": None, "contextPercent": None, "lastMessage": None})
s = new_store()
s.ingest(cx("UserPromptSubmit"))
write_rollout([ev("task_started"), token], clock.now - 5)
e = only(s)
check("context % from rollout (129200/258400)", e["contextPercent"], 50.0)
check("rollout older than the hook event: hook status stands", (e["status"], e["source"]), ("working", "codex-hook"))
write_rollout([ev("task_started"), token, ev("task_complete", last_agent_message="Shall I push?")],
              clock.now + 3)
e = only(s)
check("newer rollout: its turn state wins", e["source"], "codex-rollout")
check("newer rollout ending in a question -> blocked question", (e["status"], e["prompt"]), ("blocked", "question"))
s.ingest(cx("PermissionRequest", title="Bash"))
clock.now += 10
write_rollout([ev("task_started"), token], clock.now + 1)
check("open permission: rollout never overrides it", (only(s)["status"], only(s)["prompt"]), ("blocked", "permission"))
s2 = new_store()
s2.ingest(cx("SessionStart", sessionId="cx-uuid-1", transcriptPath="/etc/passwd"))
check("transcript_path outside CODEX_HOME ignored (glob by id instead)",
      codex_rollout.find_rollout("cx-uuid-1", "/etc/passwd"), os.path.realpath(rollout))

print("\n== herdr row matching (build_agents_view) ==")
import chief_dashboard_views as views  # noqa: E402


def feed(data):
    return {"data": data, "lastSuccessTs": 1.0, "ageSec": 0, "lastDurationSec": 0}


def snap(agents):
    return {"hookCache": feed({}), "paneScreen": feed({}), "claudeSessions": feed([]),
            "herdr": feed({"agents": agents, "tabs": [{"tab_id": "t1", "label": "tab"}]})}


views.tui_status_events.STORE = new_store()
live = views.tui_status_events.STORE
ALIVE.update({111, 222})
live.ingest(oc("permission.asked", title="bash: git push"))              # has paneId w1:p2
live.ingest(cx("UserPromptSubmit", sessionId="cx-a", cwd="/tmp/solo"))   # no pane id: cwd match
live.ingest(cx("UserPromptSubmit", sessionId="cx-b", cwd="/tmp/twins", pid=222))
agents = [
    {"pane_id": "w1:p1", "tab_id": "t1", "agent": "claude", "cwd": "/tmp/proj-oc"},
    {"pane_id": "w1:p2", "tab_id": "t1", "agent": "opencode", "cwd": "/tmp/proj-oc"},
    {"pane_id": "w1:p3", "tab_id": "t1", "agent": "codex", "cwd": "/tmp/solo"},
    {"pane_id": "w1:p4", "tab_id": "t1", "agent": "codex", "cwd": "/tmp/twins"},
    {"pane_id": "w1:p5", "tab_id": "t1", "agent": "codex", "cwd": "/tmp/twins"},
    {"pane_id": "w1:p6", "tab_id": "t1", "agent": "opencode", "cwd": "/tmp/other"},
]
rows = {r["paneId"]: r for r in views.build_agents_view(snap(agents))}
check("pane-id match: opencode row blocked", rows["w1:p2"]["hookState"], "blocked")
check("pane-id match: exact, not best guess", rows["w1:p2"]["hasHookData"], True)
check("pane-id match: statusSource", rows["w1:p2"]["statusSource"], "opencode-plugin")
check("pane-id match: tuiPrompt", rows["w1:p2"]["tuiPrompt"], "permission")
check("claude pane in same cwd untouched", rows["w1:p1"].get("statusSource"), None)
check("unique cwd match: codex row working", rows["w1:p3"]["hookState"], "working")
check("two codex panes in one cwd: neither matched (no guessing)",
      (rows["w1:p4"]["hasHookData"], rows["w1:p5"]["hasHookData"]), (False, False))
check("row with no events: still best guess", rows["w1:p6"]["hasHookData"], False)
check("tool-status row may be messaged (Phase 4: exact status)", rows["w1:p2"]["messageRefusal"], None)
check("row with no events: still refused for messaging",
      (rows["w1:p6"]["messageRefusal"] or "").startswith("refused:"), True)
check("gate rule: Claude-hook data on non-Claude still allowed",
      message_gate.blind_agent_refusal({"source": "herdr", "agentKind": "opencode",
                                        "hasHookData": True}), None)

needs = [n for n in views.build_needs_you(snap(agents), list(rows.values()))
         if n.get("paneId") == "w1:p2"]
check("blocked opencode pane -> one Needs-You row", len(needs), 1)
check("Needs-You row names the permission", needs and needs[0]["detail"].startswith("Permission: bash: git push"), True)

clock.now += tse.STALE_AFTER_SEC + 1
rows = {r["paneId"]: r for r in views.build_agents_view(snap(agents))}
check("stale: row decays back to its screen reading",
      (rows["w1:p2"]["hasHookData"], rows["w1:p2"]["hookState"], rows["w1:p2"].get("statusSource")),
      (False, None, None))

print("\n== HTTP route ==")
store = new_store()
body = lambda: oc("session.idle")  # noqa: E731
check("other path: not ours", tse.handle_post("/api/hook/permission", body, False, store), None)
check("remote listener: 404", tse.handle_post(tse.PATH, body, True, store)[1], 404)
check("local: 200", tse.handle_post(tse.PATH, body, False, store)[1], 200)


def bad_body():
    raise ValueError("Expecting value")


check("malformed JSON: 400", tse.handle_post(tse.PATH, bad_body, False, store)[1], 400)

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("ALL PASS")
