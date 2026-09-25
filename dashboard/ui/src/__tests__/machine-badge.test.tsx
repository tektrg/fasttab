/**
 * R21: the Agents view shows a machine badge and a duplicate-session marker
 * from server flags, driven entirely by the `derived:machine` property value
 * and `row.derived.duplicateOfSession` — never computed here.
 *
 * `local` (the overwhelming majority of rows) renders as plain text, not a
 * badge — a colored pill on every single row would be noise. Any other
 * machine name gets a visible badge, and a row flagged as a live-elsewhere
 * duplicate (R6: both rows kept, never merged) shows a "dup" marker next to
 * it.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { DerivedCell } from "../components/EditableCell";
import { theme } from "../theme";
import type { BoardProperty, BoardRow } from "../types";

const MACHINE_PROP: BoardProperty = {
  id: "derived:machine",
  rowKind: "session",
  name: "MACHINE",
  type: "text",
  options: [],
  source: "derived",
  editable: false,
  position: 12,
};

function boardRow(machine: string, duplicateOfSession?: string | null): BoardRow {
  return {
    rowKind: "session",
    rowId: "r1",
    status: "live",
    derived: {
      paneId: machine === "local" ? "w1:p1" : `${machine}:w2:p1`,
      paneIdSanitized: machine === "local" ? "w1-p1" : `${machine}-w2-p1`,
      label: "worker-1",
      cwd: "/tmp",
      focused: false,
      hookState: "idle",
      hookSinceSec: 1,
      herdrStatus: "idle",
      disagree: false,
      hasHookData: machine === "local",
      screenState: "WAITING",
      machine,
      duplicateOfSession: duplicateOfSession ?? null,
    },
    values: { "derived:machine": machine },
  };
}

function renderCell(row: BoardRow): { html: string; unmount: () => void } {
  const container = document.createElement("div");
  document.body.appendChild(container);
  const root = createRoot(container);
  act(() => {
    root.render(
      <MantineProvider theme={theme}>
        <table>
          <tbody>
            <tr>
              <DerivedCell property={MACHINE_PROP} row={row} />
            </tr>
          </tbody>
        </table>
      </MantineProvider>,
    );
  });
  return {
    html: container.innerHTML,
    unmount: () => {
      act(() => root.unmount());
      container.remove();
    },
  };
}

afterEach(() => {
  document.body.innerHTML = "";
});

describe("MACHINE column badge (R21)", () => {
  test("a local row renders plain text, no badge", () => {
    const { html, unmount } = renderCell(boardRow("local"));
    expect(html).toContain("local");
    expect(html).not.toContain("st-machine-remote");
    unmount();
  });

  test("a remote row renders a visible badge naming the machine", () => {
    const { html, unmount } = renderCell(boardRow("air-m1"));
    expect(html).toContain("st-machine-remote");
    expect(html).toContain("air-m1");
    unmount();
  });

  test("a duplicate-session row shows the dup marker alongside the badge", () => {
    const { html, unmount } = renderCell(boardRow("air-m1", "shared-uuid"));
    expect(html).toContain("st-machine-remote");
    expect(html).toContain("st-machine-dup");
    expect(html).toContain("dup");
    unmount();
  });

  test("a non-duplicate remote row shows no dup marker", () => {
    const { html, unmount } = renderCell(boardRow("air-m1", null));
    expect(html).not.toContain("st-machine-dup");
    unmount();
  });
});
