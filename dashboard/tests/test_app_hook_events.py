#!/usr/bin/env python3
"""Direct-run tests for POST /api/hooks/event (server/lib/app_hook_events.py): sandboxed apps
(Parklet for Mac) post plugin events here; this server runs the enabled plugins as a spec host.

Uses IndieLibKit's shared spec fixtures when the sibling checkout exists (parklet events must be
accepted, fixtures/sink/reject/ refused), plus inline cases. Hostile input: only the inert sentinel
`$(echo INJECTED)`, asserted never to expand."""
import copy
import hashlib
import json
import os
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "server", "lib"))
import app_hook_events as ahe  # noqa: E402

SPEC = os.environ.get("THEINDIE_SPEC_DIR") or os.path.normpath(
    os.path.join(HERE, "..", "..", "..", "IndieLibKit", "spec", "plugins"))
SENTINEL = "$(echo INJECTED)"

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


BASE = {
    "event": "item.tags.added", "v": 1, "app": "parklet", "eventId": "evt-parklet-5",
    "occurredAt": "2026-11-24T09:00:00.000Z",
    "item": {"id": "6F1C2D3E-0000-4000-8000-000000000001", "tags": ["project/parklet", "todo"],
             "kind": "note", "origin": "local"},
    "added": ["todo"], "source": "ai",
    "paths": {"library": "/Users/me/Library/Group Containers/x/library.sqlite"},
}


def post(body, host="127.0.0.1", remote=False, root=None):
    raw = body if isinstance(body, bytes) else json.dumps(body).encode()
    return ahe.handle_post(ahe.PATH, lambda: raw, remote, host, root=root, background=False)


def accepted(event):
    try:
        ahe.validate(event)
        return True
    except ahe.Invalid:
        return False


def make_plugin(root, pid, script, event="item.tags.added", timeout=30, enable=True):
    folder = os.path.join(root, "plugins", pid)
    os.makedirs(folder, exist_ok=True)
    manifest = json.dumps({"id": pid, "version": 1,
                           "hooks": {event: {"run": "./hook.sh", "timeoutSec": timeout}}}).encode()
    with open(os.path.join(folder, "plugin.json"), "wb") as f:
        f.write(manifest)
    hook = os.path.join(folder, "hook.sh")
    with open(hook, "w") as f:
        f.write("#!/bin/sh\n" + script + "\n")
    os.chmod(hook, 0o755)
    if enable:
        path = os.path.join(root, "plugins-enabled.json")
        state = json.load(open(path)) if os.path.exists(path) else {"version": 1, "enabled": {}}
        state["enabled"][pid] = {"sha256": hashlib.sha256(manifest).hexdigest(), "enabledAt": "x"}
        json.dump(state, open(path, "w"))
    return folder


def log_lines(root):
    path = os.path.join(root, "logs", "plugin-runs.jsonl")
    return [json.loads(l) for l in open(path)] if os.path.exists(path) else []


print("== shared spec fixtures ==")
if os.path.isdir(os.path.join(SPEC, "fixtures/sink/reject")):
    for name in ["entry.created", "entry.updated", "comment.added", "reminder.due", "item.tags.added.parklet"]:
        check(f"accepts fixture {name}", accepted(json.load(open(os.path.join(SPEC, "fixtures/events", f"{name}.v1.json")))), True)
    reject = os.path.join(SPEC, "fixtures/sink/reject")
    for f in sorted(os.listdir(reject)):
        check(f"rejects fixture {f}", accepted(json.load(open(os.path.join(reject, f)))), False)
else:
    print(f"  SKIP  no sink fixtures in {SPEC} (IndieLibKit older than the HTTP event sink? set THEINDIE_SPEC_DIR)")

print("== inline validation ==")
check("base accepted", accepted(BASE), True)
for label, mutate in [
    ("unknown top key", lambda e: e.update(text="hello")),
    ("unknown item key", lambda e: e["item"].update(title="hello")),
    ("sentinel tag", lambda e: e["item"].update(tags=[SENTINEL])),
    ("sentinel in added", lambda e: e.update(added=[SENTINEL])),
    ("sentinel item id", lambda e: e["item"].update(id=SENTINEL)),
    ("space in eventId", lambda e: e.update(eventId="a b")),
    ("newline in id", lambda e: e["item"].update(id="a\nb")),
    ("speechtodo file paths", lambda e: e.update(paths={"workspace": "/w", "source": "/s",
                                                        "transcriptMarkdown": "/t.md", "transcriptJson": "/t.json"})),
    ("relative library", lambda e: e["paths"].update(library="lib.sqlite")),
    ("control char in library", lambda e: e["paths"].update(library="/a\nb")),
    ("v as bool", lambda e: e.update(v=True)),
    ("v 2", lambda e: e.update(v=2)),
    ("empty added", lambda e: e.update(added=[])),
    ("bad source", lambda e: e.update(source="robot")),
    ("bad app", lambda e: e.update(app="Parklet App")),
    ("unknown event", lambda e: e.update(event="shell.run")),
]:
    e = copy.deepcopy(BASE)
    mutate(e)
    check(f"rejects {label}", accepted(e), False)
check("rejects non-object", accepted([BASE]), False)

