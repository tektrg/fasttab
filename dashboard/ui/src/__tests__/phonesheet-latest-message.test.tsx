/**
 * The sheet's Activity tab leads with the agent's last message, also when a
 * permission (Review) card replaces LatestMessage inside RowDetailExtras.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { PhoneSheet } from "../components/phone/PhoneSheet";
import { theme } from "../theme";
import type { BoardRow } from "../types";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
  document.body.innerHTML = "";
});

function row(derived: Partial<BoardRow["derived"]> = {}): BoardRow {
  return {
    rowKind: "session",
    rowId: "alpha",
    status: "live",
    derived: {
      paneId: "w8:p1",
      paneIdSanitized: "w8-p1",
      label: "alpha",
      cwd: null,
      focused: false,
      hookState: "idle",
      hookSinceSec: 5,
      herdrStatus: "idle",
      disagree: false,
      hasHookData: true,
      screenState: "IDLE",
      source: "herdr",
      messageVia: "pane",
      agentKind: "claude",
      ...derived,
    },
    values: {},
  };
}

function stubLatest(latestMessage: string) {
  globalThis.fetch = (async (url: unknown) => {
    const reply = String(url).startsWith("/api/session/latest")
      ? { ok: true, rowId: "alpha", latestMessage, pendingQuestion: null }
      : {};
    return { ok: true, status: 200, json: async () => reply } as Response;
  }) as typeof fetch;
}

async function mountSheet(r: BoardRow) {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  act(() => {
    root.render(
      <MantineProvider theme={theme}>
        <PhoneSheet row={r} properties={[]} onClose={() => {}} onToast={() => {}} onRefetch={() => {}} />
      </MantineProvider>,
    );
  });
  await act(async () => {
    for (let i = 0; i < 6; i++) await Promise.resolve();
  });
  return () => act(() => root.unmount());
}

describe("PhoneSheet last message", () => {
  test("an idle session shows its latest message with mono code", async () => {
    stubLatest("All **done** — see `foo.ts`");
    const unmount = await mountSheet(row());
    const block = document.querySelector(".latest-message");
    expect(block?.textContent).toContain("All done");
    expect(block?.querySelector("code")).not.toBe(null);
    unmount();
  });

  test("a session blocked on a permission box still shows the message above the Review card", async () => {
    stubLatest("I need to run the migration");
    const unmount = await mountSheet(
      row({
        screenState: "NEEDS_HUMAN",
        screenPermission: {
          tool: "Bash",
          detail: "rm build.log",
          title: "Bash command",
          options: [{ index: 1, label: "Yes" }, { index: 2, label: "No" }],
          cursorIndex: 1,
        },
      }),
    );
    const blocks = document.querySelectorAll(".latest-message");
    expect(blocks.length).toBe(1);
    expect(blocks[0].textContent).toContain("I need to run the migration");
    expect(document.body.textContent).toContain("rm build.log");
    unmount();
  });
});
