import { useCallback, useEffect, useRef, useState } from "react";
import { Badge, Collapse, SegmentedControl, TextInput, UnstyledButton } from "@mantine/core";
import type { BoardRow, BoardState, FullState, NeedsYouRow } from "../../types";
import { fetchBoard, fmtAge } from "../../api";
import { rowLabel } from "../../sessionActions";
import { KindBadge } from "../Severity";
import { PhoneSheet } from "./PhoneSheet";
import { filterAgents, type SearchableAgent } from "../../agentMatch";
import {
  groupByFolder,
  persistGroupBy,
  readGroupBy,
  type FolderGroupable,
  type GroupBy,
} from "./folderGrouping";

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
 *  agent's Needs You entry and its board row are recognized as one thing.
 *
 *  Search: a sticky filter field narrows every section below "Needs You"
 *  by name/machine/folder/status/latest line (`agentMatch.ts` — the one
 *  shared matcher, so a future desktop search box reuses it rather than
 *  growing its own). Group toggle: "Status" (Working/Parked/Ended, the
 *  original layout) or "Folder" (one section per working directory,
 *  folders with a Needs-you agent first — `folderGrouping.ts`). */

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

function boardRowSearchable(row: BoardRow, status: string): SearchableAgent {
  return {
    name: rowLabel(row),
    machine: rowMachine(row),
    project: row.derived.cwd ?? null,
    status,
    latestLine: String(row.values["derived:lastline"] ?? ""),
  };
}

