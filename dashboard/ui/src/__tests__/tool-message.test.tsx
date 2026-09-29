/**
 * Messaging an OpenCode / Codex session from the phone sheet (dashboard
 * Phase 4). The server decides (`messageRefusal`): a row with fresh exact
 * status has none, so the Composer shows, with a caption that the text goes
 * as a plain prompt; Compact/Clear never show for these tools; a best-guess
 * row keeps its caption and gets no Composer.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { PhoneSheet } from "../components/phone/PhoneSheet";
import { TOOL_MESSAGE_CAPTION, takesQuickCommands } from "../messageGates";
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
    rowId: "tool-row",
    status: "live",
    derived: {
      paneId: "w8:p1",
      paneIdSanitized: "w8-p1",
      label: "tool",
      cwd: null,
      focused: false,
      hookState: "idle",
      hookSinceSec: 5,
      herdrStatus: "idle",
      disagree: false,
      hasHookData: true,
      screenState: "WAITING",
      source: "herdr",
      messageVia: "pane",
      agentKind: "opencode",
      statusSource: "opencode-plugin",
      messageRefusal: null,
      ...derived,
    },
    values: {},
  } as BoardRow;
}

function mount(r: BoardRow) {
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
  return () => act(() => root.unmount());
}

const buttonLabels = () => [...document.querySelectorAll("button")].map((b) => b.textContent?.trim());

describe("OpenCode / Codex rows", () => {
  test.each(["opencode", "codex"])("%s with fresh status: Composer + plain-prompt caption, no Compact/Clear", (kind) => {
    const unmount = mount(row({ agentKind: kind }));
    expect(document.querySelector(".composer")).toBeTruthy();
    expect(document.querySelector(".composer-tool-note")?.textContent).toBe(TOOL_MESSAGE_CAPTION);
    expect(buttonLabels()).not.toContain("Compact");
    expect(buttonLabels()).not.toContain("Clear");
    unmount();
  });

  test("a best-guess row (server refuses): caption, no Composer", () => {
    const unmount = mount(row({ hasHookData: false, statusSource: null, messageRefusal: "refused: opencode prompts are invisible" }));
    expect(document.querySelector(".composer")).toBeNull();
    expect(document.querySelector(".phone-sheet-gate-note")?.textContent).toContain("no live status");
    unmount();
  });

  test("a Claude row shows no tool caption", () => {
    const unmount = mount(row({ agentKind: "claude", statusSource: null }));
    expect(document.querySelector(".composer")).toBeTruthy();
    expect(document.querySelector(".composer-tool-note")).toBeNull();
    unmount();
  });

  test("takesQuickCommands: never for a tool row, even with hook data", () => {
    expect(takesQuickCommands(row({ agentKind: "codex" }))).toBe(false);
    expect(takesQuickCommands(row({ agentKind: "claude" }))).toBe(true);
  });
});
