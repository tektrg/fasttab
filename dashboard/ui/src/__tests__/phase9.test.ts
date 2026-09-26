/**
 * Phase 9 pure-helper tests: context formatting/extraction, message bulk
 * evaluation, reach-verdict classifiers, and the drag-path structural proof.
 *
 * Nothing here decides availability — the server does that per POST. These
 * pin the rendering contract: — never 0, message bulk always confirms,
 * and no drop routing can yield a reach verb.
 */
import { describe, expect, test } from "bun:test";
import {
  evaluateMessageBulk,
  fmtCtx,
  fmtMem,
  isNotSubmitted,
  isQueued,
  resolveKanbanDrop,
  rowAutocompactPct,
  rowContextPct,
  type RowActions,
} from "../sessionActions";
import type { BoardRow } from "../types";

function boardRow(
  rowId: string,
  opts: {
    status?: BoardRow["status"];
    actions?: RowActions;
    memoryBytes?: number | null;
    contextPct?: number | null;
    autocompactPct?: number | null;
    valuesContext?: unknown;
  } = {},
): BoardRow {
  const values: Record<string, BoardRow["values"][string]> = {
    "derived:label": rowId,
  };
  if (opts.valuesContext !== undefined) {
    values["derived:context"] = opts.valuesContext as
      | string
      | number
      | boolean
      | string[]
      | null;
  }
  return {
    rowKind: "session",
    rowId,
    status: opts.status ?? "live",
    contextPct: opts.contextPct,
    autocompactPct: opts.autocompactPct,
    derived: {
      paneId: "w8:pX",
      paneIdSanitized: "w8-pX",
      label: rowId,
      cwd: null,
      focused: false,
      hookState: "idle",
      hookSinceSec: 1,
      herdrStatus: "idle",
      disagree: false,
      hasHookData: true,
      screenState: "WAITING",
      memoryBytes: opts.memoryBytes ?? null,
      contextPct: opts.contextPct,
      autocompactPct: opts.autocompactPct,
      actions: (opts.actions ?? {}) as never,
    },
    values,
    actions: (opts.actions ?? {}) as never,
  };
}

describe("fmtCtx / fmtMem display invariant (— never 0)", () => {
  test("context: null, undefined and 0 all read —", () => {
    expect(fmtCtx(null)).toBe("—");
    expect(fmtCtx(undefined)).toBe("—");
    expect(fmtCtx(0)).toBe("—");
  });
  test("context: real readings render with %", () => {
    expect(fmtCtx(21)).toBe("21%");
    expect(fmtCtx(100)).toBe("100%");
  });
  test("memory: 0 reads —, real readings unchanged", () => {
    expect(fmtMem(null)).toBe("—");
    expect(fmtMem(undefined)).toBe("—");
    expect(fmtMem(0)).toBe("—");
    expect(fmtMem(189 * 1024 * 1024)).toBe("189.0 MB");
  });
});

describe("rowContextPct / rowAutocompactPct", () => {
  test("top-level row field wins", () => {
    const r = boardRow("a", { contextPct: 21, valuesContext: 50 });
    expect(rowContextPct(r)).toBe(21);
  });
  test("values and agent dict are fallbacks", () => {
    expect(rowContextPct(boardRow("a", { valuesContext: 31 }))).toBe(31);
    expect(rowContextPct(boardRow("a", {}))).toBeNull();
  });
  test("non-numbers are unreadable, never 0", () => {
    expect(rowContextPct(boardRow("a", { valuesContext: "21" }))).toBeNull();
    expect(rowContextPct(boardRow("a", { valuesContext: 0 }))).toBe(0);
    expect(fmtCtx(rowContextPct(boardRow("a", { valuesContext: 0 })))).toBe(
      "—",
    );
  });
  test("autocompact: top-level, derived, absent", () => {
    expect(rowAutocompactPct(boardRow("a", { autocompactPct: 12 }))).toBe(12);
    expect(rowAutocompactPct(boardRow("a", {}))).toBeNull();
  });
});

describe("evaluateMessageBulk", () => {
  test("live rows ready, ended refused and never called", () => {
    const e = evaluateMessageBulk([
      boardRow("a", { memoryBytes: 100 }),
      boardRow("b", { status: "ended", memoryBytes: 50 }),
    ]);
    expect(e.ready.map((m) => m.row.rowId)).toEqual(["a"]);
    expect(e.refused.map((m) => m.row.rowId)).toEqual(["b"]);
    expect(e.refused[0].state.reason).toContain("not live");
    expect(e.needConfirm).toEqual([]);
    expect(e.totalBytes).toBe(150);
  });
  test("always confirms by design (allIdle false, nothing pre-armed)", () => {
    const e = evaluateMessageBulk([boardRow("a", {})]);
    expect(e.allIdle).toBe(false);
    expect(e.needConfirm).toEqual([]);
  });
});

describe("reach verdict classifiers", () => {
  test("NOT SUBMITTED is loud-only, never a confirm state", () => {
    expect(
      isNotSubmitted({ ok: false, error: "NOT SUBMITTED — stuck" }),
    ).toBe(true);
    expect(isNotSubmitted({ ok: false, needsConfirm: true, reason: "x" })).toBe(
      false,
    );
    expect(isNotSubmitted({ ok: true, state: "sent" })).toBe(false);
  });
  test("queued is success, distinct from sent", () => {
    expect(isQueued({ ok: true, state: "queued" })).toBe(true);
    expect(isQueued({ ok: true, state: "message sent" })).toBe(false);
    expect(isQueued({ ok: false, error: "x" })).toBe(false);
  });
});

describe("drag path cannot reach message or compact (structural)", () => {
  test("reach-named columns never yield an action verb", () => {
    for (const key of [
      "message",
      "Send message",
      "compact",
      "Compact",
      "/compact",
      "send",
      "message pane",
      "MESSAGE",
    ]) {
      const r = resolveKanbanDrop("some-prop", key);
      // Only blocked or passthrough exist; neither carries an endpoint verb,
      // and onDragEnd's only endpoint call takes routed.kind narrowed to
      // archive/unarchive (tsc enforces — see Kanban.tsx).
      expect(r.kind === "blocked" || r.kind === "passthrough").toBe(true);
    }
  });
  test("every kind the resolver can return is in the 4-member union", () => {
    // Runtime guard for the compile-time proof: KanbanDrop = archive |
    // unarchive | blocked | passthrough. If the resolver ever grows a
    // fifth kind (e.g. a reach verb), this fails — tsc alone would not,
    // because onDragEnd narrows before calling.
    const groups = ["archived", "some-prop", "derived:state", null];
    const keys = [
      "yes",
      "no",
      "(none)",
      "message",
      "compact",
      "/compact",
      "stop",
      "doing",
      "",
    ];
    const kinds = new Set<string>();
    for (const g of groups)
      for (const k of keys) kinds.add(resolveKanbanDrop(g, k).kind);
    expect([...kinds].sort()).toEqual(
      ["archive", "blocked", "passthrough", "unarchive"],
    );
  });
});