function needsYouSearchable(n: NeedsYouRow): SearchableAgent {
  return { name: n.label, machine: "local", status: n.detail, latestLine: n.detail };
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
  subtitle,
  count,
  open,
  onToggle,
  children,
}: {
  id: string;
  title: string;
  subtitle?: string;
  count: number;
  open: boolean;
  onToggle: () => void;
  children: React.ReactNode;
}) {
  return (
    <div className="phone-section" data-section={id}>
      <UnstyledButton className="phone-section-head" onClick={onToggle} title={subtitle}>
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

interface DisplayRow extends FolderGroupable {
  row: BoardRow;
  label: string;
  machine: string;
  status: string;
  ageSec: number | null;
  bucket: "working" | "parked" | "ended";
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
  const [open, setOpen] = useState<Record<string, boolean>>({ working: true, parked: false, ended: false });
  const [query, setQuery] = useState("");
  const [groupBy, setGroupBy] = useState<GroupBy>(() => readGroupBy());
  const searchRef = useRef<HTMLInputElement | null>(null);

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
  const needsYouAll = sortNeedsYou(state.computed.needsYou);
  const needsYouKindByPane = new Map<string, NeedsYouRow["kind"]>();
  for (const n of needsYouAll) if (n.paneId) needsYouKindByPane.set(n.paneId, n.kind);

  const needsYou = filterAgents(
    needsYouAll.map((n) => ({ ...needsYouSearchable(n), _n: n })),
    query,
  ).map((x) => x._n as NeedsYouRow);

  const allBoardRows: DisplayRow[] = rows
    .filter((r) => !needsYouKindByPane.has(r.derived.paneId ?? ""))
    .map((r) => {
      const ended = r.status === "ended";
      const bucket: DisplayRow["bucket"] = ended ? "ended" : r.archived ? "parked" : "working";
      const status = ended ? r.endedNote || "ended" : rowStatusLabel(r);
      return {
        row: r,
        rowId: r.rowId,
        label: rowLabel(r),
        machine: rowMachine(r),
        status,
        ageSec: r.derived.hookSinceSec ?? null,
        cwd: r.derived.cwd ?? null,
        needsYouKind: (r.derived.paneId && needsYouKindByPane.get(r.derived.paneId)) || null,
        bucket,
      };
    });

  const searchable = (d: DisplayRow) => boardRowSearchable(d.row, d.status);
  const filteredBoardRows = filterAgents(
    allBoardRows.map((d) => ({ ...searchable(d), _d: d })),
    query,
  ).map((x) => x._d as DisplayRow);

  const working = filteredBoardRows.filter((d) => d.bucket === "working");
  const parked = filteredBoardRows.filter((d) => d.bucket === "parked");
  const ended = filteredBoardRows.filter((d) => d.bucket === "ended");

  const folderGroups = groupByFolder(filteredBoardRows);

  const active = query.trim().length > 0;
  const nothingMatches =
    active && needsYou.length === 0 && filteredBoardRows.length === 0;

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

  const toggle = (key: string) => setOpen((o) => ({ ...o, [key]: !o[key] }));

  const setGroup = (v: string) => {
    const next = v === "folder" ? "folder" : "status";
    setGroupBy(next);
    persistGroupBy(next);
  };

  return (
    <div className="phone-inbox">
      <div className="phone-search-bar">
        <TextInput
          ref={searchRef}
          value={query}
          onChange={(e) => setQuery(e.currentTarget.value)}
          placeholder="Filter agents…"
          enterKeyHint="search"
          className="phone-search-input"
          rightSection={
            query ? (
              <UnstyledButton
                aria-label="clear filter"
                onClick={() => setQuery("")}
                className="phone-search-clear"
              >
                ✕
              </UnstyledButton>
            ) : null
          }
        />
        <SegmentedControl
          size="xs"
          value={groupBy}
          onChange={setGroup}
          data={[
            { label: "Status", value: "status" },
            { label: "Folder", value: "folder" },
          ]}
          className="phone-group-toggle"
        />
      </div>

      <div className="phone-section" data-section="needsyou">
        <div className="phone-section-head phone-section-head-static">
          <span>Needs You</span>
          <span className="small">{needsYou.length}</span>
        </div>
        {needsYou.length === 0 ? (
          <div className="empty phone-section-empty">
            {active ? "No agents match" : "nothing needs you right now"}
          </div>
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

      {nothingMatches && filteredBoardRows.length === 0 && (
        <div className="empty phone-section-empty phone-nomatch">No agents match</div>
      )}

      {!nothingMatches && groupBy === "status" && (
        <>
          {(!active || working.length > 0) && (
            <PhoneSection
              id="working"
              title="Working"
              count={working.length}
              open={open.working}
              onToggle={() => toggle("working")}
            >
              {working.map((d) => (
                <PhoneRow
                  key={d.rowId}
                  label={d.label}
                  machine={d.machine}
                  status={d.status}
                  ageSec={d.ageSec}
                  onTap={() => setOpenRowId(d.rowId)}
                />
              ))}
            </PhoneSection>
          )}

          {(!active || parked.length > 0) && (
            <PhoneSection
              id="parked"
              title="Parked"
              count={parked.length}
              open={open.parked}
              onToggle={() => toggle("parked")}
            >
              {parked.map((d) => (
                <PhoneRow
                  key={d.rowId}
                  label={d.label}
                  machine={d.machine}
                  status={d.status}
                  ageSec={d.ageSec}
                  onTap={() => setOpenRowId(d.rowId)}
                />
              ))}
            </PhoneSection>
          )}

          {(!active || ended.length > 0) && (
            <PhoneSection
              id="ended"
              title="Ended"
              count={ended.length}
              open={open.ended}
              onToggle={() => toggle("ended")}
            >
              {ended.map((d) => (
                <PhoneRow
                  key={d.rowId}
                  label={d.label}
                  machine={d.machine}
                  status={d.status}
                  ageSec={d.ageSec}
                  onTap={() => setOpenRowId(d.rowId)}
                />
              ))}
            </PhoneSection>
          )}
        </>
      )}

      {!nothingMatches && groupBy === "folder" && (
        <>
          {folderGroups.map((g) => (
            <PhoneSection
              key={g.key}
              id={g.key}
              title={g.machine !== "local" ? `${g.machine} · ${g.folderName}` : g.folderName}
              subtitle={g.folderPath}
              count={g.rows.length}
              open={open[g.key] ?? g.hasNeedsYou}
              onToggle={() => toggle(g.key)}
            >
              {g.rows.map((d) => (
                <PhoneRow
                  key={d.rowId}
                  label={d.label}
                  machine={d.machine}
                  status={d.status}
                  ageSec={d.ageSec}
                  kind={d.needsYouKind ?? undefined}
                  onTap={() => setOpenRowId(d.rowId)}
                />
              ))}
            </PhoneSection>
          ))}
        </>
      )}

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
