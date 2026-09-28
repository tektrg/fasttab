#!/usr/bin/env python3
"""POST /api/jev/route (server/lib/jev_route.py): server-side Jev persona
pick for clients with no OpenRouter key (the phone).

SAFETY: no network — every request goes to a fake `post_fn`. The key file
is a throwaway temp file holding a SENTINEL, never a real key; the real
`~/.config/agent-dashboard/openrouter-key` is never read (the path env
override points into a temp dir before the module loads).
"""
import json
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DASHBOARD_ROOT = os.path.dirname(HERE)
REPO_ROOT = os.path.dirname(DASHBOARD_ROOT)
_tmp = tempfile.mkdtemp(prefix="jev-route-test-")
KEY_FILE = os.path.join(_tmp, "openrouter-key")
os.environ["AGENT_DASHBOARD_OPENROUTER_KEY_FILE"] = KEY_FILE
os.environ["CHIEF_DASHBOARD_CONFIG_HOME"] = os.path.join(_tmp, "config")
os.environ["CHIEF_DASHBOARD_STATE_HOME"] = os.path.join(_tmp, "state")
os.environ["CHIEF_DASHBOARD_MACHINES"] = "{}"
sys.path.insert(0, os.path.join(DASHBOARD_ROOT, "server", "lib"))
import jev_route  # noqa: E402

fails = []
SENTINEL_KEY = "sk-or-SENTINEL-not-a-real-key"


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def write_key(value=SENTINEL_KEY, mode=0o600):
    with open(KEY_FILE, "w") as f:
        f.write(value + "\n")
    os.chmod(KEY_FILE, mode)


PERSONAS = [
    {"name": "chief-aptus", "description": "Runs AptusFit delivery", "routesWhen": ["app bugs", "releases"],
     "notFor": ["the dashboard"], "offline": False, "mainRowId": "row-1"},
    {"name": "fasttab-dev", "description": "FastTab and AgentBar", "routesWhen": [], "notFor": [],
     "offline": False, "mainRowId": None},
    {"name": "air-only", "description": "On the Air", "routesWhen": [], "notFor": [], "offline": True},
]


class FakeNet:
    def __init__(self, status=200, reply=None, raises=None):
        self.status, self.raises, self.calls = status, raises, []
        self.reply = reply if reply is not None else {
            "answers": {"route": {"type": "choice", "choice": "persona:fasttab-dev", "confidence": 0.82}}}

    def __call__(self, url, headers, body_bytes, timeout):
        self.calls.append({"url": url, "headers": headers, "body": json.loads(body_bytes), "timeout": timeout})
        if self.raises:
            raise self.raises
        reply = self.reply if isinstance(self.reply, bytes) else json.dumps(self.reply).encode()
        return self.status, reply


def deps(net=None, personas=PERSONAS, limiter=None):
    return jev_route.RouteDeps(personas_fn=lambda: personas, post_fn=net or FakeNet(),
                               limiter=limiter or jev_route.RateLimiter())


print("== key file ==")
for label, setup, needle in (
        ("missing", lambda: os.path.exists(KEY_FILE) and os.remove(KEY_FILE), "no OpenRouter key"),
        ("group-readable", lambda: write_key(mode=0o640), "mode 600"),
        ("empty", lambda: write_key(value="", mode=0o600), "empty")):
    setup()
    net = FakeNet()
    result = jev_route.route_message({"text": "hi"}, deps(net))
    check(f"{label} key: refused", (result["ok"], needle in result["error"]), (False, True))
    check(f"{label} key: the refusal names where the key goes", KEY_FILE in result["error"], True)
    check(f"{label} key: no network call", net.calls, [])
link = os.path.join(_tmp, "key-link")
write_key()
os.symlink(KEY_FILE, link)
try:
    jev_route.load_openrouter_key(link)
    check("a symlinked key file is refused", False, True)
except jev_route.JevRouteError:
    check("a symlinked key file is refused", True, True)

check("a path under home is shown as ~/… (no username in replies)",
      jev_route._shown_path(os.path.join(os.path.expanduser("~"), ".config", "k")), "~/.config/k")

print("\n== a good pick ==")
write_key()
net = FakeNet()
result = jev_route.route_message({"text": "fix the Tab bar $(echo INJECTED)"}, deps(net))
check("returns persona + confidence only", result, {"ok": True, "persona": "fasttab-dev", "confidence": 0.82})
check("the key never appears in the reply", SENTINEL_KEY in json.dumps(result), False)
sent = net.calls[0]
check("posts to OpenRouter's Decisions API", sent["url"], "https://openrouter.ai/api/alpha/decisions")
check("bearer auth from the key file", sent["headers"]["Authorization"], f"Bearer {SENTINEL_KEY}")
check("8s timeout", sent["timeout"], 8)
check("model = AgentBar's default", sent["body"]["model"], "~typesafe/jev-latest")
check("state = the message, verbatim", sent["body"]["state"], "fix the Tab bar $(echo INJECTED)")
question = sent["body"]["questions"]["route"]
check("a choice question", question["type"], "choice")
check("offline personas are not candidates", sorted(question["criteria"]),
      ["persona:chief-aptus", "persona:fasttab-dev"])
