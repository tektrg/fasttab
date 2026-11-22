#!/usr/bin/env python3
"""Direct-run tests for /compact with a temporary Sonnet switch
(server/lib/compact_jobs.py + the routes in chief-dashboard-server.py).

A FakeTUI plays Claude Code 2.1.330 as measured by the live probe
(dashboard/AGENTS.md "Compact on Sonnet"): the /model picker (cursor ❯, ✔ on
the live model, `s` = session only, Enter/digit = SAVE the global default),
the cache-warm `Switch model?` dialog, the `Compacting conversation…` spinner
and the transcript's `system/compact_boundary` line. Every keystroke is
logged with the screen it landed on, so "never Enter or a digit inside the
picker" is asserted on the key log, not inferred.

HARD SAFETY: no real herdr, ssh, pane or port. Server-level cases patch
`_pane_run_raw` / `herdr_transport.remote_shell_text`, set
CHIEF_DASHBOARD_STATE_HOME to a temp dir before import, and stub the board
store's writes. Run: python3 tests/test_compact_jobs.py
"""
import base64
import importlib.util
import json
import os
import stat
import sys
import tempfile

TMP = tempfile.mkdtemp(prefix="compact-jobs-test-")
os.environ["CHIEF_DASHBOARD_STATE_HOME"] = os.path.join(TMP, "state")
os.environ["CHIEF_DASHBOARD_CONFIG_HOME"] = os.path.join(TMP, "config")

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "server", "lib"))

import compact_jobs as cj  # noqa: E402

fails = []


def check(label, got, want):
    ok = got == want
    if not ok:
        fails.append(f"{label}: got {got!r} want {want!r}")
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")


# ---------------------------------------------------------------- fake TUI

ROWS = [
    ("Default (recommended)", "Use the default model (currently {default}) · $4/$20 per Mtok"),
    ("Opus", "Opus 5.5 · Best for everyday, complex tasks · $4/$20 per Mtok"),
    ("Fable", "Fable 5.2 · Most capable for your hardest and longest-running tasks · $8/$40 per Mtok"),
    ("Sonnet", "Sonnet 5.5 · Efficient for routine tasks · $2/$10 per Mtok"),
    ("Haiku", "Haiku 5.5 · Fastest for quick answers · $0.10/$0.50 per Mtok ($0.50/$2.50 for prompts over"),
]
MODEL_OF_ROW = [None, "Opus 5.5", "Fable 5.2", "Sonnet 5.5", "Haiku 5.5"]
RULE = "─" * 60
SESSION = "11111111-2222-3333-4444-555555555555"


