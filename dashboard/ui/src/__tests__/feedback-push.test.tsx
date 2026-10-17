/** Phone Web Push for new feedback: device-state matrix, key decoding, the
 *  Feedback-tab control, and the service worker's push / tap handlers.
 *  Fetch and the service worker globals are fakes; no network. */
import { afterEach, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { FeedbackPushControl } from "../feedback/FeedbackPushControl";
import { basePushState, initialTabFromUrl, vapidKeyBytes, type PushEnv } from "../feedback/feedbackPush";

const ok: PushEnv = { protocol: "https:", hasServiceWorker: true, hasPushManager: true, isIOS: true, standalone: true, permission: "default" };

describe("basePushState", () => {
  test("installed iPhone app on https can subscribe", () => expect(basePushState(ok)).toBe("off"));
  test("plain http is refused first", () => expect(basePushState({ ...ok, protocol: "http:" })).toBe("insecure"));
  test("iPhone Safari tab must be added to the Home Screen", () => expect(basePushState({ ...ok, standalone: false })).toBe("needs-install"));
  test("desktop browser tab is fine", () => expect(basePushState({ ...ok, isIOS: false, standalone: false })).toBe("off"));
  test("no PushManager", () => expect(basePushState({ ...ok, hasPushManager: false })).toBe("unsupported"));
  test("blocked", () => expect(basePushState({ ...ok, permission: "denied" })).toBe("denied"));
});

test("vapidKeyBytes decodes base64url", () => {
  expect(Array.from(vapidKeyBytes("BP-_"))).toEqual([0x04, 0xff, 0xbf]);
});

test("initialTabFromUrl only knows feedback", () => {
  expect(initialTabFromUrl("?tab=feedback&thread=x")).toBe("feedback");
  expect(initialTabFromUrl("?tab=$(echo INJECTED)")).toBe(null);
  expect(initialTabFromUrl("")).toBe(null);
});

describe("FeedbackPushControl", () => {
  const realFetch = globalThis.fetch;
  let root: Root | null = null;
  afterEach(() => {
    act(() => root?.unmount());
    root = null;
    globalThis.fetch = realFetch;
  });
  const render = (el: JSX.Element) => {
    const host = document.createElement("div");
    document.body.appendChild(host);
    root = createRoot(host);
    act(() => root!.render(el));
    return host;
  };
  const flush = () => act(async () => { await new Promise((r) => setTimeout(r, 0)); });

  test("explains the Home Screen step instead of offering a button", () => {
    const host = render(<FeedbackPushControl onToast={() => {}} initialState="needs-install" />);
    expect(host.textContent).toContain("Add to Home Screen");
    expect(host.querySelector("button")).toBe(null);
  });

  test("Send test push calls the proxy and reports the device count", async () => {
    const calls: { url: string; method?: string }[] = [];
    globalThis.fetch = (async (url: string, init?: RequestInit) => {
      calls.push({ url: String(url), method: init?.method });
      return new Response(JSON.stringify({ ok: true, sent: 2, removed: 0, failed: 0 }));
    }) as typeof fetch;
    const toasts: [string, boolean][] = [];
    const host = render(<FeedbackPushControl onToast={(m, k) => toasts.push([m, k])} initialState="on" />);
    const button = [...host.querySelectorAll("button")].find((b) => b.textContent === "Send test push")!;
    await act(async () => button.click());
    await flush();
    expect(calls).toEqual([{ url: "/api/feedback/push/test", method: "POST" }]);
    expect(toasts).toEqual([["test push sent to 2 device(s)", true]]);
  });

  test("a proxy error is shown, not swallowed", async () => {
    globalThis.fetch = (async () => new Response(JSON.stringify({ ok: false, error: "Owner Web Push is not configured" }), { status: 502 })) as typeof fetch;
    const toasts: [string, boolean][] = [];
    const host = render(<FeedbackPushControl onToast={(m, k) => toasts.push([m, k])} initialState="on" />);
    await act(async () => [...host.querySelectorAll("button")][0]!.click());
    await flush();
    expect(toasts).toEqual([["push: Owner Web Push is not configured", false]]);
  });
});

describe("service worker (public/sw.js)", () => {
  type Listener = (event: any) => void;
  function loadWorker(windows: any[] = []) {
    const listeners: Record<string, Listener> = {};
    const shown: { title: string; options: any }[] = [];
    const opened: string[] = [];
    const self = {
      location: { origin: "https://mac.example.ts.net" },
      addEventListener: (type: string, fn: Listener) => (listeners[type] = fn),
      registration: { showNotification: async (title: string, options: any) => void shown.push({ title, options }) },
      clients: { matchAll: async () => windows, openWindow: async (url: string) => void opened.push(url), claim: async () => {} },
      skipWaiting: () => {},
    };
    const source = readFileSync(path.join(import.meta.dir, "../../public/sw.js"), "utf8");
    new Function("self", "caches", "fetch", source)(self, {}, () => {});
    const fire = async (type: string, extra: any) => {
      let pending: Promise<unknown> = Promise.resolve();
      listeners[type]!({ ...extra, waitUntil: (p: Promise<unknown>) => (pending = p) });
      await pending;
    };
    return { fire, shown, opened };
  }
  const pushEvent = (payload: unknown) => ({ data: { json: () => (typeof payload === "string" ? JSON.parse(payload) : payload) } });

  test("push shows the notification with app + preview", async () => {
    const sw = loadWorker();
    await sw.fire("push", pushEvent({ title: "New feedback · Parklet", body: "crash on share", url: "/?tab=feedback&thread=t1", tag: "feedback:t1" }));
    expect(sw.shown).toHaveLength(1);
    expect(sw.shown[0]!.title).toBe("New feedback · Parklet");
    expect(sw.shown[0]!.options).toMatchObject({ body: "crash on share", tag: "feedback:t1", data: { url: "/?tab=feedback&thread=t1" } });
  });

  test("a malformed push still shows a notification (iOS revokes silent pushes)", async () => {
    const sw = loadWorker();
    await sw.fire("push", pushEvent("not json"));
    expect(sw.shown[0]!.title).toBe("New feedback");
  });

  test("an off-site url in the payload is replaced by the Feedback tab", async () => {
    const sw = loadWorker();
    await sw.fire("push", pushEvent({ title: "x", url: "https://evil.example/$(echo INJECTED)" }));
    expect(sw.shown[0]!.options.data.url).toBe("/?tab=feedback");
  });

  test("tap with the app closed opens the Feedback tab", async () => {
    const sw = loadWorker();
    await sw.fire("notificationclick", { notification: { close() {}, data: { url: "/?tab=feedback&thread=t1" } } });
    expect(sw.opened).toEqual(["/?tab=feedback&thread=t1"]);
  });

  test("tap with the app open switches it to Feedback and focuses it", async () => {
    const messages: unknown[] = [];
    let focused = false;
    const win = { url: "https://mac.example.ts.net/", postMessage: (m: unknown) => messages.push(m), focus: async () => void (focused = true) };
    const sw = loadWorker([win]);
    await sw.fire("notificationclick", { notification: { close() {}, data: { url: "/?tab=feedback" } } });
    expect(messages).toEqual([{ type: "agentbar-open-tab", tab: "feedback" }]);
    expect(focused).toBe(true);
    expect(sw.opened).toEqual([]);
  });
});
