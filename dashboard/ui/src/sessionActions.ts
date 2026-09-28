import type { AgentRow, BoardRow, SessionActionState } from "./types";
import { LOGGED_OUT_ERROR } from "./api";

/** v3 reclaim (phases 5-6) + v4 reach (phase 8-9): the server decides
 *  eligibility and returns the reason string; the UI only renders it. Never
 *  compute availability here.
 *  (The pure helpers below — drop routing, bulk evaluation, context
 *  formatting — decide nothing about safety; they route/render the
 *  server's verdicts.) */

export type SessionActionName =
  | "stop"
  | "close"
  | "relaunch"
  | "archive"
  | "unarchive";

export type RowActions = Partial<Record<SessionActionName, SessionActionState>>;

/** One two-stage "end this session" control: Stop agent first, Close pane
 *  second. The server still resolves stop/close separately (assess_row is
 *  untouched) — this only picks which stage the single UI option shows.
 *
 *  Stage 1: stop enabled → "Stop agent" (the agent is alive).
 *  Stage 2: stop off but close on → "Close pane" (stopped, pane lingers).
 *  Null: neither on (pane gone) — the caller hides the control. */
export interface EndStage {
  verb: "stop" | "close";
  state: SessionActionState;
  label: "Stop agent" | "Close pane";
}

export function resolveEndStage(actions: RowActions | undefined): EndStage | null {
  const stop = actions?.stop;
  if (stop?.enabled) return { verb: "stop", state: stop, label: "Stop agent" };
  const close = actions?.close;
  if (close?.enabled) return { verb: "close", state: close, label: "Close pane" };
  return null;
}

/** Bulk evaluation for the unified End verb: per row, stop when the agent
 *  is alive, else close when a stopped pane lingers, else refused. Pure. */
export interface EndBulkMember {
  row: BoardRow;
  verb: "stop" | "close";
  state: SessionActionState;
}

export interface EndBulkEval {
  ready: EndBulkMember[];
  needConfirm: EndBulkMember[];
  refused: BulkMember[];
  totalBytes: number;
  allIdle: boolean;
}

export function evaluateEndBulk(rows: BoardRow[]): EndBulkEval {
  const ready: EndBulkMember[] = [];
  const needConfirm: EndBulkMember[] = [];
  const refused: BulkMember[] = [];
  let totalBytes = 0;
  for (const row of rows) {
    totalBytes += rowMemoryBytes(row) ?? 0;
    const stage = resolveEndStage(rowActions(row));
    if (!stage) {
      refused.push({
        row,
        state: { enabled: false, needsConfirm: false, reason: "refused" },
      });
    } else if (stage.state.needsConfirm) {
      needConfirm.push({ row, verb: stage.verb, state: stage.state });
    } else {
      ready.push({ row, verb: stage.verb, state: stage.state });
    }
  }
  return {
    ready,
    needConfirm,
    refused,
    totalBytes,
    allIdle: needConfirm.length === 0,
  };
}

export function rowActions(row: BoardRow): RowActions | undefined {
  // Live rows carry actions on the row (copied from the agents feed);
  // ended rows carry them assessed from the pane feed. Either way the
  // server resolved them — see _annotate_live_rows/_annotate_ended_rows.
  return (
    row.actions ?? (row.derived as ActionableAgent | undefined)?.actions
  ) as RowActions | undefined;
}

/** Measured RSS for one board row, bytes (null = unmeasurable). Live rows
 *  carry it on the row (copied from the agents feed); ended rows read None. */
export function rowMemoryBytes(row: BoardRow): number | null {
  const direct = (row as BoardRow & { memoryBytes?: number | null })
    .memoryBytes;
  if (typeof direct === "number") return direct;
  const fromAgent = (row.derived as ActionableAgent | undefined)?.memoryBytes;
  return typeof fromAgent === "number" ? fromAgent : null;
}

export function rowLabel(row: BoardRow): string {
  const v = row.values["derived:label"];
  if (typeof v === "string" && v) return v;
  return row.derived.label || row.rowId;
}

export interface ActionableAgent extends AgentRow {
  /** Measured RSS across the pane's foreground process tree, bytes.
   *  Null = unmeasurable (renders —, never 0). */
  memoryBytes?: number | null;
  actions?: Record<SessionActionName, SessionActionState>;
}

/** Caveat the Memory column carries visibly: RSS double-counts shared
 *  pages, so the sum overstates. Valid for ranking, wrong as an absolute. */
export const MEMORY_CAVEAT =
  "Summed RSS over the pane's process tree — double-counts shared pages, " +
  "so it overstates. Good for ranking sessions, wrong as an absolute.";