class FakeTUI:
    def __init__(self, live_row=1, default="Opus 5.5", custom=None, cache_warm=False,
                 busy_reads=0, busy_forever=False, compact_reads=3, compact_never=False,
                 boundary=True, typed_on_read=None, transcript_path=None,
                 statusline=True, screen_compacted=True):
        self.statusline = statusline
        self.screen_compacted = screen_compacted
        self.live_row = live_row          # index into ROWS carrying ✔ (None = custom)
        self.default = default
        self.custom = custom              # custom model display (ANTHROPIC_MODEL)
        self.cache_warm = cache_warm
        self.busy_reads = busy_reads
        self.busy_forever = busy_forever
        self.compact_reads = compact_reads
        self.compact_never = compact_never
        self.boundary = boundary
        self.typed_on_read = typed_on_read  # (read number, text): the user types
        self.transcript_path = transcript_path
        self.mode = "idle"
        self.cursor = None
        self.dialog_target = None
        self.composer = ""
        self.history = ["⏺ earlier work", "✻ Brewed for 1m 2s"]
        self.transcript = [
            {"type": "system", "subtype": "compact_boundary", "uuid": "old-boundary",
             "timestamp": "2026-11-20T00:00:00Z"},
            {"type": "assistant", "message": {"model": "claude-opus-5-5", "content": []}},
        ]
        self.reads = 0
        self.key_log = []       # (mode the key landed in, key)
        self.run_log = []       # (mode, text) for `pane run`
        self.violations = []
        self.saved_default = None
        self.sent_texts = []
        self.compact_left = 0
        self._write_transcript()

    # -- what the user sees
    def model_display(self):
        if self.live_row is None:
            return self.custom
        return MODEL_OF_ROW[self.live_row] if self.live_row else self.default

    def _box(self, busy=False):
        footer = "  ⏵⏵ bypass permissions on (shift+tab to cycle)"
        if busy:
            footer += " · esc to interrupt"
        status = (f"  [{self.model_display()}] 4% context | effort:medium | pane:w4:p2"
                  if self.statusline else "  ~/project")
        return [RULE, "❯ " + self.composer, RULE, status, footer]

    def render(self):
        self.reads += 1
        if self.typed_on_read and self.reads >= self.typed_on_read[0]:
            self.composer = self.typed_on_read[1]
        if self.mode == "idle" and (self.busy_forever or self.busy_reads > 0):
            self.busy_reads -= 1
            return self.history + ["✽ Thinking… (3s · ↓ 10 tokens)"] + self._box(busy=True)
        if self.mode == "compacting":
            if not self.compact_never:
                self.compact_left -= 1
                if self.compact_left < 0:
                    self._finish_compact()
                    return self.history + self._box()
            return self.history + ["✽ Compacting conversation… (3s · ↓ 104 tokens)"] + self._box(busy=True)
        if self.mode == "picker":
            lines = ["", "  Select model",
                     "  Your pick is the default for new sessions. For other models, use --model."]
            for i, (label, desc) in enumerate(ROWS):
                mark = " ✔" if (i == self.live_row
                                or (self.live_row is None and self.custom == "check-default" and i == 0)) else ""
                cur = "❯ " if i == self.cursor else "  "
                text = f"{label}{mark}"
                lines.append(f"  {cur}{i + 1}. {text:<22} {desc.format(default=self.default)}")
                if label == "Haiku":
                    lines.append(" " * 32 + "100k)")
            lines += ["  ● High effort ←/→ to adjust",
                      "  s to use this session only · Enter to save · Esc to cancel"]
            return self.history + lines
        if self.mode == "dialog":
            name = MODEL_OF_ROW[self.dialog_target]
            return self.history + [
                "  Switch model?", "  Your next response will be slower and use more tokens",
                f"  This conversation is cached for the current model. Switching to {name} means the full history gets re-read.",
                f"  ❯ 1. Yes, switch to {name}", "    2. No, go back",
                "  Enter to confirm · Esc to cancel"]
        return self.history + self._box()

    # -- input
    def run_line(self, text):
        self.run_log.append((self.mode, text))
        if self.mode != "idle":
            self.violations.append(f"pane run {text!r} while {self.mode}")
            return
        if self.composer:
            self.violations.append(f"pane run {text!r} over typed text")
        if text == "/model":
            self.mode = "picker"
            self.cursor = self.live_row if self.live_row is not None else 0
        elif text.startswith("/compact"):
            self.history.append("❯ " + text)
            self.mode = "compacting"
            self.compact_left = self.compact_reads
        else:
            self.history.append("❯ " + text)
            self.sent_texts.append(text)

    def keys(self, *keys):
        for key in keys:
            self.key_log.append((self.mode, key))
            if self.mode == "picker":
                if key == "down":
                    self.cursor = min(self.cursor + 1, len(ROWS) - 1)
                elif key == "up":
                    self.cursor = max(self.cursor - 1, 0)
                elif key == "s":
                    if self.cache_warm and self.cursor != self.live_row:
                        self.mode, self.dialog_target = "dialog", self.cursor
                    else:
                        self._apply(self.cursor)
                elif key == "esc":
                    self.mode = "idle"
                    self.history += ["❯ /model", f"  ⎿  Kept model as {self.model_display()}"]
                elif key == "enter" or key.isdigit():
                    self.violations.append(f"{key!r} inside the picker (saves the default)")
                    self.saved_default = self.cursor if key == "enter" else int(key) - 1
                    self._apply(self.saved_default, saved=True)
            elif self.mode == "dialog":
                if key in ("1", "enter"):
                    self._apply(self.dialog_target)
                elif key == "esc":
                    self.mode = "picker"
                    self.cursor = self.live_row
                else:
                    self.violations.append(f"{key!r} inside the confirm dialog")
            # idle / compacting: a stray Enter or Esc is harmless (probe).

    def _apply(self, row, saved=False):
        if row == 0:
            self.violations.append("Default row selected")
        self.live_row = row
        self.mode = "idle"
        how = "and saved as your default for new sessions" if saved else "for this session only"
        self.history += ["❯ /model", f"  ⎿  Set model to {self.model_display()} {how}"]
        self.cache_warm = False

    def _finish_compact(self):
        self.mode = "idle"
        if self.screen_compacted:
            self.history += ["  ⎿  Compacted (ctrl+o to see full summary)"]
        if self.boundary:
            self.transcript.append({"type": "system", "subtype": "compact_boundary",
                                    "uuid": f"new-boundary-{len(self.transcript)}",
                                    "timestamp": "2026-11-22T15:22:47.096Z"})
            self.transcript.append({"type": "user", "message": {"content":
                                    "<local-command-stdout>\u001b[2mCompacted\u001b[22m</local-command-stdout>"}})
        self._write_transcript()

    def tail_bytes(self):
        return ("\n".join(json.dumps(e) for e in self.transcript) + "\n").encode()

    def _write_transcript(self):
        if self.transcript_path:
            with open(self.transcript_path, "wb") as f:
                f.write(self.tail_bytes())

    def send_message(self, text):
        """The reliable send path, as the dashboard does it: pane run + Enter."""
        self.run_line(text)
        self.keys("enter")
        return {"ok": True, "state": "message sent"}

    def io(self):
        return cj.PaneIO(self.render, self.run_line, self.keys, self.send_message,
                         self.tail_bytes)


