import { useEffect, useMemo, useRef, useState } from "react";
import { Alert, Badge, Button, Select, Text } from "@mantine/core";
import {
  DndContext,
  PointerSensor,
  closestCenter,
  useDroppable,
  useDraggable,
  useSensor,
  useSensors,
  type DragEndEvent,
} from "@dnd-kit/core";
import {
  SortableContext,
  arrayMove,
  horizontalListSortingStrategy,
  useSortable,
} from "@dnd-kit/sortable";
import { CSS } from "@dnd-kit/utilities";
import type { BoardProperty, BoardRow, BoardView } from "../types";
import type { ViewPatch } from "../api";
import { formatValue, optionName } from "./EditableCell";
import { setCellValue } from "../api";
import { CardMenu } from "./CardMenu";
import {
  ARCHIVED_PROP_ID,
  MEMORY_CAVEAT,
  fmtCtx,
  fmtMem,
  resolveKanbanDrop,
  rowAutocompactPct,
  rowContextPct,
  rowMemoryBytes,
  sessionAction,
} from "../sessionActions";

/** Kanban over any select / multi-select column, stored or derived.
 *  Dragging between groups sets the stored value; over a derived group the
 *  drop is refused with a visible reason — never a silent no-op.
 *
 *  Phase 6: a drop onto the ARCHIVED flag's `yes` column archives the card
 *  (onto `no` restores it) — a drag may archive. A drop onto a column named
 *  like destruction (stop/close/…) is blocked with a visible reason: a drag
 *  is far too cheap a gesture for an irreversible act. The card menu is the
 *  only destructive path on a card. */
