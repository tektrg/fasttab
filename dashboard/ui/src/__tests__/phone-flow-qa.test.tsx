/** P3 QA2: quick answer == prompt card payload; Inbox -> answer -> row gone; no console errors. */
import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { setDefaultTimeout } from "bun:test";
import { PhoneShell } from "../components/phone/PhoneShell";
import { InboxTab } from "../components/phone/InboxTab";
import { PanelessPrompt } from "../components/HookRequestCard";
import { ToastProvider } from "../ui/Toast";
import { theme } from "../theme";
import { FEED_ORDER, type FeedSnapshot, type FullState, type HookRequest, type NeedsYouRow } from "../types";

setDefaultTimeout(60000);
const realFetch = globalThis.fetch;
const unmounts: Array<() => void> = [];
let errors: unknown[][] = [];
let errSpy: ReturnType<typeof spyOn>;
beforeEach(() => {
  errors = [];
  errSpy = spyOn(console, "error").mockImplementation((...a: unknown[]) => void errors.push(a));
});
afterEach(() => {
  for (const u of unmounts.splice(0)) try { u(); } catch { /* gone */ }
  document.body.removeAttribute("style");
  globalThis.fetch = realFetch;
  document.body.innerHTML = "";
  errSpy.mockRestore();
});
const settle = () => act(async () => { for (let i = 0; i < 4; i++) await Promise.resolve(); });
function mount(node: React.ReactNode) {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  const render = (n: React.ReactNode) => act(() => root.render(<MantineProvider theme={theme}>{n}</MantineProvider>));
  render(node);
  unmounts.push(() => act(() => root.unmount()));
  return { host, render };
}
const click = (el: Element | null | undefined) => {
  if (!el) throw new Error("element not found");
  act(() => void el.dispatchEvent(new MouseEvent("click", { bubbles: true })));
};
const btn = (t: string) => [...document.querySelectorAll("button")].find((b) => b.textContent?.trim() === t) ?? null;
function stub(status = 200, body: unknown = { ok: true }) {
  const posts: { url: string; body: any }[] = [];
  globalThis.fetch = (async (url: unknown, init?: { body?: string }) => {
    const u = String(url);
    if (init?.body) posts.push({ url: u, body: JSON.parse(init.body) });
    const json = u.startsWith("/api/board") ? { rowKind: "session", properties: [], rows: [] } : body;
    return { ok: status < 400, status, json: async () => json } as Response;
  }) as typeof fetch;
  return posts;
}
const opts = (...l: string[]) => l.map((label) => ({ label, description: "" }));
const q = (...labels: string[]): HookRequest => ({
  requestId: "q1", kind: "question", toolName: "AskUserQuestion",
  questions: [{ question: "Ship it?", header: "", multiSelect: false, options: opts(...labels) }],
});
const perm = (tool = "Read"): HookRequest => ({
  requestId: "p1", kind: "permission", toolName: tool, permission: { title: "Read", detail: "/x", suggestions: [] },
});
const row = (hookRequest: HookRequest, i = 1): NeedsYouRow => ({
  kind: hookRequest.kind === "question" ? "question" : "blocked", urgency: 1, label: "Agent " + i, paneId: null, detail: "d",
  sinceSec: 3, identity: null, source: "claude-desktop", agentSession: "s" + i, hookRequest,
});
const noop = () => {};
const inbox = (r: NeedsYouRow) => <InboxTab needsYou={[r]} workingCount={0} onOpen={noop} onGoAgents={noop} onToast={noop} />;
const card = (r: NeedsYouRow) => <PanelessPrompt row={r} onToast={noop} phone />;

/** Body the quick bar sends for `label`, and body the full card sends for the same choice. */
async function quickBody(r: NeedsYouRow, button: string) {
  const posts = stub();
  mount(inbox(r));
  click(btn(button));
  await settle();
  for (const u of unmounts.splice(0)) u();
  document.body.innerHTML = "";
  return posts[0];
}
async function cardBody(r: NeedsYouRow, steps: () => void) {
  const posts = stub();
  mount(card(r));
  steps();
  await settle();
  for (const u of unmounts.splice(0)) u();
  document.body.innerHTML = "";
  return posts[0];
}

describe("quick answer == prompt card payload", () => {
  for (const order of [["Yes", "No"], ["No", "Yes"]]) {
    for (const choice of ["Yes", "No"]) {
      test(`question [${order}] tap ${choice}`, async () => {
        const r = row(q(...order));
        const quick = await quickBody(r, choice);
        const full = await cardBody(r, () => {
          click([...document.querySelectorAll(".ui-option")].find((o) => o.querySelector(".ui-option__label")?.textContent === choice));
          click(btn("Send answer"));
        });
        expect(quick).toEqual(full);
        expect(quick.body.answers).toEqual({ "Ship it?": choice });
      });
    }
  }
  test("permission Allow once / Deny", async () => {
    const r = row(perm());
    expect(await quickBody(r, "Allow once")).toEqual(await cardBody(r, () => click(btn("Allow once"))));
    expect(await quickBody(r, "Deny")).toEqual(await cardBody(r, () => click(btn("Deny"))));
  });
});

describe("stale / answered prompts", () => {
  for (const [status, error] of [[404, "unknown request"], [409, "already answered in Claude"]] as const) {
    test(`${status}: clear message inline + toast, no retry`, async () => {
      const posts = stub(status, { ok: false, error });
      const toasts: string[] = [];
      const m = mount(<InboxTab needsYou={[row(q("Yes", "No"))]} workingCount={0} onOpen={noop} onGoAgents={noop} onToast={(t) => toasts.push(t)} />);
      click(btn("Yes"));
      await settle();
      expect(m.host.textContent).toContain("Not sent: " + error);
      expect(toasts).toEqual(["answer not sent: " + error]);
      expect(posts.length).toBe(1);
    });
  }
});

describe("phone flow end to end", () => {
  function state(needsYou: NeedsYouRow[]): FullState {
    const f: FeedSnapshot = { name: "x", refreshIntervalSec: 5, lastSuccessTs: 0, lastAttemptTs: 0, lastDurationSec: 0, ageSec: 0, broken: false, warming: false, error: null, data: null };
    const feeds = {} as FullState["feeds"];
    for (const n of FEED_ORDER) feeds[n] = { ...f, name: n };
    return { serverTimeTs: 1000, feeds, computed: { needsYou, agents: [], disagreementCount: 0, residueCount: 0, sleepingSessions: [] } };
  }
  test("Inbox row -> quick Yes -> toast -> row disappears when the next state drops it", async () => {
    const posts = stub();
    const r = row(q("No", "Yes"));
    const m = mount(<ToastProvider><PhoneShell state={state([r])} /></ToastProvider>);
    await settle();
    expect(m.host.textContent).toContain("Agent 1");
    click(btn("Yes"));
    await settle();
    expect(posts.find((p) => p.url.includes("/answer"))?.body).toEqual({ behavior: "allow", answers: { "Ship it?": "Yes" } });
    expect(document.body.textContent).toContain('Answered "Yes"');
    m.render(<ToastProvider><PhoneShell state={state([])} /></ToastProvider>);
    await settle();
    expect(m.host.textContent).not.toContain("Agent 1");
    expect(m.host.querySelector('[data-testid="quick-answer"]')).toBeNull();
    expect(errors).toEqual([]);
  });
});