class Clock:
    def __init__(self):
        self.t = 1_000_000.0

    def now(self):
        return self.t

    def sleep(self, sec):
        self.t += sec


def new_table(path=None, clock=None):
    clock = clock or Clock()
    return cj.CompactJobs(path, clock=clock.now, sleep=clock.sleep,
                          spawn=lambda fn: fn()), clock


def run_job(fake, instructions=None, follow_up=None, table=None, row="row-1"):
    table = table or new_table()[0]
    payload, status = table.start({"rowId": row, "actor": "po", "instructions": instructions,
                                   "followUp": follow_up}, fake.io())
    job = table.get(payload["job"]["id"])[0]["job"]
    return job, status, table


def picker_keys(fake):
    return [k for mode, k in fake.key_log if mode == "picker"]


def no_save_keys(label, fake):
    bad = [k for mode, k in fake.key_log if mode == "picker" and (k == "enter" or k.isdigit())]
    check(f"{label}: never Enter or a digit inside the picker", bad, [])
    check(f"{label}: no violations", fake.violations, [])
    check(f"{label}: global default never saved", fake.saved_default, None)


# ---------------------------------------------------------------- pure parsing

print("== screen parsing ==")
f = FakeTUI()
check("idle screen reads idle", cj.prompt_reading(f.render()), "idle")
check("statusline model", cj.statusline_model(f.render()), "Opus 5.5")
f.composer = "half a thought"
check("typed text reads typed", cj.prompt_reading(f.render()), "typed")
f = FakeTUI(busy_reads=1)
check("busy screen reads busy", cj.prompt_reading(f.render()), "busy")
f = FakeTUI()
f.run_line("/model")
p = cj.parse_model_picker(f.render())
check("picker rows parsed", [r["label"] for r in p["rows"]],
      ["Default (recommended)", "Opus", "Fable", "Sonnet", "Haiku"])
check("picker cursor on the ✔ row", p["cursor"], 1)
check("current model from ✔", cj.current_model(p), (1, "Opus 5.5"))
check("Default row is never standard", p["rows"][0]["standard"], False)
check("picker reads as a prompt (never type into it)", cj.prompt_reading(f.render()), "prompt")
f = FakeTUI(live_row=0, default="Opus 5.5")
f.run_line("/model")
check("✔ on Default -> its (currently X) row",
      cj.current_model(cj.parse_model_picker(f.render())), (1, "Opus 5.5"))
f = FakeTUI(live_row=None, custom="trung/claude-opus-5-5")
f.run_line("/model")
check("no ✔ -> custom", cj.current_model(cj.parse_model_picker(f.render()))[0], None)
check("stale picker frame above the prompt is not open",
      cj.picker_open(["  Select model", "  s to use this session only · Enter to save"]
                     + ["output"] * 10 + FakeTUI()._box()), False)
