import { useCallback, useEffect, useState } from "react";
import { Badge, Collapse, UnstyledButton } from "@mantine/core";
import type { BoardRow, BoardState, FullState, NeedsYouRow } from "../../types";
import { fetchBoard, fmtAge } from "../../api";
import { rowLabel } from "../../sessionActions";
import { KindBadge } from "../Severity";
import { PhoneSheet } from "./PhoneSheet";

/** Phase 2a (docs/plans/2026-09-26-agentbar-mobile-web.md): the phone
 *  "Needs You" inbox. Mounted by App.tsx instead of the desktop
 *  FeedStrip/NeedsYou/BoardSection tree once `usePhoneLayout()` says the
 *  viewport is phone-width — so desktop-only chrome (the table, kanban,
 *  bulk bar, column menus, view switcher) is simply never mounted here,
 *  rather than hidden with CSS.
 *
 *  Needs You comes straight off `/api/state` (same data the desktop reads);
 *  Working/Parked/Ended come from `/api/board` (session rows, default
 *  view) polled the same way BoardSection does. A row tapped from either
 *  list opens the same full-screen sheet, resolved by pane id so a blocked
 *  agent's Needs You entry and its board row are recognized as one thing. */

const NEEDSYOU_RANK: Record<NeedsYouRow["kind"], number> = {
  blocked: 0,
  question: 1,
  "feed-broken": 2,
};

/** Blocked agents first — a permission prompt is the one thing that can't
 *  wait, ahead of an answerable question or a feed outage notice. Stable
 *  otherwise (Array.sort is stable in every engine this ships to). */
function sortNeedsYou(rows: NeedsYouRow[]): NeedsYouRow[] {
  return [...rows].sort((a, b) => NEEDSYOU_RANK[a.kind] - NEEDSYOU_RANK[b.kind]);
}

function rowStatusLabel(row: BoardRow): string {
  const fromValues = row.values["derived:state"];
  if (typeof fromValues === "string" && fromValues) return fromValues;
  return row.derived.screenState || row.derived.hookState || "—";
}

function rowMachine(row: BoardRow): string {
  return row.derived.machine || "local";
}

/** One big tap target: name, machine, status, age — nothing else. Meets
 *  the 44px minimum hit area with room to spare (make-interfaces-feel-
 *  better: never let two hit areas overlap, so this is the ENTIRE row). */
function PhoneRow({
  label,
  machine,
  status,
  ageSec,
  kind,
  onTap,
}: {
  label: string;
  machine: string;
  status: string;
  ageSec: number | null;
  kind?: NeedsYouRow["kind"];
  onTap: () => void;
}) {
  return (
    <UnstyledButton className="phone-row" onClick={onTap}>
      <div className="phone-row-main">
        {kind && <KindBadge kind={kind}>{kind.toUpperCase()}</KindBadge>}
        <span className="phone-row-label">{label}</span>
      </div>
      <div className="phone-row-meta small">
        {machine !== "local" && <Badge size="xs" variant="light">{machine}</Badge>}
        <span>{status}</span>
        <span className="phone-row-age">{fmtAge(ageSec)}</span>
      </div>
    </UnstyledButton>
  );
}

function PhoneSection({
  id,
  title,
  count,
  open,
  onToggle,
  children,
}: {
  id: string;
  title: string;
  count: number;
  open: boolean;
  onToggle: () => void;
  children: React.ReactNode;
}) {
  return (
    <div className="phone-section" data-section={id}>
      <UnstyledButton className="phone-section-head" onClick={onToggle}>
        <span>{title}</span>
        <span className="small">{count}</span>
        <span className="phone-section-chevron">{open ? "▾" : "▸"}</span>
      </UnstyledButton>
      <Collapse expanded={open}>
        {count === 0 ? (
          <div className="empty phone-section-empty">nothing here</div>
        ) : (
          children
        )}
      </Collapse>
    </div>
  );
}

