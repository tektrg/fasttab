/** P3: inline Yes/No on Inbox question rows; swipe tray Park / Done on Agents rows. */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { InboxTab } from "../components/phone/InboxTab";
import { SwipeableAgentRow } from "../components/phone/SwipeableAgentRow";
import { theme } from "../theme";
import type { BoardRow, HookRequest, NeedsYouRow } from "../types";

const realFetch = globalThis.fetch;
const unmounts: Array<() => void> = [];
afterEach(() => {
  for (const u of unmounts.splice(0)) u();
  globalThis.fetch = realFetch;
  document.body.innerHTML = "";
});
const settle = () => act(async () => void (await Promise.resolve(), await Promise.resolve(), await Promise.resolve()));
function mount(node: React.ReactNode) {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  act(() => root.render(<MantineProvider theme={theme}>{node}</MantineProvider>));
  unmounts.push(() => act(() => root.unmount()));
  return host;
}
const click = (el: Element | null | undefined) => {
  if (!el) throw new Error("element not found");
  act(() => void el.dispatchEvent(new MouseEvent("click", { bubbles: true })));
};
const btn = (text: string) => [...document.querySelectorAll("button")].find((b) => b.textContent?.trim() === text) ?? null;

function stubFetch(reply: { status?: number; body: unknown } = { body: { ok: true } }) {
  const posts: { url: string; body: any }[] = [];
  let release: () => void = () => {};
  const gate = { hold: false };
  globalThis.fetch = (async (url: unknown, init?: { body?: string }) => {
    posts.push({ url: String(url), body: init?.body ? JSON.parse(init.body) : null });
    if (gate.hold) await new Promise<void>((r) => (release = r));
    const status = reply.status ?? 200;
    return { ok: status < 400, status, json: async () => reply.body } as Response;
  }) as typeof fetch;
  return { posts, gate, release: () => release() };
}

const YESNO: HookRequest = {
  requestId: "hp-1", kind: "question", toolName: "AskUserQuestion",
  questions: [{ question: "Ship it?", header: "", multiSelect: false, options: [{ label: "Yes", description: "" }, { label: "No", description: "" }] }],
};
const needs = (hookRequest: HookRequest | null): NeedsYouRow => ({
  kind: "blocked", urgency: 1, label: "Agent A", paneId: null, detail: "Ship it?",
  sinceSec: 3, identity: "s1", source: "claude-desktop", agentSession: "s1", hookRequest,
});

describe("Inbox inline Yes/No", () => {
  test("simple Yes/No: tap No -> answer POST with that label, toast names it, buttons lock", async () => {
    const api = stubFetch();
    const toasts: string[] = [];
    mount(<InboxTab needsYou={[needs(YESNO)]} workingCount={0} onOpen={() => {}} onGoAgents={() => {}} onToast={(m) => toasts.push(m)} />);
    click(btn("No"));
    await settle();
    expect(api.posts).toEqual([{ url: "/api/hook/permission/hp-1/answer", body: { behavior: "allow", answers: { "Ship it?": "No" } } }]);
    expect(toasts).toEqual(['Answered "No"']);
    expect((btn("Yes") as HTMLButtonElement).disabled).toBe(true);
  });
  test("disabled while in flight (no double send)", async () => {
    const api = stubFetch();
    api.gate.hold = true;
    mount(<InboxTab needsYou={[needs(YESNO)]} workingCount={0} onOpen={() => {}} onGoAgents={() => {}} onToast={() => {}} />);
    const yes = btn("Yes");
    click(yes);
    click(yes);
    await settle();
    expect(api.posts.length).toBe(1);
    expect(yes?.textContent).toBe("Sending…");
    expect((btn("No") as HTMLButtonElement).disabled).toBe(true);
    api.release();
    await settle();
  });
  test("refusal is shown inline and toasted", async () => {
    stubFetch({ status: 409, body: { ok: false, error: "already answered" } });
    const toasts: string[] = [];
    const host = mount(<InboxTab needsYou={[needs(YESNO)]} workingCount={0} onOpen={() => {}} onGoAgents={() => {}} onToast={(m) => toasts.push(m)} />);
    click(btn("Yes"));
    await settle();
    expect(host.textContent).toContain("Not sent: already answered");
    expect(toasts[0]).toContain("answer not sent");
  });
  test("multi-option, Bash permission and transcript-only rows get no buttons", () => {
    const three = { ...YESNO, questions: [{ ...YESNO.questions![0], options: [...YESNO.questions![0].options, { label: "Later", description: "" }] }] };
    const bash: HookRequest = { requestId: "b", kind: "permission", toolName: "Bash", permission: { title: "Run", detail: "ls", suggestions: [{ index: 0, label: "don't ask again" }] } };
    const host = mount(
      <InboxTab needsYou={[needs(three), needs(bash), needs(null)]} workingCount={0} onOpen={() => {}} onGoAgents={() => {}} onToast={() => {}} />,
    );
    expect(host.querySelector('[data-testid="quick-answer"]')).toBeNull();
  });
});

function boardRow(over: Partial<BoardRow> = {}): BoardRow {
  return {
    rowKind: "session", rowId: "alpha", status: "live",
    derived: { paneId: "w:alpha", paneIdSanitized: "w", label: "alpha", cwd: "/w", focused: false, hookState: "working", hookSinceSec: 5, herdrStatus: "working", disagree: false, hasHookData: true, screenState: "WORKING" },
    values: {}, ...over,
  };
}
const rowProps = { initials: "AL", name: "alpha", subtitle: "x", age: "1m", status: "run" as const };

describe("Swipe tray", () => {
  test("Park acts at once with an Undo offer", async () => {
    const api = stubFetch();
    const undos: string[] = [];
    mount(
      <SwipeableAgentRow
        {...rowProps}
        row={boardRow({ actions: { archive: { enabled: true, needsConfirm: false, reason: "" } } })}
        onToast={() => {}} onUndo={(m) => undos.push(m)} onRefetch={() => {}}
      />,
    );
    expect(document.querySelector('[data-testid="swipe-tray"]')?.getAttribute("aria-hidden")).toBe("true");
    click(btn("Park"));
    await settle();
    expect(api.posts[0].url).toBe("/api/session/archive");
    expect(undos).toEqual(["Parked"]);
  });
  test("Done on a busy session needs a second tap (Confirm) before confirm:true goes out", async () => {
    const api = stubFetch();
    mount(
      <SwipeableAgentRow
        {...rowProps}
        row={boardRow({ actions: { stop: { enabled: true, needsConfirm: true, reason: "busy" } } })}
        onToast={() => {}} onRefetch={() => {}}
      />,
    );
    click(btn("Done"));
    await settle();
    expect(api.posts.length).toBe(0);
    click(btn("Confirm"));
    await settle();
    expect(api.posts.length).toBe(1);
    expect(api.posts[0].body.confirm).toBe(true);
  });
  test("ended row has no tray", () => {
    mount(<SwipeableAgentRow {...rowProps} row={boardRow({ status: "ended" })} onToast={() => {}} onRefetch={() => {}} />);
    expect(document.querySelector('[data-testid="swipe-tray"]')).toBeNull();
  });
});