check("boundary ids", cj.compact_boundary_ids(FakeTUI().tail_bytes()), {"old-boundary"})
check("boundary ids: unreadable", cj.compact_boundary_ids(None), None)

print("== request validation ==")
check("missing rowId", cj.validate_request({"actor": "po"})[1], "missing rowId")
check("newline in followUp refused",
      cj.validate_request({"rowId": "r", "actor": "po", "followUp": "a\nb"})[1] is not None, True)
check("newline in instructions refused",
      cj.validate_request({"rowId": "r", "actor": "po", "instructions": "a\nb"})[1] is not None, True)
fields, err = cj.validate_request({"rowId": " r ", "actor": "po", "instructions": "  keep tests ",
                                   "followUp": "  "})
check("trimmed fields, empty followUp omitted",
      (fields, err), ({"rowId": "r", "actor": "po", "instructions": "keep tests", "followUp": None}, None))


# ---------------------------------------------------------------- job runs

print("== happy path: Opus -> Sonnet (session only) -> compact -> Opus -> follow-up ==")
fake = FakeTUI()
job, status, _t = run_job(fake, instructions="keep the plan", follow_up="carry on with step 3")
check("202 on start", status, 202)
check("state done", job["state"], "done")
check("originalModel", job["originalModel"], "Opus 5.5")
check("switchSkipped false", job["switchSkipped"], False)
check("compactOk", job["compactOk"], True)
check("modelRestored", job["modelRestored"], True)
check("followUpSent", job["followUpSent"], True)
check("error none", (job["error"], job["failedStep"]), (None, None))
check("session back on Opus", fake.model_display(), "Opus 5.5")
check("picker keys: down down s (to Sonnet), up up s (back)",
      picker_keys(fake), ["down", "down", "s", "up", "up", "s"])
check("/model typed with pane run only (no extra Enter)",
      [t for _m, t in fake.run_log], ["/model", "/compact keep the plan", "/model", "carry on with step 3"])
check("compact ran on Sonnet", any("Set model to Sonnet 5.5 for this session only" in l
                                   for l in fake.history), True)
check("follow-up after the restore", fake.history.index("❯ carry on with step 3")
      > max(i for i, l in enumerate(fake.history) if "Set model to Opus 5.5" in l), True)
no_save_keys("happy path", fake)

print("== `Switch model?` confirm (cache warm) is answered with 1 ==")
fake = FakeTUI(cache_warm=True)
job, _s, _t = run_job(fake)
check("state done", job["state"], "done")
check("dialog keys: only 1", [k for m, k in fake.key_log if m == "dialog"], ["1"])
check("picker still uses s", picker_keys(fake), ["down", "down", "s", "up", "up", "s"])
check("followUpSent null without followUp", job["followUpSent"], None)
no_save_keys("confirm dialog", fake)

print("== already on Sonnet (statusline) -> no picker, compact only ==")
fake = FakeTUI(live_row=3)
job, _s, _t = run_job(fake, follow_up="next")
check("state done", job["state"], "done")
check("switchSkipped", (job["switchSkipped"], job["skipReason"]), (True, cj.ALREADY_SONNET_SKIP))
check("originalModel Sonnet", job["originalModel"], "Sonnet 5.5")
check("no picker opened", [t for _m, t in fake.run_log if t == "/model"], [])
check("modelRestored null (nothing to restore)", job["modelRestored"], None)
check("compactOk", job["compactOk"], True)
check("followUpSent", job["followUpSent"], True)

print("== already on Sonnet, no statusline -> the picker's ✔ row decides ==")
fake = FakeTUI(live_row=3, statusline=False)
job, _s, _t = run_job(fake)
check("state done", job["state"], "done")
check("switchSkipped from the picker", (job["switchSkipped"], job["skipReason"]),
      (True, cj.ALREADY_SONNET_SKIP))
check("originalModel from ✔", job["originalModel"], "Sonnet 5.5")
check("picker escaped, nothing selected", picker_keys(fake), ["esc"])
check("modelRestored null", job["modelRestored"], None)
no_save_keys("already Sonnet via picker", fake)

