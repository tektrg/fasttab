/**
 * RowDetailExtras (dashboard-move phase 2b): picks the Review card, the
 * plan card, or the latest-message/form view by row state, and gets out of
 * the way entirely for an ended row.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { RowDetailExtras } from "../components/RowDetailExtras";
import { theme } from "../theme";
import type { BoardRow } from "../types";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

function stubFetch() {
  globalThis.fetch = (async () => ({ json: async () => ({ ok: true }) })) as unknown as typeof fetch;
}

function baseRow(over: Partial<BoardRow["derived"]> = {}): BoardRow {
  return {
    rowKind: "session",
    rowId: "alpha",
    status: "live",
    derived: {
      paneId: "w8:p1",
      paneIdSanitized: "w8-p1",
      label: "alpha",
      cwd: null,
      focused: false,
      hookState: "blocked",
      hookSinceSec: 1,
      herdrStatus: "idle",
      disagree: false,
      hasHookData: true,
      screenState: "NEEDS_HUMAN",
      ...over,
    },
    values: {},
  };
}

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

async function settle() {
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
}

describe("RowDetailExtras", () => {
  test("a plain tool permission box renders the Review card", async () => {
    stubFetch();
    const row = baseRow({
      screenPermission: {
        tool: "Bash",
        detail: "rm -rf /tmp/x",
        title: "Do you want to proceed?",
        options: [{ index: 1, label: "Yes" }, { index: 2, label: "No, and tell Claude what to do differently" }],
        cursorIndex: 1,
      },
    });
    const m = mount(<RowDetailExtras row={row} onToast={() => {}} />);
    await settle();
    expect(m.host.querySelector(".review-card")).not.toBe(null);
    expect(m.host.querySelector(".plan-card")).toBe(null);
    m.unmount();
  });

  test("a plan-approval box renders the Plan card, not Review", async () => {
    stubFetch();
    const row = baseRow({
      screenPermission: {
        tool: "ExitPlanMode",
        detail: null,
        title: "Claude has written up a plan and is ready to execute. Would you like to proceed?",
        options: [{ index: 1, label: "Yes, and use auto mode" }, { index: 2, label: "Yes, manually approve edits" }],
        cursorIndex: 1,
        kind: "plan",
        planPath: "~/.claude/plans/x.md",
      },
    });
    const m = mount(<RowDetailExtras row={row} onToast={() => {}} />);
    await settle();
    expect(m.host.querySelector(".plan-card")).not.toBe(null);
    expect(m.host.querySelector(".review-card")).toBe(null);
    m.unmount();
  });

  test("no permission box: latest message / form view instead", async () => {
    stubFetch();
    const row = baseRow({ screenPermission: null, hookState: "idle", screenState: "WAITING" });
    const m = mount(<RowDetailExtras row={row} onToast={() => {}} />);
    await settle();
    expect(m.host.querySelector(".review-card")).toBe(null);
    expect(m.host.querySelector(".plan-card")).toBe(null);
    m.unmount();
  });

  test("an ended row renders nothing", async () => {
    stubFetch();
    const row: BoardRow = { ...baseRow(), status: "ended" };
    const m = mount(<RowDetailExtras row={row} onToast={() => {}} />);
    await settle();
    // Mantine injects its own <style> into the host — assert on actual
    // rendered markup, not raw textContent.
    expect(m.host.querySelectorAll(".review-card, .plan-card, .latest-message, .form-card").length).toBe(0);
    m.unmount();
  });
});
