/**
 * Phase 6 pure-helper tests: kanban drop routing and bulk evaluation.
 * Both decide nothing about safety — they route/render the server-resolved
 * verdicts — but the routing itself (archive vs blocked vs passthrough,
 * ready vs needConfirm vs refused) must be exact, or a drag silently
 * destroys and a bulk silently succeeds.
 */
import { describe, expect, test } from "bun:test";
import {
  ARCHIVED_PROP_ID,
  DROP_BLOCKED_REASON,
  evaluateBulk,
  evaluateEndBulk,
  resolveEndStage,
  resolveKanbanDrop,
  type RowActions,
} from "../sessionActions";
import type { BoardRow } from "../types";

const st = (
  enabled: boolean,
  needsConfirm = false,
  reason = "reason",
) => ({ enabled, needsConfirm, reason });

function boardRow(
  rowId: string,
  labelText: string,
  actions: RowActions,
  memoryBytes?: number | null,
): BoardRow {
  return {
    rowKind: "session",
    rowId,
    status: "live",
    derived: {
      paneId: "w8:pX",
      paneIdSanitized: "w8-pX",
      label: labelText,
      cwd: null,
      focused: false,
      hookState: "idle",
      hookSinceSec: 1,
      herdrStatus: "idle",
      disagree: false,
      hasHookData: true,
      screenState: "WAITING",
      memoryBytes: memoryBytes ?? null,
      actions: actions as never,
    },
    values: { "derived:label": labelText },
    actions: actions as never,
  };
}

describe("resolveKanbanDrop", () => {
  test("archived flag: yes archives, no restores", () => {
    expect(resolveKanbanDrop(ARCHIVED_PROP_ID, "yes")).toEqual({
      kind: "archive",
    });
    expect(resolveKanbanDrop(ARCHIVED_PROP_ID, "no")).toEqual({
      kind: "unarchive",
    });
  });
  test("archived flag: anything else blocks loudly, never writes", () => {
    const r = resolveKanbanDrop(ARCHIVED_PROP_ID, "(none)");
    expect(r.kind).toBe("blocked");
    if (r.kind === "blocked") expect(r.reason.length).toBeGreaterThan(10);
  });
  test("destruction-named columns block with the visible reason", () => {
    for (const key of [
      "stop",
      "Stopped",
      "STOP AGENT",
      "close",
      "Closed",
      "close pane",
      "kill",
    ]) {
      const r = resolveKanbanDrop("some-prop", key);
      expect(r).toEqual({ kind: "blocked", reason: DROP_BLOCKED_REASON });
    }
  });
  test("ordinary columns pass through to the cell write", () => {
    expect(resolveKanbanDrop("some-prop", "doing")).toEqual({
      kind: "passthrough",
    });
    expect(resolveKanbanDrop(null, "yes")).toEqual({ kind: "passthrough" });
  });
});

describe("evaluateBulk", () => {
  const idle = {
    stop: st(true, false),
    close: st(true, false),
    archive: st(true, false),
  };
  const busy = {
    stop: st(true, true, "working · 2.1 GB"),
    close: st(true, true, "working"),
    archive: st(true, false),
  };

  test("all idle: fast path, summed memory", () => {
    const e = evaluateBulk(
      [
        boardRow("a", "alpha", idle, 100_000_000),
        boardRow("b", "beta", idle, 50_000_000),
      ],
      "stop",
    );
    expect(e.allIdle).toBe(true);
    expect(e.ready.map((m) => m.row.rowId)).toEqual(["a", "b"]);
    expect(e.needConfirm).toEqual([]);
    expect(e.refused).toEqual([]);
    expect(e.totalBytes).toBe(150_000_000);
  });
  test("mixed: busy listed by row with reasons, unmeasurable adds 0", () => {
    const e = evaluateBulk(
      [
        boardRow("a", "alpha", idle, 10),
        boardRow("b", "beta", busy, null),
      ],
      "stop",
    );
    expect(e.allIdle).toBe(false);
    expect(e.ready.map((m) => m.row.rowId)).toEqual(["a"]);
    expect(e.needConfirm.map((m) => m.row.rowId)).toEqual(["b"]);
    expect(e.needConfirm[0].state.reason).toContain("working");
    expect(e.totalBytes).toBe(10);
  });
  test("disabled rows are refused, never called", () => {
    const e = evaluateBulk(
      [boardRow("c", "gamma", { stop: st(false, false, "already stopped") }, 5)],
      "stop",
    );
    expect(e.ready).toEqual([]);
    expect(e.needConfirm).toEqual([]);
    expect(e.refused.map((m) => m.row.rowId)).toEqual(["c"]);
    expect(e.refused[0].state.reason).toContain("already stopped");
  });
  test("missing action entry counts as refused, not ready", () => {
    const e = evaluateBulk([boardRow("d", "delta", {}, 5)], "close");
    expect(e.refused.map((m) => m.row.rowId)).toEqual(["d"]);
  });
});

describe("resolveEndStage (unified Stop agent → Close pane)", () => {
  test("stage 1: live agent shows Stop agent", () => {
    const s = resolveEndStage({
      stop: st(true, false, "idle"),
      close: st(true, false, "idle"),
    });
    expect(s).toEqual({
      verb: "stop",
      state: { enabled: true, needsConfirm: false, reason: "idle" },
      label: "Stop agent",
    });
  });
  test("stage 2: stopped pane shows Close pane", () => {
    const s = resolveEndStage({
      stop: st(false, false, "already stopped"),
      close: st(true, false, "stopped"),
    });
    expect(s?.verb).toBe("close");
    expect(s?.label).toBe("Close pane");
  });
  test("gone pane shows neither", () => {
    expect(
      resolveEndStage({
        stop: st(false, false, "pane is gone"),
        close: st(false, false, "pane is already gone"),
      }),
    ).toBe(null);
    expect(resolveEndStage(undefined)).toBe(null);
    expect(resolveEndStage({})).toBe(null);
  });
});

describe("evaluateEndBulk", () => {
  const idle = {
    stop: st(true, false),
    close: st(true, false),
    archive: st(true, false),
  };
  const stopped = {
    stop: st(false, false, "already stopped"),
    close: st(true, false, "stopped"),
    archive: st(true, false),
  };
  const gone = {
    stop: st(false, false, "pane is gone"),
    close: st(false, false, "pane is already gone"),
    archive: st(true, false),
  };

  test("per-row stage: live rows stop, stopped rows close, gone rows refuse", () => {
    const e = evaluateEndBulk([
      boardRow("a", "alpha", idle, 10),
      boardRow("b", "beta", stopped, 20),
      boardRow("c", "gamma", gone, 30),
    ]);
    expect(e.ready.map((m) => [m.row.rowId, m.verb])).toEqual([
      ["a", "stop"],
      ["b", "close"],
    ]);
    expect(e.needConfirm).toEqual([]);
    expect(e.refused.map((m) => m.row.rowId)).toEqual(["c"]);
    expect(e.totalBytes).toBe(60);
    expect(e.allIdle).toBe(true);
  });
  test("busy stop lands in needConfirm with its reason", () => {
    const e = evaluateEndBulk([
      boardRow("b", "beta", {
        stop: st(true, true, "working · 2.1 GB"),
        close: st(true, true, "working"),
      }, null),
    ]);
    expect(e.allIdle).toBe(false);
    expect(e.needConfirm.map((m) => [m.row.rowId, m.verb])).toEqual([["b", "stop"]]);
    expect(e.needConfirm[0].state.reason).toContain("working");
  });
});
