/**
 * Phase 2a (docs/plans/2026-09-26-agentbar-mobile-web.md): the phone "Needs
 * You" inbox. Three things this must prove:
 *
 *  1. Needs You lists blocked agents first (ahead of a question/feed-broken
 *     entry), same list App.tsx already had — only the ordering is new.
 *  2. Tapping a row opens the full-screen sheet for that pane.
 *  3. `App` mounts a completely separate tree on a phone-width viewport —
 *     no desktop chrome (`<table>` from BoardTable/Kanban, the view
 *     switcher, the bulk bar) ever renders, not just hidden by CSS.
 *
 * fetch and EventSource are stubbed per test (happy-dom implements neither
 * fully) — same pattern composer.test.tsx uses for fetch.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { PhoneInbox } from "../components/phone/PhoneInbox";
import App from "../App";
import { theme } from "../theme";
import { FEED_ORDER, type BoardRow, type BoardState, type FeedSnapshot, type FullState, type NeedsYouRow } from "../types";

/** One clean, unbroken snapshot per feed — enough for FeedStrip (the
 *  desktop-only App test mounts it) to read without crashing. Real state
 *  payloads always carry every FEED_ORDER key; this test data mirrors that
 *  invariant rather than a partial stub of it. */
function cleanFeeds(): FullState["feeds"] {
  const feed: FeedSnapshot = {
    name: "x",
    refreshIntervalSec: 5,
    lastSuccessTs: 0,
    lastAttemptTs: 0,
    lastDurationSec: 0,
    ageSec: 0,
    broken: false,
    warming: false,
    error: null,
    data: null,
  };
  const feeds = {} as FullState["feeds"];
  for (const name of FEED_ORDER) feeds[name] = { ...feed, name };
  return feeds;
}

/** Flush the microtask queue enough times for a stubbed fetch's
 *  `await fetch(...)` -> `await r.json()` -> `setState(...)` chain to
 *  settle and re-render before the next assertion reads the DOM. */
async function flush() {
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
  });
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

function needsYouRow(kind: NeedsYouRow["kind"], label: string, paneId: string | null): NeedsYouRow {
  return {
    kind,
    urgency: 1,
    label,
    paneId,
    detail: `${kind} detail`,
    sinceSec: 30,
    identity: null,
  };
}

function boardRow(rowId: string, paneId: string, opts: Partial<BoardRow> = {}): BoardRow {
  return {
    rowKind: "session",
    rowId,
    status: "live",
    derived: {
      paneId,
      paneIdSanitized: paneId.replace(":", "-"),
      label: rowId,
      cwd: null,
      focused: false,
      hookState: "idle",
      hookSinceSec: 42,
      herdrStatus: "idle",
      disagree: false,
      hasHookData: true,
      screenState: "WORKING",
    },
    values: { "derived:label": rowId },
    ...opts,
  };
}

function fullState(needsYou: NeedsYouRow[]): FullState {
  return {
    serverTimeTs: 0,
    feeds: cleanFeeds(),
    computed: { needsYou, agents: [], disagreementCount: 0, residueCount: 0 },
  };
}

const realFetch = globalThis.fetch;
const realEventSource = (globalThis as { EventSource?: unknown }).EventSource;

afterEach(() => {
  globalThis.fetch = realFetch;
  (globalThis as { EventSource?: unknown }).EventSource = realEventSource;
  document.body.innerHTML = "";
});

/** happy-dom has no EventSource — App's useDashboardState opens one on
 *  mount. A no-op stand-in is enough: the tests below drive state through
 *  the initial /api/state fetch, never a pushed SSE frame. */
class FakeEventSource {
  onmessage: ((ev: { data: string }) => void) | null = null;
  close() {}
}

function stubBoardFetch(board: BoardState, state?: FullState) {
  globalThis.fetch = (async (url: unknown) => {
    if (url === "/api/state" && state) {
      return { ok: true, json: async () => state } as Response;
    }
    if (typeof url === "string" && url.startsWith("/api/board")) {
      return { ok: true, json: async () => board } as Response;
    }
    return { ok: true, json: async () => ({}) } as Response;
  }) as typeof fetch;
  (globalThis as { EventSource?: unknown }).EventSource = FakeEventSource;
}

