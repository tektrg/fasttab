/**
 * Phase 9 card tests: MEM/CTX line by default, amber countdown badge, and
 * the CardMenu reach items.
 */
import { describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { KanbanCard } from "../components/Kanban";
import { CardMenu } from "../components/CardMenu";
import { theme } from "../theme";
import type { BoardRow } from "../types";

function cardRow(opts: {
  contextPct?: number | null;
  autocompactPct?: number | null;
  memoryBytes?: number | null;
} = {}): BoardRow {
  return {
    rowKind: "session",
    rowId: "sess-card",
    status: "live",
    contextPct: opts.contextPct,
    autocompactPct: opts.autocompactPct,
    derived: {
      paneId: "w8:pX",
      paneIdSanitized: "w8-pX",
      label: "card worker",
      cwd: null,
      focused: false,
      hookState: "idle",
      hookSinceSec: 1,
      herdrStatus: "idle",
      disagree: false,
      hasHookData: true,
      screenState: "WAITING",
      memoryBytes: opts.memoryBytes ?? null,
      contextPct: opts.contextPct,
      autocompactPct: opts.autocompactPct,
    },
    values: { "derived:label": "card worker" },
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

describe("KanbanCard context line", () => {
  test("MEM + CTX render by default, no column config", () => {
    const { host, unmount } = mount(
      <KanbanCard
        row={cardRow({ contextPct: 21, memoryBytes: 189 * 1024 * 1024 })}
        extraFields={[]}
        onToast={() => {}}
        onRefetch={() => {}}
      />,
    );
    expect(host.textContent).toContain("MEM 189.0 MB · CTX 21%");
    unmount();
  });

  test("unknown readings render —, and 0 appears nowhere", () => {
    const { host, unmount } = mount(
      <KanbanCard
        row={cardRow({})}
        extraFields={[]}
        onToast={() => {}}
        onRefetch={() => {}}
      />,
    );
    expect(host.textContent).toContain("MEM — · CTX —");
    // No autocompact badge without a countdown.
    expect(host.textContent).not.toContain("to autocompact");
    unmount();
  });

  test("countdown renders as its own amber badge, not merged into CTX", () => {
    const { host, unmount } = mount(
      <KanbanCard
        row={cardRow({ contextPct: 87, autocompactPct: 12 })}
        extraFields={[]}
        onToast={() => {}}
        onRefetch={() => {}}
      />,
    );
    expect(host.textContent).toContain("CTX 87%");
    expect(host.textContent).toContain("12% to autocompact");
    unmount();
  });
});

describe("CardMenu reach items", () => {
  test("reach items sit above the ladder, separated", async () => {
    const row = cardRow({});
    (row as { actions: unknown }).actions = {
      stop: { enabled: true, needsConfirm: false, reason: "idle" },
      archive: { enabled: true, needsConfirm: false, reason: "board-only" },
    };
    const { host, unmount } = mount(
      <CardMenu row={row} onToast={() => {}} onDone={() => {}} />,
    );
    const target = [...host.querySelectorAll("button")].find(
      (b) => b.textContent === "⋯",
    )!;
    await act(async () => {
      target.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    const items = [...document.querySelectorAll('[role="menuitem"]')].map(
      (el) => el.textContent,
    );
    const openIdx = items.findIndex((t) => t === "Open pane");
    const sendIdx = items.findIndex((t) => t === "Send message…");
    const stopIdx = items.findIndex((t) => t === "Stop agent");
    expect(openIdx).toBeGreaterThanOrEqual(0);
    expect(sendIdx).toBeGreaterThanOrEqual(0);
    expect(stopIdx).toBeGreaterThanOrEqual(0);
    expect(Math.max(openIdx, sendIdx)).toBeLessThan(stopIdx);
    unmount();
    document.querySelectorAll('[role="menu"]').forEach((m) => m.remove());
  });

  test("two-stage End: stopped pane shows Close pane, not Stop agent", async () => {
    const row = cardRow({});
    (row as { actions: unknown }).actions = {
      stop: { enabled: false, needsConfirm: false, reason: "already stopped" },
      close: { enabled: true, needsConfirm: false, reason: "stopped" },
      archive: { enabled: true, needsConfirm: false, reason: "board-only" },
    };
    const { host, unmount } = mount(
      <CardMenu row={row} onToast={() => {}} onDone={() => {}} />,
    );
    const target = [...host.querySelectorAll("button")].find(
      (b) => b.textContent === "⋯",
    )!;
    await act(async () => {
      target.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    const items = [...document.querySelectorAll('[role="menuitem"]')].map(
      (el) => el.textContent,
    );
    expect(items.some((t) => t === "Close pane")).toBe(true);
    expect(items.some((t) => t === "Stop agent")).toBe(false);
    unmount();
    document.querySelectorAll('[role="menu"]').forEach((m) => m.remove());
  });

  test("two-stage End: gone pane shows neither Stop agent nor Close pane", async () => {
    const row = cardRow({});
    (row as { actions: unknown }).actions = {
      stop: { enabled: false, needsConfirm: false, reason: "pane is gone" },
      close: { enabled: false, needsConfirm: false, reason: "pane is already gone" },
      archive: { enabled: true, needsConfirm: false, reason: "board-only" },
    };
    const { host, unmount } = mount(
      <CardMenu row={row} onToast={() => {}} onDone={() => {}} />,
    );
    const target = [...host.querySelectorAll("button")].find(
      (b) => b.textContent === "⋯",
    )!;
    await act(async () => {
      target.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    const items = [...document.querySelectorAll('[role="menuitem"]')].map(
      (el) => el.textContent,
    );
    expect(items.some((t) => t === "Stop agent")).toBe(false);
    expect(items.some((t) => t === "Close pane")).toBe(false);
    unmount();
    document.querySelectorAll('[role="menu"]').forEach((m) => m.remove());
  });
});
