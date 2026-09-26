/**
 * The dashboard pushes new state every 2s (SSE) and refetches the board every
 * 5s. Both hand React brand-new arrays and callbacks. That must be a
 * re-render, never a remount: a remount blows away the open editor, its
 * half-typed draft, and the focus the PO is typing into.
 *
 * This is a regression test for exactly that — it fails against the old
 * flexRender-with-inline-arrow render path.
 */
import { expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { BoardTable } from "../components/BoardTable";
import { theme } from "../theme";
import type { BoardProperty, BoardRow, BoardView } from "../types";

const prop = (id: string, editable: boolean): BoardProperty => ({
  id,
  rowKind: "session",
  name: id,
  type: "text",
  options: [],
  position: 0,
  width: null,
  editable,
  source: editable ? "stored" : "derived",
});

const row = (rowId: string, note: string): BoardRow => ({
  rowId,
  rowKind: "session",
  status: "live",
  values: { "derived:label": rowId, "stored:note": note },
  derived: {
    label: rowId,
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
});

const view: BoardView = {
  id: "v1",
  rowKind: "session",
  name: "All",
  layout: "table",
  columns: [],
  sort: [],
  filters: [],
  groupBy: null,
  position: 0,
  createdTs: 0,
  updatedTs: 0,
};

function render(rootRef: { current: ReturnType<typeof createRoot> | null }) {
  // Fresh arrays and fresh callbacks on every pass — exactly what a poll does.
  const props = [prop("derived:label", false), prop("stored:note", true)];
  const rows = [row("s1", "alpha"), row("s2", "beta")];
  act(() => {
    rootRef.current!.render(
      <MantineProvider theme={theme}>
        <BoardTable
          view={{ ...view }}
          rows={rows}
          properties={props}
          onPatch={async () => {}}
          onToast={() => {}}
          onPeek={() => {}}
          rowKind="session"
        />
      </MantineProvider>,
    );
  });
}

test("an open cell editor keeps focus and its draft across a board refresh", () => {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const rootRef = { current: null as ReturnType<typeof createRoot> | null };
  act(() => {
    rootRef.current = createRoot(host);
  });
  render(rootRef);

  // Open the editor on the stored column of the first row.
  const cells = host.querySelectorAll("td.editable-cell");
  expect(cells.length).toBe(2);
  act(() => {
    (cells[0] as HTMLElement).click();
  });

  const input = host.querySelector("td.editable-cell.editing input") as HTMLInputElement;
  expect(input).toBeTruthy();
  input.focus();
  // Type into it without committing.
  act(() => {
    const setter = Object.getOwnPropertyDescriptor(
      window.HTMLInputElement.prototype,
      "value",
    )!.set!;
    setter.call(input, "half typed");
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
  expect(document.activeElement).toBe(input);

  // Three refreshes land while the PO is still typing.
  render(rootRef);
  render(rootRef);
  render(rootRef);

  const after = host.querySelector("td.editable-cell.editing input") as HTMLInputElement;
  expect(after).toBeTruthy();
  expect(after).toBe(input); // same DOM node => re-render, not remount
  expect(after.value).toBe("half typed");
  expect(document.activeElement).toBe(after);
});

test("an open header menu stays open across a board refresh", () => {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const rootRef = { current: null as ReturnType<typeof createRoot> | null };
  act(() => {
    rootRef.current = createRoot(host);
  });
  render(rootRef);

  // The column menu is a real floating Mantine Menu: click its target to
  // open it (aria-expanded flips; the portal paints async under happy-dom,
  // so open state — not portal DOM — is the stable signal).
  const target = host.querySelector(
    'th button[aria-haspopup="menu"]',
  ) as HTMLElement;
  expect(target).toBeTruthy();
  act(() => {
    target.dispatchEvent(new MouseEvent("mousedown", { bubbles: true }));
    target.dispatchEvent(new MouseEvent("mouseup", { bubbles: true }));
    target.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  });
  expect(target.getAttribute("aria-expanded")).toBe("true");

  render(rootRef);
  render(rootRef);

  // Same open menu, not remounted shut by the refresh.
  const after = host.querySelector(
    'th button[aria-haspopup="menu"]',
  ) as HTMLElement;
  expect(after).toBe(target); // same DOM node => re-render, not remount
  expect(after.getAttribute("aria-expanded")).toBe("true");
  act(() => {
    rootRef.current!.unmount();
  });
  host.remove();
});
