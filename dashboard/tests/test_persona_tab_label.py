#!/usr/bin/env python3
"""Direct-run tests for server/lib/persona_tab_label.py — the
`<persona> · <first words>` herdr tab label of a persona start.

SAFETY: hostile strings are inert sentinels (`echo INJECTED`) and live only
in this file. The one shell round-trip runs `printf` (never herdr) on the
exact string ssh would send, to prove nothing in the label gets executed."""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "server", "lib"))
from chief_dashboard_herdr import build_remote_command  # noqa: E402
from persona_tab_label import (  # noqa: E402
    SUFFIX_MAX_CHARS, message_suffix, persona_tab_label)

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


SAFE_SUFFIX_RE = re.compile(r"[\w .-]*")  # \w = unicode letters/digits/_

print("== suffix rules ==")
for label, message, want in (
        ("first 4 words, lowercased", "Fix The Login bug on iOS please", "fix the login bug"),
        ("punctuation + quotes stripped", 'Hey, "can" you: check don\'t?!', "hey can you check"),
        ("emoji dropped", "🚀 ship it now 🎉", "ship it now"),
        ("cut on a word boundary at 28 chars",
         "investigate intermittent websocket disconnects", "investigate intermittent"),
        ("single long word hard-cut", "a" * 40, "a" * SUFFIX_MAX_CHARS),
        ("unicode letters kept (NFC)", "Sửa lỗi đăng nhập", "sửa lỗi đăng nhập"),
        ("tabs collapse", "a\tb", "a b"),
        ("dots/dashes kept inside words, trimmed at edges", "...v1.2 -- re-run_it.", "v1.2 re-run_it"),
        ("empty", "", ""),
        ("punctuation only", "?!… 🎉 ---", ""),
        ("slash command", "/compact", "compact")):
    check(label, message_suffix(message), want)

print("\n== label ==")
check("name · suffix", persona_tab_label("portfolio", "Fix the login bug"), "portfolio · fix the login bug")
check("no suffix -> bare name", persona_tab_label("portfolio", "!!!"), "portfolio")

print("\n== hostile input: only inert sentinels ==")
for label, hostile in (("command substitution", "$(echo INJECTED)"),
                       ("backticks", "`echo INJECTED`"),
                       ("semicolon", "x; echo INJECTED"),
                       ("quote break-out", "'; echo INJECTED #"),
                       ("double quotes", '"$(echo INJECTED)"'),
                       ("zsh =word", "=echo INJECTED")):
    suffix = message_suffix(hostile)
    tab_label = persona_tab_label("test-echo", hostile)
    check(f"{label}: suffix is safe charset only", bool(SAFE_SUFFIX_RE.fullmatch(suffix)), True)
    check(f"{label}: no $ ` ; quotes or parens in the label",
          any(c in tab_label for c in "$`;'\"()="), False)
    check(f"{label}: sentinel text survives only as plain words", suffix, "echo injected"
          if label != "semicolon" else "x echo injected")
    # The exact string ssh would hand the Air's shell for `--label <label>`,
    # with printf standing in for herdr: it must print the label verbatim.
    remote = build_remote_command("printf", ["%s\\n", tab_label])
    out = subprocess.run(["sh", "-c", remote], capture_output=True, text=True, timeout=5).stdout
    check(f"{label}: remote shell prints the label verbatim", out, tab_label + "\n")
    check(f"{label}: nothing executed (no INJECTED in output)", "INJECTED" in out, False)

print()
if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("All persona tab label checks passed.")
