/**
 * "/compact with a temporary Sonnet switch" — web side: the shared composer
 * input rule (parseCompactDraft, identical in Swift), plain multi-line
 * flattening, and the Composer's compact flow (POST, poll, progress line,
 * existing job on open). fetch is stubbed per URL; the server's own job
 * logic is covered by dashboard/tests/test_compact_jobs.py.
 */
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { Composer } from "../components/Composer";
import { theme } from "../theme";
import type { BoardRow } from "../types";
import {
  compactPolling,
  describeCompactJob,
  flattenMessage,
  parseCompactDraft,
  type CompactJob,
} from "../compactJob";

describe("parseCompactDraft (contract composer rule)", () => {
  test("bare /compact", () => {
    expect(parseCompactDraft("/compact")).toEqual({});
    expect(parseCompactDraft("  /compact  ")).toEqual({});
  });
  test("line 1 after /compact = instructions", () => {
    expect(parseCompactDraft("/compact keep the test plan ")).toEqual({ instructions: "keep the test plan" });
  });
  test("lines 2..n = followUp, newlines flattened to spaces", () => {
    expect(parseCompactDraft("/compact\nline one\nline two")).toEqual({ followUp: "line one line two" });
    expect(parseCompactDraft("/compact focus on auth\r\n  then fix the bug  \n")).toEqual({
      instructions: "focus on auth",
      followUp: "then fix the bug",
    });
  });
  test("empty follow-up lines are omitted", () => {
    expect(parseCompactDraft("/compact x\n\n  \n")).toEqual({ instructions: "x" });
  });
  test("anything else is a plain message", () => {
    for (const draft of ["/compactx", "/Compact", "hello /compact", "hi\n/compact", "/clear", ""]) {
      expect(parseCompactDraft(draft)).toBeNull();
    }
  });
  test("plain drafts flatten newlines to spaces", () => {
    expect(flattenMessage("first\nsecond\r\nthird ")).toBe("first second third");
  });
});

function job(over: Partial<CompactJob> = {}): CompactJob {
  return {
    id: "cj-0123456789abcdef",
    rowId: "r1",
    state: "waitingIdle",
    originalModel: "Opus 5.5",
    switchSkipped: false,
    skipReason: null,
    compactOk: null,
    modelRestored: null,
    followUpSent: null,
    error: null,
    failedStep: null,
    createdAt: 1,
    updatedAt: 1,
    ...over,
  };
}

describe("describeCompactJob", () => {
  test("one line per step", () => {
    expect(describeCompactJob(job())).toContain("waiting for the agent");
    expect(describeCompactJob(job({ state: "switchingModel" }))).toContain("switching to Sonnet");
    expect(describeCompactJob(job({ state: "compacting" }))).toContain("compacting on Sonnet");
    expect(describeCompactJob(job({ state: "restoringModel" }))).toContain("restoring Opus 5.5");
    expect(describeCompactJob(job({ state: "sendingFollowUp" }))).toContain("sending your message");
    expect(describeCompactJob(job({ state: "done", modelRestored: true, followUpSent: true }))).toBe(
      "Compact done · back on Opus 5.5 · message sent",
    );
  });
  test("skip reason and failures are explicit", () => {
    expect(
      describeCompactJob(job({ state: "compacting", switchSkipped: true, originalModel: "trung/claude-opus-5-5" })),
    ).toContain("compacting on trung/claude-opus-5-5");
    expect(
      describeCompactJob(
        job({ state: "done", switchSkipped: true, skipReason: "custom model: compacting on current model" }),
      ),
    ).toBe("Compact done · custom model: compacting on current model");
    expect(
      describeCompactJob(
        job({ state: "failed", error: "compaction did not finish within 5 min", modelRestored: false, followUpSent: true }),
      ),
    ).toBe(
      "Compact failed: compaction did not finish within 5 min · model NOT restored to Opus 5.5 — check the session · message sent",
    );
  });
});

// ---------------------------------------------------------------- Composer

