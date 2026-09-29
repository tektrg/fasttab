/**
 * Phone shell (P2): Agents tab chips/sleeping rows, Park with Undo, and the
 * numbered-option prompt sheet for a pane-less (Desktop / CLI) session.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { PhoneShell } from "../components/phone/PhoneShell";
import { PhoneSheet } from "../components/phone/PhoneSheet";
import { ToastProvider } from "../ui/Toast";
import { theme } from "../theme";
import { FEED_ORDER, type BoardRow, type FeedSnapshot, type FullState, type NeedsYouRow } from "../types";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
  document.body.innerHTML = "";
});

async function settle() {
  await act(async () => {
    for (let i = 0; i < 4; i++) await Promise.resolve();
  });
}

function mount(node: React.ReactNode) {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  act(() => {
    root.render(<MantineProvider theme={theme}>{node}</MantineProvider>);
  });
  return { host, unmount: () => act(() => root.unmount()) };
}

function feeds(): FullState["feeds"] {
  const f: FeedSnapshot = {
    name: "x", refreshIntervalSec: 5, lastSuccessTs: 0, lastAttemptTs: 0, lastDurationSec: 0,
    ageSec: 0, broken: false, warming: false, error: null, data: null,
  };
  const out = {} as FullState["feeds"];
  for (const n of FEED_ORDER) out[n] = { ...f, name: n };
  return out;
}

function row(rowId: string, over: Partial<BoardRow> = {}): BoardRow {
  return {
    rowKind: "session",
    rowId,
    status: "live",
    derived: {
      paneId: "w:" + rowId, paneIdSanitized: "w", label: rowId, cwd: "/work/" + rowId, focused: false,
      hookState: "working", hookSinceSec: 5, herdrStatus: "working", disagree: false, hasHookData: true,
      screenState: "WORKING",
    },
    values: {},
    ...over,
  };
}

function state(needsYou: NeedsYouRow[] = [], sleeping: FullState["computed"]["sleepingSessions"] = []): FullState {
  return {
    serverTimeTs: 1000,
    feeds: feeds(),
    computed: { needsYou, agents: [], disagreementCount: 0, residueCount: 0, sleepingSessions: sleeping },
  };
}

function stubApi(rows: BoardRow[]) {
  const posts: { url: string; body: any }[] = [];
  globalThis.fetch = (async (url: unknown, init?: { body?: string }) => {
    const u = String(url);
    if (init?.body) posts.push({ url: u, body: JSON.parse(init.body) });
    const json = u.startsWith("/api/board") ? { rowKind: "session", properties: [], rows } : { ok: true, state: "done" };
    return { ok: true, status: 200, json: async () => json } as Response;
  }) as typeof fetch;
  return posts;
}

const click = (el: Element | null | undefined) => {
  if (!el) throw new Error("element not found");
  act(() => void el.dispatchEvent(new MouseEvent("click", { bubbles: true })));
};

describe("Agents tab", () => {
  test("chips carry counts; Sleeping filter lists the sleeping session; Folder groups", async () => {
    stubApi([row("w1"), row("p1", { archived: true })]);
    const sleeping = [{
      desktopSessionId: "local_z", cliSessionId: "z", label: "old chat", cwd: "/work/z", lastActiveTs: 900, openUrl: "claude://code/continue?session=local_z",
    }];
    const m = mount(<ToastProvider><PhoneShell state={state([], sleeping)} /></ToastProvider>);
    await settle();
    click(m.host.querySelector('[aria-label="Main"] button:nth-child(2)'));
    const chips = [...m.host.querySelectorAll(".phone-chip")].map((c) => c.textContent);
    expect(chips).toEqual(["All3", "Working1", "Parked1", "Sleeping1", "Folder"]);
    click([...m.host.querySelectorAll(".phone-chip")][3]);
    expect([...m.host.querySelectorAll(".ui-row__name")].map((n) => n.textContent)).toEqual(["old chat"]);
    click([...m.host.querySelectorAll(".phone-chip")][4]);
    expect(m.host.querySelectorAll("[data-section]").length).toBe(3);
    m.unmount();
  });
});

describe("Park with Undo", () => {
  test("acts at once when the server needs no confirm, offers Undo, Undo unparks", async () => {
    const posts = stubApi([]);
    const undos: { message: string; undo: () => void }[] = [];
    const r = row("alpha", { actions: { archive: { enabled: true, needsConfirm: false, reason: "" } } });
    const m = mount(
      <PhoneSheet row={r} properties={[]} onClose={() => {}} onToast={() => {}} onRefetch={() => {}}
        onUndo={(message, undo) => undos.push({ message, undo })} />,
    );
    await settle();
    click([...document.querySelectorAll("button")].find((b) => b.textContent === "Park"));
    await settle();
    expect(posts.find((p) => p.url === "/api/session/archive")?.body.confirm).toBe(false);
    expect(undos.map((u) => u.message)).toEqual(["Parked"]);
    act(() => undos[0].undo());
    await settle();
    expect(posts.some((p) => p.url === "/api/session/unarchive")).toBe(true);
    m.unmount();
  });
});

describe("Prompt sheet", () => {
  test("a pane-less question opens as numbered option rows with one Send", async () => {
    stubApi([]);
    const n: NeedsYouRow = {
      kind: "question", urgency: 1, label: "desk-agent", paneId: null, detail: "asks", sinceSec: 3, identity: null,
      source: "claude-desktop", agentSession: "s1",
      hookRequest: {
        requestId: "r1", kind: "question",
        questions: [{ question: "Run it?", header: "", multiSelect: false, options: [{ label: "Yes" }, { label: "No" }] }],
      } as never,
    };
    const m = mount(<ToastProvider><PhoneShell state={state([n])} /></ToastProvider>);
    await settle();
    click(m.host.querySelector(".ui-row"));
    const opts = [...document.querySelectorAll(".ui-option")];
    expect(opts.map((o) => o.querySelector(".ui-option__n")?.textContent)).toEqual(["1", "2"]);
    const send = [...document.querySelectorAll("button")].filter((b) => b.textContent === "Send answer");
    expect(send.length).toBe(1);
    expect((send[0] as HTMLButtonElement).disabled).toBe(true);
    click(opts[0]);
    expect((send[0] as HTMLButtonElement).disabled).toBe(false);
    m.unmount();
  });
  test("a pane row carrying its own request (OpenCode/Codex) opens the prompt, not the row sheet", async () => {
    stubApi([row("p1")]);
    const n: NeedsYouRow = {
      kind: "question", urgency: 1, label: "oc-agent", paneId: "w:p1", detail: "asks", sinceSec: 3, identity: null,
      source: "opencode", agentSession: "s2",
      hookRequest: {
        requestId: "r2", kind: "question", tool: "opencode",
        questions: [{ question: "Run it?", header: "", multiSelect: false, options: [{ label: "Yes" }] }],
      } as never,
    };
    const m = mount(<ToastProvider><PhoneShell state={state([n])} /></ToastProvider>);
    await settle();
    click(m.host.querySelector(".ui-row"));
    expect(document.querySelectorAll(".ui-option").length).toBe(1);
    m.unmount();
  });
});
