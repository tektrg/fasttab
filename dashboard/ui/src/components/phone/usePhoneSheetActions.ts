import { useEffect, useRef, useState } from "react";
import type { BoardRow } from "../../types";
import {
  isQueued,
  resolveEndStage,
  rowActions,
  sendMessage,
  sessionAction,
} from "../../sessionActions";

export type QuickCommand = "compact" | "clear";
export type SheetVerb = "done" | "park" | QuickCommand;

/** The row-sheet verbs (Done / Park / Compact / Clear) and their confirm
 *  rules, kept out of the view.
 *
 *  Routine actions act at once. The one exception is the server's own
 *  `needsConfirm` (a working/blocked target): that still takes a SECOND press
 *  within ~5s before `confirm:true` is ever sent — a single tap must never
 *  force-end or force-park a busy session. Park shows an Undo toast
 *  (unarchive); Done cannot be undone, so it gets none. Clear always takes a
 *  second press (it wipes the session's context). */
export function usePhoneSheetActions({
  row,
  onToast,
  onUndo,
  onRefetch,
  onClose,
}: {
  row: BoardRow | null;
  onToast: (msg: string, ok: boolean) => void;
  /** Shows `message` with an Undo button that runs `undo`. */
  onUndo?: (message: string, undo: () => void) => void;
  onRefetch: () => void;
  onClose: () => void;
}) {
  const [busy, setBusy] = useState<SheetVerb | null>(null);
  const [armed, setArmed] = useState<SheetVerb | null>(null);
  // The server said the pane is mid-turn: the next press of this quick
  // command queues it (`confirm: true`), only while it is still armed.
  const [quickQueue, setQuickQueue] = useState<QuickCommand | null>(null);
  const armTimer = useRef<number | null>(null);
  // Same-tick double tap on Compact/Clear: `busy` disables only on the next
  // render, so both presses would type the command (ReviewCard's guard).
  const quickInFlight = useRef(false);

  useEffect(
    () => () => {
      if (armTimer.current) window.clearTimeout(armTimer.current);
    },
    [],
  );

  // A different row opened in the same sheet instance, or this one ended,
  // must never inherit a still-armed "Confirm" from whatever was open before.
  useEffect(() => {
    setArmed(null);
    setQuickQueue(null);
  }, [row?.rowId, row?.status]);

  const disarm = () => {
    if (armTimer.current) window.clearTimeout(armTimer.current);
    armTimer.current = null;
    setArmed(null);
  };
  const arm = (name: SheetVerb) => {
    if (armTimer.current) window.clearTimeout(armTimer.current);
    setArmed(name);
    armTimer.current = window.setTimeout(() => setArmed(null), 5000);
  };

  const actions = row ? rowActions(row) : undefined;
  const endStage = resolveEndStage(actions);
  const canPark = !!actions?.archive?.enabled;
  const canUnpark = !!actions?.unarchive?.enabled;
  const parkVerb = canUnpark ? "unarchive" : "archive";
  const parkNeedsConfirm = !!actions?.[parkVerb]?.needsConfirm;

  const runDone = async () => {
    if (!row || !endStage || !endStage.state.enabled || busy) return;
    if (endStage.state.needsConfirm && armed !== "done") {
      arm("done");
      return;
    }
    disarm();
    setBusy("done");
    const res = await sessionAction(endStage.verb, row.rowId, { confirm: endStage.state.needsConfirm });
    setBusy(null);
    if (res.ok) {
      onToast(`${endStage.label}: ${res.state ?? "done"}`, true);
      onRefetch();
      onClose();
    } else if (res.needsConfirm && res.reason) {
      // Server state changed since render — arm with the fresh reason.
      arm("done");
      onToast(res.reason, false);
    } else {
      onToast(`${endStage.label} refused: ${res.error || res.reason || "?"}`, false);
    }
  };

  const runPark = async () => {
    if (!row || !actions?.[parkVerb]?.enabled || busy) return;
    if (parkNeedsConfirm && armed !== "park") {
      arm("park");
      return;
    }
    disarm();
    setBusy("park");
    const verb = parkVerb;
    const res = await sessionAction(verb, row.rowId, { confirm: parkNeedsConfirm });
    setBusy(null);
    if (res.ok) {
      const rowId = row.rowId;
      const undoVerb = verb === "archive" ? "unarchive" : "archive";
      const message = verb === "archive" ? "Parked" : "Unparked";
      const undo = async () => {
        const back = await sessionAction(undoVerb, rowId, { confirm: false });
        if (back.ok) onRefetch();
        else onToast(`Undo refused: ${back.error || back.reason || "?"}`, false);
      };
      if (onUndo) onUndo(message, () => void undo());
      else onToast(message.toLowerCase(), true);
      onRefetch();
      onClose();
    } else if (res.needsConfirm && res.reason) {
      arm("park");
      onToast(res.reason, false);
    } else {
      onToast(`refused: ${res.error || res.reason || "?"}`, false);
    }
  };

  // Compact/Clear: typed like a message (AgentBar's row menu).
  const runQuick = async (cmd: QuickCommand) => {
    if (!row || busy || quickInFlight.current) return;
    const queueing = quickQueue === cmd && armed === cmd;
    if (cmd === "clear" && !queueing && armed !== "clear") {
      arm("clear");
      return;
    }
    disarm();
    setQuickQueue(null);
    quickInFlight.current = true;
    setBusy(cmd);
    const res = await sendMessage(row.rowId, `/${cmd}`, { confirm: queueing });
    quickInFlight.current = false;
    setBusy(null);
    if (res.ok) {
      onToast(isQueued(res) ? `/${cmd} queued — lands when the turn ends` : `/${cmd} sent`, true);
      onRefetch();
    } else if (res.needsConfirm) {
      setQuickQueue(cmd);
      arm(cmd);
      onToast(res.reason || "busy — press again to queue", false);
    } else {
      onToast(`/${cmd} refused: ${res.error || res.reason || "?"}`, false);
    }
  };

  const quickLabel = (cmd: QuickCommand) => {
    const name = cmd === "compact" ? "Compact" : "Clear";
    if (armed !== cmd) return name;
    return quickQueue === cmd ? `Queue ${name.toLowerCase()}` : `Confirm ${name.toLowerCase()}`;
  };

  return { busy, armed, endStage, canPark, canUnpark, runDone, runPark, runQuick, quickLabel };
}