export function Kanban({
  view,
  rows,
  properties,
  groupPropertyId,
  groups,
  onGroupBy,
  onPatch,
  onToast,
  onRefetch,
  onPeek,
  peekId,
  rowKind = "session",
}: {
  view: BoardView;
  rows: BoardRow[];
  properties: BoardProperty[];
  groupPropertyId: string | null;
  groups: { propertyId: string; editable: boolean; source: string; groups: { key: string; rowIds: string[] }[] } | null;
  onGroupBy: (propertyId: string) => void;
  /** Persists the dragged column sequence (server-side, shared). */
  onPatch: (patch: ViewPatch) => Promise<void>;
  onToast: (msg: string, ok: boolean) => void;
  onRefetch: () => void;
  /** Card click opens the peek panel — the same gesture as a table row. */
  onPeek: (rowId: string) => void;
  peekId?: string | null;
  rowKind?: string;
}) {
  const [refusal, setRefusal] = useState<string | null>(null);
  const sensors = useSensors(useSensor(PointerSensor, { activationConstraint: { distance: 6 } }));

  // Any column, stored or derived: grouping by a computed column is allowed,
  // only the drop is refused (PO ruling 2026-09-04).
  const groupables = useMemo(() => properties, [properties]);
  const prop = properties.find((p) => p.id === groupPropertyId) ?? null;
  const byId = useMemo(() => new Map(rows.map((r) => [r.rowId, r])), [rows]);
  const visibleStored = useMemo(
    () =>
      properties.filter(
        (p) => p.editable && p.id !== groupPropertyId && !isHidden(view, p.id),
      ).slice(0, 2),
    [properties, groupPropertyId, view],
  );

  // Column sequence: the server already applies the saved groupOrder, so the
  // live keys render pinned on first paint; local drag state only bridges
  // the PATCH round-trip. A new group that appears after the pin was saved
  // appends at the end (same rule as the table's mergeOrder for new props).
  const serverKeys = useMemo(
    () => (groups?.groups ?? []).map((g) => g.key),
    [groups],
  );
  const [colOrder, setColOrder] = useState<string[]>(serverKeys);
  const orderKey = `${view.id}|${groupPropertyId}|${(view.groupOrder ?? []).join(",")}|${serverKeys.join(",")}`;
  useEffect(() => {
    setColOrder(mergeGroupOrder(view.groupOrder, serverKeys));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [orderKey]);
  const groupsByKey = useMemo(() => {
    const m = new Map((groups?.groups ?? []).map((g) => [g.key, g]));
    return colOrder.map((k) => m.get(k)).filter((g): g is { key: string; rowIds: string[] } => !!g);
  }, [colOrder, groups]);

  const onDragEnd = async (e: DragEndEvent) => {
    const { active, over } = e;
    setRefusal(null);
    if (!over) return;
    // Column reorder: drag a column header's ⠿ onto another column. The
    // sequence PATCHes the view, so every browser opens the same order.
    // Either the header handle (kcol:) or the column body (group:) counts
    // as the drop target — the body is 95% of the column, refusing it
    // would make the reorder look dead unless aimed at the tiny header.
    if (String(active.id).startsWith("kcol:")) {
      const moved = resolveColumnMove(String(active.id), String(over.id), colOrder);
      if (!moved) return;
      const next = arrayMove(colOrder, moved.from, moved.to);
      setColOrder(next);
      await onPatch({ groupOrder: next });
      return;
    }
    const rowId = String(active.id).replace(/^card:/, "");
    // A card dropped onto a column's header handle lands on that column:
    // the sortable header is a second drop target for the same group.
    const targetKey = String(over.id).replace(/^group:/, "").replace(/^kcol:/, "");
    if (!prop) return;
    // Phase-6 drop routing, before any cell write: archive/restore on the
    // ARCHIVED flag's columns, loud refusal on destruction-named columns.
    const routed = resolveKanbanDrop(prop.id, targetKey);
    if (routed.kind === "blocked") {
      setRefusal(routed.reason);
      onToast(routed.reason, false);
      return;
    }
    if (routed.kind === "archive" || routed.kind === "unarchive") {
      const res = await sessionAction(routed.kind, rowId);
      if (res.ok) {
        onToast(
          routed.kind === "archive"
            ? "archived — board-only, the session is untouched"
            : "restored to the default view",
          true,
        );
        onRefetch();
      } else {
        const reason = `${routed.kind} refused: ${res.error || res.reason || "?"}`;
        setRefusal(reason);
        onToast(reason, false);
      }
      return;
    }
    if (!prop.editable || groups?.editable === false) {
      const reason = `cannot move here — ${prop.name} is computed, the page cannot set it`;
      setRefusal(reason);
      onToast(reason, false);
      return;
    }
    const row = byId.get(rowId);
    if (!row) return;
    let next: string | string[] | null;
    if (targetKey === "(none)") next = null;
    else if (prop.type === "multi_select") {
      const cur = Array.isArray(row.values[prop.id]) ? (row.values[prop.id] as string[]) : [];
      next = cur.includes(targetKey) ? cur : [...cur, targetKey];
    } else {
      next = targetKey;
    }
    const res = await setCellValue({ rowKind, rowId, propertyId: prop.id, value: next });
    if (res.ok) {
      onToast(`moved to ${groupLabel(prop, targetKey)}`, true);
      onRefetch();
    } else {
      const reason = `move refused: ${res.error || "?"}`;
      setRefusal(reason);
      onToast(reason, false);
    }
  };

  if (!groupables.length) {
    return <div className="empty">no columns to group by</div>;
  }

  return (
    <div className="kanban">
      <div className="kanban-bar">
        <Select
          label="Group by"
          value={groupPropertyId}
          onChange={(v) => v && onGroupBy(v)}
          data={groupables.map((p) => ({
            value: p.id,
            label: p.editable ? p.name : `${p.name} (computed — drops refused)`,
          }))}
          style={{ minWidth: 220 }}
        />
        {prop && !prop.editable && (
          <Text size="sm" c="orange">
            {prop.name} is computed — grouping is allowed, moving cards here is refused
          </Text>
        )}
        {(view.groupOrder?.length ?? 0) > 0 && (
          <Button
            variant="subtle"
            size="xs"
            title="Forget the saved column sequence and return to server order"
            onClick={() => void onPatch({ groupOrder: null })}
          >
            Reset column order
          </Button>
        )}
      </div>
      {refusal && (
        <Alert color="red" title="Move refused" style={{ margin: "0 12px 8px" }}>
          {refusal}
        </Alert>
      )}
      <DndContext sensors={sensors} collisionDetection={closestCenter} onDragEnd={onDragEnd}>
        <div className="kanban-cols">
          <SortableContext items={colOrder.map((k) => `kcol:${k}`)} strategy={horizontalListSortingStrategy}>
            {groupsByKey.map((g) => (
              <KanbanColumn
                key={g.key}
                groupKey={g.key}
                title={groupLabel(prop, g.key)}
                rows={g.rowIds.map((id) => byId.get(id)).filter((r): r is BoardRow => !!r)}
                extraFields={visibleStored}
                onToast={onToast}
                onRefetch={onRefetch}
                onPeek={onPeek}
                peekId={peekId}
              />
            ))}
          </SortableContext>
        </div>
      </DndContext>
    </div>
  );
}

function KanbanColumn({
  groupKey,
  title,
  rows,
  extraFields,
  onToast,
  onRefetch,
  onPeek,
  peekId,
}: {
  groupKey: string;
  title: string;
  rows: BoardRow[];
  extraFields: BoardProperty[];
  onToast: (msg: string, ok: boolean) => void;
  onRefetch: () => void;
  onPeek: (rowId: string) => void;
  peekId?: string | null;
}) {
  const { setNodeRef: setDropRef, isOver } = useDroppable({ id: `group:${groupKey}` });
  // The column is a sortable item (header ⠿ drag reorders columns) AND a
  // droppable (cards land on it). Two refs on one node fight, so the outer
  // wrapper owns the sort transform and the inner owns the drop target —
  // same nesting shape as the table's SortableHeader.
  const {
    attributes,
    listeners,
    setNodeRef: setSortRef,
    transform,
    isDragging,
  } = useSortable({ id: `kcol:${groupKey}` });
  return (
    <div
      ref={setSortRef}
      style={transform ? { transform: CSS.Translate.toString(transform) } : undefined}
      className={"kcol-wrap" + (isDragging ? " dragging" : "")}
    >
      <div ref={setDropRef} className={isOver ? "kcol over" : "kcol"}>
        <div className="kcol-head">
          <span
            className="coldrag"
            title={`drag to reorder ${title}`}
            {...attributes}
            {...listeners}
          >
            ⠿
          </span>{" "}
          {title} <Badge size="sm" variant="light" color={isOver ? "blue" : "gray"}>{rows.length}</Badge>
        </div>
      {rows.map((r) => (
        <KanbanCard
          key={r.rowId}
          row={r}
          extraFields={extraFields}
          onToast={onToast}
          onRefetch={onRefetch}
          onPeek={onPeek}
          peeked={peekId === r.rowId}
        />
      ))}
      {rows.length === 0 && <div className="empty">drop here</div>}
      </div>
    </div>
  );
}

/** Saved pin first, unknown keys dropped, brand-new groups appended — the
 *  same merge the table uses for new properties, so a group that appears
 *  after the pin was saved never vanishes. */
export function mergeGroupOrder(saved: string[] | null | undefined, all: string[]): string[] {
  if (!saved?.length) return [...all];
  const seen = new Set(saved);
  return [...saved.filter((k) => all.includes(k)), ...all.filter((k) => !seen.has(k))];
}

/** Column-drop target resolution, exported for tests. A dragged column may
 *  land on another column's header handle (`kcol:key`, the sortable node)
 *  or anywhere on its body (`group:key`, the card drop target) — both mean
 *  "reorder onto that column". Anything else (or a no-op) is null. */
export function resolveColumnMove(
  activeId: string,
  overId: string,
  colOrder: string[],
): { from: number; to: number } | null {
  const fromKey = activeId.replace(/^kcol:/, "");
  const toKey = overId.replace(/^kcol:/, "").replace(/^group:/, "");
  const from = colOrder.indexOf(fromKey);
  const to = colOrder.indexOf(toKey);
  if (from < 0 || to < 0 || from === to) return null;
  return { from, to };
}

/** Exported for the phase-9 render tests (card line + badge). */
export function KanbanCard({  row,
  extraFields,
  onToast,
  onRefetch,
  onPeek,
  peeked = false,
}: {
  row: BoardRow;
  extraFields: BoardProperty[];
  onToast: (msg: string, ok: boolean) => void;
  onRefetch: () => void;
  /** Optional so the render tests can mount a card on its own. */
  onPeek?: (rowId: string) => void;
  peeked?: boolean;
}) {
  const { attributes, listeners, setNodeRef, transform, isDragging } = useDraggable({
    id: `card:${row.rowId}`,
  });
  // The whole card is the drag handle, and a finished drag still fires a
  // click. dnd-kit's 6px activation constraint decides drag-vs-click for the
  // DRAG; this decides it for the CLICK, from the same distance — without it
  // every card you drop also opens the panel for it.
  const downAt = useRef<{ x: number; y: number } | null>(null);
  const ended = row.status === "ended";
  const label = String(row.values["derived:label"] ?? row.derived.label ?? row.rowId);
  // Session rows carry a state/screen pair; other row shapes simply omit it.
  const stateLine = [row.values["derived:state"], row.values["derived:screen"]]
    .filter((v) => v !== null && v !== undefined && String(v) !== "")
    .map(String)
    .join(" · ");
  // Phase 9: MEM + CTX on their own line, ALWAYS (no column config). — when
  // unknown, never 0 (fmtCtx/fmtMem coerce both). The countdown is a
  // separate amber badge — the big CTX % is not compaction proximity.
  // Mantine has no amber: orange is the closest loud swatch.
  const auto = rowAutocompactPct(row);
  const lastLine = String(row.values["derived:lastline"] ?? "").trim();
  return (
    <div
      ref={setNodeRef}
      style={transform ? { transform: CSS.Translate.toString(transform) } : undefined}
      className={
        "kcard" +
        (ended ? " ended-row" : "") +
        (isDragging ? " dragging" : "") +
        (peeked ? " peeked" : "")
      }
      {...attributes}
      {...listeners}
      onPointerDown={(e) => {
        downAt.current = { x: e.clientX, y: e.clientY };
        listeners?.onPointerDown?.(e);
      }}
      onClick={(e) => {
        const from = downAt.current;
        downAt.current = null;
        if (!onPeek || e.defaultPrevented) return;
        if (from && Math.hypot(e.clientX - from.x, e.clientY - from.y) > 6) return;
        onPeek(row.rowId);
      }}
    >
      <div className="kcard-title">
        {label} {ended && <span className="ended-badge">ended</span>}
        <span onClick={(e) => e.stopPropagation()} onPointerDown={(e) => e.stopPropagation()}>
          <CardMenu row={row} onToast={onToast} onDone={onRefetch} />
        </span>
      </div>
      {stateLine && <div className="small">{stateLine}</div>}
      <div className="small" title={MEMORY_CAVEAT}>
        MEM {fmtMem(rowMemoryBytes(row))} · CTX {fmtCtx(rowContextPct(row))}{" "}
        {auto !== null && (
          <Badge color="orange" size="xs" title="close to auto-compact — act now">
            {auto}% to autocompact
          </Badge>
        )}
      </div>
      {lastLine && (
        // The pane's last meaningful line. Clamped to two lines with the full
        // text on hover: a recap is prose and would otherwise make one card
        // taller than its whole column. Always shown, no column config — this
        // is the "what is it saying?" that NEEDS YOU no longer answers for
        // anything that is not stopped at a prompt.
        <div className="kcard-lastline" title={lastLine}>
          {lastLine}
        </div>
      )}
      {extraFields.map((p) => (
        <div className="small" key={p.id}>
          {p.name}: {formatValue(row.values[p.id] ?? null, p)}
        </div>
      ))}
    </div>
  );
}

function groupLabel(prop: BoardProperty | null, key: string): string {
  if (key === "(none)") return "(no value)";
  // The archive flag groups as yes/no — render what they mean.
  if (prop && prop.id === ARCHIVED_PROP_ID) {
    if (key === "yes") return "Archived";
    if (key === "no") return "Active";
  }
  if (!prop || !prop.options?.length) return key;
  return optionName(prop, key) !== key ? optionName(prop, key) : key;
}

function isHidden(view: BoardView, pid: string): boolean {
  return !!view.columns.find((c) => c.propertyId === pid)?.hidden;
}
