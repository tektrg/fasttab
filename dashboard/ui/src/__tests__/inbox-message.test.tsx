/**
 * Messaging a Claude Desktop / CLI row (no pane) through its session inbox,
 * and the "Open in Claude" button. The server decides deliverability
 * (`messageVia`); the UI only shows the Composer + caption for an inbox row
 * and picks the right link for the device.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { PhoneSheet } from "../components/phone/PhoneSheet";
import { OpenInClaudeButton } from "../components/OpenInClaudeButton";
import {
  CLAUDE_CODE_WEB_URL,
  INBOX_CAPTION,
  messagesViaInbox,
  openInClaudeLink,
} from "../openInClaude";
import { theme } from "../theme";
import type { AgentRow, BoardRow } from "../types";

const DESKTOP_URL = "claude://code/continue?session=local_8711df12-aaaa";
const MAC_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15";
const IPHONE_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
  document.body.innerHTML = "";
});

function derived(extra: Partial<AgentRow>): AgentRow {
  return {
    paneId: null,
    paneIdSanitized: null,
    label: "desk",
    cwd: null,
    focused: false,
    hookState: "idle",
    hookSinceSec: 5,
    herdrStatus: null,
    disagree: false,
    hasHookData: true,
    screenState: null,
    ...extra,
  };
}

function boardRow(extra: Partial<AgentRow>): BoardRow {
  return { rowKind: "session", rowId: "sess-1", status: "live", derived: derived(extra), values: {} };
}

function stubFetch() {
  const calls: { url: string; body: unknown }[] = [];
  globalThis.fetch = (async (url: unknown, init?: unknown) => {
    let body: unknown = null;
    try {
      body = JSON.parse((init as { body: string }).body as string);
    } catch {
      /* GET */
    }
    calls.push({ url: String(url), body });
    return { ok: true, json: async () => ({ ok: true, state: "message sent" }) } as Response;
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
  return () => {
    act(() => root.unmount());
    host.remove();
  };
}

async function settle() {
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
}

const sheet = (row: BoardRow) => (
  <PhoneSheet row={row} properties={[]} onClose={() => {}} onToast={() => {}} onRefetch={() => {}} />
);

describe("openInClaudeLink", () => {
  test("Mac browser opens the desktop session itself", () => {
    expect(openInClaudeLink({ openUrl: DESKTOP_URL }, MAC_UA)).toEqual({
      href: DESKTOP_URL,
      label: "Open in Claude",
      title: "Opens this session in the Claude app on this Mac",
    });
  });
  test("phone gets the generic claude.ai/code page, labelled as such", () => {
    const link = openInClaudeLink({ openUrl: DESKTOP_URL }, IPHONE_UA);
    expect(link?.href).toBe(CLAUDE_CODE_WEB_URL);
    expect(link?.label).toBe("Open claude.ai/code");
  });
  test("no link for rows without Claude's own continue URL", () => {
    expect(openInClaudeLink({ openUrl: null }, MAC_UA)).toBe(null);
    expect(openInClaudeLink({ openUrl: "https://evil.example/x" }, MAC_UA)).toBe(null);
    expect(openInClaudeLink(undefined, MAC_UA)).toBe(null);
  });
});

describe("messagesViaInbox", () => {
  test("only a pane-less row the server marked inbox", () => {
    expect(messagesViaInbox({ paneId: null, messageVia: "inbox" })).toBe(true);
    expect(messagesViaInbox({ paneId: "w1:p1", messageVia: "pane" })).toBe(false);
    expect(messagesViaInbox({ paneId: null, messageVia: null })).toBe(false);
    expect(messagesViaInbox({ paneId: null })).toBe(false);
  });
});

describe("PhoneSheet on a Claude Desktop row", () => {
  test("inbox row shows the Composer with the peer-message caption and sends by rowId", async () => {
    const calls = stubFetch();
    const unmount = mount(sheet(boardRow({ source: "claude-desktop", messageVia: "inbox", openUrl: DESKTOP_URL })));
    await settle();
    const input = document.querySelector<HTMLInputElement>(".composer input");
    expect(input).not.toBe(null);
    expect(document.body.textContent).toContain(INBOX_CAPTION);
    expect(input!.placeholder).toBe("one line to the session — Enter sends");
    act(() => {
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
      setter.call(input, "hello desk");
      input!.dispatchEvent(new Event("input", { bubbles: true }));
    });
    act(() => {
      input!.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    });
    await settle();
    const post = calls.find((c) => c.url === "/api/session/message");
    expect(post?.body).toMatchObject({ rowId: "sess-1", text: "hello desk", actor: "po" });
    unmount();
  });

  test("status-only row the server can't message: no Composer", async () => {
    stubFetch();
    const unmount = mount(sheet(boardRow({ source: "claude-cli", messageVia: null })));
    await settle();
    expect(document.querySelector(".composer")).toBe(null);
    unmount();
  });

  test("pane row keeps the Composer, without the inbox caption", async () => {
    stubFetch();
    const unmount = mount(
      sheet(boardRow({ paneId: "w1:p1", paneIdSanitized: "w1-p1", source: "herdr", messageVia: "pane" })),
    );
    await settle();
    expect(document.querySelector(".composer")).not.toBe(null);
    expect(document.body.textContent).not.toContain(INBOX_CAPTION);
    expect(document.querySelector<HTMLInputElement>(".composer input")!.placeholder).toBe(
      "one line to the pane — Enter sends",
    );
    unmount();
  });
});

describe("OpenInClaudeButton", () => {
  test("Mac: a link to the claude:// session URL", () => {
    const unmount = mount(<OpenInClaudeButton row={{ openUrl: DESKTOP_URL }} userAgent={MAC_UA} />);
    const a = document.querySelector("a");
    expect(a?.getAttribute("href")).toBe(DESKTOP_URL);
    expect(a?.textContent).toBe("Open in Claude");
    expect(a?.getAttribute("target")).toBe(null);
    unmount();
  });
  test("phone: claude.ai/code in a new tab", () => {
    const unmount = mount(<OpenInClaudeButton row={{ openUrl: DESKTOP_URL }} userAgent={IPHONE_UA} />);
    const a = document.querySelector("a");
    expect(a?.getAttribute("href")).toBe(CLAUDE_CODE_WEB_URL);
    expect(a?.getAttribute("target")).toBe("_blank");
    expect(a?.getAttribute("rel")).toContain("noopener");
    unmount();
  });
  test("nothing for a row without openUrl", () => {
    const unmount = mount(<OpenInClaudeButton row={{ openUrl: null }} userAgent={MAC_UA} />);
    expect(document.querySelector("a")).toBe(null);
    unmount();
  });
});
