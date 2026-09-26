import { useEffect, useRef, useState } from "react";
import { Button } from "@mantine/core";
import type { BoardRow } from "../types";
import { focusPane } from "../api";
import {
  resolveEndStage,
  rowActions,
  rowLabel,
  sessionAction,
  type RowActions,
  type SessionActionName,
} from "../sessionActions";

/** Row buttons minus the unified End control (Stop agent → Close pane). */
const ACTION_ORDER: SessionActionName[] = [
  "relaunch",
  "archive",
  "unarchive",
];
const ACTION_LABEL: Record<SessionActionName, string> = {
  stop: "Stop agent",
  close: "Close pane",
  relaunch: "Relaunch",
  archive: "Archive",
  unarchive: "Unarchive",
};
const ACTION_COLOR: Record<SessionActionName, string> = {
  stop: "red",
  close: "orange",
  relaunch: "blue",
  archive: "gray",
  unarchive: "teal",
};

/** The Stop → Close → Relaunch ladder for one session row, with Stop agent
 *  and Close pane merged into ONE two-stage option:
 *
 *  Stage 1 "Stop agent" while the agent is alive; once stopped, the same
 *  spot becomes stage 2 "Close pane" (the pane lingers). A gone pane shows
 *  neither — there is nothing left to end.
 *
 *  Confirm rule (server-resolved, rendered here): an idle target acts on one
 *  click; a working/blocked/unknown target arms to `Confirm — <reasons>` and
 *  needs the second click within ~5s, then reverts. The armed reason names
 *  the stake: state, uncommitted files, owned work items, memory.
 *
 *  Ended rows keep their note (`ended · stopped by you`) plus whatever the
 *  server still offers on the surviving pane: Close removes it, Relaunch
 *  (the undo) brings the session back. Stop never appears there — the agent
 *  is gone, and re-stopping would walk the shell's tree.
 *
 *  Poll-safety: arming lives in this component's state keyed by row, and the
 *  5s timer reverts it — a board refetch never leaves a stale Confirm armed.
 */
