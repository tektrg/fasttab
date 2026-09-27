/**
 * PlanCard (plan-mode approval — dashboard-move phase 2b). Renders the plan
 * file as markdown (GET /api/session/plan), never via
 * dangerouslySetInnerHTML — a plan file containing a raw HTML tag must show
 * as inert text, not run as markup. Sends via POST /api/permission
 * {choice:"select", index, text?}; a privilege-change row ("auto mode")
 * needs a second press; only the "Tell Claude what to change" row accepts
 * typed feedback.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { PlanCard, feedbackOption, isPrivilegeChangeLabel } from "../components/PlanCard";
import { theme } from "../theme";
import type { PermissionPrompt } from "../types";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

const SENTINEL = '<img src=x onerror="window.__pwned = true">';

function planPrompt(): PermissionPrompt {
  return {
    tool: "ExitPlanMode",
    detail: null,
    title: "Claude has written up a plan and is ready to execute. Would you like to proceed?",
    options: [
      { index: 1, label: "Yes, and use auto mode" },
      { index: 2, label: "Yes, manually approve edits" },
      { index: 3, label: "Tell Claude what to change" },
    ],
    cursorIndex: 1,
    kind: "plan",
    planPath: "~/.claude/plans/dapper-strolling-sprout.md",
  };
}

function stubFetch(planReply: unknown, permissionReply: unknown = { ok: true }) {
  const calls: { url: unknown; body: unknown }[] = [];
  globalThis.fetch = (async (url: unknown, init?: unknown) => {
    const u = String(url);
    if (u.startsWith("/api/session/plan")) {
      calls.push({ url: u, body: null });
      return { json: async () => planReply };
    }
    let body: unknown = null;
    try {
      body = JSON.parse((init as { body: string }).body as string);
    } catch {
      /* no body */
    }
    calls.push({ url: u, body });
    return { json: async () => permissionReply };
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
  });
}

function click(el: Element | null | undefined) {
  if (!el) throw new Error("element not found");
  act(() => {
    el.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  });
}

function buttonWithText(host: HTMLElement, text: string): HTMLButtonElement | null {
  return (
    ([...host.querySelectorAll("button")].find((b) => b.textContent?.trim() === text) as
      | HTMLButtonElement
      | undefined) ?? null
  );
}

describe("isPrivilegeChangeLabel / feedbackOption", () => {
  test("auto mode / bypass permissions rows are privilege changes", () => {
    expect(isPrivilegeChangeLabel("Yes, and use auto mode")).toBe(true);
    expect(isPrivilegeChangeLabel("Yes, and bypass permissions")).toBe(true);
    expect(isPrivilegeChangeLabel("Yes, manually approve edits")).toBe(false);
  });

  test("feedback option is the Tell Claude row", () => {
    const opt = feedbackOption(planPrompt().options);
    expect(opt?.label).toBe("Tell Claude what to change");
  });
});

describe("PlanCard", () => {
  test("renders plan text as markdown, a raw HTML sentinel shows as literal text", async () => {
    const calls = stubFetch({
      ok: true,
      rowId: "alpha",
      plan: { status: "text", text: `# Plan\n\nStep one uses ${SENTINEL} as a literal string.`, truncated: false },
    });
    const m = mount(
      <PlanCard rowId="alpha" paneId="w8:p1" permission={planPrompt()} onToast={() => {}} />,
    );
    await settle();
    expect(calls.some((c) => String(c.url).startsWith("/api/session/plan?rowId=alpha"))).toBe(true);
    // The sentinel text is visible verbatim in the rendered text...
    expect(m.host.textContent).toContain(SENTINEL);
    // ...but never as an actual <img> element (no HTML injection).
    expect(m.host.querySelector("img")).toBe(null);
    m.unmount();
  });

  test("a privilege-change row (auto mode) needs a second press before sending", async () => {
    const calls = stubFetch({ ok: true, plan: { status: "noPath" } });
    const m = mount(
      <PlanCard rowId="alpha" paneId="w8:p1" permission={planPrompt()} onToast={() => {}} />,
    );
    await settle();
    click(buttonWithText(m.host, "Yes, and use auto mode"));
    await settle();
    expect(calls.filter((c) => c.url === "/api/permission").length).toBe(0);
    expect(buttonWithText(m.host, "Press again to confirm")).not.toBe(null);
    click(buttonWithText(m.host, "Press again to confirm"));
    await settle();
    const post = calls.find((c) => c.url === "/api/permission");
    expect(post).toBeDefined();
    expect((post!.body as { choice: string; index: number }).choice).toBe("select");
    expect((post!.body as { choice: string; index: number }).index).toBe(1);
    m.unmount();
  });

  test("a non-privilege row (manually approve edits) sends on the first press", async () => {
    const calls = stubFetch({ ok: true, plan: { status: "noPath" } });
    const m = mount(
      <PlanCard rowId="alpha" paneId="w8:p1" permission={planPrompt()} onToast={() => {}} />,
    );
    await settle();
    click(buttonWithText(m.host, "Yes, manually approve edits"));
    await settle();
    const post = calls.find((c) => c.url === "/api/permission");
    expect(post).toBeDefined();
    expect((post!.body as { index: number }).index).toBe(2);
    m.unmount();
  });

  test("Tell Claude what to change opens a feedback field; text is sent with the select", async () => {
    const calls = stubFetch({ ok: true, plan: { status: "noPath" } });
    const m = mount(
      <PlanCard rowId="alpha" paneId="w8:p1" permission={planPrompt()} onToast={() => {}} />,
    );
    await settle();
    click(buttonWithText(m.host, "Tell Claude what to change"));
    await settle();
    const textarea = m.host.querySelector("textarea") as HTMLTextAreaElement;
    expect(textarea).not.toBe(null);
    act(() => {
      const setter = Object.getOwnPropertyDescriptor(
        HTMLTextAreaElement.prototype,
        "value",
      )!.set!;
      setter.call(textarea, "please use a different approach");
      textarea.dispatchEvent(new Event("input", { bubbles: true }));
    });
    await settle();
    click(buttonWithText(m.host, "Send feedback"));
    await settle();
    const post = calls.find((c) => c.url === "/api/permission");
    expect(post).toBeDefined();
    const body = post!.body as { index: number; text: string; choice: string };
    expect(body.choice).toBe("select");
    expect(body.index).toBe(3);
    expect(body.text).toBe("please use a different approach");
    m.unmount();
  });

  test("an unreadable plan file shows the server's reason", async () => {
    stubFetch({ ok: true, plan: { status: "unreadable", reason: "the plan file was not found." } });
    const m = mount(
      <PlanCard rowId="alpha" paneId="w8:p1" permission={planPrompt()} onToast={() => {}} />,
    );
    await settle();
    expect(m.host.textContent).toContain("the plan file was not found.");
    m.unmount();
  });
});
