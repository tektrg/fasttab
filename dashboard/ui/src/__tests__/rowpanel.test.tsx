/**
 * Row peek panel tests: content renders, a row swap REPLACES that content
 * (the drawer never re-opens), the three message statuses stay
 * distinguishable, a truncated stub says it is one, and the pane screen
 * repeats the server's error verbatim.
 *
 * fetch is stubbed per test and answered BY URL, never from a queue: bun
 * runs every test file in one process, so another file's in-flight save can
 * land in this stub. Assertions filter by URL for the same reason.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { RowPanel } from "../components/RowPanel";
import { PaneScreen } from "../components/PaneScreen";
import { theme } from "../theme";
import type {
  BoardProperty,
  BoardRow,
  SessionHistoryEntry,
} from "../types";

const NOW = Date.now() / 1000;

function boardRow(rowId: string, over: Partial<BoardRow> = {}): BoardRow {
  return {
    rowKind: "session",
    rowId,
    status: "live",
    derived: {
      paneId: `w8:${rowId}`,
      paneIdSanitized: `w8-${rowId}`,
      label: rowId,
      cwd: "/Users/trungluong/01_Project/AptusFit",
      focused: false,
      hookState: "idle",
      hookSinceSec: 1,
      herdrStatus: "idle",
      disagree: false,
      hasHookData: true,
      screenState: "WAITING",
      memoryBytes: 2 * 1024 * 1024 * 1024,
      contextPct: 21,
    },
    values: {
      "derived:label": `label-${rowId}`,
      "derived:state": "idle",
      "derived:screen": "WAITING",
      "derived:lastline": `last line for ${rowId}`,
      "note": `note-${rowId}`,
    },
    ...over,
  };
}

const PROPS: BoardProperty[] = [
  {
    id: "derived:label",
    rowKind: "session",
    name: "Label",
    type: "text",
    options: [],
    source: "derived",
    editable: false,
    position: 0,
  },
  {
    id: "note",
    rowKind: "session",
    name: "Note",
    type: "text",
    options: [],
    source: "stored",
    editable: true,
    position: 1,
  },
];

function entry(over: Partial<SessionHistoryEntry> = {}): SessionHistoryEntry {
  return {
    id: 1,
    action: "message",
    ts: NOW - 240,
    actor: "po",
    text: "hello worker",
    status: "sent",
    ...over,
  };
}

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

/** Answer by URL prefix. Anything unmatched (a foreign call bleeding in
 *  from another test file) gets a bare ok. */
function stubFetch(routes: { history?: unknown; screen?: unknown } = {}) {
  const calls: string[] = [];
  globalThis.fetch = (async (url: unknown) => {
    const u = String(url);
    calls.push(u);
    if (u.startsWith("/api/session/history")) {
      return { json: async () => routes.history ?? { ok: true, entries: [] } };
    }
    if (u.startsWith("/api/pane/screen")) {
      return {
        json: async () =>
          routes.screen ?? { ok: true, lines: ["line one"], readTs: NOW },
      };
    }
    return { json: async () => ({ ok: true }) };
  }) as typeof fetch;
  return calls;
}

function mount(node: React.ReactNode) {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  act(() => {
    root.render(<MantineProvider theme={theme}>{node}</MantineProvider>);
  });
  return {
    // The drawer portals out of `host`, so panel assertions read its
    // content root instead — document.body carries other test files'
    // leftovers (and Mantine's injected stylesheet) in the shared process.
    text: () =>
      document.querySelector(".rp-content")?.textContent ??
      host.textContent ??
      "",
    query: (sel: string) => host.querySelector(sel),
    render: (next: React.ReactNode) =>
      act(() => {
        root.render(<MantineProvider theme={theme}>{next}</MantineProvider>);
      }),
    unmount: () => {
      act(() => root.unmount());
      host.remove();
    },
  };
}

function panel(row: BoardRow | null) {
  return (
    <RowPanel
      row={row}
      properties={PROPS}
      rowKind="session"
      onClose={() => {}}
      onToast={() => {}}
      onRefetch={() => {}}
      onFocusPane={() => {}}
    />
  );
}

async function settle() {
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
}

