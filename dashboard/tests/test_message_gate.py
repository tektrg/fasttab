#!/usr/bin/env python3
"""The non-Claude message gate (server/lib/message_gate.py): a herdr pane
running OpenCode/Codex (no hook data) is never typed into, on every client.

Covers: the pure rule, the row fields `build_agents_view` emits
(`agentKind`, `messageRefusal`), Needs-You rows carrying `machine`, and
`POST /api/session/message` refusing before any keystroke.

SAFETY: no server bound, no herdr/ssh call — the server's type/send/read
helpers are replaced by recorders that fail the test if ever reached.
"""
import importlib.util
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DASHBOARD_ROOT = os.path.dirname(HERE)
_tmp = tempfile.mkdtemp(prefix="message-gate-test-")
os.environ["CHIEF_DASHBOARD_CONFIG_HOME"] = os.path.join(_tmp, "config")
os.environ["CHIEF_DASHBOARD_STATE_HOME"] = os.path.join(_tmp, "state")
os.environ["CHIEF_DASHBOARD_MACHINES"] = "{}"
os.environ["CHIEF_HERDR_BIN"] = os.path.join(_tmp, "no-such-herdr")
os.environ["AGENTBAR_PERSONAS_FILE"] = os.path.join(_tmp, "no-personas.json")
sys.path.insert(0, os.path.join(DASHBOARD_ROOT, "server", "lib"))
import message_gate  # noqa: E402

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def herdr_row(kind, has_hook=False, **extra):
    return dict({"source": "herdr", "agentKind": kind, "hasHookData": has_hook,
                 "paneId": "w1:p1", "rowId": "row-a", "label": "a", "machine": "local"}, **extra)


print("== the rule ==")
check("claude pane: allowed", message_gate.blind_agent_refusal(herdr_row("claude")), None)
check("claude pane on the Air (no hook data): allowed",
      message_gate.blind_agent_refusal(herdr_row("claude", machine="air-m1")), None)
for kind in ("opencode", "codex", "gemini"):
    why = message_gate.blind_agent_refusal(herdr_row(kind))
    check(f"{kind} pane without hook data: refused", (why or "").startswith("refused:"), True)
    check(f"{kind}: reason names the tool", kind in (why or ""), True)
check("non-Claude WITH hook data (AgentBar's own gate passes it): allowed",
      message_gate.blind_agent_refusal(herdr_row("opencode", has_hook=True)), None)
check("herdr row with no agentKind: refused (unknown = blind)",
      bool(message_gate.blind_agent_refusal(herdr_row(None))), True)
check("status-only Desktop row: never refused here",
      message_gate.blind_agent_refusal({"source": "claude-desktop", "hasHookData": True}), None)
check("None row: no crash", message_gate.blind_agent_refusal(None), None)

print("\n== build_agents_view: agentKind + messageRefusal on herdr rows ==")
import chief_dashboard_views as views  # noqa: E402


def feed(data):
    return {"data": data, "lastSuccessTs": 1.0, "ageSec": 0, "lastDurationSec": 0}


snap = {
    "hookCache": feed({}),
    "herdr": feed({"agents": [
        {"pane_id": "w1:p1", "tab_id": "t1", "agent": "claude", "cwd": "/tmp/a"},
        {"pane_id": "w1:p2", "tab_id": "t1", "agent": "opencode", "cwd": "/tmp/b"},
    ], "tabs": [{"tab_id": "t1", "label": "tab"}]}),
    "paneScreen": feed({}),
    "claudeSessions": feed([]),
}
try:
    rows = {r["paneId"]: r for r in views.build_agents_view(snap)}
    check("claude row: agentKind", rows["w1:p1"]["agentKind"], "claude")
    check("opencode row: agentKind", rows["w1:p2"]["agentKind"], "opencode")
    check("claude row without hook data: still refused? no -> None",
          rows["w1:p1"]["messageRefusal"], None)
    check("opencode row: messageRefusal set",
          (rows["w1:p2"]["messageRefusal"] or "").startswith("refused:"), True)
except Exception as e:  # a snapshot-shape change should fail loudly, not crash
    check(f"build_agents_view ran ({e!r})", False, True)

print("\n== build_needs_you: every row names its machine ==")
agents = [
    {"paneId": "air-m1:w2:p3", "label": "air one", "hookSinceSec": 3, "hookState": None,
     "screenState": "NEEDS_HUMAN", "screenSignal": "Allow?", "machine": "air-m1",
     "source": "herdr"},
    {"paneId": "w1:p9", "label": "local one", "hookSinceSec": 3, "hookState": None,
     "screenState": "NEEDS_HUMAN", "screenSignal": "Allow?", "machine": "local",
     "source": "herdr"},
]
needs = {n["label"]: n for n in views.build_needs_you(
    {"paneScreen": {"lastSuccessTs": 1.0, "ageSec": 0, "lastDurationSec": 0, "data": {}}}, agents)
    if n.get("label") in ("air one", "local one")}
check("air-m1 pane's Needs-You row says air-m1", needs.get("air one", {}).get("machine"), "air-m1")
check("local pane's Needs-You row says local", needs.get("local one", {}).get("machine"), "local")

print("\n== POST /api/session/message refuses before any keystroke ==")
_spec = importlib.util.spec_from_file_location(
    "chief_dashboard_server_message_gate_test",
    os.path.join(DASHBOARD_ROOT, "server", "chief-dashboard-server.py"))
_srv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_srv)

touched = []
_srv._type_text = lambda *a, **k: touched.append(("type", a))
_srv._send_keys = lambda *a, **k: touched.append(("keys", a))
_srv._read_pane_now = lambda *a, **k: touched.append(("read", a)) or ([], None)
_srv._enrich_agents_for_actions = lambda state, agents: None
FAKE_AGENTS = [herdr_row("opencode", agentSession="oc-row", paneId="w1:p2"),
               herdr_row("codex", agentSession="cx-row", paneId="air-m1:w6:p2", machine="air-m1")]
_srv.get_full_state = lambda: {"computed": {"agents": FAKE_AGENTS}}

for row_id, text in (("oc-row", "hello $(echo INJECTED)"), ("oc-row", "/compact"),
                     ("oc-row", "/clear"), ("cx-row", "hi")):
    touched.clear()
    result = _srv.handle_session_action("message", {"rowId": row_id, "actor": "po", "text": text})
    check(f"{row_id} {text!r}: refused", (result.get("ok"), "invisible" in (result.get("error") or "")),
          (False, True))
    check(f"{row_id} {text!r}: refused before typing", result.get("typed"), False)
    check(f"{row_id} {text!r}: pane never read or typed into", touched, [])

# Positive control: a Claude pane (AgentBar's case) passes the gate and goes
# on to the fresh pane read — the gate adds no refusal AgentBar would see.
_srv._own_pane_cached = lambda ids: None
_srv.time.sleep = lambda s: None
FAKE_AGENTS.append(herdr_row("claude", agentSession="cl-row", paneId="w1:p1", hasHookData=True))
touched.clear()
_srv.handle_session_action("message", {"rowId": "cl-row", "actor": "po", "text": "hi"})
check("claude pane: gate passes, pane is read fresh", touched[:1], [("read", ("w1:p1",))])

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("All message gate checks passed.")