describe("PhoneInbox: Needs You ordering", () => {
  test("blocked agents list ahead of a question or feed-broken entry", () => {
    const state = fullState([
      needsYouRow("feed-broken", "feed", null),
      needsYouRow("question", "picker-agent", "w1:p1"),
      needsYouRow("blocked", "blocked-agent", "w1:p2"),
    ]);
    const { host, unmount } = mount(<PhoneInbox state={state} onToast={() => {}} />);
    const labels = [...host.querySelectorAll(".phone-row-label")].map((n) => n.textContent);
    expect(labels[0]).toBe("blocked-agent");
    expect(labels).toContain("picker-agent");
    expect(labels).toContain("feed");
    unmount();
  });
});

describe("PhoneInbox: sheet opens", () => {
  test("tapping a Needs You row opens the full-screen sheet for its pane", async () => {
    const state = fullState([needsYouRow("blocked", "blocked-agent", "w1:p2")]);
    const board: BoardState = {
      rowKind: "session",
      properties: [],
      rows: [boardRow("r1", "w1:p2")],
    };
    stubBoardFetch(board);
    const { host, unmount } = mount(<PhoneInbox state={state} onToast={() => {}} />);
    await flush(); // let the board fetch resolve so the pane->row lookup can find r1
    act(() => {
      (host.querySelector(".phone-row") as HTMLElement).click();
    });
    // The sheet is a Mantine Modal — it portals to document.body, not the
    // mount host, so look for it there.
    const sheetTitle = document.querySelector(".phone-sheet-title");
    expect(sheetTitle?.textContent).toContain("r1");
    unmount();
  });

  test("tapping a Working row opens the sheet directly (no pane lookup needed)", async () => {
    const state = fullState([]);
    const board: BoardState = {
      rowKind: "session",
      properties: [],
      rows: [boardRow("worker-9", "w1:p9")],
    };
    stubBoardFetch(board);
    const { host, unmount } = mount(<PhoneInbox state={state} onToast={() => {}} />);
    // Working starts expanded — the row is on screen without an extra tap.
    await flush();
    const row = host.querySelector('[data-section="working"] .phone-row') as HTMLElement;
    expect(row).not.toBeNull();
    act(() => {
      row.click();
    });
    const sheetTitle = document.querySelector(".phone-sheet-title");
    expect(sheetTitle?.textContent).toContain("worker-9");
    unmount();
  });
});

describe("PhoneInbox: no desktop chrome", () => {
  test("renders no <table> — BoardTable/Kanban are never mounted here", async () => {
    const state = fullState([]);
    const board: BoardState = { rowKind: "session", properties: [], rows: [boardRow("r1", "w1:p1")] };
    stubBoardFetch(board);
    const { host, unmount } = mount(<PhoneInbox state={state} onToast={() => {}} />);
    await flush();
    expect(host.querySelector("table")).toBeNull();
    unmount();
  });
});

describe("App: phone layout swap", () => {
  function stubMatchMedia(phoneMatches: boolean) {
    window.matchMedia = ((query: string) => ({
      matches: query.includes("max-width") ? phoneMatches : false,
      media: query,
      onchange: null,
      addListener: () => {},
      removeListener: () => {},
      addEventListener: () => {},
      removeEventListener: () => {},
      dispatchEvent: () => false,
    })) as unknown as typeof window.matchMedia;
  }

  test("phone viewport: App mounts the phone header, never the desktop board", async () => {
    stubMatchMedia(true);
    const state = fullState([]);
    stubBoardFetch({ rowKind: "session", properties: [], rows: [] }, state);
    const { host, unmount } = mount(<App />);
    await flush();
    expect(host.querySelector("h1")?.textContent).toBe("AGENTBAR");
    expect(host.querySelector("#board-body")).toBeNull();
    expect(host.querySelector("#needsyou-body")).toBeNull();
    unmount();
  });

  test("desktop viewport: App mounts the existing board chrome, unchanged", async () => {
    stubMatchMedia(false);
    const state = fullState([]);
    stubBoardFetch({ rowKind: "session", properties: [], rows: [] }, state);
    const { host, unmount } = mount(<App />);
    await flush();
    expect(host.querySelector("h1")?.textContent).toBe("CHIEF DASHBOARD");
    expect(host.querySelector("#needsyou-body")).not.toBeNull();
    unmount();
  });
});
