import { useState } from "react";
import { Button, Menu, Modal } from "@mantine/core";
import type {
  AgentRow,
  BoardProperty,
  BoardRow,
  BoardState,
  BoardValue,
} from "../types";
import { AddColumnModal, DeleteColumnConfirm, OptionsModal, RenameColumnModal } from "./ColumnMenus";
import { DerivedCell, EditableCell } from "./EditableCell";
import { SessionButtons } from "./SessionActions";
import { Composer } from "./Composer";

// BeautifulUI (06) Task Rows + (05) Tool Chips: every row carries a left
// status spine + status icon (blocked red, question blue, working green
// pulse, idle dim). Pure chrome — row-click focuses the pane, the action
// cell stops propagation, all modals unchanged.
export type AgentStatus = "blocked" | "question" | "working" | "idle";

export function agentStatus(a: AgentRow): AgentStatus {
  const hook = (a.hookState ?? "").toLowerCase();
  const screen = (a.screenState ?? "").toUpperCase();
  if (
    hook === "blocked" ||
    screen === "NEEDS_HUMAN" ||
    screen === "NEEDS_LOGIN" ||
    screen === "CRASHED"
  )
    return "blocked";
  if (a.screenQuestion) return "question";
  // Parked past the 2h ceiling: the frame may be a dead session's last draw, so
  // it stops reading green (a stale hook `working` included).
  if (a.backgroundWaitExpired) return "idle";
  // Parked on its own monitor/agent is busy, not idle (see classify_pane).
  if (hook === "working" || screen === "ACTIVE" || screen === "WAITING_ON_BACKGROUND")
    return "working";
  return "idle";
}

const AGENT_ICON: Record<AgentStatus, string> = {
  blocked: "⛔",
  question: "?",
  working: "●",
  idle: "○",
};

export function Agents({
  agents,
  board,
  onFocus,
  onToast,
}: {
  agents: AgentRow[];
  board?: BoardState;
  onFocus: (paneId: string, label: string) => void;
  onToast: (msg: string, ok: boolean) => void;
}) {
  const rows: BoardRow[] = board?.rows ?? agents.map((agent) => ({
    rowKind: "session",
    rowId: agent.rowId ?? agent.paneId ?? agent.paneIdSanitized ?? agent.label,
    derived: agent,
    values: {} as Record<string, BoardValue>,
  }));
  const properties = board?.properties ?? [];
  const [addOpen, setAddOpen] = useState(false);
  // Phase 9: per-row Message opens the composer for that one row. The rows
  // are BoardRow-shaped with server-resolved actions where the feed
  // enriched them — SessionButtons renders nothing without those, same as
  // the table, so availability stays server-decided.
  const [composeRow, setComposeRow] = useState<BoardRow | null>(null);

  return (
    <>
      <div
        className="small"
        style={{ padding: "6px 12px", color: "var(--dim)" }}
      >
        Three views of one pane. STATE = what the worker pushed (right about{" "}
        <em>working</em>, and it was the source of the old false-
        <em>blocked</em> flood). SCREEN = what the pane actually shows,
        classified the same way the chief&apos;s own CLI does — believed over
        the other two for blocked-vs-finished. HERDR = the terminal
        manager&apos;s screen guess, shown for comparison only, never believed.
        Click a row to focus its pane in herdr.
      </div>
      <div id="agents-body">
        {rows.length === 0 ? (
          <div className="empty">no agent data yet</div>
        ) : (
          <table className="agent-table">
            <thead>
              <tr>
                <th className="agent-spine-head" aria-hidden="true" />
                {properties.map((property) => (
                  <ColumnHeader
                    key={property.id}
                    property={property}
                    onToast={onToast}
                  />
                ))}
                <th><Button variant="subtle" size="xs" color="green" onClick={() => setAddOpen(true)} title="New column">+</Button></th>
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => {
                const a = row.derived;
                const st = agentStatus(a);
                return (
                <tr
                  key={row.rowId}
                  data-pane={a.paneId ?? undefined}
                  className={"agent-row agent-" + st}
                  onClick={() => a.paneId && onFocus(a.paneId, a.label)}
                >
                  <td className="agent-spine" aria-hidden="true">
                    <span className={"agent-dot agent-dot-" + st} title={st}>
                      {AGENT_ICON[st]}
                    </span>
                  </td>
                  {properties.map((property) => property.editable ? (
                    <EditableCell
                      key={property.id}
                      rowId={row.rowId}
                      property={property}
                      value={row.values[property.id] ?? null}
                      onToast={onToast}
                    />
                  ) : (
                    <DerivedCell
                      key={property.id}
                      property={property}
                      row={row}
                    />
                  ))}
                  <td className="small" onClick={(e) => e.stopPropagation()}>
                    <SessionButtons
                      row={row}
                      onToast={onToast}
                      onDone={() => {}}
                      onFocusRow={onFocus}
                      onMessageRow={(r) => setComposeRow(r)}
                    />
                  </td>
                </tr>
                );
              })}
            </tbody>
          </table>
        )}
        <AddColumnModal
          opened={addOpen}
          onClose={() => setAddOpen(false)}
          onToast={onToast}
        />
        <Modal
          opened={composeRow !== null}
          onClose={() => setComposeRow(null)}
          title={
            composeRow ? `Send message to ${composeRow.derived.label}` : ""
          }
          size="lg"
        >
          {composeRow && (
            <Composer rows={[composeRow]} onToast={onToast} />
          )}
        </Modal>
      </div>
    </>
  );
}

function ColumnHeader({
  property,
  onToast,
}: {
  property: BoardProperty;
  onToast: (msg: string, ok: boolean) => void;
}) {
  const [renameOpen, setRenameOpen] = useState(false);
  const [optionsOpen, setOptionsOpen] = useState(false);
  const [deleteOpen, setDeleteOpen] = useState(false);
  if (!property.editable) {
    return <th className={property.id === "derived:cwd" ? "wrap derived-header" : "derived-header"}>{property.name}</th>;
  }
  return (
    <th className="stored-header">
      <Menu position="bottom-start">
        <Menu.Target>
          <Button variant="subtle" size="xs" title={`${property.name} — column menu`}>
            {property.name}
          </Button>
        </Menu.Target>
        <Menu.Dropdown>
          <Menu.Item onClick={() => setRenameOpen(true)}>Rename…</Menu.Item>
          {(property.type === "select" || property.type === "multi_select") && (
            <Menu.Item onClick={() => setOptionsOpen(true)}>Edit options…</Menu.Item>
          )}
          <Menu.Divider />
          <Menu.Item color="red" onClick={() => setDeleteOpen(true)}>
            Delete column…
          </Menu.Item>
        </Menu.Dropdown>
      </Menu>
      <RenameColumnModal
        prop={property}
        opened={renameOpen}
        onClose={() => setRenameOpen(false)}
        onToast={onToast}
      />
      <OptionsModal
        prop={property}
        opened={optionsOpen}
        onClose={() => setOptionsOpen(false)}
        onToast={onToast}
      />
      <DeleteColumnConfirm
        prop={property}
        opened={deleteOpen}
        onClose={() => setDeleteOpen(false)}
        onToast={onToast}
      />
    </th>
  );
}
