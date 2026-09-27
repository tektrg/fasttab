import { useRef, useState } from "react";
import { Badge, Button, Drawer } from "@mantine/core";
import type { BoardProperty, BoardRow, WorkItemLinkTarget } from "../types";
import {
  MEMORY_CAVEAT,
  fmtCtx,
  fmtMem,
  rowAutocompactPct,
  rowContextPct,
  rowLabel,
  rowMemoryBytes,
} from "../sessionActions";
import { CardMenu } from "./CardMenu";
import { DerivedCell, EditableCell } from "./EditableCell";
import { PaneScreen } from "./PaneScreen";
import { RowDetailExtras } from "./RowDetailExtras";
import { RowMessages } from "./RowMessages";

const WIDTH_KEY = "chief-dashboard-peek-width";
const DEFAULT_WIDTH = 480;
const MIN_WIDTH = 320;
/** Leave enough board visible that the panel can never swallow the thing it
 *  is a peek at — clicking the next row is the primary gesture. */
const MIN_BOARD_VISIBLE = 160;

/** Exported for tests: the width rules, free of any DOM. */
export function clampPanelWidth(px: number, viewport: number): number {
  const max = Math.max(MIN_WIDTH, viewport - MIN_BOARD_VISIBLE);
  return Math.round(Math.min(Math.max(px, MIN_WIDTH), max));
}

function readWidth(): number {
  try {
    const raw = Number(window.localStorage.getItem(WIDTH_KEY));
    if (!Number.isFinite(raw) || raw <= 0) return DEFAULT_WIDTH;
    return clampPanelWidth(raw, window.innerWidth);
  } catch {
    return DEFAULT_WIDTH; // private mode
  }
}

function persistWidth(px: number): void {
  try {
    window.localStorage.setItem(WIDTH_KEY, String(px));
  } catch {
    /* private mode — the width simply does not survive the reload */
  }
}

/** The row peek panel: everything about one row, without leaving the board.
 *
 *  Deliberately non-modal. The primary gesture is clicking straight from
 *  one row to the next and watching the panel content swap, so the board
 *  behind it must stay lit, scrollable and clickable — hence no overlay, no
 *  scroll lock, no focus trap, no close-on-click-outside. Escape still
 *  closes, because that is the one dismissal that costs nothing.
 *
 *  The drawer itself never re-opens on a row change (`opened` stays true),
 *  so the slide-in plays once per session with the panel; only the content
 *  cross-fades. A re-slide on every row click is the difference between a
 *  peek panel and a modal that keeps slamming. */