function boardRow(rowId: string): BoardRow {
  return {
    rowKind: "session",
    rowId,
    status: "live",
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

interface Call {
  url: string;
  method: string;
  body: unknown;
}

const realFetch = globalThis.fetch;
const realInterval = compactPolling.intervalMs;
beforeEach(() => {
  compactPolling.intervalMs = 15;
});
afterEach(() => {
  globalThis.fetch = realFetch;
  compactPolling.intervalMs = realInterval;
});

/** `onRow`: GET ?rowId= answer; `post`: POST compact answer (+status);
 *  `polls`: successive GET /<id> jobs (the last one repeats). */
function stubFetch(opts: { onRow?: CompactJob | null; post?: { status: number; body: unknown }; polls?: CompactJob[] }) {
  const calls: Call[] = [];
  const polls = [...(opts.polls ?? [])];
  globalThis.fetch = (async (url: unknown, init?: { method?: string; body?: string }) => {
    const u = String(url);
    let body: unknown = null;
    try {
      body = init?.body ? JSON.parse(init.body) : null;
    } catch {
      /* not JSON */
    }
    calls.push({ url: u, method: init?.method ?? "GET", body });
    let status = 200;
    let answer: unknown = { ok: true };
    if (u.startsWith("/api/session/compact?rowId=")) answer = { ok: true, job: opts.onRow ?? null };
    else if (u === "/api/session/compact" && init?.method === "POST") {
      status = opts.post?.status ?? 202;
      answer = opts.post?.body ?? { ok: true, job: job() };
    } else if (u.startsWith("/api/session/compact/")) {
      const next = polls.length > 1 ? polls.shift() : polls[0];
      answer = next ? { ok: true, job: next } : { ok: false, error: "unknown job" };
    }
    return { status, json: async () => answer };
  }) as typeof fetch;
  return calls;
}

function mount(rows: BoardRow[], onToast: (msg: string, ok: boolean) => void = () => {}) {
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

function box(host: HTMLElement) {
  return host.querySelector("textarea") as HTMLTextAreaElement;
}

function typeInto(host: HTMLElement, value: string) {
  const input = box(host);
  act(() => {
    input.focus();
    Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, "value")!.set!.call(input, value);
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
}

async function key(host: HTMLElement, init: KeyboardEventInit) {
  await act(async () => {
    box(host).dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init }));
  });
}

async function settle(ms = 0) {
  await act(async () => {
    await new Promise((r) => setTimeout(r, ms));
  });
}

function progress(host: HTMLElement) {
  return host.querySelector(".composer-compact-progress")?.textContent ?? null;
}

describe("Composer: multi-line + compact", () => {
  test("Shift+Enter never sends; Enter sends a plain draft as one line", async () => {
    const calls = stubFetch({});
    const { host, unmount } = mount([boardRow("r1")]);
    typeInto(host, "first line\nsecond line");
    const shift = new KeyboardEvent("keydown", { key: "Enter", shiftKey: true, bubbles: true, cancelable: true });
    await act(async () => {
      box(host).dispatchEvent(shift);
    });
    expect(shift.defaultPrevented).toBe(false); // the textarea inserts the newline
    expect(calls.filter((c) => c.method === "POST")).toEqual([]);
    await key(host, { key: "Enter" });
    await settle();
    const posts = calls.filter((c) => c.method === "POST");
    expect(posts.map((c) => c.url)).toEqual(["/api/session/message"]);
    expect((posts[0].body as { text: string }).text).toBe("first line second line");
    unmount();
  });

  test("a /compact draft starts a job, polls, and shows each step to done", async () => {
    const calls = stubFetch({
      post: { status: 202, body: { ok: true, job: job() } },
      polls: [
        job({ state: "switchingModel" }),
        job({ state: "compacting" }),
        job({ state: "restoringModel", compactOk: true }),
        job({ state: "sendingFollowUp", compactOk: true, modelRestored: true }),
        job({ state: "done", compactOk: true, modelRestored: true, followUpSent: true }),
      ],
    });
    const { host, unmount } = mount([boardRow("r1")]);
    typeInto(host, "/compact keep the plan\nthen run the tests\nand report");
    await key(host, { key: "Enter" });
    await settle();
    const posts = calls.filter((c) => c.method === "POST");
    expect(posts.map((c) => c.url)).toEqual(["/api/session/compact"]);
    expect(posts[0].body).toEqual({
      rowId: "r1",
      actor: "po",
      instructions: "keep the plan",
      followUp: "then run the tests and report",
    });
    expect(box(host).value).toBe("");
    expect(progress(host)).toContain("waiting for the agent");
    const seen = new Set<string>();
    for (let i = 0; i < 40 && !(progress(host) ?? "").startsWith("Compact done"); i++) {
      await settle(20);
      seen.add(progress(host) ?? "");
    }
    expect([...seen].some((s) => s.includes("switching to Sonnet") || s.includes("compacting"))).toBe(true);
    expect(progress(host)).toBe("Compact done · back on Opus 5.5 · message sent×");
    const pollsBefore = calls.filter((c) => c.url.startsWith("/api/session/compact/")).length;
    await settle(80);
    expect(calls.filter((c) => c.url.startsWith("/api/session/compact/")).length).toBe(pollsBefore); // stopped
    unmount();
  });

  test("a failed job shows the error in red", async () => {
    stubFetch({
      polls: [job({ state: "failed", error: "you typed into the session", failedStep: "compacting", modelRestored: true })],
    });
    const { host, unmount } = mount([boardRow("r1")]);
    typeInto(host, "/compact");
    await key(host, { key: "Enter" });
    for (let i = 0; i < 20 && !(progress(host) ?? "").includes("failed"); i++) await settle(20);
    expect(progress(host)).toContain("Compact failed: you typed into the session");
    expect(host.querySelector(".composer-compact-progress")!.getAttribute("data-state")).toBe("failed");
    unmount();
  });

  test("opening the composer shows the row's running job", async () => {
    const calls = stubFetch({ onRow: job({ state: "compacting" }), polls: [job({ state: "compacting" })] });
    const { host, unmount } = mount([boardRow("r1")]);
    await settle(5);
    expect(calls[0].url).toBe("/api/session/compact?rowId=r1");
    expect(progress(host)).toBe("Compact: compacting on Sonnet…");
    unmount();
  });

  test("409 job-active: says so and shows the running job, nothing new typed", async () => {
    const toasts: string[] = [];
    stubFetch({
      post: { status: 409, body: { ok: false, error: "job-active", job: job({ state: "compacting" }) } },
      polls: [job({ state: "compacting" })],
    });
    const { host, unmount } = mount([boardRow("r1")], (t) => toasts.push(t));
    typeInto(host, "/compact");
    await key(host, { key: "Enter" });
    await settle();
    expect(toasts).toContain("a compact is already running for label-r1");
    expect(progress(host)).toContain("compacting");
    expect(box(host).value).toBe("");
    unmount();
  });

  test("a refusal (400) puts the draft back in the box", async () => {
    const toasts: string[] = [];
    stubFetch({ post: { status: 400, body: { ok: false, error: "row r1 is not a Claude pane" } } });
    const { host, unmount } = mount([boardRow("r1")], (t) => toasts.push(t));
    typeInto(host, "/compact\nfollow up");
    await key(host, { key: "Enter" });
    await settle();
    expect(toasts).toContain("compact refused for label-r1: row r1 is not a Claude pane");
    expect(box(host).value).toBe("/compact\nfollow up");
    expect(progress(host)).toBeNull();
    unmount();
  });
});
