import { useState } from "react";
import { Alert, Button, List, Text } from "@mantine/core";
import type { BoardRow } from "../types";
import {
  evaluateBulk,
  evaluateEndBulk,
  fmtMem,
  rowLabel,
  rowMemoryBytes,
  sessionAction,
  type BulkEval,
  type EndBulkEval,
  type SessionActionName,
} from "../sessionActions";

const BULK_VERBS: { name: SessionActionName | "end"; label: string; color: string }[] = [
  { name: "end", label: "End", color: "red" },
  { name: "archive", label: "Archive", color: "gray" },
];

interface RowReport {
  rowId: string;
  label: string;
  ok: boolean;
  detail: string;
}

/** Bulk bar over a multi-selection: summed memory, one verb at a time.
 *
 *  Confirm follows the same rule evaluated over the set: every selected row
 *  idle → one click. Any busy row → the confirm step lists the busy ones by
 *  name with their reasons before acting. Applied per row, reported per
 *  row — a partial failure is itemized, never rounded to success. */
export function BulkBar({
  rows,
  onToast,
  onDone,
  onClear,
}: {
  rows: BoardRow[];
  onToast: (msg: string, ok: boolean) => void;
  onDone: () => void;
  onClear: () => void;
}) {
  const [verb, setVerb] = useState<SessionActionName | "end" | null>(null);
  const [confirming, setConfirming] = useState(false);
  const [busy, setBusy] = useState(false);
  const [report, setReport] = useState<RowReport[] | null>(null);

  // Evaluated fresh each render from the server-resolved actions — the 5s
  // board refetch can change verdicts under us, and stale ones must not act.
  // "end" is the unified two-stage verb (Stop agent → Close pane, per row);
  // every other verb evaluates the server verdicts directly.
  const evals = new Map<string, BulkEval | EndBulkEval>();
  const getEval = (v: SessionActionName | "end"): BulkEval | EndBulkEval => {
    let e = evals.get(v);
    if (!e) {
      e = v === "end" ? evaluateEndBulk(rows) : evaluateBulk(rows, v);
      evals.set(v, e);
    }
    return e;
  };
  const totalBytes = rows.reduce(
    (n, r) => n + (rowMemoryBytes(r) ?? 0),
    0,
  );

  const start = (v: SessionActionName | "end") => {
    setVerb(v);
    setReport(null);
    const e = getEval(v);
    if (e.needConfirm.length > 0) {
      setConfirming(true);
      return;
    }
    void run(v, e);
  };

  const run = async (v: SessionActionName | "end", e?: BulkEval | EndBulkEval) => {
    const ev = e ?? getEval(v);
    setConfirming(false);
    setBusy(true);
    const out: RowReport[] = [];
    // Sequential per-row POSTs with confirm:true (the panel already showed
    // the reasons). Each row re-evaluated server-side — authoritative.
    // "end" posts each row's own stage verb (stop while alive, close once
    // stopped); other verbs post one verb for every row.
    for (const m of [...ev.ready, ...ev.needConfirm]) {
      const action = v === "end" ? (m as unknown as { verb: SessionActionName }).verb : v;
      try {
        const res = await sessionAction(action, m.row.rowId, { confirm: true });
        out.push({
          rowId: m.row.rowId,
          label: rowLabel(m.row),
          ok: res.ok,
          detail: res.ok
            ? (`${v === "end" ? `${action === "stop" ? "Stop agent" : "Close pane"}: ` : ""}${res.state ?? "done"}`)
            : (res.error || res.reason || "?"),
        });
      } catch (err) {
        out.push({
          rowId: m.row.rowId,
          label: rowLabel(m.row),
          ok: false,
          detail: String(err),
        });
      }
    }
    for (const m of ev.refused) {
      out.push({
        rowId: m.row.rowId,
        label: rowLabel(m.row),
        ok: false,
        detail: m.state.reason || "refused",
      });
    }
    setBusy(false);
    setReport(out);
    const okCount = out.filter((r) => r.ok).length;
    onToast(
      `${v === "end" ? "End" : v}: ${okCount} of ${out.length} ${out.length === 1 ? "row" : "rows"} ok`,
      okCount === out.length,
    );
    onDone();
  };

  const cancel = () => {
    setVerb(null);
    setConfirming(false);
    setReport(null);
  };

  const label =
    verb === "end"
      ? "End (Stop agent → Close pane)"
      : verb === "archive"
        ? "Archive"
        : "Act";

  return (
    <div className="bulkbar" onClick={(e) => e.stopPropagation()}>
      <div
        style={{ display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap" }}
      >
        <Text size="sm" fw={600}>
          {rows.length} selected · Σ {fmtMem(totalBytes)}
        </Text>
        {BULK_VERBS.map((b) => (
          <Button
            key={b.name}
            variant={verb === b.name ? "filled" : "light"}
            color={b.color}
            size="xs"
            disabled={busy}
            title={
              b.name === "archive"
                ? "board-only: hides the rows, frees nothing"
                : b.name === "end"
                  ? "bulk end — stops live agents, closes stopped panes; busy rows need a second click"
                  : `bulk ${b.name} — busy rows need a second click`
            }
            onClick={() => void start(b.name)}
          >
            {b.label}
          </Button>
        ))}
        <Button variant="subtle" size="xs" disabled={busy} onClick={onClear}>
          Clear
        </Button>
      </div>

      {verb && confirming && (
        <Alert color="yellow" title={`${label} ${getEval(verb).needConfirm.length} busy — confirm each stake`}>
          <List size="sm">
            {getEval(verb).needConfirm.map((m) => (
              <List.Item key={m.row.rowId}>
                <strong>{rowLabel(m.row)}</strong>
                {verb === "end" ? ` (${(m as unknown as { verb: string }).verb === "stop" ? "Stop agent" : "Close pane"})` : ""} — {m.state.reason}
              </List.Item>
            ))}
          </List>
          {getEval(verb).ready.length > 0 && (
            <Text size="sm" mt={4}>
              Plus {getEval(verb).ready.length} idle{" "}
              {getEval(verb).ready.length === 1 ? "row" : "rows"} (one click).
            </Text>
          )}
          {getEval(verb).refused.length > 0 && (
            <Text size="sm" mt={4}>
              {getEval(verb).refused.length} will be reported refused, never
              called.
            </Text>
          )}
          <div style={{ display: "flex", gap: 8, marginTop: 8 }}>
            <Button
              color="red"
              size="xs"
              disabled={busy}
              onClick={() => void run(verb)}
            >
              Confirm {label} ({getEval(verb).ready.length + getEval(verb).needConfirm.length})
            </Button>
            <Button variant="subtle" size="xs" disabled={busy} onClick={cancel}>
              Cancel
            </Button>
          </div>
        </Alert>
      )}

      {report && (
        <Alert
          color={report.every((r) => r.ok) ? "green" : "yellow"}
          title={`${label} report — ${report.filter((r) => r.ok).length} of ${report.length} ok`}
        >
          <List size="sm">
            {report.map((r) => (
              <List.Item key={r.rowId}>
                <strong>{r.label}</strong> — {r.ok ? "✓ " : "✗ "}
                {r.detail}
              </List.Item>
            ))}
          </List>
          <Button variant="subtle" size="xs" mt={6} onClick={cancel}>
            Dismiss
          </Button>
        </Alert>
      )}
    </div>
  );
}
