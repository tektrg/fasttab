/**
 * Phase 9 Composer tests: one-line send, server-driven confirm, loud
 * NOT SUBMITTED, queued-is-success. fetch is stubbed per test — the
 * assertions pin what the UI POSTs and what it renders back, never the
 * server's own guards.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { Composer } from "../components/Composer";
import { theme } from "../theme";
import type { BoardRow } from "../types";

function boardRow(rowId: string, status: BoardRow["status"] = "live"): BoardRow {
  return {
    rowKind: "session",
    rowId,
    status,
    derived: {
      paneId: "w8:pX",
      paneIdSanitized: "w8-pX",
      label: rowId,
      cwd: null,
      focused: false,
      hookState: "idle",
      hookSinceSec: 1,
      herdrStatus: "idle",
      disagree: false,
      hasHookData: true,
      screenState: "WAITING",
    },
    values: { "derived:label": `label-${rowId}` },
  };
}

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

function stubFetch(responses: unknown[]) {
  const calls: { url: unknown; body: unknown }[] = [];
  const queue = [...responses];
  globalThis.fetch = (async (url: unknown, init: unknown) => {
    let body: unknown = null;
    try {
      body = JSON.parse((init as { body: string }).body as string);
    } catch {
      /* non-JSON (foreign bleed) — recorded, answered ok */
    }
    calls.push({ url, body });
    // Bun runs test files in one process: another file's in-flight save can
    // land here. Only message POSTs consume the queue; assertions below
    // filter to /api/session/message so foreign calls cannot shift it.
    const next =
      url === "/api/session/message"
        ? (queue.shift() ?? { ok: true })
        : { ok: true };
    return { json: async () => next };
  }) as typeof fetch;
  return calls;
}

function messageCalls(calls: { url: unknown; body: unknown }[]) {
  return calls.filter((c) => c.url === "/api/session/message");
}

function mount(
  rows: BoardRow[],
  onToast: (msg: string, ok: boolean) => void = () => {},
) {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  act(() => {
    root.render(
      <MantineProvider theme={theme}>
        <Composer rows={rows} onToast={onToast} />
      </MantineProvider>,
    );
  });
  return { host, unmount: () => act(() => root.unmount()) };
}

