import { useEffect, useRef, useState } from "react";
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
import { OpenInClaudeButton } from "../OpenInClaudeButton";
import { messagesViaInbox } from "../../openInClaude";
import { blindAgentCaption, messageRefusal, takesQuickCommands } from "../../messageGates";
import { isQueued, sendMessage } from "../../sessionActions";

type QuickCommand = "compact" | "clear";
type SheetVerb = "done" | "park" | QuickCommand;

/** Full-screen row detail — the phone equivalent of the desktop RowPanel
 *  drawer, but modal (a phone has no "board behind it" to keep clickable)
 *  and built around the two verbs a phone visit actually needs: read what
 *  happened (last line + terminal peek) and act (Done, Park, or reply).
 *
 *  `RowDetailExtras` adds the Review / plan / latest-message cards. */
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
  const [busy, setBusy] = useState<SheetVerb | null>(null);
  // Mirrors the desktop SessionActions two-stage arm/confirm pattern: a
  // working/blocked/unknown target needs a SECOND press within ~5s before
  // `confirm:true` is ever sent — a single tap must never force-end or
  // force-park a busy session (server contract: `SessionActionState
  // .needsConfirm`).
  const [armed, setArmed] = useState<SheetVerb | null>(null);
  // The server said the pane is mid-turn: the next press of this quick
  // command queues it (`confirm: true`), only while it is still armed.
  const [quickQueue, setQuickQueue] = useState<QuickCommand | null>(null);
  const armTimer = useRef<number | null>(null);
  const keyboardInset = useVisualViewportOffset();

  useEffect(
    () => () => {
      if (armTimer.current) window.clearTimeout(armTimer.current);
    },
    [],
  );

  // A different row opened in the same sheet instance, or this one ended,
  // must never inherit a still-armed "Confirm" from whatever was open
  // before it (mirrors the desktop's `setArmed(null)` on row/stage change).
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

  if (!row) return null;

  const label = rowLabel(row);
  const paneId = row.derived.paneId ?? null;
  // A Claude Desktop / CLI row has no pane but may take messages via its inbox.
  const canMessage = !!paneId || messagesViaInbox(row.derived);
  const blind = messageRefusal(row.derived) !== null;
  const quick = takesQuickCommands(row);
  const ended = row.status === "ended";
  const lastLine = String(row.values["derived:lastline"] ?? "").trim();
  const actions = rowActions(row);
  const endStage = resolveEndStage(actions);
  const canPark = !!actions?.archive?.enabled;
  const canUnpark = !!actions?.unarchive?.enabled;
  const parkVerb = canUnpark ? "unarchive" : "archive";
  const parkNeedsConfirm = !!actions?.[parkVerb]?.needsConfirm;

  const runDone = async () => {
    if (!endStage || !endStage.state.enabled || busy) return;
    if (endStage.state.needsConfirm && armed !== "done") {
      arm("done");
      return;
    }
    disarm();
    setBusy("done");
    const res = await sessionAction(endStage.verb, row.rowId, {
      confirm: endStage.state.needsConfirm,
    });
    setBusy(null);
    if (res.ok) {
      onToast(`${endStage.label}: ${res.state ?? "done"}`, true);
      onRefetch();
      onClose();
    } else if (res.needsConfirm && res.reason) {
      // Server state changed since render — arm with the fresh reason
      // instead of failing silently, same as the desktop.
      arm("done");
      onToast(res.reason, false);
    } else {
      onToast(`${endStage.label} refused: ${res.error || res.reason || "?"}`, false);
    }
  };

  const runPark = async () => {
    const verb = parkVerb;
    if (!actions?.[verb]?.enabled || busy) return;
    if (parkNeedsConfirm && armed !== "park") {
      arm("park");
      return;
    }
    disarm();
    setBusy("park");
    const res = await sessionAction(verb, row.rowId, { confirm: parkNeedsConfirm });
    setBusy(null);
    if (res.ok) {
      onToast(verb === "archive" ? "parked" : "unparked", true);
      onRefetch();
    } else if (res.needsConfirm && res.reason) {
      arm("park");
      onToast(res.reason, false);
    } else {
      onToast(`refused: ${res.error || res.reason || "?"}`, false);
    }
  };

  // Compact/Clear: typed like a message (AgentBar's row menu). Clear wipes
  // the session's context, so it always takes a second press first.
  const runQuick = async (cmd: QuickCommand) => {
    if (busy) return;
    const queueing = quickQueue === cmd && armed === cmd;
    if (cmd === "clear" && !queueing && armed !== "clear") {
      arm("clear");
      return;
    }
    disarm();
    setQuickQueue(null);
    setBusy(cmd);
    const res = await sendMessage(row.rowId, `/${cmd}`, { confirm: queueing });
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
        <RowDetailExtras row={row} onToast={onToast} phone />
      </div>

      <div
        className="phone-sheet-footer"
        style={{ transform: keyboardInset > 0 ? `translateY(-${keyboardInset}px)` : undefined }}
      >
        {!ended && (
          <div className="phone-sheet-actions">
            {endStage && (
              <Button
                color={armed === "done" ? "orange" : endStage.verb === "stop" ? "red" : undefined}
                variant={armed === "done" ? "filled" : "light"}
                size="sm"
                disabled={!endStage.state.enabled || busy !== null}
                loading={busy === "done"}
                onClick={() => void runDone()}
              >
                {armed === "done" ? "Confirm" : "Done"}
              </Button>
            )}
            <OpenInClaudeButton row={row.derived} size="sm" />
            {(canPark || canUnpark) && (
              <Button
                color={armed === "park" ? "orange" : undefined}
                variant={armed === "park" ? "filled" : "light"}
                size="sm"
                disabled={busy !== null}
                loading={busy === "park"}
                onClick={() => void runPark()}
              >
                {armed === "park" ? "Confirm" : canUnpark ? "Unpark" : "Park"}
              </Button>
            )}
          </div>
        )}
        {!ended && quick && (
          <div className="phone-sheet-quick">
            {(["compact", "clear"] as const).map((cmd) => (
              <Button
                key={cmd}
                size="xs"
                color={armed === cmd ? "orange" : undefined}
                variant={armed === cmd ? "filled" : "light"}
                disabled={busy !== null}
                loading={busy === cmd}
                onClick={() => void runQuick(cmd)}
              >
                {quickLabel(cmd)}
              </Button>
            ))}
          </div>
        )}
        {!ended && canMessage && !blind && <Composer rows={[row]} onToast={onToast} onDone={onRefetch} />}
        {!ended && blind && (
          <div className="phone-sheet-gate-note">{blindAgentCaption(row.derived.agentKind)}</div>
        )}
        {ended && (
          <Badge size="sm" variant="light" color="gray" className="phone-sheet-ended-note">
            {row.endedNote || "ended — no further action here"}
          </Badge>
        )}
      </div>
    </Modal>
  );
}
