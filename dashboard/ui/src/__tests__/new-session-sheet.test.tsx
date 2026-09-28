/**
 * NewSessionSheet — the phone's "New session" entry point. Lists only what
 * GET /api/personas returned, and posts {persona, text, fresh} to
 * POST /api/persona/start; a refusal stays on screen.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { NewSessionSheet } from "../components/phone/NewSessionSheet";
import { theme } from "../theme";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
  document.body.innerHTML = "";
});

const PERSONAS = [
  { name: "phone-ok", description: "Test persona.", idleStart: "resume" },
  { name: "second", description: "Another.", idleStart: "fresh" },
];

function stubFetch(startReply: object, personas: unknown = PERSONAS) {
  const calls: { url: string; body: unknown }[] = [];
  globalThis.fetch = (async (url: unknown, init?: { body?: string }) => {
    const body = init?.body ? JSON.parse(init.body) : null;
    calls.push({ url: String(url), body });
    const reply = String(url) === "/api/personas" ? personas : startReply;
    return { ok: true, status: 200, json: async () => reply } as Response;
  }) as typeof fetch;
  return calls;
}

async function settle() {
  await act(async () => {
    for (let i = 0; i < 5; i++) await Promise.resolve();
  });
}

function mount(onClose = () => {}, onToast = (_m: string, _ok: boolean) => {}) {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  act(() => {
    root.render(
      <MantineProvider theme={theme}>
        <NewSessionSheet opened onClose={onClose} onToast={onToast} />
      </MantineProvider>,
    );
  });
  return () => act(() => root.unmount());
}

function typeMessage(text: string) {
  const input = document.querySelector('input[aria-label="first message"]') as HTMLInputElement;
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
  act(() => {
    setter.call(input, text);
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
}

function startButton() {
  return [...document.querySelectorAll("button")].find((b) => b.textContent?.trim() === "Start")!;
}

describe("NewSessionSheet", () => {
  test("lists the server's personas and posts persona + text + fresh", async () => {
    const calls = stubFetch({ ok: true, paneId: "w1:p1", mode: "started" });
    let closed = false;
    const toasts: string[] = [];
    const unmount = mount(() => (closed = true), (m) => toasts.push(m));
    await settle();
    expect(document.body.textContent).toContain("phone-ok");
    expect(document.body.textContent).toContain("second");
    expect(startButton().disabled).toBe(true); // no message yet

    typeMessage("hello $(echo INJECTED)");
    act(() => startButton().click());
    await settle();
    const post = calls.find((c) => c.url === "/api/persona/start");
    expect(post?.body).toEqual({ persona: "phone-ok", text: "hello $(echo INJECTED)", fresh: false });
    expect(closed).toBe(true);
    expect(toasts[0]).toContain("started: phone-ok");
    unmount();
  });

  test("a refusal is shown and the sheet stays open", async () => {
    stubFetch({ ok: false, error: "unknown persona 'phone-ok'" });
    let closed = false;
    const unmount = mount(() => (closed = true));
    await settle();
    typeMessage("hi");
    act(() => startButton().click());
    await settle();
    expect(document.body.textContent).toContain("unknown persona");
    expect(closed).toBe(false);
    unmount();
  });

  test("no startable persona -> explains how to enable one", async () => {
    stubFetch({ ok: true }, []);
    const unmount = mount();
    await settle();
    expect(document.body.textContent).toContain("remoteStart");
    unmount();
  });
});