export function PhoneInbox({
  state,
  onToast,
}: {
  state: FullState;
  onToast: (msg: string, ok: boolean) => void;
}) {
  const [board, setBoard] = useState<BoardState | null>(null);
  const [openRowId, setOpenRowId] = useState<string | null>(null);
  // Working starts open (the phone's default view is "what's active right
  // now"); Parked/Ended start collapsed — they're for when nothing needs
  // you and you're checking on something specific.
  const [open, setOpen] = useState({ working: true, parked: false, ended: false });

  const reload = useCallback(async () => {
    try {
      const next = await fetchBoard(null, "session");
      setBoard(next);
    } catch {
      /* keep the last good board rather than blanking the screen on one
         missed poll */
    }
  }, []);

  useEffect(() => {
    void reload();
    const t = window.setInterval(reload, 5000);
    return () => window.clearInterval(t);
  }, [reload]);

  const rows = board?.rows ?? [];
  const needsYou = sortNeedsYou(state.computed.needsYou);
  const needsYouPaneIds = new Set(
    needsYou.map((n) => n.paneId).filter((id): id is string => !!id),
  );

  const working = rows.filter(
    (r) => r.status !== "ended" && !r.archived && !needsYouPaneIds.has(r.derived.paneId ?? ""),
  );
  const parked = rows.filter((r) => !!r.archived);
  const ended = rows.filter((r) => r.status === "ended");

  const openRow = rows.find((r) => r.rowId === openRowId) ?? null;

  const openForPane = (paneId: string | null) => {
    if (!paneId) {
      onToast("no pane behind this row yet", false);
      return;
    }
    const row = rows.find((r) => r.derived.paneId === paneId);
    if (row) setOpenRowId(row.rowId);
    else onToast("still loading detail for this agent — try again in a moment", false);
  };

  const toggle = (key: keyof typeof open) =>
    setOpen((o) => ({ ...o, [key]: !o[key] }));

  return (
    <div className="phone-inbox">
      <div className="phone-section" data-section="needsyou">
        <div className="phone-section-head phone-section-head-static">
          <span>Needs You</span>
          <span className="small">{needsYou.length}</span>
        </div>
        {needsYou.length === 0 ? (
          <div className="empty phone-section-empty">nothing needs you right now</div>
        ) : (
          <div>
            {needsYou.map((n) => (
              <PhoneRow
                key={(n.paneId ?? n.label) + "::" + n.kind}
                label={n.label}
                machine="local"
                status={n.detail}
                ageSec={n.sinceSec}
                kind={n.kind}
                onTap={() => openForPane(n.paneId)}
              />
            ))}
          </div>
        )}
      </div>

      <PhoneSection
        id="working"
        title="Working"
        count={working.length}
        open={open.working}
        onToggle={() => toggle("working")}
      >
        {working.map((r) => (
          <PhoneRow
            key={r.rowId}
            label={rowLabel(r)}
            machine={rowMachine(r)}
            status={rowStatusLabel(r)}
            ageSec={r.derived.hookSinceSec ?? null}
            onTap={() => setOpenRowId(r.rowId)}
          />
        ))}
      </PhoneSection>

      <PhoneSection
        id="parked"
        title="Parked"
        count={parked.length}
        open={open.parked}
        onToggle={() => toggle("parked")}
      >
        {parked.map((r) => (
          <PhoneRow
            key={r.rowId}
            label={rowLabel(r)}
            machine={rowMachine(r)}
            status={rowStatusLabel(r)}
            ageSec={r.derived.hookSinceSec ?? null}
            onTap={() => setOpenRowId(r.rowId)}
          />
        ))}
      </PhoneSection>

      <PhoneSection
        id="ended"
        title="Ended"
        count={ended.length}
        open={open.ended}
        onToggle={() => toggle("ended")}
      >
        {ended.map((r) => (
          <PhoneRow
            key={r.rowId}
            label={rowLabel(r)}
            machine={rowMachine(r)}
            status={r.endedNote || "ended"}
            ageSec={r.derived.hookSinceSec ?? null}
            onTap={() => setOpenRowId(r.rowId)}
          />
        ))}
      </PhoneSection>

      <PhoneSheet
        row={openRow}
        properties={board?.properties ?? []}
        onClose={() => setOpenRowId(null)}
        onToast={onToast}
        onRefetch={reload}
      />
    </div>
  );
}
