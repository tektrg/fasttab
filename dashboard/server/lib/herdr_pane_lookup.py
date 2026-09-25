#!/usr/bin/env python3
"""Find a herdr pane by its TAB LABEL, so scripts stop hardcoding pane ids.

Pane ids go stale every time herdr resets a workspace (2026-09-14: the
dashboard's `w2:p1A` vanished entirely); tab labels are what we name on purpose.

    python3 scripts/lib/herdr_pane_lookup.py chief-dashboard-server   # -> wB:p1P
    python3 scripts/lib/herdr_pane_lookup.py --title-of wB:p41        # -> the pane's terminal title

Exit 0 + pane id on stdout; exit 1 when no tab carries the label (nothing on
stdout); exit 2 when herdr itself cannot be read. Several tabs sharing one label
(e.g. `sim-janitor`) resolve to the first tab's first pane, with a stderr warning.
"""
import json
import subprocess
import sys


def pane_rows_for_label(tab_list, pane_list, label):
    """Panes (dicts) of every tab labelled `label`, in `herdr tab list` order.

    Takes the two parsed JSON payloads; tolerates missing or reshaped keys by
    returning [] instead of raising.
    """
    try:
        tab_ids = [tab["tab_id"] for tab in tab_list["result"]["tabs"] if tab.get("label") == label]
        panes = pane_list["result"]["panes"]
    except (KeyError, TypeError):
        return []
    ordered = []
    for tab_id in tab_ids:
        ordered.extend(pane for pane in panes if pane.get("tab_id") == tab_id)
    return ordered


def _herdr_json(*args):
    output = subprocess.run(["herdr", *args], capture_output=True, text=True, timeout=15, check=True)
    return json.loads(output.stdout)


def main(argv):
    if argv[:1] == ["--title-of"] and len(argv) == 2:
        try:
            panes = _herdr_json("pane", "list")["result"]["panes"]
        except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as error:
            print(f"herdr_pane_lookup: cannot read herdr ({error})", file=sys.stderr)
            return 2
        match = next((pane for pane in panes if pane.get("pane_id") == argv[1]), None)
        if match is None:
            return 1
        print(match.get("terminal_title_stripped") or match.get("terminal_title") or "")
        return 0
    label = next((arg for arg in argv if not arg.startswith("--")), None)
    if not label:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        rows = pane_rows_for_label(_herdr_json("tab", "list"), _herdr_json("pane", "list"), label)
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        print(f"herdr_pane_lookup: cannot read herdr ({error})", file=sys.stderr)
        return 2
    if not rows:
        return 1
    if len({row.get("tab_id") for row in rows}) > 1:
        print(f"herdr_pane_lookup: several tabs labelled {label!r}; using the first", file=sys.stderr)
    print(rows[0]["pane_id"])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