print("== custom model (ANTHROPIC_MODEL) -> no switch, compact on current model ==")
fake = FakeTUI(live_row=None, custom="trung/claude-opus-5-5")
job, _s, _t = run_job(fake)
check("state done", job["state"], "done")
check("skip reason", (job["switchSkipped"], job["skipReason"]), (True, cj.CUSTOM_MODEL_SKIP))
check("picker escaped, nothing selected", picker_keys(fake), ["esc"])
check("compactOk", job["compactOk"], True)
check("modelRestored null", job["modelRestored"], None)
check("model untouched", fake.model_display(), "trung/claude-opus-5-5")
no_save_keys("custom model", fake)

print("== custom model shown as ✔ on Default with no standard row -> skip ==")
fake = FakeTUI(live_row=None, custom="check-default", default="trung/claude-opus-5-5")
job, _s, _t = run_job(fake)
check("skip reason", job["skipReason"], cj.CUSTOM_MODEL_SKIP)
check("state done", job["state"], "done")
no_save_keys("custom on Default", fake)

print("== compact timeout, TUI idles later: restore runs, follow-up still sent, state failed ==")


class StallThenIdle(FakeTUI):
    """Compaction outlives the 5 min deadline, then the prompt comes back."""

    def render(self):
        if self.mode == "compacting" and self.compact_never and self.reads > 200:
            self.compact_never = False
            self.compact_left = -1
        return super().render()


fake = StallThenIdle(compact_never=True)
job, _s, _t = run_job(fake, follow_up="go on")
check("state failed", job["state"], "failed")
check("failedStep compacting", job["failedStep"], "compacting")
check("error", job["error"], "compaction did not finish within 5 min")
check("compactOk false", job["compactOk"], False)
check("restore ran after the timeout", job["modelRestored"], True)
check("back on Opus", fake.model_display(), "Opus 5.5")
check("follow-up still sent", (job["followUpSent"], fake.sent_texts), (True, ["go on"]))
no_save_keys("stall then idle", fake)

print("== compact never ends: restore + follow-up attempted, nothing typed into the spinner ==")
fake = FakeTUI(compact_never=True)
job, _s, _t = run_job(fake, follow_up="after the compact")
check("state failed", job["state"], "failed")
check("compactOk false", job["compactOk"], False)
check("restore attempted but the prompt never came back", job["modelRestored"], False)
check("follow-up attempted but not sent", (job["followUpSent"], fake.sent_texts), (False, []))
check("no key or text typed while compacting",
      [k for m, k in fake.key_log if m == "compacting" and k != "enter"]
      + [t for m, t in fake.run_log if m == "compacting"], [])
no_save_keys("compact never ends", fake)

print("== screen fallback: no transcript boundary, `Compacted` line counts ==")
fake = FakeTUI(boundary=False)
job, _s, _t = run_job(fake)
check("compactOk via screen", job["compactOk"], True)
check("state done", job["state"], "done")

print("== transcript boundary alone proves the compact (screen line missing) ==")
fake = FakeTUI(screen_compacted=False)
job, _s, _t = run_job(fake)
check("compactOk via transcript", (job["compactOk"], job["state"]), (True, "done"))

print("== an OLD boundary in the transcript never counts ==")
fake = FakeTUI(screen_compacted=False, boundary=False)
job, _s, _t = run_job(fake)
check("no new boundary, no screen line -> timeout", (job["compactOk"], job["state"]), (False, "failed"))

print("== `Not enough messages to compact.` (live 2026-11-22) fails at once, not after 5 min ==")


class NotEnoughMessages(FakeTUI):
    """Live screen: `⎿  Not enough messages to compact.` under the echo, no
    compact_boundary written. An older successful `/compact` sits above it."""

    def __init__(self, **kw):
        super().__init__(**kw)
        self.history += ["❯ /compact", "  ⎿  Compacted (ctrl+o to see full summary)",
                         "  ⎿  Referenced file ../notes.md"]

    def _finish_compact(self):
        self.mode = "idle"
        self.history += ["  ⎿  Not enough messages to compact."]


