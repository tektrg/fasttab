/**
 * The whole web app (App -> phone inbox / desktop Needs You) renders and
 * answers a hook-held prompt from REAL `/api/state` payloads, not a
 * hand-built row: `fixtures/hook-live-state-*.json` are the phone's own
 * `/api/state` replies from a scratch dashboard (:4713/:4714) holding a real
 * hook's prompt (QA pass 2, 2026-09-27), cut down to that one session (every
 * feed's data dropped — the scratch server also read this Mac's panes).
 * The answer bodies asserted here are the ones that e2e posted to the remote
 * route and saw the hook print as Claude's exact decision.
 *
 * State arrives the way the SPA really gets it: the first `/api/state` fetch,
 * then SSE pushes on `/api/events?answerSurface=web`.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import App from "../App";
import { theme } from "../theme";
import questionState from "./fixtures/hook-live-state-question.json";
import permissionState from "./fixtures/hook-live-state-permission.json";

const realFetch = globalThis.fetch;
const realEventSource = (globalThis as { EventSource?: unknown }).EventSource;
const realMatchMedia = window.matchMedia;
afterEach(() => {
  globalThis.fetch = realFetch;
  (globalThis as { EventSource?: unknown }).EventSource = realEventSource;
  window.matchMedia = realMatchMedia;
  document.body.innerHTML = "";
});

let openStreams: { url: string; onmessage: ((ev: { data: string }) => void) | null }[] = [];

class FakeEventSource {
  static CLOSED = 2;
  readyState = 1;
  onmessage: ((ev: { data: string }) => void) | null = null;
  onerror: (() => void) | null = null;
  constructor(public url: string) {
    openStreams.push(this);
  }
  close() {}
}

function push(state: unknown) {
  act(() => {
    for (const s of openStreams) s.onmessage?.({ data: JSON.stringify(state) });
  });
}

function stubServer(initialState: unknown) {
  openStreams = [];
  const posts: { url: string; body: unknown }[] = [];
  globalThis.fetch = (async (url: unknown, init?: { method?: string; body?: string }) => {
    const u = String(url);
    if (init?.method === "POST") {
      posts.push({ url: u, body: init.body ? JSON.parse(init.body) : null });
      return { ok: true, status: 200, json: async () => ({ ok: true, state: "answered" }) } as Response;
    }
    if (u === "/api/state") return { ok: true, status: 200, json: async () => initialState } as Response;
    if (u.startsWith("/api/board")) {
      return { ok: true, status: 200, json: async () => ({ rowKind: "session", properties: [], rows: [] }) } as Response;
    }
    return { ok: true, status: 200, json: async () => ({}) } as Response;
  }) as typeof fetch;
  (globalThis as { EventSource?: unknown }).EventSource = FakeEventSource;
  return posts;
}

function viewport(phone: boolean) {
  window.matchMedia = ((query: string) => ({
    matches: query.includes("max-width") ? phone : false,
    media: query, onchange: null,
    addListener: () => {}, removeListener: () => {},
    addEventListener: () => {}, removeEventListener: () => {}, dispatchEvent: () => false,
  })) as unknown as typeof window.matchMedia;
}

async function settle() {
  await act(async () => {
    for (let k = 0; k < 6; k++) await Promise.resolve();
  });
}

function mountApp() {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  act(() => root.render(<MantineProvider theme={theme}><App /></MantineProvider>));
  return { host, unmount: () => act(() => root.unmount()) };
}

function click(el: Element | null | undefined) {
  if (!el) throw new Error("element not found");
  act(() => {
    el.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  });
}

function button(text: string): HTMLButtonElement | null {
  return ([...document.querySelectorAll("button")].find((b) => b.textContent?.trim() === text) as
    HTMLButtonElement | undefined) ?? null;
}

function chip(labelText: string): HTMLInputElement {
  const label = [...document.querySelectorAll("label")].find((l) => l.textContent?.trim() === labelText);
  const input = label && document.getElementById(label.getAttribute("for") || "");
  if (!input) throw new Error("chip not found: " + labelText);
  return input as HTMLInputElement;
}

/** Phone: a pane-less prompt lives in a sheet opened from its Inbox row. */
function openPromptRow(phone: boolean) {
  if (phone) click(document.querySelector(".ui-row"));
}

/** Desktop: the "2. Beta" chip. Phone: the numbered option row "Beta". */
function pick(phone: boolean, n: number, label: string) {
  if (!phone) return click(chip(`${n}. ${label}`));
  const opt = [...document.querySelectorAll(".ui-option")].find(
    (o) => o.querySelector(".ui-option__label")?.textContent === label,
  );
  click(opt);
}

function typeInto(input: HTMLInputElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
  act(() => {
    setter.call(input, value);
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
}

const questionId = questionState.computed.needsYou[0].hookRequest!.requestId;
const permissionId = permissionState.computed.needsYou[0].hookRequest!.requestId;

for (const phone of [true, false]) {
  const where = phone ? "phone inbox" : "desktop Needs You";
  describe(`real /api/state -> ${where}`, () => {
    test("question form: single + multi-select + Other -> the body e2e proved Claude accepts", async () => {
      viewport(phone);
      const posts = stubServer(questionState);
      const { unmount } = mountApp();
      await settle();
      expect(openStreams.map((s) => s.url)).toEqual(["/api/events?answerSurface=web"]);
      openPromptRow(phone);
      expect(document.querySelectorAll(".hook-card").length).toBe(1);
      expect(document.body.textContent).toContain("QA2 pick any?");
      pick(phone, 2, "Beta");
      pick(phone, 3, "Blue");
      pick(phone, 1, "Red");
      const inputs = [...document.querySelectorAll(".hook-card input[type=text], .hook-card input:not([type])")] as HTMLInputElement[];
      typeInto(inputs[2], "$(echo INJECTED) free text");
      click(button("Send 3 answers"));
      await settle();
      expect(posts).toEqual([{
        url: `/api/hook/permission/${questionId}/answer`,
        body: { behavior: "allow", answers: {
          "QA2 pick one?": "Beta", "QA2 pick any?": "Red, Blue", "QA2 other?": "$(echo INJECTED) free text",
        } },
      }]);
      unmount();
    });

    test("SSE push swaps to the next prompt (new id, clean card); rule button needs a second tap", async () => {
      viewport(phone);
      const posts = stubServer(questionState);
      const { unmount } = mountApp();
      await settle();
      openPromptRow(phone);
      push(permissionState);
      expect(document.body.textContent).toContain("echo QA2_SENTINEL_NOOP");
      expect(document.body.textContent).not.toContain("QA2 pick any?");
      click(button("Always allow Bash(echo QA2_SENTINEL:*) in this project"));
      await settle();
      expect(posts.length).toBe(0);
      click(button("Tap again to save: Always allow Bash(echo QA2_SENTINEL:*) in this project"));
      await settle();
      expect(posts).toEqual([{ url: `/api/hook/permission/${permissionId}/answer`,
        body: { behavior: "allow", suggestionIndex: 0 } }]);
      unmount();
    });

    test("answered in Claude: the next push has no hookRequest -> the card goes away", async () => {
      viewport(phone);
      stubServer(permissionState);
      const { unmount } = mountApp();
      await settle();
      openPromptRow(phone);
      expect(document.querySelectorAll(".hook-card").length).toBe(1);
      push({ ...permissionState, computed: { ...permissionState.computed, needsYou: [] } });
      expect(document.querySelectorAll(".hook-card").length).toBe(0);
      unmount();
    });
  });
}