export function fmtMem(bytes: number | null | undefined): string {
  // Phase 9 display invariant: unknown AND zero both render —. A 0 would
  // read as "cheapest to keep" and point the PO at the wrong pane; a live
  // pane always has some RSS, so 0 means unmeasurable in practice.
  if (!bytes) return "—";
  let n = bytes;
  for (const unit of ["B", "KB", "MB", "GB", "TB"]) {
    if (n < 1024 || unit === "TB") {
      return unit === "B" ? `${Math.round(n)} B` : `${n.toFixed(1)} ${unit}`;
    }
    n /= 1024;
  }
  return `${n.toFixed(1)} TB`;
}

/** Property id of the phase-8 CONTEXT column (% of window in use). */
export const CONTEXT_PROP_ID = "derived:context";

/** % of the context window in use for one board row (null = unreadable).
 *  Live rows carry it top-level (what Proof 2 checks); the store mapping
 *  and the agent dict are fallbacks. Numeric only — anything else is —. */
export function rowContextPct(row: BoardRow): number | null {
  const direct = (row as BoardRow & { contextPct?: number | null })
    .contextPct;
  if (typeof direct === "number") return direct;
  const fromValues = row.values[CONTEXT_PROP_ID];
  if (typeof fromValues === "number") return fromValues;
  const fromAgent = (row.derived as ActionableAgent | undefined)?.contextPct;
  return typeof fromAgent === "number" ? fromAgent : null;
}

/** The rare "N% until auto-compact" countdown for one row (null = absent).
 *  Present on only a handful of panes at a time: a badge, never a column. */
export function rowAutocompactPct(row: BoardRow): number | null {
  const direct = (row as BoardRow & { autocompactPct?: number | null })
    .autocompactPct;
  if (typeof direct === "number") return direct;
  const fromAgent = (row.derived as ActionableAgent | undefined)
    ?.autocompactPct;
  return typeof fromAgent === "number" ? fromAgent : null;
}

/** Render a context % — null AND 0 both read —. 0 would sort as "most
 *  headroom" and the brief's proof 2 requires the glyph to appear nowhere.
 *  Sorting still uses the real number; this is display only. */
export function fmtCtx(pct: number | null | undefined): string {
  if (pct === null || pct === undefined || pct === 0) return "—";
  return `${pct}%`;
}

export interface SessionActionResult {
  ok: boolean;
  state?: string;
  reason?: string;
  error?: string;
  needsConfirm?: boolean;
  /** `false` ONLY when the server positively proved it typed nothing into
   *  the pane (a pre-send guard refused). Absent on every other failure —
   *  a mid-sequence error, NOT SUBMITTED, or a dropped connection may all
   *  have delivered the text. */
  typed?: boolean;
}

