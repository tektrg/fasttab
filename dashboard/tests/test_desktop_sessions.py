#!/usr/bin/env python3
"""Direct-run tests for sleeping Claude Desktop sessions (desktop_sessions.py
+ computed.sleepingSessions in get_full_state)."""
import json
import os
import sys
import tempfile

LIB = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "server", "lib")
sys.path.insert(0, LIB)

import desktop_sessions  # noqa: E402

fails = []
NOW = 1_790_433_800.0
DAY = 86400


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


def desktop_file(uuid, days_ago, **extra):
    entry = {"sessionId": f"local_{uuid}", "cliSessionId": f"cli-{uuid}",
             "cwd": "/Users/x/01_Project/demo", "title": f"Title {uuid}",
             "isArchived": False, "createdAt": int((NOW - 30 * DAY) * 1000),
             "lastActivityAt": int((NOW - days_ago * DAY) * 1000)}
    entry.update(extra)
    return entry


def write_store(root, files, mtime_days_ago=None):
    """files: {name: dict|str}; every file's mtime = NOW - its own activity
    (or `mtime_days_ago` when given), like Desktop writes them."""
    org = os.path.join(root, "account-1", "org-1")
    os.makedirs(org, exist_ok=True)
    for name, content in files.items():
        path = os.path.join(org, name)
        with open(path, "w") as f:
            f.write(content if isinstance(content, str) else json.dumps(content))
        la = content.get("lastActivityAt") if isinstance(content, dict) else None
        mtime = NOW - mtime_days_ago * DAY if mtime_days_ago is not None else (la / 1000 if la else NOW)
        os.utime(path, (mtime, mtime))
    return org


print("== parse_session_file ==")
with tempfile.TemporaryDirectory() as tmp:
    org = write_store(tmp, {
        "local_aaa.json": desktop_file("aaa", 1),
        "local_arch.json": desktop_file("arch", 1, isArchived=True),
        "local_badid.json": desktop_file("x", 1, sessionId="not-a-desktop-id"),
        "local_notitle.json": desktop_file("nt", 1, title=None),
        "local_noactivity.json": desktop_file("na", 1, lastActivityAt=None),
        "local_garbage.json": "{not json",
    })
    parsed = desktop_sessions.parse_session_file(os.path.join(org, "local_aaa.json"))
    check("compact shape", parsed, {
        "desktopSessionId": "local_aaa", "cliSessionId": "cli-aaa", "label": "Title aaa",
        "cwd": "/Users/x/01_Project/demo", "lastActiveTs": NOW - DAY,
        "openUrl": "claude://code/continue?session=local_aaa"})
    check("archived -> None", desktop_sessions.parse_session_file(os.path.join(org, "local_arch.json")), None)
    check("id Claude.app can't open -> None",
          desktop_sessions.parse_session_file(os.path.join(org, "local_badid.json")), None)
    check("no title -> folder name",
          desktop_sessions.parse_session_file(os.path.join(org, "local_notitle.json"))["label"], "demo")
    check("no lastActivityAt -> createdAt",
          desktop_sessions.parse_session_file(os.path.join(org, "local_noactivity.json"))["lastActiveTs"],
          NOW - 30 * DAY)
    check("bad JSON -> None", desktop_sessions.parse_session_file(os.path.join(org, "local_garbage.json")), None)

print("== DesktopSessionScanner: window, stat filter, cache, non-session files ==")
with tempfile.TemporaryDirectory() as tmp:
    write_store(tmp, {
        "local_new.json": desktop_file("new", 0.5),
        "local_mid.json": desktop_file("mid", 5),
        "local_old.json": desktop_file("old", 20),
        "scheduled-tasks.json": {"sessionId": "local_zzz", "lastActivityAt": int(NOW * 1000)},
        "deleted_abc": "x",
    })
    # A file touched recently but whose last activity is old (focus/metadata write).
    write_store(tmp, {"local_touched.json": desktop_file("touched", 20)}, mtime_days_ago=0)
    scanner = desktop_sessions.DesktopSessionScanner(store_dirs=[tmp], window_days=14)
    got = scanner.scan(now=NOW)
    check("window keeps new+mid, newest first; scheduled-tasks / old / touched-but-old dropped",
          [s["desktopSessionId"] for s in got], ["local_new", "local_mid"])

    calls = []
    real_parse = desktop_sessions.parse_session_file
    desktop_sessions.parse_session_file = lambda p: calls.append(os.path.basename(p)) or real_parse(p)
    try:
        scanner.scan(now=NOW)
        check("second scan: unchanged files come from the cache", calls, [])
        fresh = desktop_sessions.DesktopSessionScanner(store_dirs=[tmp], window_days=14)
        fresh.scan(now=NOW)
        check("stat filter: a file older than the window is never parsed", "local_old.json" in calls, False)
        check("a recent-mtime file is parsed", sorted(calls), ["local_mid.json", "local_new.json", "local_touched.json"])
    finally:
        desktop_sessions.parse_session_file = real_parse
    check("missing store folder -> []",
          desktop_sessions.DesktopSessionScanner(store_dirs=["/nonexistent/x"]).scan(now=NOW), [])

print("== default_store_dirs: env override ==")
os.environ[desktop_sessions.STORES_ENV] = os.pathsep.join(["/a", "", "/b"])
check("override split, blanks dropped", desktop_sessions.default_store_dirs(), ["/a", "/b"])
del os.environ[desktop_sessions.STORES_ENV]

print("== build_sleeping_sessions: live wins ==")
sessions = [{"desktopSessionId": f"local_{k}", "cliSessionId": f"cli-{k}", "lastActiveTs": NOW}
            for k in ("host", "cli", "herdr", "asleep")]
sessions.append({"desktopSessionId": "local_nocli", "cliSessionId": None, "lastActiveTs": NOW})
live = [{"sessionId": "resumed-with-new-id", "hostSessionId": "local_host"},
        {"sessionId": "cli-cli", "hostSessionId": None}]
agents = [{"agentSession": "cli-herdr"}, {"agentSession": None}]
check("running by Desktop id / by Claude session id / as a herdr pane -> dropped",
      [s["desktopSessionId"] for s in desktop_sessions.build_sleeping_sessions(sessions, live, agents)],
      ["local_asleep", "local_nocli"])
check("no feed data -> []", desktop_sessions.build_sleeping_sessions(None, None, None), [])

print("== get_full_state: computed.sleepingSessions, feed data summarized ==")
import chief_dashboard_views as views  # noqa: E402
views.FEEDS["claudeSessions"].set_success([{"sessionId": "cli-cli", "hostSessionId": None}])
views.FEEDS["desktopSessions"].set_success(sessions)
state = views.get_full_state()
check("sleeping rows in computed",
      [s["desktopSessionId"] for s in state["computed"]["sleepingSessions"]],
      ["local_host", "local_herdr", "local_asleep", "local_nocli"])
check("never mixed into computed.agents",
      any(a.get("desktopSessionId") for a in state["computed"]["agents"]), False)
check("feed entry keeps health, carries only a count",
      (state["feeds"]["desktopSessions"]["data"], state["feeds"]["desktopSessions"]["broken"]),
      ({"sleepingCount": 4}, False))
check("the live feed object itself is untouched", len(views.FEEDS["desktopSessions"].data), 5)

if fails:
    print("\nFAILURES:")
    for f in fails:
        print("  " + f)
    sys.exit(1)
print("\nALL PASS")