clock = Clock()
fake = NotEnoughMessages(live_row=3)
job, _s, _t = run_job(fake, follow_up="say done", table=new_table(clock=clock)[0])
check("state failed", job["state"], "failed")
check("error names the TUI's reason", (job["failedStep"], job["error"]),
      ("compacting", "compact failed: Not enough messages to compact."))
check("compactOk false", job["compactOk"], False)
check("ended within seconds (no 5 min wait)", clock.t - 1_000_000.0 < 60, True)
check("follow-up still sent", (job["followUpSent"], fake.sent_texts), (True, ["say done"]))
check("an older `Compacted` above the last echo never counts",
      cj.screen_compacted(fake.render()), False)

print("== user typed into the session mid-job -> failed, restore attempted, no follow-up ==")
class TypesAfterSwitch(FakeTUI):
    """The user starts typing in the terminal right after the Sonnet switch."""

    def _apply(self, row, saved=False):
        super()._apply(row, saved)
        if MODEL_OF_ROW[row] == "Sonnet 5.5":
            self.composer = "wait, one more thing"


fake = TypesAfterSwitch()
job, _s, _t = run_job(fake, follow_up="should not be sent")
check("state failed", job["state"], "failed")
check("error", job["error"], cj.USER_TYPED_ERROR)
check("failedStep compacting", job["failedStep"], "compacting")
check("compact never typed", [t for _m, t in fake.run_log if t.startswith("/compact")], [])
check("follow-up not sent", fake.sent_texts, [])
check("followUpSent null", job["followUpSent"], None)
check("restore could not type over the user's text", job["modelRestored"], False)
check("nothing typed over the user's text", [v for v in fake.violations if "typed text" in v], [])
no_save_keys("user typed", fake)

print("== user typed, then cleared the box: restore proceeds ==")


class TypesThenClears(TypesAfterSwitch):
    def render(self):
        if self.composer and self.reads > 40:
            self.composer = ""
        return super().render()


fake = TypesThenClears()
job, _s, _t = run_job(fake)
check("state failed", job["state"], "failed")
check("error", job["error"], cj.USER_TYPED_ERROR)
check("model restored once the box is empty", job["modelRestored"], True)
check("back on Opus", fake.model_display(), "Opus 5.5")
no_save_keys("typed then cleared", fake)

print("== busy agent: waits, then proceeds ==")
fake = FakeTUI(busy_reads=20)
clock = Clock()
table, clock = new_table(clock=clock)
job, _s, _t = run_job(fake, table=table)
check("state done after waiting", job["state"], "done")
check("waited ~20 polls", clock.t - 1_000_000.0 >= 20 * cj.POLL_SEC, True)

print("== busy agent: 10 min timeout -> failed, nothing typed ==")
fake = FakeTUI(busy_forever=True)
job, _s, _t = run_job(fake, follow_up="x")
check("state failed", job["state"], "failed")
check("failedStep waitingIdle", job["failedStep"], "waitingIdle")
check("error", job["error"], "agent did not reach an idle prompt within 10 min")
check("nothing typed", (fake.run_log, fake.key_log), ([], []))
check("no follow-up", job["followUpSent"], None)

print("== single-flight per row: 409 while active ==")
held = []
table = cj.CompactJobs(None, spawn=lambda fn: held.append(fn))
p1, s1 = table.start({"rowId": "row-9", "actor": "po"}, FakeTUI().io())
p2, s2 = table.start({"rowId": "row-9", "actor": "po"}, FakeTUI().io())
check("first 202", s1, 202)
check("second 409", s2, 409)
check("409 body", (p2["ok"], p2["error"], p2["job"]["id"]), (False, "job-active", p1["job"]["id"]))
p3, s3 = table.start({"rowId": "row-other", "actor": "po"}, FakeTUI().io())
check("another row is independent", s3, 202)
check("GET by rowId returns the active job", table.for_row("row-9")[0]["job"]["id"], p1["job"]["id"])
check("GET unknown row -> null", table.for_row("nope"), ({"ok": True, "job": None}, 200))
check("GET unknown id -> 404", table.get("cj-0000000000000000")[1], 404)

