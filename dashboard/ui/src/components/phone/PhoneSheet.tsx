import { useEffect, useRef, useState, type ReactNode } from "react";
import type { BoardProperty, BoardRow } from "../../types";
import { fmtAge } from "../../api";
import { rowLabel } from "../../sessionActions";
import { PaneScreen } from "../PaneScreen";
import { RowDetailExtras, showsPermissionCard } from "../RowDetailExtras";
import { LatestMessage } from "../LatestMessage";
import { Composer } from "../Composer";
import { OpenInClaudeButton } from "../OpenInClaudeButton";
import { messagesViaInbox, wakesToMessage } from "../../openInClaude";
import { blindAgentCaption, messageRefusal, takesQuickCommands } from "../../messageGates";
import { ActionMenu, type MenuItem } from "../../ui/ActionMenu";
import { Screen } from "../../ui/Screen";
import { StatusBadge } from "../../ui/StatusBadge";
import { defaultSheetTab, initialsOf, sheetStatus, sheetTabs, type SheetTab } from "./phoneModel";
import { usePhoneSheetActions } from "./usePhoneSheetActions";

const TAB_LABEL: Record<SheetTab, string> = { activity: "Activity", terminal: "Terminal", plan: "Plan" };

/** Age text for a header ("5m"); empty when the age is unknown, so the
 *  header never shows a lone "—". */
export function headerMeta(machine: string, ageSec: number | null | undefined): string {
  return [machine !== "local" ? machine : null, ageSec == null ? null : fmtAge(ageSec)].filter(Boolean).join(" · ");
}

/** Shared sheet header: avatar, name over (status chip + optional meta), then
 *  `actions` (Open in Claude, the "•••" menu) when the sheet has any. */
export function SheetHeader({ name, badge, meta, actions }: { name: string; badge: ReactNode; meta?: string; actions?: ReactNode }) {
  return (
    <>
      <span className="phone-sheet-avatar" aria-hidden="true">{initialsOf(name)}</span>
      <span className="phone-sheet-headtext">
        <span className="phone-sheet-title">{name}</span>
        <span className="phone-sheet-sub">
          {badge}
          {meta ? <span className="phone-sheet-meta">{meta}</span> : null}
        </span>
      </span>
      {actions}
    </>
  );
}

/** A session's detail on a full-screen pushed screen: read what happened
 *  (Activity / Terminal / Plan tabs) and act (reply in the pinned Composer;
 *  Done / Park / compact / clear live in the header's "•••" menu).
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
  const [menuOpen, setMenuOpen] = useState(false);
  // True between a menu press and its outcome: the menu closes once the verb
  // settles, but stays open while it waits for a confirm press.
  const pressed = useRef(false);
  const rowId = row?.rowId;
  useEffect(() => setMenuOpen(false), [rowId]);
  useEffect(() => {
    if (pressed.current && a.busy === null && a.armed === null) {
      pressed.current = false;
      setMenuOpen(false);
    }
  }, [a.busy, a.armed]);
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
  const meta = headerMeta(machine, row.derived.hookSinceSec);

  // Done and /clear always ask for a second press (Done cannot be undone, /clear
  // wipes context); Park and /compact follow the server's own confirm rules.
  const press = (run: () => void) => () => {
    pressed.current = true;
    run();
  };
  const idle = a.busy === null;
  const menuItems: MenuItem[] = [];
  if (a.endStage) {
    menuItems.push({
      key: "done",
      label: a.armed === "done" ? "Confirm done" : "Done",
      tone: "danger",
      disabled: !a.endStage.state.enabled || !idle,
      onSelect: press(() => (a.armed === "done" ? void a.runDone() : a.arm("done"))),
    });
  }
  if (a.canPark || a.canUnpark) {
    const verb = a.canUnpark ? "Unpark" : "Park";
    menuItems.push({
      key: "park",
      label: a.armed === "park" ? `Confirm ${verb.toLowerCase()}` : verb,
      disabled: !idle,
      onSelect: press(() => void a.runPark()),
    });
  }
  if (quick) {
    for (const cmd of ["compact", "clear"] as const) {
      menuItems.push({
        key: cmd,
        label: a.armed === cmd ? a.quickLabel(cmd) : `/${cmd}`,
        tone: cmd === "clear" ? "danger" : undefined,
        disabled: !idle,
        onSelect: press(() => void a.runQuick(cmd)),
      });
    }
  }
  const headerActions = !ended && (
    <>
      <OpenInClaudeButton row={row.derived} icon />
      {menuItems.length > 0 && <ActionMenu label="More actions" open={menuOpen} onOpenChange={setMenuOpen} items={menuItems} />}
    </>
  );

  const footer = (
    <div className="phone-sheet-footer">
      {(!ended || wakeable) && canMessage && !blind && <Composer rows={[row]} onToast={onToast} onDone={onRefetch} phone />}
      {!ended && blind && <div className="phone-sheet-gate-note">{blindAgentCaption(row.derived.agentKind)}</div>}
      {ended && !wakeable && <div className="phone-sheet-gate-note">{row.endedNote || "ended — no further action here"}</div>}
    </div>
  );

  return (
    <Screen
      open={!!current}
      onClose={onClose}
      title={name}
      header={<SheetHeader name={name} badge={<StatusBadge status={sheetStatus(row, wakeable)} />} meta={meta} actions={headerActions} />}
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
          {/* A Review / Plan card replaces LatestMessage inside RowDetailExtras;
              the agent's last message still leads the Activity tab. */}
          {!ended && showsPermissionCard(row) && (
            <LatestMessage rowId={row.rowId} paneId={paneId} onToast={onToast} phone messageOnly />
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
    </Screen>
  );
}
