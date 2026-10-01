/**
 * Image attachments in the Composer (board + PhoneSheet): attach -> upload
 * raw bytes -> message carries the ids; a failed upload sends nothing.
 * fetch, createImageBitmap and object URLs are stubbed — nothing leaves the test.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { Composer } from "../components/Composer";
import { fitWithin, imagesFromClipboard, MAX_IMAGES } from "../imageAttachments";
import { theme } from "../theme";
import type { BoardRow } from "../types";

const g = globalThis as unknown as Record<string, unknown>;
g.createImageBitmap = async () => ({ width: 10, height: 10, close() {} });
URL.createObjectURL = () => "blob:thumb";
URL.revokeObjectURL = () => {};

const row: BoardRow = {
  rowKind: "session",
  rowId: "r1",
  status: "live",
  derived: {
    paneId: "w8:pX", paneIdSanitized: "w8-pX", label: "r1", cwd: null, focused: false,
    hookState: "idle", hookSinceSec: 1, herdrStatus: "idle", disagree: false,
    hasHookData: true, screenState: "WAITING",
  },
  values: { "derived:label": "label-r1" },
};

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

function stubFetch(upload: { ok: boolean; id?: string; error?: string }) {
  const calls: { url: unknown; body: unknown; type?: string }[] = [];
  globalThis.fetch = (async (url: unknown, init: { body: unknown; headers: Record<string, string> }) => {
    const isUpload = url === "/api/attachments/image";
    calls.push({
      url,
      body: isUpload ? init.body : JSON.parse(init.body as string),
      type: init.headers?.["Content-Type"],
    });
    return { status: 200, json: async () => (isUpload ? upload : { ok: true, state: "message sent" }) };
  }) as unknown as typeof fetch;
  return calls;
}

const airRow: BoardRow = {
  ...row,
  rowId: "r-air",
  derived: { ...row.derived, paneId: "air-m1:w2:p1", hasHookData: false, agentKind: "claude", acceptsImages: false },
};

function mount(onToast: (m: string, ok: boolean) => void = () => {}, rows: BoardRow[] = [row]) {
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

async function attach(host: HTMLElement, count = 1) {
  const input = host.querySelector('input[type="file"]') as HTMLInputElement;
  const files = Array.from({ length: count }, (_, i) => new File([new Uint8Array([137, 80, 78, 71, i])], `$(echo INJECTED)${i}.png`, { type: "image/png" }));
  Object.defineProperty(input, "files", { value: files, configurable: true });
  await act(async () => {
    input.dispatchEvent(new Event("change", { bubbles: true }));
    await new Promise((r) => setTimeout(r, 0));
  });
}

async function pasteImage(input: HTMLInputElement) {
  const png = new File([new Uint8Array([1])], "x.png", { type: "image/png" });
  const paste = new Event("paste", { bubbles: true, cancelable: true }) as Event & { clipboardData: unknown };
  paste.clipboardData = { files: [png], getData: () => "" };
  await act(async () => {
    input.dispatchEvent(paste);
    await new Promise((r) => setTimeout(r, 0));
  });
}

async function clickSend(host: HTMLElement) {
  const btn = [...host.querySelectorAll("button")].find((b) => b.textContent === "Send")!;
  await act(async () => {
    btn.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    await new Promise((r) => setTimeout(r, 0));
  });
}

describe("image attachments", () => {
  test("fitWithin caps the long edge at 2048", () => {
    expect(fitWithin(4000, 1000)).toEqual({ width: 2048, height: 512 });
    expect(fitWithin(800, 600)).toEqual({ width: 800, height: 600 });
  });

  test("a paste carrying text (Office copies add an image rendering) stays a text paste", () => {
    const png = new File([new Uint8Array([1])], "x.png", { type: "image/png" });
    const clip = (text: string) => ({ files: [png], getData: () => text }) as unknown as DataTransfer;
    expect(imagesFromClipboard(clip("hello"))).toEqual([]);
    expect(imagesFromClipboard(clip("")).length).toBe(1);
  });

  test("an image alone enables Send; upload first, then the message carries the id", async () => {
    const calls = stubFetch({ ok: true, id: "a".repeat(32) });
    const { host, unmount } = mount();
    await attach(host);
    expect(host.querySelectorAll(".image-attach-thumb").length).toBe(1);
    await clickSend(host);
    expect(calls.map((c) => c.url)).toEqual(["/api/attachments/image", "/api/session/message"]);
    expect(calls[0].type).toBe("image/png");
    expect((calls[1].body as { attachments: string[] }).attachments).toEqual(["a".repeat(32)]);
    expect(JSON.stringify(calls[1].body)).not.toContain("INJECTED"); // file names never travel
    expect(host.querySelectorAll(".image-attach-thumb").length).toBe(0); // cleared after sending
    unmount();
  });

  test("a failed upload sends no message and keeps the image", async () => {
    const calls = stubFetch({ ok: false, error: "not an image" });
    const toasts: string[] = [];
    const { host, unmount } = mount((m) => toasts.push(m));
    await attach(host);
    await clickSend(host);
    expect(calls.filter((c) => c.url === "/api/session/message").length).toBe(0);
    expect(toasts.some((t) => t.includes("not an image"))).toBe(true);
    expect(host.querySelectorAll(".image-attach-thumb").length).toBe(1);
    unmount();
  });

  test("a row on another machine: no attach button, paste ignored, text messaging unchanged", async () => {
    const calls = stubFetch({ ok: true, id: "c".repeat(32) });
    const { host, unmount } = mount(() => {}, [airRow]);
    expect(host.querySelector(".image-attach-button")).toBeNull();
    expect(host.textContent).toContain("Images can only go to agents on this Mac");
    const input = host.querySelector("input:not([type=file])") as HTMLInputElement;
    await pasteImage(input);
    expect(host.querySelectorAll(".image-attach-thumb").length).toBe(0);
    await act(async () => {
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
      setter.call(input, "hello air");
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    await clickSend(host);
    expect(calls.map((c) => c.url)).toEqual(["/api/session/message"]);
    expect((calls[0].body as { text: string }).text).toBe("hello air");
    unmount();
  });

  test("a local row keeps the attach button, takes a pasted image, no remote note", async () => {
    stubFetch({ ok: true });
    const { host, unmount } = mount();
    expect(host.querySelector(".image-attach-button")).not.toBeNull();
    expect(host.textContent).not.toContain("Images can only go to agents on this Mac");
    await pasteImage(host.querySelector("input:not([type=file])") as HTMLInputElement);
    expect(host.querySelectorAll(".image-attach-thumb").length).toBe(1);
    unmount();
  });

  test(`at most ${MAX_IMAGES} images`, async () => {
    stubFetch({ ok: true, id: "b".repeat(32) });
    const { host, unmount } = mount();
    await attach(host, MAX_IMAGES + 1);
    expect(host.querySelectorAll(".image-attach-thumb").length).toBe(MAX_IMAGES);
    expect(host.textContent).toContain(`At most ${MAX_IMAGES} images`);
    unmount();
  });
});
