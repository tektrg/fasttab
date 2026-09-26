/**
 * Column layout must survive: every columns write (drag, hide, unhide,
 * resize) PATCHes the full live order. The regression this guards: hiding
 * a column right after a drag used to build the PATCH from the `view` prop,
 * which still held the PRE-drag order until the drag's PATCH round-tripped —
 * last-writer-wins silently restored the old order (lost on next refresh).
 * Hide is now built from the live order refs, so the prop's staleness is
 * irrelevant.
 */
import { expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { BoardTable, buildColumnEntries } from "../components/BoardTable";
import { theme } from "../theme";
import type { ViewPatch } from "../api";
import type { BoardProperty, BoardRow, BoardView } from "../types";

function mergeOrderRef(saved: string[], all: string[]): string[] {
  const seen = new Set(saved);
  return [...saved.filter((id) => all.includes(id)), ...all.filter((id) => !seen.has(id))];
}

test("buildColumnEntries carries the full live order, hidden flags, widths", () => {
  const out = buildColumnEntries(["c", "a", "b"], { b: true }, { a: 200 }, { a: true }, { c: true });
  expect(out).toEqual([
    { propertyId: "c", hidden: false, width: null, wrap: false, sticky: true },
    { propertyId: "a", hidden: false, width: 200, wrap: true, sticky: false },
    { propertyId: "b", hidden: true, width: null, wrap: false, sticky: false },
  ]);
});

test("mergeOrder keeps the saved order first, appends new, drops removed", () => {
  expect(mergeOrderRef(["b", "a"], ["a", "b", "c"])).toEqual(["b", "a", "c"]);
  expect(mergeOrderRef([], ["a", "b"])).toEqual(["a", "b"]);
  expect(mergeOrderRef(["a", "gone"], ["a", "b"])).toEqual(["a", "b"]);
});

const prop = (id: string): BoardProperty => ({
  id,
  rowKind: "session",
  name: id,
  type: "text",
  options: [],
  position: 0,
  width: null,
  editable: false,
  source: "derived",
});

const mkView = (columns: string[]): BoardView => ({
  id: "v1",
  rowKind: "session",
  name: "All",
  layout: "table",
  columns: columns.map((propertyId) => ({ propertyId, hidden: false, width: null })),
  sort: [],
  filters: [],
  groupBy: null,
  position: 0,
  createdTs: 0,
  updatedTs: 0,
});

const rows: BoardRow[] = [
  {
    rowId: "s1",
    rowKind: "session",
    status: "live",
    values: { a: "x", b: "y", c: "z" },
    derived: {
      label: "s1",
      paneId: null,
      paneIdSanitized: null,
      cwd: null,
      focused: false,
      hookState: "idle",
      hookSinceSec: null,
      herdrStatus: "idle",
      disagree: false,
      hasHookData: true,
      screenState: "idle",
    },
  },
];

function mount(view: BoardView, onPatch: (p: ViewPatch) => Promise<void>) {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const rootRef = { current: null as ReturnType<typeof createRoot> | null };
  const props = [prop("a"), prop("b"), prop("c")];
  act(() => {
    rootRef.current = createRoot(host);
  });
  act(() => {
    rootRef.current!.render(
      <MantineProvider theme={theme}>
        <BoardTable
          view={view}
          rows={rows}
          properties={props}
          onPatch={onPatch}
          onToast={() => {}}
          onPeek={() => {}}
          rowKind="work_item"
        />
      </MantineProvider>,
    );
  });
  return { host, rootRef };
}

async function clickHide(host: HTMLElement, columnName: string): Promise<void> {
  const headerBtn = Array.from(host.querySelectorAll("th button")).find(
    (b) => b.textContent === columnName,
  ) as HTMLElement;
  expect(headerBtn).toBeTruthy();
  act(() => {
    headerBtn.dispatchEvent(new MouseEvent("mousedown", { bubbles: true }));
    headerBtn.dispatchEvent(new MouseEvent("mouseup", { bubbles: true }));
    headerBtn.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  });
  // Mantine renders the dropdown into a body portal; poll briefly.
  let item: HTMLElement | null = null;
  for (let i = 0; i < 50 && !item; i++) {
    item = Array.from(document.body.querySelectorAll('[role="menuitem"]')).find(
      (el) => el.textContent === "Hide column",
    ) as HTMLElement;
    if (!item) await new Promise((r) => setTimeout(r, 20));
  }
  expect(item).toBeTruthy();
  act(() => {
    item!.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  });
}

test("hide preserves a reordered (server-acked) column order", async () => {
  const patches: ViewPatch[] = [];
  // The view already carries the dragged order b,a,c (as after a drag's
  // PATCH round-tripped). Hiding one column must keep that order.
  const { host, rootRef } = mount(mkView(["b", "a", "c"]), async (p) => {
    patches.push(p);
  });
  await clickHide(host, "a");
  expect(patches.length).toBe(1);
  expect(patches[0].columns).toEqual([
    { propertyId: "b", hidden: false, width: null, wrap: false, sticky: false },
    { propertyId: "a", hidden: true, width: null, wrap: false, sticky: false },
    { propertyId: "c", hidden: false, width: null, wrap: false, sticky: false },
  ]);
  act(() => {
    rootRef.current!.unmount();
  });
  host.remove();
});

test("hide on a view with no saved order materializes the full order", async () => {
  const patches: ViewPatch[] = [];
  const { host, rootRef } = mount(mkView([]), async (p) => {
    patches.push(p);
  });
  await clickHide(host, "b");
  expect(patches.length).toBe(1);
  expect(patches[0].columns).toEqual([
    { propertyId: "a", hidden: false, width: null, wrap: false, sticky: false },
    { propertyId: "b", hidden: true, width: null, wrap: false, sticky: false },
    { propertyId: "c", hidden: false, width: null, wrap: false, sticky: false },
  ]);
  act(() => {
    rootRef.current!.unmount();
  });
  host.remove();
});

test("mergeGroupOrder pins saved keys, drops ghosts, appends new groups", async () => {
  const { mergeGroupOrder } = await import("../components/Kanban");
  expect(mergeGroupOrder(null, ["a", "b"])).toEqual(["a", "b"]);
  expect(mergeGroupOrder([], ["a", "b"])).toEqual(["a", "b"]);
  expect(mergeGroupOrder(["b", "a", "ghost"], ["a", "b", "c"])).toEqual(["b", "a", "c"]);
});

test("resolveColumnMove accepts header-handle and column-body drops", async () => {
  const { resolveColumnMove } = await import("../components/Kanban");
  const order = ["a", "b", "c"];
  expect(resolveColumnMove("kcol:a", "kcol:c", order)).toEqual({ from: 0, to: 2 });
  expect(resolveColumnMove("kcol:a", "group:c", order)).toEqual({ from: 0, to: 2 });
  expect(resolveColumnMove("kcol:b", "group:b", order)).toBeNull();
  expect(resolveColumnMove("kcol:ghost", "group:c", order)).toBeNull();
});