export async function sessionAction(
  action: SessionActionName,
  rowId: string,
  opts: { confirm?: boolean; actor?: string } = {},
): Promise<SessionActionResult> {
  try {
    const r = await fetch(`/api/session/${action}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      // actor is always the PO here: this board has no chief surface, and
      // the field guards against accident (misclick), not attack.
      body: JSON.stringify({
        rowId,
        actor: opts.actor ?? "po",
        confirm: !!opts.confirm,
      }),
    });
    return await r.json();
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

/** Phase 8 reach verbs. Separate functions (not SessionActionName members)
 *  on purpose: they take different arguments (text / always-confirm), and
 *  the kanban drop path — typed to archive/unarchive only — must have no
 *  code path that can reach them. See resolveKanbanDrop + proof 9. */
export async function sendMessage(
  rowId: string,
  text: string,
  opts: { confirm?: boolean } = {},
): Promise<SessionActionResult> {
  try {
    const r = await fetch("/api/session/message", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ rowId, actor: "po", text, confirm: !!opts.confirm }),
    });
    if (r.status === 401) return { ok: false, typed: false, error: LOGGED_OUT_ERROR };
    return await r.json();
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

/** Refused before a single keystroke — the server says so (`typed:false`).
 *  The one failure after which the text may safely go back in the box: any
 *  other failure (incl. a fetch exception, which carries no `typed`) may
 *  have delivered it, and a restored box double-sends on the next Enter. */
export function isRefusedBeforeTyping(res: SessionActionResult): boolean {
  return !res.ok && res.typed === false;
}

/** The server's stuck verdict — loud failure, never a soft one. */
export function isNotSubmitted(res: SessionActionResult): boolean {
  return !res.ok && !res.needsConfirm && (res.error ?? "").includes("NOT SUBMITTED");
}

/** The server's queued verdict — SUCCESS that lands when the turn ends.
 *  Never an invitation to re-send (that would double-send into the queue). */
export function isQueued(res: SessionActionResult): boolean {
  return !!res.ok && res.state === "queued";
}

/** One composer target: row id to POST at, label to show so the PO can
 *  never type into a pane they did not mean. */
export interface ComposerTarget {
  rowId: string;
  label: string;
}

/** Bulk message evaluation, in the evaluateBulk SHAPE (ready /
 *  needConfirm / refused + summed memory) but with message semantics:
 *
 *  The server deliberately offers no message assess entries (the
 *  guards need a fresh pane read at send time), so busy-ness is decided
 *  per POST, never pre-evaluated here. Message is the only non-destructive
 *  bulk verb: live rows are always sent (each POST authoritative, each
 *  result per-row reported, busy ones confirmed on the server's say-so),
 *  ended rows are listed as refused and never called. needConfirm stays
 *  empty and allIdle false — never claim the fast path before the server
 *  has answered. Nothing here decides safety; the server refuses loudly
 *  per row (picker open, dev pane, gone). */
export function evaluateMessageBulk(rows: BoardRow[]): BulkEval {
  const ready: BulkMember[] = [];
  const refused: BulkMember[] = [];
  let totalBytes = 0;
  for (const row of rows) {
    totalBytes += rowMemoryBytes(row) ?? 0;
    if (row.status === "ended") {
      refused.push({
        row,
        state: {
          enabled: false,
          needsConfirm: false,
          reason: "not live — no agent there to read it (the server refuses these; never called)",
        },
      });
    } else {
      ready.push({
        row,
        state: {
          enabled: true,
          needsConfirm: false,
          reason: "message is board-to-pane text, not destruction",
        },
      });
    }
  }
  return { ready, needConfirm: [], refused, totalBytes, allIdle: false };
}

/** Property id of the board-only archive flag (checkbox, derived). */
export const ARCHIVED_PROP_ID = "archived";

/** Group keys whose drop target would imply destruction. A drag is far too
 *  cheap a gesture for an irreversible act, so drops here are blocked with
 *  a visible reason — use the card menu instead. */
const STOP_CLOSE_KEYS = new Set([
  "stop",
  "stopped",
  "stop agent",
  "close",
  "closed",
  "close pane",
  "close tab",
  "kill",
  "terminate",
  "delete",
  "remove",
]);

export const DROP_BLOCKED_REASON =
  "a drag is too cheap a gesture for an irreversible act — " +
  "stopping or closing needs the card menu, where the confirm names the stake";

export type KanbanDrop =
  | { kind: "archive" }
  | { kind: "unarchive" }
  | { kind: "blocked"; reason: string }
  | { kind: "passthrough" };

/** Route a kanban drop before any cell write. Grouping by the ARCHIVED flag
 *  gives real meaning to two columns: `yes` archives, `no` restores. A
 *  column named like destruction blocks loudly. Everything else falls
 *  through to the normal set-cell-value path. Pure — unit-tested. */
export function resolveKanbanDrop(
  groupPropertyId: string | null,
  targetKey: string,
): KanbanDrop {
  const key = targetKey.trim().toLowerCase();
  if (groupPropertyId === ARCHIVED_PROP_ID) {
    if (key === "yes") return { kind: "archive" };
    if (key === "no") return { kind: "unarchive" };
    return {
      kind: "blocked",
      reason: `cannot move here — "${targetKey}" is not a shelf the board understands`,
    };
  }
  if (STOP_CLOSE_KEYS.has(key)) return { kind: "blocked", reason: DROP_BLOCKED_REASON };
  return { kind: "passthrough" };
}

export interface BulkMember {
  row: BoardRow;
  state: SessionActionState;
}

export interface BulkEval {
  /** Enabled + no confirm needed: acts on one click. */
  ready: BulkMember[];
  /** Enabled but needs the second click: listed by name with reasons. */
  needConfirm: BulkMember[];
  /** Disabled: reported as refused, never called. */
  refused: BulkMember[];
  /** Summed measured memory of the selection (unmeasurable rows add 0). */
  totalBytes: number;
  /** True when nothing needs the second click (fast path: one click). */
  allIdle: boolean;
}

/** Evaluate a bulk verb over a set of rows. The per-row verdicts come from
 *  the server-resolved actions — this only partitions them. Pure. */
export function evaluateBulk(
  rows: BoardRow[],
  verb: SessionActionName,
): BulkEval {
  const ready: BulkMember[] = [];
  const needConfirm: BulkMember[] = [];
  const refused: BulkMember[] = [];
  let totalBytes = 0;
  for (const row of rows) {
    totalBytes += rowMemoryBytes(row) ?? 0;
    const st = rowActions(row)?.[verb];
    if (!st || !st.enabled) {
      refused.push({
        row,
        state: st ?? { enabled: false, needsConfirm: false, reason: "refused" },
      });
    } else if (st.needsConfirm) {
      needConfirm.push({ row, state: st });
    } else {
      ready.push({ row, state: st });
    }
  }
  return {
    ready,
    needConfirm,
    refused,
    totalBytes,
    allIdle: needConfirm.length === 0,
  };
}