export function RowPanel({
  row,
  properties,
  rowKind,
  onClose,
  onToast,
  onRefetch,
  onFocusPane,
}: {
  row: BoardRow | null;
  properties: BoardProperty[];
  rowKind: string;
  onClose: () => void;
  onToast: (msg: string, ok: boolean) => void;
  onRefetch: () => void;
  onFocusPane: (paneId: string, label: string) => void;
}) {
  // The row that vanishes on close must survive the ~150ms exit, or the
  // panel empties itself before it has finished sliding away.
  const lastRef = useRef<BoardRow | null>(null);
  if (row) lastRef.current = row;
  const shown = row ?? lastRef.current;

  // Width is committed to state only on release. During the drag the width
  // is written straight to the DOM node: this panel holds a table, a log and
  // two fetch results, and re-rendering all of it on every pointermove makes
  // the edge lag behind the cursor.
  const [width, setWidth] = useState(readWidth);
  const dragRef = useRef<HTMLElement | null>(null);

  const startResize = (e: React.PointerEvent<HTMLDivElement>) => {
    const el = e.currentTarget.closest(".rp-content") as HTMLElement | null;
    if (!el) return;
    e.preventDefault(); // or the drag selects the text under it
    // Optional: happy-dom (tests) has no pointer capture, and losing it only
    // costs the fling-past-the-strip case, not the drag itself.
    e.currentTarget.setPointerCapture?.(e.pointerId);
    dragRef.current = el;
    document.body.classList.add("rp-resizing");
  };

  // The panel is anchored right, so its width is the distance from the
  // cursor to the right edge of the window.
  const widthFromPointer = (clientX: number) =>
    clampPanelWidth(window.innerWidth - clientX, window.innerWidth);

  const moveResize = (e: React.PointerEvent<HTMLDivElement>) => {
    if (!dragRef.current) return;
    dragRef.current.style.width = `${widthFromPointer(e.clientX)}px`;
  };

  const endResize = (e: React.PointerEvent<HTMLDivElement>) => {
    const el = dragRef.current;
    if (!el) return;
    dragRef.current = null;
    document.body.classList.remove("rp-resizing");
    const next = widthFromPointer(e.clientX);
    el.style.width = ""; // hand control back to the size prop
    setWidth(next);
    persistWidth(next);
  };

  return (
    <Drawer
      opened={row !== null}
      onClose={onClose}
      position="right"
      size={width}
      padding={0}
      withOverlay={false}
      lockScroll={false}
      trapFocus={false}
      closeOnClickOutside={false}
      closeOnEscape
      zIndex={100}
      title={<span className="rp-kind">{rowKind}</span>}
      transitionProps={{
        duration: 200,
        exitDuration: 140,
        timingFunction: "cubic-bezier(0.2, 0, 0, 1)",
      }}
      classNames={{
        content: "rp-content",
        body: "rp-body",
        header: "rp-drawerhead",
      }}
    >
      {/* Sits on the panel's inner edge, full height, outside the scrolling
          sections so it cannot be clipped or scrolled away. Pointer capture
          keeps the drag alive when the cursor outruns the 6px strip. */}
      <div
        className="rp-resize"
        role="separator"
        aria-orientation="vertical"
        aria-label="drag to resize the panel"
        title="drag to resize"
        onPointerDown={startResize}
        onPointerMove={moveResize}
        onPointerUp={endResize}
        onPointerCancel={endResize}
      />
      {shown && (
        // Keyed by row id: the swap re-runs the 120ms content fade and
        // remounts the two on-demand fetchers (screen, history) for the new
        // row, without touching the drawer's own open state.
        <div className="rp-swap" key={shown.rowId}>
          <div className="rp-sections">
            <Header
              row={shown}
              onToast={onToast}
              onRefetch={onRefetch}
              onFocusPane={onFocusPane}
            />
            <Pulse row={shown} />
            <LastLine row={shown} />
            <RowDetailExtras row={shown} onToast={onToast} />
            <PaneScreen paneId={paneIdOf(shown)} />
            <Fields row={shown} properties={properties} rowKind={rowKind} onToast={onToast} />
            <Links row={shown} />
          </div>
          <RowMessages row={shown} onToast={onToast} onRefetch={onRefetch} />
        </div>
      )}
    </Drawer>
  );
}

/** A pane id worth reading a screen from: ended rows keep the id on the
 *  record but the pane is gone, and work items never had one. */
function paneIdOf(row: BoardRow): string | null {
  if (row.status === "ended") return null;
  return row.derived?.paneId ?? null;
}

function Header({
  row,
  onToast,
  onRefetch,
  onFocusPane,
}: {
  row: BoardRow;
  onToast: (msg: string, ok: boolean) => void;
  onRefetch: () => void;
  onFocusPane: (paneId: string, label: string) => void;
}) {
  const label = rowLabel(row);
  const ended = row.status === "ended";
  const paneId = row.derived?.paneId ?? null;
  return (
    <div className="rp-header">
      <div className="rp-title">
        {label} {ended && <span className="ended-badge">ended</span>}
        {/* endedNote already opens with "ended · " (it is a suffix the
            server composes for the table), so the badge would otherwise
            read "ended ended · stopped by you". */}
        {ended && endedDetail(row.endedNote) && (
          <span className="small"> {endedDetail(row.endedNote)}</span>
        )}
      </div>
      {paneId && <div className="rp-paneid">{paneId}</div>}
      <div className="rp-actions">
        {paneId && !ended && (
          <Button
            className="rp-hit"
            variant="subtle"
            size="compact-sm"
            title="move terminal focus here — sends no keystrokes"
            onClick={() => onFocusPane(paneId, label)}
          >
            Open pane
          </Button>
        )}
        <CardMenu row={row} onToast={onToast} onDone={onRefetch} />
      </div>
    </div>
  );
}