describe("RowPanel", () => {
  test("renders the label, pane id and field values", async () => {
    stubFetch();
    const m = mount(panel(boardRow("alpha")));
    await settle();
    expect(m.text()).toContain("label-alpha");
    expect(m.text()).toContain("w8:alpha");
    expect(m.text()).toContain("Note");
    expect(m.text()).toContain("note-alpha");
    expect(m.text()).toContain("last line for alpha");
    // Pulse: MEM/CTX rendered from the shared formatters, never raw bytes.
    expect(m.text()).toContain("MEM 2.0 GB");
    expect(m.text()).toContain("CTX 21%");
    m.unmount();
  });

  test("row swap replaces the content — old row gone, new row present", async () => {
    stubFetch();
    const m = mount(panel(boardRow("alpha")));
    await settle();
    expect(m.text()).toContain("label-alpha");
    m.render(panel(boardRow("beta")));
    await settle();
    expect(m.text()).not.toContain("label-alpha");
    expect(m.text()).toContain("label-beta");
    expect(m.text()).toContain("w8:beta");
    m.unmount();
  });

  test("message log distinguishes sent, queued and failed", async () => {
    stubFetch({
      history: {
        ok: true,
        entries: [
          entry({ id: 3, status: "failed", text: "never landed", reason: "NOT SUBMITTED — stuck in the box", ts: NOW - 60 }),
          entry({ id: 2, status: "queued", text: "mid turn", ts: NOW - 120 }),
          entry({ id: 1, status: "sent", text: "hello worker", ts: NOW - 240 }),
        ],
      },
    });
    const m = mount(panel(boardRow("alpha")));
    await settle();
    const text = m.text();
    expect(text).toContain("hello worker");
    expect(text).toContain("mid turn");
    expect(text).toContain("queued — lands when the turn ends. Do not re-send.");
    expect(text).toContain("FAILED — this message never arrived");
    expect(text).toContain("NOT SUBMITTED — stuck in the box");
    // Loud styling is part of the contract, not decoration: a failed entry
    // that renders like a sent one is unreadable at a glance.
    expect(document.querySelectorAll(".rp-msg-failed").length).toBe(1);
    m.unmount();
  });

  test("oldest at top: the newest message sits nearest the composer", async () => {
    stubFetch({
      history: {
        ok: true,
        entries: [
          entry({ id: 2, text: "newest", ts: NOW - 10 }),
          entry({ id: 1, text: "oldest", ts: NOW - 900 }),
        ],
      },
    });
    const m = mount(panel(boardRow("alpha")));
    await settle();
    const bodies = [...document.querySelectorAll(".rp-msg-text")].map(
      (n) => n.textContent,
    );
    expect(bodies).toEqual(["oldest", "newest"]);
    m.unmount();
  });

  test("ladder actions render as subordinate context, not conversation", async () => {
    stubFetch({
      history: {
        ok: true,
        entries: [entry({ id: 5, action: "compact", text: null, status: "sent", ts: NOW - 30 })],
      },
    });
    const m = mount(panel(boardRow("alpha")));
    await settle();
    expect(document.querySelectorAll(".rp-msg-ladder").length).toBe(1);
    expect(document.querySelectorAll(".rp-msg-text").length).toBe(0);
    m.unmount();
  });

  test("truncated entries say only 80 characters were recorded", async () => {
    stubFetch({
      history: {
        ok: true,
        entries: [entry({ text: "a stub of the original", truncated: true })],
      },
    });
    const m = mount(panel(boardRow("alpha")));
    await settle();
    expect(m.text()).toContain("only the first 80 characters were recorded");
    m.unmount();
  });

  test("empty history says so rather than showing a blank band", async () => {
    stubFetch({ history: { ok: true, entries: [] } });
    const m = mount(panel(boardRow("alpha")));
    await settle();
    expect(m.text()).toContain("no messages to this worker yet");
    m.unmount();
  });
});

describe("PaneScreen", () => {
  test("ok:false renders the server's error verbatim", async () => {
    stubFetch({ screen: { ok: false, error: "pane w8:p38 is gone" } });
    const m = mount(<PaneScreen paneId="w8:p38" />);
    await settle();
    expect(m.text()).toContain("pane w8:p38 is gone");
    m.unmount();
  });

  test("no paneId renders nothing and reads no pane", async () => {
    const calls = stubFetch();
    const m = mount(<PaneScreen paneId={null} />);
    await settle();
    expect(calls.filter((u) => u.startsWith("/api/pane/screen")).length).toBe(0);
    // Nothing at all — not an empty box, not a "no pane" placeholder.
    // (MantineProvider injects its own <style> into the host, so the
    // absence is asserted on the component's own markup, not on text.)
    expect(m.query(".rp-screen")).toBe(null);
    m.unmount();
  });

  test("reads the pane once per paneId, never on a timer", async () => {
    const calls = stubFetch();
    const m = mount(<PaneScreen paneId="w8:p38" />);
    await settle();
    await settle();
    const screenCalls = calls.filter((u) => u.startsWith("/api/pane/screen"));
    expect(screenCalls.length).toBe(1);
    expect(screenCalls[0]).toContain("paneId=w8%3Ap38");
    expect(m.text()).toContain("line one");
    expect(m.text()).toContain("snapshot");
    m.unmount();
  });

  test("ended rows read no screen — the pane is gone", async () => {
    const calls = stubFetch();
    const m = mount(panel(boardRow("alpha", { status: "ended", endedNote: "ended · stopped by you" })));
    await settle();
    expect(calls.filter((u) => u.startsWith("/api/pane/screen")).length).toBe(0);
    // The badge says "ended"; the note contributes only what the badge does
    // not already say, so the header never reads "ended ended · …".
    expect(m.text()).toContain("ended");
    expect(m.text()).toContain("stopped by you");
    expect(m.text()).not.toContain("ended ended");
    m.unmount();
  });
});
