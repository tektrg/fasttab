/** Feedback tab QA pass 2: out-of-order refetch, error after load, keyboard. Fetch is stubbed; no network. */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { FeedbackTab } from "../feedback/FeedbackTab";

const T0 = Date.parse("2026-10-01T00:00:00Z");
const row = (id: string, status: string, text: string) => ({ threadID: id, app: "parklet", status, lastMessageAt: T0, lastAuthor: "user", lastUserMessage: text });
const realFetch = globalThis.fetch;
const realConfirm = window.confirm;
let root: Root | null = null;
afterEach(() => {
  act(() => root?.unmount());
  root = null;
  globalThis.fetch = realFetch;
  window.confirm = realConfirm;
});

type Pending = { url: string; resolve: (body: unknown, status?: number) => void };
function stubFetch() {
  const pending: Pending[] = [];
  globalThis.fetch = ((url: string) =>
    new Promise((done) => {
      pending.push({ url: String(url), resolve: (body, status = 200) => done(new Response(JSON.stringify(body), { status })) });
    })) as typeof fetch;
  return pending;
}
const flush = () => act(async () => { await new Promise((r) => setTimeout(r, 0)); });

async function mount() {
  const host = document.createElement("div");
  document.body.appendChild(host);
  root = createRoot(host);
  await act(async () => root!.render(<FeedbackTab layout="table" onToast={() => {}} />));
  return host;
}

describe("feedback tab QA pass 2", () => {
  test("a slower, older list reply never overwrites the newer one", async () => {
    const A = "0f8fad5b-d9cb-469f-a165-70867728950e", B = "1f8fad5b-d9cb-469f-a165-70867728950e";
    const pending = stubFetch();
    window.confirm = () => true;
    const host = await mount();
    pending[0].resolve({ ok: true, threads: [row(A, "open", "a"), row(B, "open", "b")] });
    await flush();
    const pick = async (index: number) => {
      const select = host.querySelectorAll<HTMLSelectElement>('select[aria-label="Thread status"]')[index];
      await act(async () => { select.value = "resolved"; select.dispatchEvent(new Event("change", { bubbles: true })); });
    };
    await pick(0);
    await pick(1);
    for (const p of pending.filter((p) => p.url.endsWith("/resolve"))) p.resolve({ ok: true, messageID: "m" });
    await flush();
    const lists = pending.filter((p) => p.url.includes("scope=all")).slice(1);
    expect(lists.length).toBe(2);
    lists[1].resolve({ ok: true, threads: [row(A, "resolved", "a"), row(B, "resolved", "b")] });
    await flush();
    lists[0].resolve({ ok: true, threads: [row(A, "resolved", "a"), row(B, "open", "b")] });
    await flush();
    expect(host.querySelector("tbody")).toBeNull();
  });

  test("refetch error after a good load keeps the table and shows a banner", async () => {
    const pending = stubFetch();
    window.confirm = () => true;
    const host = await mount();
    pending[0].resolve({ ok: true, threads: [row("0f8fad5b-d9cb-469f-a165-70867728950e", "open", "first")] });
    await flush();
    const select = host.querySelector<HTMLSelectElement>('select[aria-label="Thread status"]')!;
    await act(async () => { select.value = "resolved"; select.dispatchEvent(new Event("change", { bubbles: true })); });
    pending.find((p) => p.url.endsWith("/resolve"))!.resolve({ ok: false, error: "theindie-api HTTP 404" }, 404);
    await flush();
    pending.filter((p) => p.url.includes("scope=all"))[1].resolve({ ok: false, error: "theindie-api unreachable: TimeoutError" }, 502);
    await flush();
    expect(host.querySelector('[role="alert"]')?.textContent).toContain("unreachable");
    expect(host.querySelector("table")).not.toBeNull();
  });

  test("row opens with keyboard and says whether it is expanded", async () => {
    const pending = stubFetch();
    const host = await mount();
    pending[0].resolve({ ok: true, threads: [row("0f8fad5b-d9cb-469f-a165-70867728950e", "open", "first")] });
    await flush();
    const tr = host.querySelector<HTMLTableRowElement>("tbody tr")!;
    expect(tr.tabIndex).toBe(0);
    expect(tr.getAttribute("aria-expanded")).toBe("false");
    act(() => tr.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true })));
    expect(host.querySelector("tbody tr")!.getAttribute("aria-expanded")).toBe("true");
  });
});
