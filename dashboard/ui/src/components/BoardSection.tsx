import { useCallback, useEffect, useState } from "react";
import { Alert, Button } from "@mantine/core";
import type { BoardState, BoardView } from "../types";
import {
  createView,
  deleteView,
  fetchBoard,
  fmtAge,
  listViews,
  patchView,
  persistViewId,
  storedViewId,
} from "../api";
import { ViewSwitcher } from "./ViewSwitcher";
import { BoardTable } from "./BoardTable";
import { Kanban } from "./Kanban";
import { RowPanel } from "./RowPanel";
import { AddColumnModal } from "./ColumnMenus";
import { MEMORY_CAVEAT } from "../sessionActions";

/** The one row kind left after the work-item board was retired. Kept as a
 *  named constant (rather than inlined everywhere) because the API layer
 *  and every child component still take `rowKind` as a generic parameter. */
const rowKind = "session";

/** Saved views over the session board: table, kanban, filters and custom
 *  columns all share this one machinery. */
export function BoardSection({
  onToast,
  onFocus,
}: {
  onToast: (msg: string, ok: boolean) => void;
  onFocus: (paneId: string, label: string) => void;
}) {
  const [views, setViews] = useState<BoardView[]>([]);
  const [activeId, setActiveId] = useState<string | null>(() => storedViewId(rowKind));
  const [board, setBoard] = useState<BoardState | null>(null);
  const [failed, setFailed] = useState<string | null>(null);
  const [addOpen, setAddOpen] = useState(false);
  // The peeked row is held by id, not by object: the board refetches every
  // 5s, and holding the row itself would freeze the panel on a stale copy.
  // Resolving against the fresh rows also closes the panel by itself when
  // the row leaves the board — no orphaned panel over a row that is gone.
  const [peekId, setPeekId] = useState<string | null>(null);

  const active = views.find((v) => v.id === activeId) ?? null;
  const peeked = board?.rows.find((r) => r.rowId === peekId) ?? null;

  const reloadViews = useCallback(async () => {
    try {
      const list = await listViews(rowKind);
      setViews(list);
      setActiveId((prev) => {
        if (list.some((v) => v.id === prev)) return prev;
        const fallback = storedViewId(rowKind);
        const next = list.some((v) => v.id === fallback) ? fallback : (list[0]?.id ?? null);
        persistViewId(next, rowKind);
        return next;
      });
    } catch (e) {
      setFailed(String(e));
    }
  }, []);

  const reloadBoard = useCallback(async () => {
    try {
      const id = storedViewId(rowKind);
      const next = await fetchBoard(id, rowKind);
      setBoard(next);
      setFailed(next.error ?? null);
    } catch (e) {
      setFailed(String(e));
    }
  }, []);

  useEffect(() => {
    void reloadViews();
  }, [reloadViews]);
  useEffect(() => {
    void reloadBoard();
    const t = window.setInterval(reloadBoard, 5000);
    return () => window.clearInterval(t);
  }, [reloadBoard, activeId]);

  const select = (id: string) => {
    setActiveId(id);
    persistViewId(id, rowKind); // last-opened view is local UI state, not a view property
  };

  const patch = async (p: Parameters<typeof patchView>[1]) => {
    if (!active) return;
    const res = await patchView(active.id, p);
    if (!res.ok || !res.view) {
      onToast(`view save failed: ${res.error || "?"}`, false);
      return;
    }
    setViews((vs) => vs.map((v) => (v.id === active.id ? res.view! : v)));
    await reloadBoard();
  };

  const create = async (name: string) => {
    const res = await createView({ name, layout: "table", rowKind });
    if (!res.ok || !res.view) {
      onToast(`new view failed: ${res.error || "?"}`, false);
      return;
    }
    setViews((vs) => [...vs, res.view!]);
    select(res.view.id);
    onToast(`view created: ${name}`, true);
  };

  const addColumn = () => setAddOpen(true);

  const rename = async (name: string) => {
    if (!active || name === active.name) return;
    await patch({ name });
    onToast("view renamed", true);
  };

  const duplicate = async () => {
    if (!active) return;
    const res = await createView({ name: active.name + " copy", layout: active.layout, rowKind });
    if (!res.ok || !res.view) {
      onToast(`duplicate failed: ${res.error || "?"}`, false);
      return;
    }
    const full = await patchView(res.view.id, {
      columns: active.columns,
      sort: active.sort,
      filters: active.filters,
      groupBy: active.groupBy,
      groupOrder: active.groupOrder ?? null,
    });
    setViews((vs) => [...vs, full.view ?? res.view!]);
    if (full.view) select(full.view.id);
    onToast("view duplicated", true);
  };

  const remove = async () => {
    if (!active) return;
    const res = await deleteView(active.id);
    if (!res.ok) {
      onToast(`delete failed: ${res.error || "?"}`, false);
      return;
    }
    const rest = views.filter((v) => v.id !== active.id);
    setViews(rest);
    select(rest[0]?.id ?? null);
    onToast("view deleted", true);
  };

  const groupBy = (propertyId: string) => {
    void patch({ groupBy: propertyId || null });
  };

  const feed = board?.feed;
  const feedBroken = !!feed?.broken && !feed?.warming;

  return (
    <div id="board-body">
      {feedBroken && (
        <Alert
          color="red"
          variant="filled"
          title="⛔ FEED BROKEN — board"
          style={{ margin: "10px 12px 0" }}
        >
          {feed?.ageSec != null ? "last good " + fmtAge(feed.ageSec) + " ago" : "never succeeded"}
          {feed?.error ? " — " + feed.error : ""}
        </Alert>
      )}
      <ViewSwitcher
        views={views}
        active={active}
        onSelect={select}
        onNew={create}
        onRename={rename}
        onDuplicate={duplicate}
        onDelete={remove}
        onLayout={(layout) => void patch({ layout })}
      />
      <div className="viewactions">
        <Button variant="light" size="xs" color="green" onClick={() => void addColumn()}>+ Column</Button>
      </div>
      <AddColumnModal
        opened={addOpen}
        rowKind={rowKind}
        onClose={() => setAddOpen(false)}
        onToast={onToast}
        onCreated={() => void reloadBoard()}
      />
      {failed && <div className="empty">board failed: {failed}</div>}
      <div className="small" style={{ padding: "6px 12px", color: "var(--dim)" }}>
        MEMORY sorts the fattest sessions first — {MEMORY_CAVEAT} Stop frees
        a session&apos;s RAM (one click when idle, Confirm when busy); Close
        removes its pane; Relaunch undoes a Stop. CONTEXT is % of window in
        use (— when unreadable); the amber countdown badge is the real act-now
        signal. LAST LINE is what the pane is actually saying right now — the
        same string NEEDS YOU shows, and since that list only carries panes
        stopped at a prompt, this column is where a finished or quiet worker
        reports itself. The composer above the table sends text to the
        selected rows — the only bulk verb that destroys nothing. Click any
        row to peek at it on the right; the board stays live behind the
        panel, so clicking another row swaps it.
      </div>
      {active && board && active.layout === "table" && (
        <BoardTable
          view={active}
          rows={board.rows}
          properties={board.properties}
          onPatch={patch}
          onToast={onToast}
          onPeek={setPeekId}
          peekId={peekId}
          rowKind={rowKind}
          onRefetch={reloadBoard}
        />
      )}
      {active && board && active.layout === "kanban" && (
        <Kanban
          view={active}
          rows={board.rows}
          properties={board.properties}
          groupPropertyId={active.groupBy}
          groups={board.groups ?? null}
          onGroupBy={groupBy}
          onPatch={patch}
          onToast={onToast}
          onRefetch={reloadBoard}
          onPeek={setPeekId}
          peekId={peekId}
          rowKind={rowKind}
        />
      )}
      <RowPanel
        row={peeked}
        properties={board?.properties ?? []}
        rowKind={rowKind}
        onClose={() => setPeekId(null)}
        onToast={onToast}
        onRefetch={reloadBoard}
        onFocusPane={onFocus}
      />
      {active && !board && !failed && <div className="empty">loading board…</div>}
      {!active && views.length === 0 && !failed && <div className="empty">loading views…</div>}
    </div>
  );
}
