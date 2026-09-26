#!/usr/bin/env python3
"""Compact health summary of the chief dashboard's /api/state payload.

Used by scripts/chief-dashboard-restart.sh and scripts/restart-chief-harness.sh.
Reads the JSON on stdin.

    ... | python3 scripts/lib/dashboard_state_summary.py             # print summary
    ... | python3 scripts/lib/dashboard_state_summary.py --is-warm   # exit 0 warm, 1 warming, 2 unreadable

The real health signal is per-feed: each `feeds[<name>]` snapshot carries
`warming` (cold start, retry soon) and `broken` (stale AND past its warm-up).
`feeds` ALSO holds non-feed keys — `machines` (per-machine {status, ...}) and
`machinesConfigError` (null when fine; a truthy value IS an error, never a
warming signal). A feed that is `null` (older/other shape) reads as warming.
Anything else unrecognised is reported as "unknown", never raised on: a status
printout must not crash on a payload shape it has not seen.
"""
import json
import sys

NON_FEED_KEYS = ("machines", "machinesConfigError")


def classify_feed(snapshot):
    """'warming' | 'broken' | 'ok' | 'unknown' for one `feeds[...]` value."""
    if snapshot is None:
        return "warming"
    if not isinstance(snapshot, dict) or not ("warming" in snapshot or "broken" in snapshot):
        return "unknown"
    if snapshot.get("warming"):
        return "warming"
    return "broken" if snapshot.get("broken") else "ok"


def summarize_state(state):
    """Structured summary; every field degrades to None/[] on an odd shape."""
    feeds = state.get("feeds") if isinstance(state, dict) else None
    buckets = {"warming": [], "broken": [], "unknown": []}
    if isinstance(feeds, dict):
        for name, snapshot in feeds.items():
            if name in NON_FEED_KEYS:
                continue
            verdict = classify_feed(snapshot)
            if verdict in buckets:
                buckets[verdict].append(name)
        machines = feeds.get("machines")
        if isinstance(machines, dict):
            for machine_name, machine in machines.items():
                status = machine.get("status") if isinstance(machine, dict) else None
                if status in ("warming", "broken"):
                    buckets[status].append(f"machine:{machine_name}")
        config_error = feeds.get("machinesConfigError")
    else:
        buckets["unknown"].append("feeds")
        config_error = None
    computed = state.get("computed") if isinstance(state, dict) else None
    agents = computed.get("agents") if isinstance(computed, dict) else None
    needs_you = computed.get("needsYou") if isinstance(computed, dict) else None
    screen_counts = None
    if isinstance(agents, list):
        screen_counts = {}
        for agent in agents:
            key = agent.get("screenState") if isinstance(agent, dict) else None
            screen_counts[key or "unknown"] = screen_counts.get(key or "unknown", 0) + 1
    return {
        "warming": buckets["warming"], "broken": buckets["broken"], "unknown": buckets["unknown"],
        "machinesConfigError": config_error,
        "agentCount": len(agents) if isinstance(agents, list) else None,
        "screenStates": screen_counts,
        "needsYouCount": len(needs_you) if isinstance(needs_you, list) else None,
        "needsYou": needs_you if isinstance(needs_you, list) else [],
    }


def is_warm(summary):
    return not summary["warming"]


def _count_text(count):
    return "unknown" if count is None else str(count)


def format_summary(summary):
    lines = []
    states = summary["screenStates"]
    state_text = ", ".join(f"{k}={v}" for k, v in sorted(states.items())) if states else "unknown"
    lines.append(f"agents {_count_text(summary['agentCount'])} ({state_text}) · "
                 f"needsYou {_count_text(summary['needsYouCount'])}")
    lines.append("warming: " + (", ".join(summary["warming"]) or "none"))
    if summary["broken"]:
        lines.append("BROKEN: " + ", ".join(summary["broken"]))
    if summary["unknown"]:
        lines.append("unknown shape: " + ", ".join(summary["unknown"]))
    if summary["machinesConfigError"]:
        lines.append(f"machines config error: {summary['machinesConfigError']}")
    for row in summary["needsYou"]:
        if not isinstance(row, dict):
            continue
        since = row.get("sinceSec")
        age = f"{since / 3600:.1f}h" if isinstance(since, (int, float)) and since else "  -  "
        lines.append("%-12s %6s  %-28s %s" % (str(row.get("kind", "?")).upper(), age,
                                              str(row.get("label", ""))[:28],
                                              str(row.get("detail", ""))[:70]))
    return "\n".join(lines)


def main(argv):
    try:
        state = json.load(sys.stdin)
    except (ValueError, OSError):
        print("no readable state from the server", file=sys.stderr)
        return 2
    summary = summarize_state(state)
    if "--is-warm" in argv:
        return 0 if is_warm(summary) else 1
    print(format_summary(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