function typeInto(host: HTMLElement, value: string) {
  const input = host.querySelector("input")!;
  act(() => {
    input.focus();
    // React 19 reads the native setter — assign then dispatch.
    const setter = Object.getOwnPropertyDescriptor(
      window.HTMLInputElement.prototype,
      "value",
    )!.set!;
    setter.call(input, value);
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
}

async function clickSend(host: HTMLElement) {
  const btn = [...host.querySelectorAll("button")].find((b) =>
    /^(Send|Confirm queue)/.test(b.textContent ?? ""),
  )!;
  await act(async () => {
    btn.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  });
}

describe("Composer", () => {
  test("no rows: disabled, says to select first", () => {
    const { host, unmount } = mount([]);
    expect(host.textContent).toContain("select rows first");
    expect(
      (host.querySelector("input") as HTMLInputElement).disabled,
    ).toBe(true);
    unmount();
  });

  test("targets show by label; Enter POSTs the text", async () => {
    const calls = stubFetch([
      { ok: true, state: "message sent" },
      { ok: true, state: "message sent" },
    ]);
    const toasts: [string, boolean][] = [];
    const { host, unmount } = mount([boardRow("a"), boardRow("b")], (...t) =>
      toasts.push(t),
    );
    expect(host.textContent).toContain("2 selected rows");
    typeInto(host, "hello there");
    await clickSend(host);
    const sent = messageCalls(calls);
    expect(sent.length).toBe(2);
    expect(sent[0].body).toMatchObject({
      rowId: "a",
      actor: "po",
      text: "hello there",
      confirm: false,
    });
    expect(toasts.some(([m, ok]) => ok && m.includes("label-a"))).toBe(true);
    expect(host.textContent).toContain("2 of 2 ok");
    unmount();
  });

  test("Enter empties the box — the receipt for a 4-6s send", async () => {
    const calls = stubFetch([{ ok: true, state: "message sent" }]);
    const { host, unmount } = mount([boardRow("a")]);
    typeInto(host, "go on then");
    await clickSend(host);
    expect(messageCalls(calls)[0].body).toMatchObject({ text: "go on then" });
    expect((host.querySelector("input") as HTMLInputElement).value).toBe("");
    unmount();
  });

  test("failed send holds the text, one click from the box", async () => {
    stubFetch([{ ok: false, error: "NOT SUBMITTED — stuck in the box" }]);
    const { host, unmount } = mount([boardRow("a")]);
    typeInto(host, "recover me");
    await clickSend(host);
    const input = host.querySelector("input") as HTMLInputElement;
    expect(input.value).toBe("");
    expect(host.textContent).toContain("recover me");
    const restore = [...host.querySelectorAll("button")].find((b) =>
      /Put it back/.test(b.textContent ?? ""),
    )!;
    await act(async () => {
      restore.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    expect((host.querySelector("input") as HTMLInputElement).value).toBe(
      "recover me",
    );
    unmount();
  });

  test("a plain refusal puts the text back in the box", async () => {
    stubFetch([{ ok: false, error: "refused: control character '\\x03'" }]);
    const { host, unmount } = mount([boardRow("a")]);
    typeInto(host, "keep me");
    await clickSend(host);
    expect((host.querySelector("input") as HTMLInputElement).value).toBe(
      "keep me",
    );
    unmount();
  });

  test("a refusal on one row only (another row got it) leaves the box empty", async () => {
    stubFetch([
      { ok: true, state: "message sent" },
      { ok: false, error: "refused: row b is not live" },
    ]);
    const { host, unmount } = mount([boardRow("a"), boardRow("b")]);
    typeInto(host, "once only");
    await clickSend(host);
    expect((host.querySelector("input") as HTMLInputElement).value).toBe("");
    unmount();
  });

  test("confirm-queue sends the held text, not an empty box", async () => {
    const calls = stubFetch([
      { ok: false, needsConfirm: true, reason: "mid-turn — queues" },
      { ok: true, state: "queued", reason: "queued — lands" },
    ]);
    const { host, unmount } = mount([boardRow("a")]);
    typeInto(host, "held through confirm");
    await clickSend(host);
    expect((host.querySelector("input") as HTMLInputElement).value).toBe("");
    await clickSend(host);
    expect(messageCalls(calls)[1].body).toMatchObject({
      confirm: true,
      text: "held through confirm",
    });
    unmount();
  });

  test("busy row asks first: confirm panel, then confirm:true", async () => {
    const calls = stubFetch([
      { ok: false, needsConfirm: true, reason: "mid-turn — queues" },
      { ok: true, state: "queued", reason: "queued — lands" },
    ]);
    const { host, unmount } = mount([boardRow("a")]);
    typeInto(host, "nudge");
    await clickSend(host);
    expect(messageCalls(calls).length).toBe(1);
    expect(host.textContent).toContain("busy — confirm each queue");
    expect(host.textContent).toContain("mid-turn — queues");
    await clickSend(host);
    expect(messageCalls(calls).length).toBe(2);
    expect(messageCalls(calls)[1].body).toMatchObject({ confirm: true });
    expect(host.textContent).toContain("Do not re-send");
    unmount();
  });

  test("NOT SUBMITTED is loud: persistent red panel with the error", async () => {
    stubFetch([{ ok: false, error: "NOT SUBMITTED — stuck in the box" }]);
    const { host, unmount } = mount([boardRow("a")]);
    typeInto(host, "hello");
    await clickSend(host);
    expect(host.textContent).toContain("NOT SUBMITTED — the message did not arrive");
    expect(host.textContent).toContain("Look at the pane before retrying");
    unmount();
  });

  test("ended rows listed as refused, never POSTed", async () => {
    const calls = stubFetch([]);
    const { host, unmount } = mount([boardRow("a"), boardRow("z", "ended")]);
    expect(host.textContent).toContain("will be refused");
    typeInto(host, "hi");
    await clickSend(host);
    const sent = messageCalls(calls);
    expect(sent.length).toBe(1);
    expect(sent[0].body).toMatchObject({ rowId: "a" });
    unmount();
  });
});