print("== persistence: 0600 file, restart marks running jobs failed ==")
state_path = os.path.join(TMP, "persist", "compact-jobs.json")
clock = Clock()
held = []
table = cj.CompactJobs(state_path, clock=clock.now, sleep=clock.sleep, spawn=lambda fn: held.append(fn))
running, _ = table.start({"rowId": "row-r", "actor": "po"}, FakeTUI().io())
check("state file mode 0600", stat.S_IMODE(os.stat(state_path).st_mode), 0o600)
fresh = cj.CompactJobs(state_path, clock=clock.now, sleep=clock.sleep)
after = fresh.get(running["job"]["id"])[0]["job"]
check("restarted job failed", (after["state"], after["error"], after["failedStep"]),
      ("failed", cj.RESTARTED_ERROR, "waitingIdle"))
check("restart rewrote the file", json.load(open(state_path))["jobs"][0]["state"], "failed")
check("finished job still shown for the row", fresh.for_row("row-r")[0]["job"]["id"], running["job"]["id"])
clock.t += cj.RECENT_FINISHED_SEC + 1
check("finished job older than 30 min -> null", fresh.for_row("row-r")[0]["job"], None)


# ---------------------------------------------------------------- server level

print("== server: routes, JSON shape, local + remote rows ==")
_spec = importlib.util.spec_from_file_location(
    "chief_dashboard_server",
    os.path.join(os.path.dirname(__file__), "..", "server", "chief-dashboard-server.py"))
_srv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_srv)

PROJECTS = os.path.join(TMP, "projects")
os.makedirs(os.path.join(PROJECTS, "proj"), exist_ok=True)
_srv._CLAUDE_PROJECTS_ROOT = PROJECTS
_srv.MACHINES = {"air-m1": {"ssh": "air"}}
_srv.STORE.log_session_action = lambda *a, **k: None
_srv._own_pane_cached = lambda ids: None
_srv._enrich_agents_for_actions = lambda state, agents: None
_srv.time.sleep = lambda *a, **k: None  # _handle_reach_action's 2s verify wait


def install(fake, agent):
    calls = []

    def pane_run_raw(args, machine="local", timeout=15):
        calls.append((machine, args[:2], args[2]))
        if args[:2] == ["pane", "read"]:
            return "\n".join(fake.render())
        if args[:2] == ["pane", "run"]:
            fake.run_line(args[3])
            return ""
        if args[:2] == ["pane", "send-keys"]:
            fake.keys(*args[3:])
            return ""
        raise AssertionError(f"unexpected herdr call {args}")

    remote_reads = []

    def remote_shell_text(machine, script, **kw):
        remote_reads.append(machine)
        data = fake.tail_bytes()
        return json.dumps({"found": True, "size": len(data), "chunkStartsAtFileStart": True,
                           "tailB64": base64.b64encode(data).decode()})

    _srv._pane_run_raw = pane_run_raw
    _srv.herdr_transport.remote_shell_text = remote_shell_text
    _srv.get_full_state = lambda: {"computed": {"agents": [agent]}, "feeds": {}}
    clock = Clock()
    _srv._COMPACT_JOBS = cj.CompactJobs(os.path.join(TMP, "srv-jobs.json"), clock=clock.now,
                                        sleep=clock.sleep, spawn=lambda fn: fn())
    return calls, remote_reads


def agent_row(pane_id, machine=None, kind="claude"):
    row = {"paneId": pane_id, "label": "worker", "agentSession": SESSION, "hasHookData": True,
           "hookState": "idle", "agentKind": kind, "source": "herdr"}
    if machine:
        row["machine"] = machine
    return row


CONTRACT_KEYS = {"id", "rowId", "state", "originalModel", "switchSkipped", "skipReason",
                 "compactOk", "modelRestored", "followUpSent", "error", "failedStep",
                 "createdAt", "updatedAt"}

# local row: transcript from local disk
fake = FakeTUI(transcript_path=os.path.join(PROJECTS, "proj", f"{SESSION}.jsonl"))
calls, remote_reads = install(fake, agent_row("w4:p2"))
payload, status = _srv.handle_compact_post({"rowId": SESSION, "actor": "po",
                                            "instructions": "keep it short", "followUp": "next step"})
