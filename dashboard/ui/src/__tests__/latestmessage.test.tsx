/**
 * LatestMessage (GET /api/session/latest — dashboard-move phase 2b). Shows
 * the last assistant text as markdown, or the server's `ok:false` reason;
 * mounts the form card when a pendingQuestion form is present.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { LatestMessage } from "../components/LatestMessage";
import { theme } from "../theme";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

function stubFetch(latestReply: unknown) {
  globalThis.fetch = (async (url: unknown) => {
    const u = String(url);
    if (u.startsWith("/api/session/latest")) {
      return { json: async () => latestReply };
    }
    return { json: async () => ({ ok: true }) };
  }) as typeof fetch;
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

describe("LatestMessage", () => {
  test("renders the latest assistant text as markdown", async () => {
    stubFetch({ ok: true, rowId: "alpha", latestMessage: "**done** — see `foo.ts`", pendingQuestion: null });
    const m = mount(<LatestMessage rowId="alpha" paneId="w8:p1" onToast={() => {}} />);
    await settle();
    expect(m.host.textContent).toContain("done");
    expect(m.host.textContent).toContain("foo.ts");
    expect(m.host.querySelector("strong")).not.toBe(null);
    expect(m.host.querySelector("code")).not.toBe(null);
    m.unmount();
  });

  test("ok:false shows the server's reason, not a blank card", async () => {
    stubFetch({ ok: false, error: "row alpha has no Claude session transcript" });
    const m = mount(<LatestMessage rowId="alpha" paneId="w8:p1" onToast={() => {}} />);
    await settle();
    expect(m.host.textContent).toContain("no Claude session transcript");
    m.unmount();
  });

  test("a pendingQuestion form mounts the form card", async () => {
    stubFetch({
      ok: true,
      rowId: "alpha",
      latestMessage: null,
      pendingQuestion: {
        toolUseId: "toolu_1",
        questions: [
          { header: "", question: "Proceed?", isMultiSelect: false, options: [{ label: "Yes" }, { label: "No" }] },
        ],
      },
    });
    const m = mount(<LatestMessage rowId="alpha" paneId="w8:p1" onToast={() => {}} />);
    await settle();
    expect(m.host.textContent).toContain("Proceed?");
    expect(m.host.querySelector(".form-card")).not.toBe(null);
    m.unmount();
  });

  test("no pane id: the form card never mounts (nothing to send to)", async () => {
    stubFetch({
      ok: true,
      rowId: "alpha",
      latestMessage: null,
      pendingQuestion: {
        toolUseId: "toolu_1",
        questions: [{ header: "", question: "Proceed?", isMultiSelect: false, options: [{ label: "Yes" }] }],
      },
    });
    const m = mount(<LatestMessage rowId="alpha" paneId={null} onToast={() => {}} />);
    await settle();
    expect(m.host.querySelector(".form-card")).toBe(null);
    m.unmount();
  });
});