/** The part of `endedNote` the "ended" badge does not already say. */
function endedDetail(note: string | undefined): string {
  const trimmed = (note ?? "").trim().replace(/^ended\s*·?\s*/, "");
  return trimmed;
}

function Pulse({ row }: { row: BoardRow }) {
  const stateLine = [row.values["derived:state"], row.values["derived:screen"]]
    .filter((v) => v !== null && v !== undefined && String(v) !== "")
    .map(String)
    .join(" · ");
  const auto = rowAutocompactPct(row);
  return (
    <div className="rp-section rp-pulse">
      {stateLine && <div className="rp-pulse-state">{stateLine}</div>}
      <div className="rp-pulse-nums">
        <span title={MEMORY_CAVEAT}>MEM {fmtMem(rowMemoryBytes(row))}</span>
        {" · "}
        <span title="% of the context window in use, parsed off the pane's status line — ranks honestly, not an absolute">
          CTX {fmtCtx(rowContextPct(row))}
        </span>{" "}
        {auto !== null && (
          // The big CTX % is occupancy, not proximity: a pane at 29% can be
          // compacting while one at 53% is nowhere near. Only this
          // countdown means "act now", so only it gets the loud swatch.
          <Badge color="orange" size="xs" title="close to auto-compact — act now">
            {auto}% to autocompact
          </Badge>
        )}
      </div>
    </div>
  );
}

function LastLine({ row }: { row: BoardRow }) {
  const text = String(row.values["derived:lastline"] ?? "").trim();
  if (!text) return null;
  return (
    <div className="rp-section">
      <div className="rp-section-name">last line</div>
      <div className="rp-lastline">{text}</div>
    </div>
  );
}

function Fields({
  row,
  properties,
  rowKind,
  onToast,
}: {
  row: BoardRow;
  properties: BoardProperty[];
  rowKind: string;
  onToast: (msg: string, ok: boolean) => void;
}) {
  if (properties.length === 0) return null;
  return (
    <div className="rp-section">
      <div className="rp-section-name">fields</div>
      {properties.map((prop) => (
        <div className="rp-field" key={prop.id}>
          <div className="rp-field-name">{prop.name}</div>
          {/* DerivedCell/EditableCell render a <td>, and a bare <td> outside
              a table is dropped by the DOM. A one-cell table is the cheapest
              legal host — forking their rendering would fork the editor,
              the save path and the derived-column formatting with it.
              onToast/onDone are withheld from DerivedCell on purpose: with
              them the label cell grows its own ⋯ menu, and the panel header
              already carries one. */}
          <table className="rp-fieldtable">
            <tbody>
              <tr>
                {prop.editable ? (
                  <EditableCell
                    rowId={row.rowId}
                    property={prop}
                    value={row.values[prop.id] ?? null}
                    rowKind={rowKind}
                    onToast={onToast}
                  />
                ) : (
                  <DerivedCell property={prop} row={row} />
                )}
              </tr>
            </tbody>
          </table>
        </div>
      ))}
    </div>
  );
}

function Links({ row }: { row: BoardRow }) {
  const links = row.links;
  if (!links) return null;
  return (
    <div className="rp-section">
      <div className="rp-section-name">links</div>
      <div className="rp-links">
        <span className="small">sessions: </span>
        {links.sessions.length === 0 && <span className="small">none</span>}
        {links.sessions.map((s) => (
          <span className="linkchip" key={s.id ?? s.label ?? ""}>
            {s.label ?? s.id} · {s.status} · {sourceBadge(s.source)}
          </span>
        ))}
        <span className="small"> · branch: </span>
        <LinkChip target={links.branch} />
        <span className="small"> · worktree: </span>
        <LinkChip target={links.worktree} />
      </div>
    </div>
  );
}

function LinkChip({ target }: { target: WorkItemLinkTarget | null }) {
  if (!target) return <span className="small">none</span>;
  return (
    <span className="linkchip">
      {target.name ?? target.label ?? target.id} · {sourceBadge(target.source)}
    </span>
  );
}

/** Same vocabulary the table uses: a guess must never pose as certain.
 *  manual (the PO said so, survives resyncs) > certain (the record's own
 *  fields) > guessed (slug / itemId heuristics). */
function sourceBadge(source: string): string {
  if (source === "manual") return "manual";
  if (source === "authoritative") return "certain";
  return "guessed";
}
