/**
 * Messaging a SLEEPING Claude Desktop session (an ended row the server marked
 * `messageVia: "wake"`): the phone sheet keeps the Composer, says it will wake
 * the session, and POSTs by rowId. Any other ended row stays unmessageable.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { PhoneSheet } from "../components/phone/PhoneSheet";
import { WAKE_CAPTION, messagesViaInbox, wakesToMessage } from "../openInClaude";
import { evaluateMessageBulk } from "../sessionActions";
import { theme } from "../theme";
import type { BoardRow } from "../types";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
  document.body.innerHTML = "";
});

function endedRow(messageVia: "wake" | null): BoardRow {
  return {
    rowKind: "session",
    rowId: "sess-sleepy",
    status: "ended",
    derived: { label: "desk", paneId: null, messageVia, openUrl: "claude://code/continue?session=local_abc" } as BoardRow["derived"],
    values: {},
  };
}

function mount(row: BoardRow) {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  act(() => {
    root.render(
      <MantineProvider theme={theme}>
        <PhoneSheet row={row} properties={[]} onClose={() => {}} onToast={() => {}} onRefetch={() => {}} />
      </MantineProvider>,
    );
  });
  return () => act(() => root.unmount());
}

describe("wake rows", () => {
  test("gates", () => {
    expect(wakesToMessage(endedRow("wake"))).toBe(true);
    expect(wakesToMessage(endedRow(null))).toBe(false);
    expect(wakesToMessage({ ...endedRow("wake"), status: "live" })).toBe(false);
    expect(messagesViaInbox({ paneId: null, messageVia: "wake" })).toBe(true);
    expect(evaluateMessageBulk([endedRow("wake")]).ready.length).toBe(1);
    expect(evaluateMessageBulk([endedRow(null)]).refused.length).toBe(1);
  });

  test("sleeping row keeps the Composer with the wake caption and POSTs", async () => {
    const calls: { url: string; body: unknown }[] = [];
    globalThis.fetch = (async (url: unknown, init?: { body?: string }) => {
      calls.push({ url: String(url), body: init?.body ? JSON.parse(init.body) : null });
      return { ok: true, json: async () => ({ ok: true, state: "message sent" }) } as Response;
    }) as typeof fetch;
    const unmount = mount(endedRow("wake"));
    const input = document.querySelector<HTMLInputElement>(".composer input");
    expect(input).not.toBe(null);
    expect(document.body.textContent).toContain(WAKE_CAPTION);
    act(() => {
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
      setter.call(input, "wake up");
      input!.dispatchEvent(new Event("input", { bubbles: true }));
    });
    act(() => {
      input!.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    });
    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
    });
    expect(calls.find((c) => c.url === "/api/session/message")?.body).toMatchObject({ rowId: "sess-sleepy", text: "wake up" });
    unmount();
  });

  test("a plain ended row has no Composer", () => {
    const unmount = mount(endedRow(null));
    expect(document.querySelector(".composer input")).toBe(null);
    unmount();
  });
});
