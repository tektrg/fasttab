import { useEffect, useRef, useState, type ReactNode } from "react";
import type { BoardProperty, BoardRow } from "../../types";
import { fmtAge } from "../../api";
import { rowLabel } from "../../sessionActions";
import { PaneScreen } from "../PaneScreen";
import { RowDetailExtras } from "../RowDetailExtras";
import { Composer } from "../Composer";
import { OpenInClaudeButton } from "../OpenInClaudeButton";
import { messagesViaInbox, wakesToMessage } from "../../openInClaude";
import { blindAgentCaption, messageRefusal, takesQuickCommands } from "../../messageGates";
import { ActionButton } from "../../ui/ActionButton";
import { Sheet } from "../../ui/Sheet";
import { StatusBadge } from "../../ui/StatusBadge";
import { defaultSheetTab, initialsOf, sheetStatus, sheetTabs, type SheetTab } from "./phoneModel";
import { usePhoneSheetActions } from "./usePhoneSheetActions";

const TAB_LABEL: Record<SheetTab, string> = { activity: "Activity", terminal: "Terminal", plan: "Plan" };

/** Shared sheet header: avatar, name, status badge, one meta line. */
export function SheetHeader({ name, badge, meta }: { name: string; badge: ReactNode; meta: string }) {
  return (
    <>
      <span className="phone-sheet-avatar" aria-hidden="true">{initialsOf(name)}</span>
      <span className="phone-sheet-headtext">
        <span className="phone-sheet-title">{name}</span>
        <span className="phone-sheet-meta">{meta}</span>
      </span>
      {badge}
    </>
  );
}

/** A session's detail in a bottom sheet (peek -> full): read what happened
 *  (Activity / Terminal / Plan tabs) and act (Park, Done, or reply — the
 *  Composer is pinned in the footer).
 *
 *  `RowDetailExtras` supplies the Review / plan / latest-message + form
 *  cards; the verbs and their confirm rules live in `usePhoneSheetActions`. */
export function PhoneSheet({
  row: current,
  properties: _properties,
  onClose,
  onToast,
  onUndo,
  onRefetch,
}: {
  row: BoardRow | null;
  properties: BoardProperty[];
  onClose: () => void;
  onToast: (msg: string, ok: boolean) => void;
  onUndo?: (message: string, undo: () => void) => void;
  onRefetch: () => void;
}) {
  // Keep the last row while the sheet slides out, so closing (Done, Park, a
  // row that vanished from the poll) animates instead of unmounting at once.
  const last = useRef<BoardRow | null>(current);
  if (current) last.current = current;
  const row = current ?? last.current;
  const a = usePhoneSheetActions({ row, onToast, onUndo, onRefetch, onClose });
  const [tab, setTab] = useState<SheetTab>("activity");
  const rowId = row?.rowId;
  const pendingTab = row ? defaultSheetTab(row) : "activity";
  // A different row (or a plan that just appeared) opens on its own tab.
  useEffect(() => setTab(pendingTab), [rowId, pendingTab]);

  if (!row) return null;

  const name = rowLabel(row);
  const paneId = row.derived.paneId ?? null;
  const ended = row.status === "ended";
  // A Claude Desktop / CLI row has no pane but may take messages via its inbox.
  const canMessage = !!paneId || messagesViaInbox(row.derived);
  const blind = messageRefusal(row.derived) !== null;
  const quick = takesQuickCommands(row);
  // A sleeping Claude Desktop session: ended, but the server wakes it to deliver.
  const wakeable = wakesToMessage(row);
  const lastLine = String(row.values["derived:lastline"] ?? "").trim();
  const tabs = sheetTabs(row);
  const active = tabs.includes(tab) ? tab : "activity";
  const machine = row.derived.machine || "local";
  const meta = [machine !== "local" ? machine : null, fmtAge(row.derived.hookSinceSec ?? null)]
    .filter(Boolean)
    .join(" · ");

  const footer = (
    <div className="phone-sheet-footer">
      {!ended && (
        <div className="phone-sheet-actions">
          {a.endStage && (
            <ActionButton
              variant={a.armed === "done" ? "danger" : "secondary"}
              disabled={!a.endStage.state.enabled || a.busy !== null}
              onClick={() => void a.runDone()}
            >
              {a.armed === "done" ? "Confirm" : "Done"}
            </ActionButton>
          )}
          <OpenInClaudeButton row={row.derived} size="sm" />
          {(a.canPark || a.canUnpark) && (
            <ActionButton
              variant={a.armed === "park" ? "danger" : "secondary"}
              disabled={a.busy !== null}
              onClick={() => void a.runPark()}
            >
              {a.armed === "park" ? "Confirm" : a.canUnpark ? "Unpark" : "Park"}
            </ActionButton>
          )}
        </div>
      )}
      {!ended && quick && (
        <div className="phone-sheet-quick">
          {(["compact", "clear"] as const).map((cmd) => (
            <ActionButton
              key={cmd}
              size="sm"
              variant={a.armed === cmd ? "danger" : "secondary"}
              disabled={a.busy !== null}
              onClick={() => void a.runQuick(cmd)}
            >
              {a.quickLabel(cmd)}
            </ActionButton>
          ))}
        </div>
      )}
      {(!ended || wakeable) && canMessage && !blind && <Composer rows={[row]} onToast={onToast} onDone={onRefetch} />}
      {!ended && blind && <div className="phone-sheet-gate-note">{blindAgentCaption(row.derived.agentKind)}</div>}
      {ended && !wakeable && <div className="phone-sheet-gate-note">{row.endedNote || "ended — no further action here"}</div>}
    </div>
  );

  return (
    <Sheet
      open={!!current}
      onOpenChange={(o) => !o && onClose()}
      title={name}
      header={<SheetHeader name={name} badge={<StatusBadge status={sheetStatus(row, wakeable)} />} meta={meta} />}
      footer={footer}
    >
      {tabs.length > 1 && (
        <div className="phone-tabs" role="tablist">
          {tabs.map((t) => (
            <button
              key={t}
              type="button"
              role="tab"
              aria-selected={t === active}
              className="phone-tab"
              onClick={() => setTab(t)}
            >
              {TAB_LABEL[t]}
            </button>
          ))}
        </div>
      )}
      {active === "activity" && (
        <>
          {lastLine && (
            <div className="phone-sheet-section">
              <div className="rp-section-name">last line</div>
              <div className="rp-lastline">{lastLine}</div>
            </div>
          )}
          {tabs.includes("plan") ? (
            <div className="phone-sheet-gate-note">A plan is waiting for your approval — see the Plan tab.</div>
          ) : (
            <RowDetailExtras row={row} onToast={onToast} phone />
          )}
        </>
      )}
      {active === "terminal" && <PaneScreen paneId={ended ? null : paneId} />}
      {active === "plan" && <RowDetailExtras row={row} onToast={onToast} phone />}
    </Sheet>
  );
}
