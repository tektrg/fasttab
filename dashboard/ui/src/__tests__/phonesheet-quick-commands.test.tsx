/**
 * PhoneSheet Compact / Clear + the non-Claude message gate (AgentBar
 * parity). Threat model: `/clear` wipes a real session's context, and any
 * text typed into an OpenCode/Codex pane can answer a prompt nobody saw.
 * - Compact/Clear only on a live Claude pane with hook data, not blocked,
 *   not an inbox row (`RowButtons.takesQuickCommands`).
 * - Clear needs a second press; a busy pane's queue needs another.
 * - A row the server won't message shows a caption, never the Composer.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { PhoneSheet } from "../components/phone/PhoneSheet";
import { takesQuickCommands } from "../messageGates";
import { theme } from "../theme";
import type { BoardRow } from "../types";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
  document.body.innerHTML = "";
});

function row(derived: Partial<BoardRow["derived"]> = {}, extra: Partial<BoardRow> = {}): BoardRow {
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
      hookState: "idle",
      hookSinceSec: 5,
      herdrStatus: "idle",
      disagree: false,
      hasHookData: true,
      screenState: "IDLE",
      source: "herdr",
      messageVia: "pane",
      agentKind: "claude",
      ...derived,
    },
    values: {},
    ...extra,
  };
}

function stubFetch(replies: object[]) {
  const calls: { url: string; body: unknown }[] = [];
  globalThis.fetch = (async (url: unknown, init?: { body?: string }) => {
    const body = init?.body ? JSON.parse(init.body) : null;
    calls.push({ url: String(url), body });
    const reply = String(url) === "/api/session/message" ? (replies.shift() ?? { ok: true }) : {};
    return { ok: true, status: 200, json: async () => reply } as Response;
  }) as typeof fetch;
  return calls;
}

async function settle() {
  await act(async () => {
    for (let i = 0; i < 5; i++) await Promise.resolve();
  });
}

function mount(r: BoardRow, onToast = (_m: string, _ok: boolean) => {}) {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  act(() => {
    root.render(
      <MantineProvider theme={theme}>
        <PhoneSheet row={r} properties={[]} onClose={() => {}} onToast={onToast} onRefetch={() => {}} />
      </MantineProvider>,
    );
  });
  return () => act(() => root.unmount());
}

function button(label: string) {
  return [...document.querySelectorAll("button")].find((b) => b.textContent?.trim() === label);
}

const messages = (calls: { url: string; body: unknown }[]) =>
  calls.filter((c) => c.url === "/api/session/message").map((c) => c.body);

describe("takesQuickCommands (AgentBar's gate)", () => {
  test("live Claude pane with hook data: yes", () => {
    expect(takesQuickCommands(row())).toBe(true);
  });
  test.each([
    ["an inbox row", row({ paneId: null, messageVia: "inbox", source: "claude-desktop" })],
    ["a waiting row (question picker)", row({ screenState: "NEEDS_HUMAN" })],
    ["a hook-held prompt", row({ hookRequest: { requestId: "r1" } as never })],
    ["a non-Claude pane", row({ agentKind: "opencode", hasHookData: false, messageRefusal: "refused: …" })],
    ["no hook data (e.g. an Air pane)", row({ hasHookData: false })],
    ["an ended row", row({}, { status: "ended" })],
  ])("%s: no", (_label, r) => {
    expect(takesQuickCommands(r as BoardRow)).toBe(false);
  });
});

describe("PhoneSheet Compact / Clear", () => {
  test("Compact sends /compact at once", async () => {
    const calls = stubFetch([{ ok: true, state: "message sent" }]);
    const unmount = mount(row());
    act(() => button("Compact")!.click());
    await settle();
    expect(messages(calls)).toEqual([{ rowId: "alpha", actor: "po", text: "/compact", confirm: false }]);
    unmount();
  });

  test("Clear needs a second press before anything is sent", async () => {
    const calls = stubFetch([{ ok: true, state: "message sent" }]);
    const unmount = mount(row());
    act(() => button("Clear")!.click());
    await settle();
    expect(messages(calls)).toEqual([]);
    expect(button("Confirm clear")).toBeTruthy();
    act(() => button("Confirm clear")!.click());
    await settle();
    expect(messages(calls)).toEqual([{ rowId: "alpha", actor: "po", text: "/clear", confirm: false }]);
    unmount();
  });

  test("a busy pane: the server's needsConfirm arms a queue press", async () => {
    const calls = stubFetch([{ ok: false, needsConfirm: true, reason: "mid-turn" }, { ok: true, state: "queued" }]);
    const unmount = mount(row());
    act(() => button("Compact")!.click());
    await settle();
    expect(button("Queue compact")).toBeTruthy();
    act(() => button("Queue compact")!.click());
    await settle();
    expect(messages(calls).map((b) => (b as { confirm: boolean }).confirm)).toEqual([false, true]);
    unmount();
  });

  test("no buttons on a waiting row", () => {
    stubFetch([]);
    const unmount = mount(row({ screenState: "NEEDS_HUMAN" }));
    expect(button("Compact")).toBeUndefined();
    expect(button("Clear")).toBeUndefined();
    unmount();
  });
});

describe("PhoneSheet non-Claude gate", () => {
  test("an OpenCode pane: caption instead of the Composer, no quick commands", () => {
    stubFetch([]);
    const unmount = mount(
      row({ agentKind: "opencode", hasHookData: false, messageRefusal: "refused: opencode prompts are invisible" }),
    );
    expect(document.body.textContent).toContain("Messages are off for opencode");
    expect(document.querySelector(".composer")).toBeNull();
    expect(button("Compact")).toBeUndefined();
    unmount();
  });

  test("a Claude pane keeps its Composer", () => {
    stubFetch([]);
    const unmount = mount(row());
    expect(document.querySelector(".composer")).not.toBeNull();
    expect(document.body.textContent).not.toContain("Messages are off");
    unmount();
  });
});