print("== HTTP routing ==")
check("other path -> None", ahe.handle_post("/api/other", lambda: b"{}", False, "127.0.0.1"), None)
with tempfile.TemporaryDirectory() as root:
    check("non-loopback client -> 403", post(BASE, host="100.64.0.7", root=root)[1], 403)
    check("remote listener (loopback proxy) -> 403", post(BASE, remote=True, root=root)[1], 403)
    check("bad JSON -> 400", post(b"{not json", root=root)[1], 400)
    check("empty body -> 400", post(b"", root=root)[1], 400)
    reply, status = post(BASE, root=root)
    check("valid, no plugins -> 202", status, 202)
    check("valid reply counts plugins", reply.get("plugins"), 0)
    check("::1 accepted", post(BASE, host="::1", root=root)[1], 202)

print("== delivery (spec host) ==")
with tempfile.TemporaryDirectory() as root:
    folder = make_plugin(root, "rec", 'cat > got.json; printf "%s|%s|%s" "$THEINDIE_EVENT" "$THEINDIE_APP" "$THEINDIE_EVENT_VERSION" > env.txt')
    off = make_plugin(root, "off", "touch ran", enable=False)
    other = make_plugin(root, "other", "touch ran", event="entry.created")
    changed = make_plugin(root, "changed", "touch ran")
    with open(os.path.join(changed, "plugin.json"), "ab") as f:
        f.write(b" ")  # edited after consent
    reply, status = post(BASE, root=root)
    check("202", status, 202)
    check("one plugin matched", reply["plugins"], 1)
    got = json.load(open(os.path.join(folder, "got.json")))
    check("stdin = the event JSON", got, BASE)
    check("env vars", open(os.path.join(folder, "env.txt")).read(), "item.tags.added|parklet|1")
    for name, f in [("not enabled", off), ("other event", other), ("changed manifest", changed)]:
        check(f"{name} did not run", os.path.exists(os.path.join(f, "ran")), False)
    lines = log_lines(root)
    check("one log line", len(lines), 1)
    check("log: app is the sender", lines[0]["app"], "parklet")
    check("log: ok", (lines[0]["pluginId"], lines[0]["status"], lines[0]["exitCode"]), ("rec", "ok", 0))
    check("log: event id", lines[0]["eventId"], "evt-parklet-5")

print("== hostile values never expand ==")
with tempfile.TemporaryDirectory() as root:
    folder = make_plugin(root, "rec", "cat > got.json")
    e = copy.deepcopy(BASE)
    e["item"]["tags"] = [SENTINEL]
    reply, status = post(e, root=root)
    check("sentinel tag -> 400", status, 400)
    check("sentinel tag: nothing ran", os.path.exists(os.path.join(folder, "got.json")), False)
    check("sentinel tag: nothing logged", log_lines(root), [])
    e = copy.deepcopy(BASE)
    e["paths"]["library"] = "/tmp/" + SENTINEL + "/library.sqlite"  # a path may hold these characters
    reply, status = post(e, root=root)
    check("sentinel in library path accepted", status, 202)
    text = open(os.path.join(folder, "got.json")).read()
    check("stdin carries the literal, unexpanded", SENTINEL in json.loads(text)["paths"]["library"], True)
    check("no INJECTED output anywhere", any("INJECTED" == l.strip() for l in text.splitlines()), False)

print("== failure, timeout, post ==")
with tempfile.TemporaryDirectory() as root:
    make_plugin(root, "bad", "echo boom >&2; exit 3")
    make_plugin(root, "slow", "sleep 30", timeout=1)
    pfolder = os.path.join(root, "plugins", "poster")
    os.makedirs(pfolder)
    manifest = json.dumps({"id": "poster", "version": 1,
                           "hooks": {"item.tags.added": {"post": "http://127.0.0.1:9/x"}}}).encode()
    open(os.path.join(pfolder, "plugin.json"), "wb").write(manifest)
    state = json.load(open(os.path.join(root, "plugins-enabled.json")))
    state["enabled"]["poster"] = {"sha256": hashlib.sha256(manifest).hexdigest()}
    json.dump(state, open(os.path.join(root, "plugins-enabled.json"), "w"))
    started = time.monotonic()
    records = {r["pluginId"]: r for r in ahe.deliver(ahe.validate(copy.deepcopy(BASE)), root)}
    check("timeout bounded (<6 s)", time.monotonic() - started < 6, True)
    check("failed with exit code + stderr", (records["bad"]["status"], records["bad"]["exitCode"],
                                              records["bad"]["stderrTail"].strip()), ("failed", 3, "boom"))
    check("timeout status", records["slow"]["status"], "timeout")
    check("post skipped", (records["poster"]["status"], records["poster"]["stderrTail"]),
          ("skipped", "skipped: post not supported"))

print("== corrupt consent file = nothing runs ==")
with tempfile.TemporaryDirectory() as root:
    folder = make_plugin(root, "rec", "touch ran")
    open(os.path.join(root, "plugins-enabled.json"), "w").write("{oops")
    check("no targets", ahe.targets("item.tags.added", root), [])

print("== config root ==")
check("env override", ahe.config_root({"THEINDIE_CONFIG_DIR": "/x/y", "HOME": "/h"}), "/x/y")
check("default", ahe.config_root({"HOME": "/h"}), "/h/.config/theindie")

if fails:
    print(f"\n{len(fails)} FAIL")
    for f in fails:
        print("  " + f)
    sys.exit(1)
print("\nall PASS")
