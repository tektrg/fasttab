import { Fragment, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { Button, Checkbox, Chip, Group, Menu, Select, Stack, Text, TextInput } from "@mantine/core";
import {
  getCoreRowModel,
  useReactTable,
  type ColumnDef,
} from "@tanstack/react-table";
import {
  DndContext,
  PointerSensor,
  closestCenter,
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
import type {
  BoardProperty,
  BoardRow,
  BoardView,
  ViewFilter,
} from "../types";
import type { ViewPatch } from "../api";
import { createLink, deleteLink } from "../api";
import { DerivedCell, EditableCell } from "./EditableCell";
import { BulkBar } from "./BulkBar";
import { Composer } from "./Composer";
import {
  ChangeTypeModal,
  ColumnMenuItems,
  DeleteColumnConfirm,
  OptionsModal,
  RenameColumnModal,
} from "./ColumnMenus";

const FILTER_OPS: ViewFilter["op"][] = [
  "is",
  "is not",
  "contains",
  "is empty",
  "is not empty",
  ">",
  "<",
];

function SortableHeader({
  id,
  label,
  width,
  stickyLeft,
  children,
}: {
  id: string;
  label: string;
  width?: number;
  /** Non-null pins the header to the left edge at this offset. */
  stickyLeft?: number | null;
  children: React.ReactNode;
}) {
  const { attributes, listeners, setNodeRef, transform, isDragging } =
    useSortable({ id });
  const sticky = stickyLeft != null;
  return (
    <th
      ref={setNodeRef}
      style={{
        ...(transform ? { transform: CSS.Translate.toString(transform) } : undefined),
        // TanStack knows the dragged width but nothing renders it onto the
        // header — without this the ⋮ handle drags, PATCHes, reloads, and
        // the column never visibly moves until a refresh.
        ...(width ? { width, minWidth: width, maxWidth: width } : undefined),
        ...(sticky
          ? {
              position: "sticky",
              left: stickyLeft,
              zIndex: 3,
              background: "var(--paper)",
            }
          : undefined),
      }}
      className={[
        isDragging ? "dragging" : "",
        sticky ? "colsticky" : "",
      ]
        .filter(Boolean)
        .join(" ") || undefined}
    >
      <span
        className="coldrag"
        title={`drag to reorder ${label}`}
        {...attributes}
        {...listeners}
      >
        ⠿
      </span>{" "}
      {children}
    </th>
  );
}

/** Server-resolved table: TanStack renders, dnd-kit reorders, every change
 *  PATCHes the view immediately — reload shows exactly what was left. */
export function BoardTable({
  view,
  rows,
  properties,
  onPatch,
  onToast,
  onPeek,
  peekId,
  rowKind = "session",
  onRefetch,
}: {
  view: BoardView;
  rows: BoardRow[];
  properties: BoardProperty[];
  onPatch: (patch: ViewPatch) => Promise<void>;
  onToast: (msg: string, ok: boolean) => void;
  /** Row click opens the peek panel. It used to raise the terminal and jump
   *  focus to the pane — a whole-desktop move on a misclick. Focusing is now
   *  the panel's own "Open pane" button, a deliberate act. */
  onPeek: (rowId: string) => void;
  peekId?: string | null;
  rowKind?: string;
  onRefetch?: () => void;
}) {
  const propsById = useMemo(
    () => new Map(properties.map((p) => [p.id, p])),
    [properties],
  );

  // Column order: the view's saved order first, then any new property appended.
  const allIds = useMemo(() => properties.map((p) => p.id), [properties]);
  const [order, setOrder] = useState<string[]>(() =>
    mergeOrder(view.columns.map((c) => c.propertyId), allIds),
  );
  const [hidden, setHidden] = useState<Record<string, boolean>>(() =>
    Object.fromEntries(view.columns.filter((c) => c.hidden).map((c) => [c.propertyId, true])),
  );
  const [sizing, setSizing] = useState<Record<string, number>>(() =>
    Object.fromEntries(
      view.columns.filter((c) => c.width != null).map((c) => [c.propertyId, c.width as number]),
    ),
  );
  // Per-column layout prefs: wrap long text, pin left while scrolling.
  // Same persistence as width/hide — the header menu PATCHes the view.
  const [wrap, setWrap] = useState<Record<string, boolean>>(() =>
    Object.fromEntries(view.columns.filter((c) => c.wrap).map((c) => [c.propertyId, true])),
  );
  const [sticky, setSticky] = useState<Record<string, boolean>>(() =>
    Object.fromEntries(view.columns.filter((c) => c.sticky).map((c) => [c.propertyId, true])),
  );
  // Resync when switching views OR when the view's saved config changes
  // (a header-menu edit PATCHes the server; the new view object must win
  // over local drag state, or the click looks dead until reload).
  const viewId = view.id;
  const columnsKey = JSON.stringify(view.columns);
  useEffect(() => {
    setOrder(mergeOrder(view.columns.map((c) => c.propertyId), allIds));
    setHidden(
      Object.fromEntries(view.columns.filter((c) => c.hidden).map((c) => [c.propertyId, true])),
    );
    setSizing(
      Object.fromEntries(
        view.columns.filter((c) => c.width != null).map((c) => [c.propertyId, c.width as number]),
      ),
    );
    setWrap(
      Object.fromEntries(view.columns.filter((c) => c.wrap).map((c) => [c.propertyId, true])),
    );
    setSticky(
      Object.fromEntries(view.columns.filter((c) => c.sticky).map((c) => [c.propertyId, true])),
    );
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [viewId, columnsKey]);

  const persistColumns = (
    nextOrder: string[],
    nextHidden: Record<string, boolean>,
    nextSizing: Record<string, number>,
    nextWrap: Record<string, boolean> = wrapRef.current,
    nextSticky: Record<string, boolean> = stickyRef.current,
  ) => {
    void onPatch({ columns: buildColumnEntries(nextOrder, nextHidden, nextSizing, nextWrap, nextSticky) });
  };

  const sensors = useSensors(useSensor(PointerSensor, { activationConstraint: { distance: 6 } }));
  const onHeaderDragEnd = (e: DragEndEvent) => {
    const { active, over } = e;
    if (!over || active.id === over.id) return;
    const from = order.indexOf(String(active.id));
    const to = order.indexOf(String(over.id));
    if (from < 0 || to < 0) return;
    const next = arrayMove(order, from, to);
    setOrder(next);
    persistColumns(next, hidden, sizing);
  };

  // Layout only. Headers and cells are rendered directly below, NOT through
  // flexRender with inline arrows: an arrow defined inside this memo is a new
  // *component type* on every recompute, so React unmounts and remounts the
  // subtree — which is how a poll every 2-5s used to steal focus mid-edit and
  // snap open header menus shut.
  const columns = useMemo<ColumnDef<BoardRow>[]>(() => {
    return order
      .filter((pid) => propsById.has(pid) && !hidden[pid])
      .map((pid) => {
        const prop = propsById.get(pid)!;
        return {
          id: pid,
          accessorFn: (row) => row.values[pid] ?? null,
          size: sizing[pid] ?? prop.width ?? 150,
        };
      });
  }, [order, hidden, sizing, propsById]);

  const sorting = useMemo(
    () =>
      (view.sort ?? []).map((s) => ({
        id: s.propertyId,
        desc: s.dir === "desc",
      })),
    [view.sort],
  );

  const table = useReactTable({
    data: rows,
    columns,
    state: { columnSizing: Object.fromEntries(Object.entries(sizing).map(([k, v]) => [k, v])) },
    onColumnSizingChange: (updater) => {
      const next = typeof updater === "function" ? updater(sizing as never) : updater;
      setSizing(next as Record<string, number>);
      sizeCommitRef.current?.commit(next as Record<string, number>);
    },
    columnResizeMode: "onChange",
    getCoreRowModel: getCoreRowModel(),
    enableSorting: false, // sorting is server-side per the view; header menu edits it
  });

  // Debounced width commit so a drag writes once, not per pixel.
  const sizeCommitRef = useRef<{ commit: (s: Record<string, number>) => void } | null>(null);
  if (!sizeCommitRef.current) {
    let timer: number | null = null;
    sizeCommitRef.current = {
      commit: (s) => {
        if (timer) window.clearTimeout(timer);
        timer = window.setTimeout(() => persistColumns(orderRef.current, hiddenRef.current, s), 400);
      },
    };
  }
  const orderRef = useRef(order);
  orderRef.current = order;
  const hiddenRef = useRef(hidden);
  hiddenRef.current = hidden;
  const sizingRef = useRef(sizing);
  sizingRef.current = sizing;
  const wrapRef = useRef(wrap);
  wrapRef.current = wrap;
  const stickyRef = useRef(sticky);
  stickyRef.current = sticky;

  // Hide built from the LIVE order/hidden/sizing refs — never from the
  // `view` prop. The prop lags one PATCH round-trip behind a just-finished
  // drag, so building from it silently restores the pre-drag order
  // (last-writer-wins against your own reorder). The refs already hold the
  // dragged order the moment it renders.
  const hideColumn = (pid: string) => {
    const nextHidden = { ...hiddenRef.current, [pid]: true };
    setHidden(nextHidden);
    persistColumns(orderRef.current, nextHidden, sizingRef.current);
  };

  const hiddenProps = properties.filter((p) => hidden[p.id]);

  // Bulk selection (session rows only — the ladder/archive endpoints act on
  // sessions, never work items). Keyed by rowId so a 5s refetch never loses
  // the set; rows that vanish are pruned at render.
  const bulkable = rowKind === "session";
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const presentIds = useMemo(() => new Set(rows.map((r) => r.rowId)), [rows]);
  const selectedRows = useMemo(
    () => rows.filter((r) => selected.has(r.rowId)),
    [rows, selected],
  );
  const toggleOne = (rowId: string, on: boolean) => {
    setSelected((prev) => {
      const next = new Set(prev);
      if (on) next.add(rowId);
      else next.delete(rowId);
      return next;
    });
  };
  const toggleAll = (on: boolean) => {
    if (on) setSelected(new Set(rows.map((r) => r.rowId)));
    else setSelected(new Set());
  };
  const allChecked =
    rows.length > 0 && rows.every((r) => selected.has(r.rowId));
  const someChecked =
    !allChecked && rows.some((r) => selected.has(r.rowId));
  // Prune silently: a row that left the board cannot stay selected.
  useEffect(() => {
    setSelected((prev) => {
      let changed = false;
      const next = new Set<string>();
      for (const id of prev) {
        if (presentIds.has(id)) next.add(id);
        else changed = true;
      }
      return changed ? next : prev;
    });
  }, [presentIds]);

  // Sticky columns pin left in table order: each pinned column sits at the
  // summed widths of the pinned columns before it (plus the bulk checkbox
  // column when present — it is leftmost and never pins, so it is a fixed
  // part of every offset). Unpinned columns get no offset.
  const visibleIds = useMemo(
    () => order.filter((id) => propsById.has(id) && !hidden[id]),
    [order, hidden, propsById],
  );
  // The checkbox column's real width, measured off the header cell — a
  // hardcoded guess leaves a see-through sliver between it and the first
  // pinned column whenever the guess is wider than the rendered box.
  const checkThRef = useRef<HTMLTableCellElement | null>(null);
  const [checkW, setCheckW] = useState(48);
  useLayoutEffect(() => {
    const w = checkThRef.current?.offsetWidth;
    if (w && w !== checkW) setCheckW(w);
  });
  const stickyLeft = useMemo(() => {
    const base = bulkable ? checkW : 0;
    const left: Record<string, number> = {};
    let acc = base;
    for (const pid of visibleIds) {
      if (!sticky[pid]) continue;
      left[pid] = acc;
      acc += sizing[pid] ?? propsById.get(pid)?.width ?? 150;
    }
    return left;
  }, [visibleIds, sticky, sizing, propsById, bulkable, checkW]);

  // A toggle from a header menu PATCHes the full live column entries — same
  // last-writer-wins rule as drag/hide/resize (never the stale view prop).
  const toggleColumnPref = (pid: string, key: "wrap" | "sticky") => {
    const ref = key === "wrap" ? wrapRef : stickyRef;
    const set = key === "wrap" ? setWrap : setSticky;
    const next = { ...ref.current };
    if (next[pid]) delete next[pid];
    else next[pid] = true;
    set(next);
    persistColumns(
      orderRef.current,
      hiddenRef.current,
      sizingRef.current,
      key === "wrap" ? next : wrapRef.current,
      key === "sticky" ? next : stickyRef.current,
    );
  };

  return (
    <div className="boardtable">
      {bulkable && rowKind === "session" && (
        <StatusFilterChips view={view} rows={rows} onPatch={onPatch} />
      )}
      {/* Bulk send is now the exception, not the default path: it appears
          only once rows are ticked. Single-row messaging lives in the peek
          panel, next to the row it belongs to, so this no longer sits at the
          top of the board as the thing you scroll back up to. */}
      {bulkable && rowKind === "session" && selectedRows.length > 0 && (
        <div id="table-composer" style={{ padding: "8px 12px 0" }}>
          <Composer
            rows={selectedRows}
            onToast={onToast}
            onDone={() => onRefetch?.()}
          />
        </div>
      )}
      {bulkable && selectedRows.length > 0 && (
        <BulkBar
          rows={selectedRows}
          onToast={onToast}
          onDone={() => onRefetch?.()}
          onClear={() => setSelected(new Set())}
        />
      )}
      <DndContext sensors={sensors} collisionDetection={closestCenter} onDragEnd={onHeaderDragEnd}>
        <table>
          <thead>
            <SortableContext items={order.filter((id) => !hidden[id])} strategy={horizontalListSortingStrategy}>
              {table.getHeaderGroups().map((hg) => (
                <tr key={hg.id}>
                  {bulkable && (
                    <th
                      ref={checkThRef}
                      title="select all rows for bulk stop / close / archive"
                      className="colsticky"
                      style={{
                        position: "sticky",
                        left: 0,
                        zIndex: 3,
                        background: "var(--paper)",
                      }}
                    >
                      <Checkbox
                        checked={allChecked}
                        indeterminate={someChecked}
                        onChange={(e) => toggleAll(e.currentTarget.checked)}
                        aria-label="select all rows"
                      />
                    </th>
                  )}
                  {hg.headers.map((h) => {
                    const pid = h.column.id;
                    const prop = propsById.get(pid);
                    return (
                      <SortableHeader
                        key={pid}
                        id={pid}
                        label={prop?.name ?? pid}
                        width={h.column.getSize()}
                        stickyLeft={stickyLeft[pid] ?? null}
                      >
                        {prop && (
                          <HeaderMenu
                            prop={prop}
                            view={view}
                            onPatch={onPatch}
                            onToast={onToast}
                            onHideColumn={hideColumn}
                            wrapped={!!wrap[pid]}
                            stuck={!!sticky[pid]}
                            onToggleWrap={() => toggleColumnPref(pid, "wrap")}
                            onToggleSticky={() => toggleColumnPref(pid, "sticky")}
                          />
                        )}
                        <span
                          className="colresize"
                          title="drag to resize"
                          onMouseDown={h.getResizeHandler()}
                          onTouchStart={h.getResizeHandler()}
                          onClick={(e) => e.stopPropagation()}
                        >
                          ⋮
                        </span>
                      </SortableHeader>
                    );
                  })}
                  <th className="addcol">
                    {hiddenProps.length > 0 && (
                      <Menu position="bottom-end">
                        <Menu.Target>
                          <Button
                            variant="subtle"
                            size="xs"
                            color="green"
                            title="show a hidden column"
                          >
                            +{hiddenProps.length}
                          </Button>
                        </Menu.Target>
                        <Menu.Dropdown>
                          <Menu.Label>Hidden columns</Menu.Label>
                          {hiddenProps.map((p) => (
                            <Menu.Item
                              key={p.id}
                              onClick={() => {
                                const next = { ...hiddenRef.current };
                                delete next[p.id];
                                setHidden(next);
                                persistColumns(orderRef.current, next, sizing);
                              }}
                            >
                              Show {p.name}
                            </Menu.Item>
                          ))}
                        </Menu.Dropdown>
                      </Menu>
                    )}
                  </th>
                </tr>
              ))}
            </SortableContext>
          </thead>
          <tbody>
            {table.getRowModel().rows.map((r) => {
              const ended = r.original.status === "ended";
              const pane = r.original.derived.paneId;
              const peeked = peekId === r.original.rowId;
              return (
                <Fragment key={r.original.rowId}>
                  <tr
                    className={
                      [ended ? "ended-row" : "", peeked ? "row-peeked" : ""]
                        .filter(Boolean)
                        .join(" ") || undefined
                    }
                    data-pane={pane ?? undefined}
                    onClick={() => onPeek(r.original.rowId)}
                  >
                    {bulkable && (
                      <td
                        onClick={(e) => e.stopPropagation()}
                        className="colsticky"
                        style={{
                          position: "sticky",
                          left: 0,
                          zIndex: 2,
                          background: "var(--paper)",
                        }}
                      >
                        <Checkbox
                          checked={selected.has(r.original.rowId)}
                          onChange={(e) =>
                            toggleOne(r.original.rowId, e.currentTarget.checked)
                          }
                          aria-label={`select ${r.original.rowId}`}
                        />
                      </td>
                    )}
                    {r.getVisibleCells().map((c) => {
                      const prop = propsById.get(c.column.id);
                      if (!prop) return null;
                      const lead =
                        ended && c.column.id === visibleIds[0] ? (
                          <span className="ended-badge">ended</span>
                        ) : null;
                      // key is the column id, not TanStack's row-index-derived
                      // cell id: a reordered poll must not rekey a live editor.
                      return prop.editable ? (
                        <EditableCell
                          key={c.column.id}
                          rowId={r.original.rowId}
                          rowKind={r.original.rowKind ?? rowKind}
                          property={prop}
                          value={r.original.values[c.column.id] ?? null}
                          onToast={onToast}
                          width={c.column.getSize()}
                          lead={lead}
                          wrap={!!wrap[c.column.id]}
                          stickyLeft={stickyLeft[c.column.id] ?? null}
                        />
                      ) : (
                        <DerivedCell
                          key={c.column.id}
                          property={prop}
                          row={r.original}
                          width={c.column.getSize()}
                          lead={lead}
                          onToast={onToast}
                          onDone={onRefetch ?? (() => {})}
                          wrap={!!wrap[c.column.id]}
                          stickyLeft={stickyLeft[c.column.id] ?? null}
                        />
                      );
                    })}
                    <td className="small" />
                  </tr>
                  {r.original.links && (
                    <tr>
                      <td colSpan={visibleIds.length + (bulkable ? 2 : 1)} style={{ padding: 0 }}>
                        <LinksDetail
                          row={r.original}
                          onToast={onToast}
                          onRefetch={onRefetch ?? (() => {})}
                        />
                      </td>
                    </tr>
                  )}
                </Fragment>
              );
            })}
          </tbody>
        </table>
      </DndContext>
      {rows.length === 0 && <div className="empty">no rows match this view</div>}
      {sorting.length > 0 && (
        <div className="small viewsort">
          sorted by{" "}
          {sorting
            .map((s) => `${propsById.get(s.id)?.name ?? s.id} ${s.desc ? "↓" : "↑"}`)
            .join(" · ")}
        </div>
      )}
    </div>
  );
}

function mergeOrder(saved: string[], all: string[]): string[] {
  const seen = new Set(saved);
  return [...saved.filter((id) => all.includes(id)), ...all.filter((id) => !seen.has(id))];
}

/** BeautifulUI (13) Filter Table chip bar: All + per-STATE counts that
 *  reflect the view's filters and PATCH them on click. Counts are of the
 *  currently loaded rows; the active chip matches a `derived:state is
 *  <value>` view filter, All means no such filter. Session rows only —
 *  work items have no hook STATE. dnd-kit / TanStack / bulk selection
 *  below are untouched. */
function StatusFilterChips({
  view,
  rows,
  onPatch,
}: {
  view: BoardView;
  rows: BoardRow[];
  onPatch: (patch: ViewPatch) => Promise<void>;
}) {
  const counts = useMemo(() => {
    const c: Record<string, number> = { blocked: 0, working: 0, idle: 0, unknown: 0 };
    for (const r of rows) {
      const s = (r.derived.hookState ?? "").toLowerCase();
      if (s === "blocked") c.blocked++;
      else if (s === "working") c.working++;
      else if (s === "idle") c.idle++;
      else c.unknown++;
    }
    return c;
  }, [rows]);
  const activeState = (view.filters ?? []).find(
    (f) => f.propertyId === "derived:state" && f.op === "is",
  )?.value as string | undefined;
  const active = typeof activeState === "string" ? activeState.toLowerCase() : null;
  const pick = (next: string | null) => {
    const rest = (view.filters ?? []).filter(
      (f) => !(f.propertyId === "derived:state" && f.op === "is"),
    );
    void onPatch(
      next ? { filters: [...rest, { propertyId: "derived:state", op: "is", value: next }] } : { filters: rest },
    );
  };
  const chip = (key: string | null, label: string, n: number) => (
    <Chip
      key={label}
      checked={active === key || (key === null && !active)}
      onChange={() => pick(key)}
      color={key === "blocked" ? "red" : key === "working" ? "green" : "gray"}
      variant={(active === key || (key === null && !active)) ? "filled" : "outline"}
      size="xs"
      className="status-chip"
    >
      {label} · {n}
    </Chip>
  );
  return (
    <Group gap="xs" px="sm" py="xs" className="status-chips" wrap="wrap">
      {chip(null, "All", rows.length)}
      {chip("working", "Working", counts.working)}
      {chip("blocked", "Blocked", counts.blocked)}
      {chip("idle", "Idle", counts.idle)}
      {counts.unknown > 0 ? chip("unknown", "Unknown", counts.unknown) : null}
      {(view.filters ?? []).length > 0 && (
        <Text size="xs" c="dimmed">
          {view.filters.length} filter{(view.filters.length > 1 ? "s" : "")} on view
        </Text>
      )}
    </Group>
  );
}

function HeaderMenu({
  prop,
  view,
  onPatch,
  onToast,
  onHideColumn,
  wrapped,
  stuck,
  onToggleWrap,
  onToggleSticky,
}: {
  prop: BoardProperty;
  view: BoardView;
  onPatch: (patch: ViewPatch) => Promise<void>;
  onToast: (msg: string, ok: boolean) => void;
  onHideColumn: (propertyId: string) => void;
  wrapped: boolean;
  stuck: boolean;
  onToggleWrap: () => void;
  onToggleSticky: () => void;
}) {
  const [op, setOp] = useState<ViewFilter["op"]>("contains");
  const [val, setVal] = useState("");
  const [renameOpen, setRenameOpen] = useState(false);
  const [optionsOpen, setOptionsOpen] = useState(false);
  const [typeOpen, setTypeOpen] = useState(false);
  const [deleteOpen, setDeleteOpen] = useState(false);
  const existing = (view.filters ?? []).filter((f) => f.propertyId === prop.id);
  const sortEntry = (view.sort ?? []).find((s) => s.propertyId === prop.id);

  const setSort = (dir: "asc" | "desc" | null) => {
    const rest = (view.sort ?? []).filter((s) => s.propertyId !== prop.id);
    void onPatch(dir ? { sort: [...rest, { propertyId: prop.id, dir }] } : { sort: rest });
  };

  const addFilter = () => {
    if (op !== "is empty" && op !== "is not empty" && !val) {
      onToast("filter needs a value (or use is empty)", false);
      return;
    }
    void onPatch({
      filters: [...(view.filters ?? []), { propertyId: prop.id, op, value: val }],
    });
    setVal("");
  };

  // A real floating menu: Escape and click-outside close it, and it floats
  // above the header instead of expanding inline and shoving the table
  // taller. Stable component type (not an inline arrow) so the 2s poll
  // re-renders without remounting it shut mid-use.
  return (
    <>
      <Menu position="bottom-start" closeOnItemClick={false}>
        <Menu.Target>
          <Button
            variant="subtle"
            size="xs"
            title={`${prop.name} — menu for hide, sort, filter`}
          >
            {prop.name}
          </Button>
        </Menu.Target>
        <Menu.Dropdown onClick={(e) => e.stopPropagation()}>
          <Menu.Item onClick={() => onHideColumn(prop.id)}>
            Hide column
          </Menu.Item>
          <Menu.Item
            onClick={onToggleWrap}
            title="Wrap long text onto multiple lines (saved in this view)"
          >
            {wrapped ? "✓ Wrap text" : "Wrap text"}
          </Menu.Item>
          <Menu.Item
            onClick={onToggleSticky}
            title="Pin this column to the left while scrolling sideways (saved in this view)"
          >
            {stuck ? "✓ Pin column left" : "Pin column left"}
          </Menu.Item>
          <Menu.Divider />
          <Menu.Label>Sort</Menu.Label>
          <Menu.Item
            disabled={sortEntry?.dir === "asc"}
            onClick={() => setSort("asc")}
          >
            ↑ Ascending{sortEntry?.dir === "asc" ? " ✓" : ""}
          </Menu.Item>
          <Menu.Item
            disabled={sortEntry?.dir === "desc"}
            onClick={() => setSort("desc")}
          >
            ↓ Descending{sortEntry?.dir === "desc" ? " ✓" : ""}
          </Menu.Item>
          <Menu.Item disabled={!sortEntry} onClick={() => setSort(null)}>
            Clear sort
          </Menu.Item>
          <Menu.Divider />
          <Menu.Label>Filter</Menu.Label>
          <Stack gap="xs" p="xs">
            <Select
              value={op}
              onChange={(v) => v && setOp(v as ViewFilter["op"])}
              data={FILTER_OPS}
              aria-label="filter operator"
            />
            {op !== "is empty" && op !== "is not empty" && (
              <TextInput
                value={val}
                onChange={(e) => setVal(e.currentTarget.value)}
                placeholder="value"
                aria-label="filter value"
                onKeyDown={(e) => {
                  if (e.key === "Enter") addFilter();
                }}
              />
            )}
            <Button size="xs" onClick={addFilter}>
              Add filter
            </Button>
          </Stack>
          {existing.map((f, i) => (
            <Menu.Item
              key={i}
              color="red"
              onClick={() =>
                onPatch({ filters: (view.filters ?? []).filter((x) => x !== f) })
              }
            >
              × {f.op}{" "}
              {f.op === "is empty" || f.op === "is not empty"
                ? ""
                : formatFilterValue(f.value, prop)}
            </Menu.Item>
          ))}
          <Menu.Divider />
          <ColumnMenuItems
            prop={prop}
            onRename={() => setRenameOpen(true)}
            onEditOptions={() => setOptionsOpen(true)}
            onChangeType={() => setTypeOpen(true)}
            onDelete={() => setDeleteOpen(true)}
          />
          {prop.editable && (
            <Text size="xs" c="dimmed" px="sm" py={4}>
              Stored column — values persist
            </Text>
          )}
        </Menu.Dropdown>
      </Menu>
      {prop.editable && (
        <>
          <RenameColumnModal
            prop={prop}
            opened={renameOpen}
            onClose={() => setRenameOpen(false)}
            onToast={onToast}
          />
          <OptionsModal
            prop={prop}
            opened={optionsOpen}
            onClose={() => setOptionsOpen(false)}
            onToast={onToast}
          />
          <ChangeTypeModal
            prop={prop}
            opened={typeOpen}
            onClose={() => setTypeOpen(false)}
            onToast={onToast}
          />
          <DeleteColumnConfirm
            prop={prop}
            opened={deleteOpen}
            onClose={() => setDeleteOpen(false)}
            onToast={onToast}
          />
        </>
      )}
    </>
  );
}

/** Every columns write — drag, hide, unhide, resize, wrap, pin — goes through this so
 *  the PATCH always carries the full live order, never a stale snapshot. */
export function buildColumnEntries(
  order: string[],
  hidden: Record<string, boolean>,
  sizing: Record<string, number>,
  wrap: Record<string, boolean> = {},
  sticky: Record<string, boolean> = {},
): { propertyId: string; hidden: boolean; width: number | null; wrap: boolean; sticky: boolean }[] {
  return order.map((pid) => ({
    propertyId: pid,
    hidden: !!hidden[pid],
    width: sizing[pid] ?? null,
    wrap: !!wrap[pid],
    sticky: !!sticky[pid],
  }));
}

function formatFilterValue(v: unknown, _prop: BoardProperty): string {
  return String(v ?? "");
}

/** Row-level link detail, rendered for any row carrying resolved `links`
 *  (work items today). Every link shows HOW it was made: manual (set by the
 *  PO, survives resyncs) beats certain (the record's own fields) beats
 *  guessed (slug / itemId heuristics) — a guess never poses as certain. */
function LinksDetail({
  row,
  onToast,
  onRefetch,
}: {
  row: BoardRow;
  onToast: (msg: string, ok: boolean) => void;
  onRefetch: () => void;
}) {
  const links = row.links!;
  const stop = (e: React.MouseEvent) => e.stopPropagation();

  const linkSession = async () => {
    const targetId = window.prompt(
      "Link a session to this work item (agent session id). Manual links beat guesses and survive resyncs.",
    )?.trim();
    if (!targetId) return;
    const res = await createLink({ workRowId: row.rowId, targetKind: "session", targetId });
    onToast(res.ok ? "session linked (manual)" : `link failed: ${res.error || "?"}`, res.ok);
    if (res.ok) onRefetch();
  };

  const unlink = async (targetKind: "session" | "branch" | "worktree", targetId: string) => {
    const res = await deleteLink({ workRowId: row.rowId, targetKind, targetId });
    onToast(res.ok ? "manual link removed" : `unlink failed: ${res.error || "?"}`, res.ok);
    if (res.ok) onRefetch();
  };

  const overrideNamed = async (
    targetKind: "branch" | "worktree",
    current: string,
    hint: string,
  ) => {
    const targetId = window.prompt(
      `Manual ${targetKind} for this work item (empty clears the override). ${hint}`,
      current,
    );
    if (targetId === null) return;
    const trimmed = targetId.trim();
    if (!trimmed) {
      const existing = links[targetKind];
      if (existing && existing.source === "manual") {
        await unlink(targetKind, existing.name ?? "");
      }
      return;
    }
    const res = await createLink({ workRowId: row.rowId, targetKind, targetId: trimmed });
    onToast(res.ok ? `${targetKind} set (manual)` : `link failed: ${res.error || "?"}`, res.ok);
    if (res.ok) onRefetch();
  };

  return (
    <div className="linkdetail" onClick={stop}>
      <span className="small">sessions: </span>
      {links.sessions.length === 0 && <span className="small">none</span>}
      {links.sessions.map((s) => (
        <span className="linkchip" key={s.id ?? s.label ?? ""}>
          {s.label ?? s.id} · {s.status} · {sourceBadge(s.source)}
          {s.source === "manual" && (
            <button title="remove manual link" onClick={() => void unlink("session", s.id ?? "")}>×</button>
          )}
        </span>
      ))}
      <Button variant="subtle" size="compact-xs" onClick={() => void linkSession()}>+ Link session</Button>
      <span className="small"> · branch: </span>
      {links.branch ? (
        <span className="linkchip">
          {links.branch.name} · {sourceBadge(links.branch.source)}
          {links.branch.source === "manual" && (
            <button title="remove manual override" onClick={() => void unlink("branch", links.branch!.name ?? "")}>×</button>
          )}
        </span>
      ) : (
        <span className="small">none</span>
      )}
      <Button variant="subtle" size="compact-xs" onClick={() => void overrideNamed("branch", links.branch?.source === "manual" ? (links.branch.name ?? "") : "", "Beats the slug/itemId guess.")}>Override</Button>
      <span className="small"> · worktree: </span>
      {links.worktree ? (
        <span className="linkchip">
          {links.worktree.name} · {sourceBadge(links.worktree.source)}
          {links.worktree.source === "manual" && (
            <button title="remove manual override" onClick={() => void unlink("worktree", links.worktree!.name ?? "")}>×</button>
          )}
        </span>
      ) : (
        <span className="small">none</span>
      )}
      <Button variant="subtle" size="compact-xs" onClick={() => void overrideNamed("worktree", links.worktree?.source === "manual" ? (links.worktree.name ?? "") : "", "Beats the slug/itemId guess.")}>Override</Button>
    </div>
  );
}

function sourceBadge(source: string): string {
  if (source === "manual") return "manual";
  if (source === "authoritative") return "certain";
  return "guessed";
}
