/**
 * Wave-2 wiring: the gesture that opens the peek panel.
 *
 * A table row click used to raise the terminal and jump focus to the pane —
 * a whole-desktop move on a misclick. It now opens the panel, and focusing
 * is the panel's own deliberate button. A kanban card is its own drag
 * handle, so the card's click has to tell a click from a finished drag by
 * the same 6px the dnd sensor uses, or every drop would also open a panel.
 *
 * fetch is not stubbed here: nothing in these paths fetches. Assertions are
 * scoped to the mounted host, never document.body — bun runs every test file
 * in one process and other files leave nodes behind.
 */
import { describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { DndContext } from "@dnd-kit/core";
import { MantineProvider } from "@mantine/core";
import { BoardTable } from "../components/BoardTable";
import { KanbanCard } from "../components/Kanban";
import { RowPanel, clampPanelWidth } from "../components/RowPanel";
import { theme } from "../theme";
import type { BoardProperty, BoardRow, BoardView } from "../types";

function prop(id: string, editable: boolean): BoardProperty {
  return {
    id,
    rowKind: "session",
    name: id,
    type: "text",
    options: [],
    source: editable ? "stored" : "derived",
    editable,
    position: 0,
  };
}

function row(rowId: string, label: string): BoardRow {
  return {
    rowKind: "session",
    rowId,
    status: "live",
    derived: {
      paneId: `w8:${rowId}`,
      paneIdSanitized: `w8-${rowId}`,
      label,
      cwd: null,
      focused: false,
      hookState: "idle",
      hookSinceSec: 1,
      herdrStatus: "idle",
      disagree: false,
      hasHookData: true,
      screenState: "WAITING",
    },
    values: { "derived:label": label },
  };
}

const view: BoardView = {
  id: "v1",
  rowKind: "session",
  name: "v",
  layout: "table",
  columns: [],
  sort: [],
  filters: [],
  groupBy: null,
  position: 0,
  createdTs: 0,
  updatedTs: 0,
};

function mount(node: React.ReactNode) {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  act(() => {
    root.render(<MantineProvider theme={theme}>{node}</MantineProvider>);
  });
  return {
    host,
    unmount: () => {
      act(() => root.unmount());
      host.remove();
    },
  };
}

function mountTable(onPeek: (rowId: string) => void, peekId?: string | null) {
  return mount(
    <BoardTable
      view={view}
      rows={[row("s1", "alpha"), row("s2", "beta")]}
      properties={[prop("derived:label", false)]}
      onPatch={async () => {}}
      onToast={() => {}}
      onPeek={onPeek}
      peekId={peekId}
      rowKind="session"
    />,
  );
}

/** The first body row's first data cell — clicking a cell is what a user
 *  actually does; the handler lives on the <tr>. */
function firstRowCell(host: HTMLElement): HTMLElement {
  const tr = host.querySelectorAll("tbody tr")[0] as HTMLElement;
  return tr.querySelectorAll("td")[1] as HTMLElement;
}

describe("peek wiring", () => {
  test("a table row click opens the panel for that row", () => {
    const peeked: string[] = [];
    const { host, unmount } = mountTable((id) => peeked.push(id));
    act(() => {
      firstRowCell(host).dispatchEvent(
        new MouseEvent("click", { bubbles: true }),
      );
    });
    expect(peeked).toEqual(["s1"]);
    unmount();
  });

  test("the peeked row is marked, and only that row", () => {
    const { host, unmount } = mountTable(() => {}, "s2");
    const marked = [...host.querySelectorAll("tbody tr")].filter((tr) =>
      tr.className.includes("row-peeked"),
    );
    expect(marked.length).toBe(1);
    expect(marked[0].textContent).toContain("beta");
    unmount();
  });

  test("the bulk composer stays hidden until rows are ticked", () => {
    const { host, unmount } = mountTable(() => {});
    expect(host.querySelector("#table-composer")).toBeNull();
    const box = host.querySelector(
      'input[aria-label="select s1"]',
    ) as HTMLInputElement;
    act(() => {
      box.click();
    });
    expect(host.querySelector("#table-composer")).not.toBeNull();
    unmount();
  });

  test("a kanban card click opens the panel; a drag does not", () => {
    const peeked: string[] = [];
    const card = (
      <DndContext>
        <KanbanCard
          row={row("s1", "alpha")}
          extraFields={[]}
          onToast={() => {}}
          onRefetch={() => {}}
          onPeek={(id) => peeked.push(id)}
        />
      </DndContext>
    );
    const { host, unmount } = mount(card);
    const el = host.querySelector(".kcard") as HTMLElement;

    // A click: pointer goes down and comes up in the same place.
    act(() => {
      el.dispatchEvent(
        new MouseEvent("pointerdown", { bubbles: true, clientX: 10, clientY: 10 }),
      );
      el.dispatchEvent(
        new MouseEvent("click", { bubbles: true, clientX: 10, clientY: 10 }),
      );
    });
    expect(peeked).toEqual(["s1"]);

    // A drag: the trailing click lands far from where the pointer went down.
    act(() => {
      el.dispatchEvent(
        new MouseEvent("pointerdown", { bubbles: true, clientX: 10, clientY: 10 }),
      );
      el.dispatchEvent(
        new MouseEvent("click", { bubbles: true, clientX: 90, clientY: 60 }),
      );
    });
    expect(peeked).toEqual(["s1"]);
    unmount();
  });
});

describe("peek panel width", () => {
  test("clamps to a usable band and always leaves board visible", () => {
    // Below the floor: a panel narrower than this cannot hold the composer.
    expect(clampPanelWidth(50, 1600)).toBe(320);
    // Above the ceiling: the board it is a peek at must stay clickable.
    expect(clampPanelWidth(5000, 1600)).toBe(1440);
    // In band: taken as asked, rounded to a whole pixel.
    expect(clampPanelWidth(612.4, 1600)).toBe(612);
  });

  test("a narrow window keeps the floor rather than inverting the band", () => {
    // viewport - 160 would be 240, below the 320 floor. The floor wins, so
    // the clamp can never return a max lower than its own min.
    expect(clampPanelWidth(480, 400)).toBe(320);
    expect(clampPanelWidth(100, 400)).toBe(320);
  });
});

/** The grip's handler chain. NOTE: the bug that shipped here was CSS, not
 *  JS — Mantine's drawer content has no `position`, so the absolutely placed
 *  grip anchored to the pointer-events:none layer above it and went deaf.
 *  happy-dom has no layout or inherited pointer-events, so no unit test can
 *  see that; this only guards the part that IS testable — that a
 *  down/move/up on the grip resizes and persists. */
describe("peek panel resize handler", () => {
  test("a drag on the grip commits and persists the new width", () => {
    const realFetch = globalThis.fetch;
    globalThis.fetch = (async () => ({
      json: async () => ({ ok: true, entries: [], lines: [] }),
    })) as unknown as typeof fetch;
    try {
      window.localStorage.removeItem("chief-dashboard-peek-width");
      const { unmount } = mount(
        <RowPanel
          row={row("s1", "alpha")}
          properties={[]}
          rowKind="session"
          onClose={() => {}}
          onToast={() => {}}
          onRefetch={() => {}}
          onFocusPane={() => {}}
        />,
      );
      // The drawer portals out of the mount host, so reach for it by class.
      const grip = document.querySelector(".rp-resize") as HTMLElement;
      expect(grip).not.toBeNull();

      const at = (type: string, clientX: number) =>
        new MouseEvent(type, { bubbles: true, clientX });
      act(() => {
        grip.dispatchEvent(at("pointerdown", 1000));
        grip.dispatchEvent(at("pointermove", 900));
        grip.dispatchEvent(at("pointerup", 900));
      });

      const saved = Number(
        window.localStorage.getItem("chief-dashboard-peek-width"),
      );
      expect(saved).toBe(clampPanelWidth(window.innerWidth - 900, window.innerWidth));
      expect(document.body.classList.contains("rp-resizing")).toBe(false);
      unmount();
    } finally {
      globalThis.fetch = realFetch;
    }
  });
});
