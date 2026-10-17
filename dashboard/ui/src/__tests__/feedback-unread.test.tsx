/** Feedback new-dot: count, mark-seen while viewing, document.title. Fetch is stubbed; no network. */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { syncAppBadge, titleWithCount, unseenWaiting, useFeedbackUnread } from "../feedback/feedbackUnread";
import { TabBar } from "../components/phone/TabBar";

const A = "0f8fad5b-d9cb-469f-a165-70867728950e", B = "1f8fad5b-d9cb-469f-a165-70867728950e";
const t = (id: string, at: number) => ({ threadID: id, app: "strider", status: "open", lastMessageAt: at, lastAuthor: "user" });
const realFetch = globalThis.fetch;
const realHasFocus = document.hasFocus;
let root: Root | null = null;
afterEach(() => {
  act(() => root?.unmount());
  root = null;
  globalThis.fetch = realFetch;
  document.hasFocus = realHasFocus;
  document.title = "Chief Dashboard";
});
const flush = () => act(async () => { await new Promise((r) => setTimeout(r, 0)); });

/** Fake dashboard server: waiting list + seen store that merges POSTs. */
function fakeServer(waiting: ReturnType<typeof t>[], seen: Record<string, number> = {}) {
  const posts: unknown[] = [];
  globalThis.fetch = (async (url: string, init?: RequestInit) => {
    if (String(url).startsWith("/api/feedback/threads")) return new Response(JSON.stringify({ ok: true, threads: waiting }));
    if (init?.method === "POST") {
      const body = JSON.parse(String(init.body));
      posts.push(body);
      Object.assign(seen, body.seen);
    }
    return new Response(JSON.stringify({ ok: true, seen }));
  }) as typeof fetch;
  return { posts, seen };
}

let lastCount = -1;
function Probe({ viewing }: { viewing: boolean }) {
  lastCount = useFeedbackUnread(viewing);
  return null;
}
async function mount(viewing: boolean) {
  const host = document.createElement("div");
  root = createRoot(host);
  await act(async () => root!.render(<Probe viewing={viewing} />));
  await flush();
  await flush();
}

describe("feedback new dot", () => {
  test("only waiting threads newer than their seen mark count", () => {
    expect(unseenWaiting([t(A, 100), t(B, 100)], { [A]: 100, [B]: 50 }).map((x) => x.threadID)).toEqual([B]);
    expect(titleWithCount("AgentBar", 3)).toBe("(3) AgentBar");
    expect(titleWithCount("AgentBar", 0)).toBe("AgentBar");
  });

  test("not viewing: shows the count and puts it in the browser tab title, marks nothing", async () => {
    document.title = "Chief Dashboard";
    const server = fakeServer([t(A, 100), t(B, 200)], { [A]: 100 });
    await mount(false);
    expect(lastCount).toBe(1);
    expect(document.title).toBe("(1) Chief Dashboard");
    expect(server.posts).toEqual([]);
  });

  test("viewing with the window in front marks every waiting thread seen", async () => {
    document.hasFocus = () => true;
    const server = fakeServer([t(A, 100), t(B, 200)]);
    await mount(true);
    expect(server.posts).toEqual([{ seen: { [A]: 100, [B]: 200 } }]);
    expect(lastCount).toBe(0);
  });

  test("viewing in a background window keeps the dot", async () => {
    document.hasFocus = () => false;
    const server = fakeServer([t(A, 100)]);
    await mount(true);
    expect(server.posts).toEqual([]);
    expect(lastCount).toBe(1);
  });

  test("phone tab bar shows the feedback badge", async () => {
    const host = document.createElement("div");
    root = createRoot(host);
    await act(async () => root!.render(<TabBar tab="inbox" onTab={() => {}} inboxBadge={0} feedbackBadge={2} />));
    expect(host.querySelector('[aria-label="Feedback, 2 new"] .phone-tabbar__badge')?.textContent).toBe("2");
  });

  test("app icon badge: set to the count, cleared at 0, silent where unsupported or refused", () => {
    const calls: unknown[] = [];
    const nav = { setAppBadge: async (n?: number) => void calls.push(n), clearAppBadge: async () => void calls.push("cleared") } as unknown as Navigator;
    syncAppBadge(4, nav);
    syncAppBadge(0, nav);
    expect(calls).toEqual([4, "cleared"]);
    syncAppBadge(2, {} as Navigator);
    syncAppBadge(2, { setAppBadge: () => Promise.reject(new Error("denied")) } as unknown as Navigator);
  });
});
