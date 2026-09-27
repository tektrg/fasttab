/**
 * ReviewCard (permission Allow / Allow always / Deny — dashboard-move
 * phase 2b). Every send must POST /api/permission with the exact
 * `permission` object it was given (server contract, chief-dashboard-
 * server.py ~L109-160: it re-reads the pane fresh and refuses on a
 * mismatch). Allow always only ever shows when the box actually offers a
 * "for good" row (mirrors PermissionPrompt.swift's `option(for:)`), and
 * needs a second press before it sends.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { ReviewCard, reviewChoices } from "../components/ReviewCard";
import { theme } from "../theme";
import type { PermissionPrompt } from "../types";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

function bashPrompt(): PermissionPrompt {
  return {
    tool: "Bash",
    detail: "rm -rf /tmp/scratch",
    title: "Do you want to proceed?",
    options: [
      { index: 1, label: "Yes" },
      { index: 2, label: "Yes, and don't ask again for Bash commands" },
      { index: 3, label: "No, and tell Claude what to do differently" },
    ],
    cursorIndex: 1,
  };
}

function noAlwaysPrompt(): PermissionPrompt {
  return {
    tool: "Bash",
    detail: "ls",
    title: "Do you want to proceed?",
    options: [
      { index: 1, label: "Yes" },
      { index: 2, label: "No, and tell Claude what to do differently" },
    ],
    cursorIndex: 1,
  };
}

function stubFetch(reply: unknown = { ok: true }) {
  const calls: { url: unknown; body: unknown }[] = [];
  globalThis.fetch = (async (url: unknown, init: unknown) => {
    let body: unknown = null;
    try {
      body = JSON.parse((init as { body: string }).body as string);
    } catch {
      /* GET, no body */
    }
    calls.push({ url, body });
    return { json: async () => reply };
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

describe("reviewChoices", () => {
  test("allow-always only appears when the box offers a for-good row", () => {
    expect(reviewChoices(noAlwaysPrompt()).allowAlways).toBe(null);
    expect(reviewChoices(bashPrompt()).allowAlways).not.toBe(null);
  });
});

describe("ReviewCard", () => {
  test("Allow posts the exact permission object with choice allow", async () => {
    const calls = stubFetch({ ok: true });
    const m = mount(<ReviewCard paneId="w8:p1" permission={bashPrompt()} onToast={() => {}} />);
    click(buttonWithText(m.host, "Allow"));
    await settle();
    const post = calls.find((c) => c.url === "/api/permission");
    expect(post).toBeDefined();
    expect((post!.body as { choice: string }).choice).toBe("allow");
    expect((post!.body as { paneId: string }).paneId).toBe("w8:p1");
    expect((post!.body as { permission: PermissionPrompt }).permission.title).toBe(
      "Do you want to proceed?",
    );
    m.unmount();
  });

  test("Deny posts choice deny", async () => {
    const calls = stubFetch({ ok: true });
    const m = mount(<ReviewCard paneId="w8:p1" permission={bashPrompt()} onToast={() => {}} />);
    click(buttonWithText(m.host, "Deny"));
    await settle();
    const post = calls.find((c) => c.url === "/api/permission");
    expect((post!.body as { choice: string }).choice).toBe("deny");
    m.unmount();
  });

  test("Allow always is hidden when the box offers no for-good row", async () => {
    stubFetch();
    const m = mount(<ReviewCard paneId="w8:p1" permission={noAlwaysPrompt()} onToast={() => {}} />);
    expect(buttonWithText(m.host, "Allow always")).toBe(null);
    m.unmount();
  });

  test("Allow always needs a second press before it sends", async () => {
    const calls = stubFetch({ ok: true });
    const m = mount(<ReviewCard paneId="w8:p1" permission={bashPrompt()} onToast={() => {}} />);
    click(buttonWithText(m.host, "Allow always"));
    await settle();
    expect(calls.length).toBe(0); // armed, not sent yet
    expect(buttonWithText(m.host, "Confirm always allow")).not.toBe(null);
    click(buttonWithText(m.host, "Confirm always allow"));
    await settle();
    const post = calls.find((c) => c.url === "/api/permission");
    expect((post!.body as { choice: string }).choice).toBe("allow-always");
    m.unmount();
  });

  test("a refusal shows the server's reason, never auto-retried", async () => {
    stubFetch({ ok: false, error: "permission prompt changed or gone — re-check the pane" });
    const m = mount(<ReviewCard paneId="w8:p1" permission={bashPrompt()} onToast={() => {}} />);
    click(buttonWithText(m.host, "Allow"));
    await settle();
    expect(m.host.textContent).toContain("permission prompt changed or gone");
    m.unmount();
  });

  // Threat model: a wrong or duplicated keystroke here can approve a
  // dangerous command. Two clicks in the same event-loop turn (a fast
  // real-world double tap) both pass before Mantine's `loading`-driven
  // `disabled` re-render commits, so state alone does not stop a second
  // POST — confirmed by dispatching both clicks inside one `act()`.
  test("a same-tick double tap on Allow sends exactly one POST", async () => {
    const calls = stubFetch({ ok: true });
    const m = mount(<ReviewCard paneId="w8:p1" permission={bashPrompt()} onToast={() => {}} />);
    const allow = buttonWithText(m.host, "Allow")!;
    act(() => {
      allow.dispatchEvent(new MouseEvent("click", { bubbles: true }));
      allow.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    await settle();
    const posts = calls.filter((c) => c.url === "/api/permission");
    expect(posts.length).toBe(1);
    m.unmount();
  });

  test("a same-tick double tap on Confirm always allow sends exactly one POST", async () => {
    const calls = stubFetch({ ok: true });
    const m = mount(<ReviewCard paneId="w8:p1" permission={bashPrompt()} onToast={() => {}} />);
    click(buttonWithText(m.host, "Allow always"));
    await settle();
    const confirm = buttonWithText(m.host, "Confirm always allow")!;
    act(() => {
      confirm.dispatchEvent(new MouseEvent("click", { bubbles: true }));
      confirm.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    await settle();
    const posts = calls.filter((c) => c.url === "/api/permission");
    expect(posts.length).toBe(1);
    m.unmount();
  });
});