check("local: 202", status, 202)
check("local: body keys", set(payload), {"ok", "job"})
check("local: Job has exactly the contract keys", set(payload["job"]), CONTRACT_KEYS)
job = _srv._compact_jobs().get(payload["job"]["id"])[0]["job"]
check("local: done", (job["state"], job["error"]), ("done", None))
check("local: every pane call stayed local", {m for m, _a, _p in calls}, {"local"})
check("local: no ssh transcript read", remote_reads, [])
check("local: compact + follow-up through the message path",
      [t for _m, t in fake.run_log], ["/model", "/compact keep it short", "/model", "next step"])
no_save_keys("server local", fake)
types_ok = (isinstance(job["id"], str) and isinstance(job["createdAt"], float)
            and isinstance(job["updatedAt"], float) and isinstance(job["switchSkipped"], bool))
check("local: field types", types_ok, True)
got, st = cj.handle_get(cj.COMPACT_PATH, {"rowId": [SESSION]}, _srv._compact_jobs())
check("GET ?rowId= shape", (st, set(got), got["job"]["id"]), (200, {"ok", "job"}, job["id"]))
got, st = cj.handle_get(cj.COMPACT_PATH + "/" + job["id"], {}, _srv._compact_jobs())
check("GET /<id> shape", (st, got["ok"], set(got["job"])), (200, True, CONTRACT_KEYS))
check("GET /<bad id> 404", cj.handle_get(cj.COMPACT_PATH + "/../x", {}, _srv._compact_jobs())[1], 404)
check("GET without rowId 400", cj.handle_get(cj.COMPACT_PATH, {}, _srv._compact_jobs())[1], 400)

# remote row: every pane call over machine air-m1, transcript over the ssh tail reader
fake = FakeTUI(cache_warm=True)
calls, remote_reads = install(fake, agent_row("air-m1:w2:p3", machine="air-m1"))
payload, status = _srv.handle_compact_post({"rowId": SESSION, "actor": "po", "followUp": "go"})
job = _srv._compact_jobs().get(payload["job"]["id"])[0]["job"]
check("remote: 202 + done", (status, job["state"], job["error"]), (202, "done", None))
check("remote: every pane call routed to air-m1", {m for m, _a, _p in calls}, {"air-m1"})
check("remote: raw pane id handed to herdr", {p for _m, _a, p in calls}, {"w2:p3"})
check("remote: transcript read over ssh", set(remote_reads), {"air-m1"})
check("remote: compactOk + restored + follow-up",
      (job["compactOk"], job["modelRestored"], job["followUpSent"]), (True, True, True))
no_save_keys("server remote", fake)

print("== server: refusals ==")
fake = FakeTUI()
install(fake, agent_row("w4:p2"))
check("unknown row 404", _srv.handle_compact_post({"rowId": "nope", "actor": "po"})[1], 404)
check("bad actor 400", _srv.handle_compact_post({"rowId": SESSION, "actor": "chief"})[1], 400)
check("newline followUp 400",
      _srv.handle_compact_post({"rowId": SESSION, "actor": "po", "followUp": "a\nb"})[1], 400)
install(fake, agent_row("w4:p2", kind="opencode"))
check("non-Claude pane 400", _srv.handle_compact_post({"rowId": SESSION, "actor": "po"})[1], 400)
nopane = agent_row(None)
install(fake, nopane)
check("row without a pane 400", _srv.handle_compact_post({"rowId": SESSION, "actor": "po"})[1], 400)
check("nothing typed by refusals", (fake.run_log, fake.key_log), ([], []))

print("== server: single-flight 409 through the endpoint ==")
fake = FakeTUI()
install(fake, agent_row("w4:p2"))
pending = []
_srv._COMPACT_JOBS = cj.CompactJobs(None, spawn=lambda fn: pending.append(fn))
first, s1 = _srv.handle_compact_post({"rowId": SESSION, "actor": "po"})
second, s2 = _srv.handle_compact_post({"rowId": SESSION, "actor": "po"})
check("409 + job-active + same job", (s1, s2, second["error"], second["job"]["id"]),
      (202, 409, "job-active", first["job"]["id"]))

print()
if fails:
    print(f"{len(fails)} FAILED:")
    for f_ in fails:
        print("  " + f_)
    sys.exit(1)
print("all passed")