check("summary format matches RouteCandidateBuilder.swift",
      question["criteria"]["persona:chief-aptus"],
      "chief-aptus — Runs AptusFit delivery. Routes here: app bugs, releases. Not for: the dashboard.")
check("empty clauses omitted", question["criteria"]["persona:fasttab-dev"], "fasttab-dev — FastTab and AgentBar.")

print("\n== bad replies ==")
for label, net, needle in (
        ("HTTP 401", FakeNet(status=401), "HTTP 401"),
        ("unreadable", FakeNet(reply=b"not json"), "unreadable"),
        ("no choice", FakeNet(reply={"answers": {"route": {}}}), "did not pick"),
        ("unknown choice", FakeNet(reply={"answers": {"route": {"choice": "persona:ghost"}}}), "unknown agent"),
        ("offline persona picked", FakeNet(reply={"answers": {"route": {"choice": "persona:air-only"}}}),
         "unknown agent"),
        ("timeout", FakeNet(raises=TimeoutError("timed out")), "timed out"),
        ("unreachable", FakeNet(raises=OSError("connection refused")), "could not reach")):
    result = jev_route.route_message({"text": "hi"}, deps(net))
    check(f"{label}: refused", (result["ok"], needle in result.get("error", "")), (False, True))
    check(f"{label}: never leaks the key", SENTINEL_KEY in json.dumps(result), False)
result = jev_route.route_message({"text": "hi"}, deps(FakeNet(
    reply={"answers": {"route": {"choice": "persona:chief-aptus"}}})))
check("missing confidence reads as 0.0, never a guess", result.get("confidence"), 0.0)

print("\n== input rules ==")
for label, body, needle in (
        ("newline", {"text": "a\nb"}, "newline"),
        ("blank", {"text": "  "}, "empty"),
        ("control char", {"text": "hi \x03echo INJECTED"}, "control"),
        ("extra field", {"text": "hi", "model": "other"}, "unexpected field"),
        ("not an object", ["hi"], "JSON object")):
    net = FakeNet()
    result = jev_route.route_message(body, deps(net))
    check(f"{label}: refused", (result["ok"], needle in result.get("error", "")), (False, True))
    check(f"{label}: no network call", net.calls, [])
net = FakeNet()
result = jev_route.route_message({"text": "hi"}, deps(net, personas=[]))
check("no persona: refused without a network call", (result["ok"], net.calls), (False, []))

print("\n== rate limit ==")
clock = [0.0]
limiter = jev_route.RateLimiter(limit=2, window=60, clock=lambda: clock[0])
for i in range(2):
    check(f"request {i + 1} within the limit: ok",
          jev_route.route_message({"text": "hi"}, deps(limiter=limiter))["ok"], True)
result = jev_route.route_message({"text": "hi"}, deps(limiter=limiter))
check("third in the window: refused", (result["ok"], "Too many" in result["error"]), (False, True))
clock[0] = 61
check("after the window: ok again", jev_route.route_message({"text": "hi"}, deps(limiter=limiter))["ok"], True)
busy = jev_route.RateLimiter()
busy.acquire()
result = jev_route.route_message({"text": "hi"}, deps(limiter=busy))
check("one in flight at a time", (result["ok"], "already routing" in result["error"]), (False, True))
limiter = jev_route.RateLimiter()
jev_route.route_message({"text": "hi"}, deps(FakeNet(raises=OSError("down")), limiter=limiter))
check("a failed request releases the in-flight slot", limiter._in_flight, False)

print("\n== drift: same contract as AgentBar's Swift client ==")
swift_dir = os.path.join(REPO_ROOT, "Sources", "AgentBar", "Routing")
with open(os.path.join(swift_dir, "OpenRouterJevClient.swift")) as f:
    client_src = f.read()
with open(os.path.join(swift_dir, "RoutingSettings.swift")) as f:
    settings_src = f.read()
match = re.search(r'routeInstructions = "((?:[^"\\]|\\.)*)"', client_src)
check("route instructions identical", match and match.group(1), jev_route.ROUTE_INSTRUCTIONS)
match = re.search(r'endpoint = URL\(string: "([^"]+)"', client_src)
check("endpoint identical", match and match.group(1), jev_route.DECISIONS_URL)
match = re.search(r'defaultModelID = "([^"]+)"', settings_src)
check("default model identical", match and match.group(1), jev_route.DEFAULT_MODEL)
check("same question key", 'routeQuestionKey = "route"' in client_src, True)

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("All jev route checks passed.")
