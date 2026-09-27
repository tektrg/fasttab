/**
 * PhoneSheet Done/Park confirmation parity (phase 2 QA). Threat model: each
 * button here can stop, close, or archive a real session on the Mac. The
 * desktop `SessionActions` requires a SECOND press within ~5s before
 * sending `confirm:true` for a busy/working target (`SessionActionState
 * .needsConfirm`) — this pins the phone sheet to the same rule: a single
 * tap must never force-end or force-park a session that needs confirming.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { PhoneSheet } from "../components/phone/PhoneSheet";
import { theme } from "../theme";
import type { BoardRow } from "../types";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
  document.body.innerHTML = "";
});

function row(actions: BoardRow["actions"]): BoardRow {
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
      hookState: "working",
      hookSinceSec: 5,
      herdrStatus: "working",
      disagree: false,
      hasHookData: true,
      screenState: "WORKING",
    },
    values: {},
    actions,
  };
}

function stubFetch() {
  const calls: { url: string; body: unknown }[] = [];
  globalThis.fetch = (async (url: unknown, init?: unknown) => {
    let body: unknown = null;
    try {
      body = JSON.parse((init as { body: string }).body as string);
    } catch {
      /* GET, no body */
    }
    calls.push({ url: String(url), body });
    return { ok: true, json: async () => ({ ok: true, state: "stopped" }) } as Response;
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
    await Promise.resolve();
  });
}

function click(el: Element | null | undefined) {
  if (!el) throw new Error("element not found");
  act(() => {
    el.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  });
}

function buttonWithText(text: string): HTMLButtonElement | null {
  return (
    ([...document.querySelectorAll("button")].find((b) => b.textContent?.trim() === text) as
      | HTMLButtonElement
      | undefined) ?? null
  );
}

describe("PhoneSheet Done — needs-confirm parity with desktop", () => {
  test("a busy target's Done needs a SECOND tap before confirm:true is ever sent", async () => {
    const calls = stubFetch();
    const r = row({
      stop: { enabled: true, needsConfirm: true, reason: "agent is mid-turn" },
    });
    const m = mount(
      <PhoneSheet row={r} properties={[]} onClose={() => {}} onToast={() => {}} onRefetch={() => {}} />,
    );
    await settle();
    click(buttonWithText("Done"));
    await settle();
    // First tap only arms — no /api/session/stop call yet, and never with confirm:true.
    expect(calls.some((c) => c.url === "/api/session/stop")).toBe(false);
    expect(buttonWithText("Confirm")).not.toBe(null);

    click(buttonWithText("Confirm"));
    await settle();
    const post = calls.find((c) => c.url === "/api/session/stop");
    expect(post).toBeDefined();
    expect((post!.body as { confirm: boolean }).confirm).toBe(true);
    m.unmount();
  });

  test("an idle target's Done sends on the first press (no confirm needed)", async () => {
    const calls = stubFetch();
    const r = row({
      stop: { enabled: true, needsConfirm: false, reason: "" },
    });
    const m = mount(
      <PhoneSheet row={r} properties={[]} onClose={() => {}} onToast={() => {}} onRefetch={() => {}} />,
    );
    await settle();
    click(buttonWithText("Done"));
    await settle();
    const post = calls.find((c) => c.url === "/api/session/stop");
    expect(post).toBeDefined();
    expect((post!.body as { confirm: boolean }).confirm).toBe(false);
    m.unmount();
  });
});

describe("PhoneSheet Park — needs-confirm parity with desktop", () => {
  test("a busy target's Park needs a SECOND tap before confirm:true is ever sent", async () => {
    const calls = stubFetch();
    const r = row({
      archive: { enabled: true, needsConfirm: true, reason: "agent is mid-turn" },
    });
    const m = mount(
      <PhoneSheet row={r} properties={[]} onClose={() => {}} onToast={() => {}} onRefetch={() => {}} />,
    );
    await settle();
    click(buttonWithText("Park"));
    await settle();
    expect(calls.some((c) => c.url === "/api/session/archive")).toBe(false);
    expect(buttonWithText("Confirm")).not.toBe(null);

    click(buttonWithText("Confirm"));
    await settle();
    const post = calls.find((c) => c.url === "/api/session/archive");
    expect(post).toBeDefined();
    expect((post!.body as { confirm: boolean }).confirm).toBe(true);
    m.unmount();
  });
});