export function SessionButtons({
  row,
  onToast,
  onDone,
  onFocusRow,
  onMessageRow,
}: {
  row: BoardRow;
  onToast: (msg: string, ok: boolean) => void;
  onDone: () => void;
  /** Focus this pane (table row click does the same). Absent → POSTs
   *  /api/focus directly. */
  onFocusRow?: (paneId: string, label: string) => void;
  /** Prefill the message composer for this one row. Absent → no button. */
  onMessageRow?: (row: BoardRow) => void;
}) {
  // Server-resolved, carried on the row (live: copied from the agents
  // feed; ended: assessed from the pane feed). Rendered here, never decided.
  const actions = rowActions(row) as RowActions | undefined;
  const [armed, setArmed] = useState<SessionActionName | "end" | null>(null);
  const [busy, setBusy] = useState(false);
  const timer = useRef<number | null>(null);

  useEffect(
    () => () => {
      if (timer.current) window.clearTimeout(timer.current);
    },
    [],
  );

  /** The unified two-stage End control, resolved per render from the server
   *  verdicts: Stop agent while alive, Close pane once stopped. The POST
   *  still hits the matching /api/session/{stop,close}. */
  const endStage = resolveEndStage(actions);
  const endVerb = endStage?.verb ?? null;

  // The row left (ended), the server changed its mind, or the End control
  // moved stage (Stop agent → Close pane) — drop the arm.
  useEffect(() => {
    setArmed(null);
  }, [row.rowId, row.status, endVerb]);

  if (!actions) {
    if (row.status === "ended") {
      const note = (row as BoardRow & { endedNote?: string }).endedNote;
      return <span className="small">{note ?? "ended"}</span>;
    }
    return null;
  }

  const disarm = () => {
    if (timer.current) window.clearTimeout(timer.current);
    timer.current = null;
    setArmed(null);
  };

  const arm = (name: SessionActionName | "end") => {
    if (timer.current) window.clearTimeout(timer.current);
    setArmed(name);
    timer.current = window.setTimeout(disarm, 5000);
  };

  /** The unified two-stage End control's click: arms to Confirm when the
   *  stage needs it, else POSTs the stage's own verb. */

  const clickEnd = async () => {
    if (!endStage || busy) {
      if (endStage && !endStage.state.enabled)
        onToast(endStage.state.reason || "refused", false);
      return;
    }
    const { verb, state: st, label } = endStage;
    if (st.needsConfirm && armed !== "end") {
      arm("end");
      return;
    }
    disarm();
    setBusy(true);
    const res = await sessionAction(verb, row.rowId, {
      confirm: st.needsConfirm,
    });
    setBusy(false);
    if (res.ok) {
      onToast(`${label}: ${res.state ?? "done"}`, true);
      onDone();
    } else if (res.needsConfirm && res.reason) {
      arm("end");
      onToast(res.reason, false);
    } else {
      onToast(`${label} refused: ${res.error || res.reason || "?"}`, false);
    }
  };

  const click = async (name: SessionActionName) => {
    const st = actions[name];
    if (!st || !st.enabled || busy) {
      if (st && !st.enabled) onToast(st.reason || "refused", false);
      return;
    }
    if (st.needsConfirm && armed !== name) {
      arm(name);
      return;
    }
    disarm();
    setBusy(true);
    const res = await sessionAction(name, row.rowId, {
      confirm: st.needsConfirm,
    });
    setBusy(false);
    if (res.ok) {
      onToast(`${ACTION_LABEL[name]}: ${res.state ?? "done"}`, true);
      onDone();
    } else if (res.needsConfirm && res.reason) {
      // Server asked for confirm (state changed between render and click):
      // arm with the fresh reason instead of failing.
      arm(name);
      onToast(res.reason, false);
    } else {
      onToast(`${ACTION_LABEL[name]} refused: ${res.error || res.reason || "?"}`, false);
    }
  };

  const note =
    row.status === "ended"
      ? (row as BoardRow & { endedNote?: string }).endedNote ?? "ended"
      : null;

  // Reach (phase 9): Open / Message before the ladder. Rendered from
  // server-provided facts (live row? pane id?) — the endpoints refuse
  // loudly when wrong.
  const live = row.status !== "ended";
  const paneId = row.derived.paneId;

  const clickOpen = async () => {
    if (!paneId || busy) return;
    if (onFocusRow) {
      onFocusRow(paneId, row.derived.label);
      return;
    }
    const res = await focusPane(paneId);
    onToast(
      res.ok ? `focused: ${rowLabel(row)}` : `focus failed: ${res.error || "?"}`,
      !!res.ok,
    );
  };

  return (
    <span
      className="session-actions"
      onClick={(e) => e.stopPropagation()}
      style={{ display: "inline-flex", gap: 4, alignItems: "center" }}
    >
      {note && <span className="small">{note}</span>}
      {live && paneId && (
        <Button
          variant="subtle"
          color="blue"
          size="compact-xs"
          title="move terminal focus here — sends no keystrokes"
          disabled={busy}
          onClick={() => void clickOpen()}
        >
          Open
        </Button>
      )}
      {live && onMessageRow && (
        <Button
          variant="subtle"
          color="blue"
          size="compact-xs"
          title="write to this pane — prefills the composer below"
          disabled={busy}
          onClick={() => onMessageRow(row)}
        >
          Message
        </Button>
      )}
      {endStage && (
        <span style={{ display: "inline-flex", flexDirection: "column", gap: 2 }}>
          <Button
            variant={armed === "end" ? "filled" : "subtle"}
            color={ACTION_COLOR[endStage.verb]}
            size="compact-xs"
            title={endStage.state.reason || endStage.label}
            disabled={!endStage.state.enabled || busy}
            onClick={() => void clickEnd()}
          >
            {armed === "end" ? "Confirm" : endStage.label}
          </Button>
          {armed === "end" && (
            <span className="small" style={{ maxWidth: 220, whiteSpace: "normal" }}>
              {endStage.state.reason}
            </span>
          )}
        </span>
      )}
      {ACTION_ORDER.map((name) => {
        const st = actions[name];
        if (!st) return null;
        // Dead weight stays out of the row: relaunch only when offered, and
        // archive/unarchive are a toggle pair — exactly one shows.
        if (!st.enabled && (name === "relaunch" || row.status === "ended")) {
          return null;
        }
        if (!st.enabled && (name === "archive" || name === "unarchive")) {
          return null;
        }
        const isArmed = armed === name;
        return (
          <span key={name} style={{ display: "inline-flex", flexDirection: "column", gap: 2 }}>
            <Button
              variant={isArmed ? "filled" : "subtle"}
              color={ACTION_COLOR[name]}
              size="compact-xs"
              title={st.reason || ACTION_LABEL[name]}
              disabled={!st.enabled || busy}
              onClick={() => void click(name)}
            >
              {isArmed ? "Confirm" : ACTION_LABEL[name]}
            </Button>
            {isArmed && (
              <span className="small" style={{ maxWidth: 220, whiteSpace: "normal" }}>
                {st.reason}
              </span>
            )}
          </span>
        );
      })}
    </span>
  );
}
