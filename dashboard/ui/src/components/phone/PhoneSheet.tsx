import { useState } from "react";
import { Badge, Button, Modal } from "@mantine/core";
import type { BoardProperty, BoardRow } from "../../types";
import {
  resolveEndStage,
  rowActions,
  rowLabel,
  sessionAction,
} from "../../sessionActions";
import { useVisualViewportOffset } from "../../hooks/useVisualViewportOffset";
import { PaneScreen } from "../PaneScreen";
import { RowDetailExtras } from "../RowDetailExtras";
import { Composer } from "../Composer";

/** Full-screen row detail — the phone equivalent of the desktop RowPanel
 *  drawer, but modal (a phone has no "board behind it" to keep clickable)
 *  and built around the two verbs a phone visit actually needs: read what
 *  happened (last line + terminal peek) and act (Done, Park, or reply).
 *
 *  `RowDetailExtras` is a deliberate no-op today — see that file. */
export function PhoneSheet({
  row,
  properties: _properties,
  onClose,
  onToast,
  onRefetch,
}: {
  row: BoardRow | null;
  properties: BoardProperty[];
  onClose: () => void;
  onToast: (msg: string, ok: boolean) => void;
  onRefetch: () => void;
}) {
  const [busy, setBusy] = useState<"done" | "park" | null>(null);
  const keyboardInset = useVisualViewportOffset();

  if (!row) return null;

  const label = rowLabel(row);
  const paneId = row.derived.paneId ?? null;
  const ended = row.status === "ended";
  const lastLine = String(row.values["derived:lastline"] ?? "").trim();
  const actions = rowActions(row);
  const endStage = resolveEndStage(actions);
  const canPark = !!actions?.archive?.enabled;
  const canUnpark = !!actions?.unarchive?.enabled;

  const runDone = async () => {
    if (!endStage || !endStage.state.enabled || busy) return;
    setBusy("done");
    const res = await sessionAction(endStage.verb, row.rowId, {
      confirm: endStage.state.needsConfirm,
    });
    setBusy(null);
    onToast(
      res.ok ? `${endStage.label}: ${res.state ?? "done"}` : `${endStage.label} refused: ${res.error || res.reason || "?"}`,
      !!res.ok,
    );
    if (res.ok) {
      onRefetch();
      onClose();
    }
  };

  const runPark = async () => {
    const verb = canUnpark ? "unarchive" : "archive";
    if (!actions?.[verb]?.enabled || busy) return;
    setBusy("park");
    const res = await sessionAction(verb, row.rowId, { confirm: false });
    setBusy(null);
    onToast(
      res.ok ? (verb === "archive" ? "parked" : "unparked") : `refused: ${res.error || res.reason || "?"}`,
      !!res.ok,
    );
    if (res.ok) onRefetch();
  };

  return (
    <Modal
      opened={!!row}
      onClose={onClose}
      fullScreen
      radius={0}
      transitionProps={{ duration: 160 }}
      classNames={{ content: "phone-sheet", body: "phone-sheet-body", header: "phone-sheet-head" }}
      title={
        <div className="phone-sheet-title">
          <span>{label}</span>
          {ended && <span className="ended-badge">ended</span>}
        </div>
      }
    >
      <div className="phone-sheet-scroll">
        {paneId && <div className="small phone-sheet-paneid">{paneId}</div>}
        {lastLine && (
          <div className="phone-sheet-section">
            <div className="rp-section-name">last line</div>
            <div className="rp-lastline">{lastLine}</div>
          </div>
        )}
        <PaneScreen paneId={ended ? null : paneId} />
        <RowDetailExtras row={row} />
      </div>

      <div
        className="phone-sheet-footer"
        style={{ transform: keyboardInset > 0 ? `translateY(-${keyboardInset}px)` : undefined }}
      >
        {!ended && (
          <div className="phone-sheet-actions">
            {endStage && (
              <Button
                color={endStage.verb === "stop" ? "red" : undefined}
                variant="light"
                size="sm"
                disabled={!endStage.state.enabled || busy !== null}
                loading={busy === "done"}
                onClick={() => void runDone()}
              >
                Done{endStage.state.needsConfirm ? " (confirm)" : ""}
              </Button>
            )}
            {(canPark || canUnpark) && (
              <Button
                variant="light"
                size="sm"
                disabled={busy !== null}
                loading={busy === "park"}
                onClick={() => void runPark()}
              >
                {canUnpark ? "Unpark" : "Park"}
              </Button>
            )}
          </div>
        )}
        {!ended && paneId && <Composer rows={[row]} onToast={onToast} onDone={onRefetch} />}
        {ended && (
          <Badge size="sm" variant="light" color="gray" className="phone-sheet-ended-note">
            {row.endedNote || "ended — no further action here"}
          </Badge>
        )}
      </div>
    </Modal>
  );
}
