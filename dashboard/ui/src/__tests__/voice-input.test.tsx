/**
 * Voice input: record (fake MediaRecorder / getUserMedia) -> upload -> poll
 * transcribe -> transcript joins the draft. fetch is stubbed; no mic, no network.
 */
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { Composer } from "../components/Composer";
import { VoiceRecorderBar } from "../components/VoiceRecorderBar";
import { theme } from "../theme";
import type { BoardRow } from "../types";
import { appendTranscript, formatClock } from "../voice/transcript";
import { useVoiceInput } from "../voice/useVoiceInput";
import {
  MIC_DENIED_MESSAGE,
  MIC_UNSUPPORTED_MESSAGE,
  MAX_RECORDING_MS,
  TOO_SHORT_MESSAGE,
  baseMime,
  pickRecorderMime,
} from "../voice/useVoiceRecorder";
import { TIMEOUT_MESSAGE } from "../voice/useTranscription";

const g = globalThis as unknown as Record<string, unknown>;
const realFetch = globalThis.fetch;
const realMediaRecorder = g.MediaRecorder;
const mediaDevicesDescriptor = Object.getOwnPropertyDescriptor(navigator, "mediaDevices");

// ---- fakes -------------------------------------------------------------
let supported: string[] = [];
let recorders: FakeRecorder[] = [];
class FakeRecorder {
  static isTypeSupported(m: string) {
    return supported.includes(m);
  }
  state = "inactive";
  mimeType: string;
  ondataavailable: ((e: { data: Blob }) => void) | null = null;
  onstop: (() => void) | null = null;
  onerror: (() => void) | null = null;
  constructor(_stream: unknown, opts?: { mimeType?: string }) {
    this.mimeType = opts?.mimeType ?? "";
    recorders.push(this);
  }
  start() {
    this.state = "recording";
  }
  stop() {
    this.state = "inactive";
    this.ondataavailable?.({ data: new Blob(["audio-bytes"]) });
    this.onstop?.();
  }
}

let trackStops = 0;
let micError: { name: string } | null = null;
function installMic() {
  Object.defineProperty(navigator, "mediaDevices", {
    configurable: true,
    value: {
      getUserMedia: async () => {
        if (micError) throw micError;
        return { getTracks: () => [{ stop: () => void trackStops++ }] };
      },
    },
  });
}

let clock = 0;
const now = () => clock;

type Call = { url: string; method: string; type?: string; body: unknown };
let calls: Call[] = [];
/** Scripted answers: upload, then each transcribe/poll answer in order. */
function stubServer(opts: { upload?: Response | object; polls?: object[]; start?: object; uploadStatus?: number }) {
  calls = [];
  const polls = [...(opts.polls ?? [])];
  globalThis.fetch = (async (url: string, init?: { method?: string; headers?: Record<string, string>; body?: unknown }) => {
    const method = init?.method ?? "GET";
    calls.push({ url, method, type: init?.headers?.["Content-Type"], body: init?.body });
    const reply = (status: number, json: object) => ({ status, ok: status < 400, json: async () => json });
    if (url === "/api/attachments/audio") {
      return reply(opts.uploadStatus ?? 200, (opts.upload as object) ?? { ok: true, id: "a1" });
    }
    if (url === "/api/transcribe") return reply(200, opts.start ?? { ok: true, id: "a1", state: "pending" });
    if (url.startsWith("/api/transcribe/")) {
      const next = polls.length > 1 ? polls.shift()! : polls[0] ?? { ok: true, state: "pending" };
      return reply(200, next);
    }
    return reply(404, { ok: false });
  }) as unknown as typeof fetch;
}

beforeEach(() => {
  supported = ["audio/mp4", "audio/webm"];
  recorders = [];
  trackStops = 0;
  micError = null;
  clock = 1_000;
  g.MediaRecorder = FakeRecorder;
  installMic();
});
afterEach(() => {
  globalThis.fetch = realFetch;
  g.MediaRecorder = realMediaRecorder;
  if (mediaDevicesDescriptor) Object.defineProperty(navigator, "mediaDevices", mediaDevicesDescriptor);
  document.body.innerHTML = "";
});

// ---- harness -----------------------------------------------------------
const wait = (ms = 30) => act(async () => void (await new Promise((r) => setTimeout(r, ms))));

function Harness({ onText, giveUpAfterMs }: { onText: (t: string) => void; giveUpAfterMs?: number }) {
  const voice = useVoiceInput({ onText, now, pollIntervalMs: 5, giveUpAfterMs });
  return <VoiceRecorderBar voice={voice} />;
}

function mount(onText: (t: string) => void = () => {}, giveUpAfterMs?: number) {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  act(() => root.render(<Harness onText={onText} giveUpAfterMs={giveUpAfterMs} />));
  return { host, unmount: () => act(() => root.unmount()) };
}

async function press(host: HTMLElement, label: string) {
  const btn = host.querySelector(`button[aria-label="${label}"]`) as HTMLButtonElement;
  expect(btn).toBeTruthy();
  await act(async () => {
    btn.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    await new Promise((r) => setTimeout(r, 0));
  });
}

async function recordFor(host: HTMLElement, ms: number) {
  await press(host, "record voice message");
  clock += ms;
  await press(host, "stop recording");
}

// ---- tests -------------------------------------------------------------
describe("pure helpers", () => {
  test("mime preference: mp4, then webm opus, then webm, else browser default", () => {
    supported = ["audio/webm", "audio/mp4", "audio/webm;codecs=opus"];
    expect(pickRecorderMime()).toBe("audio/mp4");
    supported = ["audio/webm", "audio/webm;codecs=opus"];
    expect(pickRecorderMime()).toBe("audio/webm;codecs=opus");
    supported = ["audio/webm"];
    expect(pickRecorderMime()).toBe("audio/webm");
    supported = [];
    expect(pickRecorderMime()).toBe("");
    expect(baseMime("audio/webm;codecs=opus")).toBe("audio/webm");
  });

  test("transcript joins after the draft and never replaces it", () => {
    expect(appendTranscript("", "hello there")).toBe("hello there");
    expect(appendTranscript("   ", "hello")).toBe("hello");
    expect(appendTranscript("fix the bug  ", " and add tests ")).toBe("fix the bug and add tests");
    expect(appendTranscript("keep me", "")).toBe("keep me");
  });

  test("clock format", () => {
    expect(formatClock(65_000)).toBe("1:05");
    expect(formatClock(-5)).toBe("0:00");
  });
});

describe("recording", () => {
  test("record -> upload with the bare mime -> transcribe -> text delivered, mic released", async () => {
    stubServer({ polls: [{ ok: true, state: "pending" }, { ok: true, state: "done", text: "hello world" }] });
    const texts: string[] = [];
    const { host } = mount((t) => texts.push(t));
    await press(host, "record voice message");
    expect(host.querySelector(".voice-dot")).toBeTruthy();
    clock += 5_000;
    await press(host, "stop recording");
    await wait();
    expect(calls[0].url).toBe("/api/attachments/audio");
    expect(calls[0].type).toBe("audio/mp4");
    expect(calls[1]).toMatchObject({ url: "/api/transcribe", method: "POST", body: JSON.stringify({ id: "a1" }) });
    expect(calls.some((c) => c.url === "/api/transcribe/a1")).toBe(true);
    expect(texts).toEqual(["hello world"]);
    expect(trackStops).toBe(1);
    expect(host.querySelector('button[aria-label="record voice message"]')).toBeTruthy();
  });

  test("webm recorder: header type has no codecs param", async () => {
    supported = ["audio/webm;codecs=opus"];
    stubServer({ polls: [{ ok: true, state: "done", text: "x" }] });
    const { host } = mount();
    await recordFor(host, 2_000);
    await wait();
    expect(calls[0].type).toBe("audio/webm");
  });

  test("permission denied explains how to allow it", async () => {
    micError = { name: "NotAllowedError" };
    stubServer({});
    const { host } = mount();
    await press(host, "record voice message");
    expect(host.querySelector(".voice-error")?.textContent).toBe(MIC_DENIED_MESSAGE);
    expect(MIC_DENIED_MESSAGE).toContain("Settings");
    expect(calls.length).toBe(0);
  });

  test("no MediaRecorder -> plain message, nothing starts", async () => {
    g.MediaRecorder = undefined;
    const { host } = mount();
    await press(host, "record voice message");
    expect(host.querySelector(".voice-error")?.textContent).toBe(MIC_UNSUPPORTED_MESSAGE);
  });

  test("a recording under 0.7s is ignored and the mic is released", async () => {
    stubServer({});
    const { host } = mount();
    await recordFor(host, 300);
    await wait();
    expect(calls.length).toBe(0);
    expect(trackStops).toBe(1);
    expect(host.querySelector(".voice-error")?.textContent).toBe(TOO_SHORT_MESSAGE);
  });

  test("cancel uploads nothing and releases the mic", async () => {
    stubServer({});
    const { host } = mount();
    await press(host, "record voice message");
    clock += 5_000;
    await press(host, "cancel recording");
    await wait();
    expect(calls.length).toBe(0);
    expect(trackStops).toBe(1);
  });

  test("tab backgrounded mid-recording stops and keeps the audio", async () => {
    stubServer({ polls: [{ ok: true, state: "done", text: "kept" }] });
    const texts: string[] = [];
    const { host } = mount((t) => texts.push(t));
    await press(host, "record voice message");
    clock += 4_000;
    Object.defineProperty(document, "visibilityState", { configurable: true, value: "hidden" });
    await act(async () => {
      document.dispatchEvent(new Event("visibilitychange"));
      await new Promise((r) => setTimeout(r, 0));
    });
    await wait();
    Object.defineProperty(document, "visibilityState", { configurable: true, value: "visible" });
    expect(calls[0].url).toBe("/api/attachments/audio");
    expect(texts).toEqual(["kept"]);
    expect(trackStops).toBe(1);
  });

  test("hitting the 15 minute cap stops automatically", async () => {
    stubServer({ polls: [{ ok: true, state: "done", text: "long" }] });
    const { host } = mount();
    await press(host, "record voice message");
    clock += MAX_RECORDING_MS;
    await wait(320); // one 250ms timer tick
    expect(recorders[0].state).toBe("inactive");
    expect(calls[0].url).toBe("/api/attachments/audio");
  });

  test("countdown shows once 14:00 has passed", async () => {
    stubServer({});
    const { host } = mount();
    await press(host, "record voice message");
    expect(host.querySelector(".voice-countdown")).toBeNull();
    clock += 14 * 60_000 + 1_000;
    await wait(320);
    expect(host.querySelector(".voice-countdown")?.textContent).toBe("0:59 left");
  });

  test("leaving mid-recording frees the mic and uploads nothing", async () => {
    stubServer({});
    const { host, unmount } = mount();
    await press(host, "record voice message");
    clock += 5_000;
    unmount();
    await wait();
    expect(trackStops).toBe(1);
    expect(calls.length).toBe(0);
  });
});

describe("transcription", () => {
  test("failed shows the server's plain error; Retry re-POSTs the same id, then succeeds", async () => {
    stubServer({ polls: [{ ok: true, state: "failed", error: "The speech service is busy." }] });
    const texts: string[] = [];
    const { host } = mount((t) => texts.push(t));
    await recordFor(host, 3_000);
    await wait();
    expect(host.querySelector(".voice-error")?.textContent).toBe("The speech service is busy.");
    const before = calls.filter((c) => c.url === "/api/transcribe").length;
    stubServer({ polls: [{ ok: true, state: "done", text: "second try" }] });
    await press(host, "retry transcription");
    await wait();
    expect(calls[0]).toMatchObject({ url: "/api/transcribe", method: "POST", body: JSON.stringify({ id: "a1" }) });
    expect(before).toBe(1);
    expect(texts).toEqual(["second try"]);
    // the audio was not uploaded again
    expect(calls.some((c) => c.url === "/api/attachments/audio")).toBe(false);
  });

  test("upload refused (413) shows a size message and Retry re-uploads", async () => {
    stubServer({ uploadStatus: 413, upload: { ok: false } });
    const { host } = mount();
    await recordFor(host, 3_000);
    await wait();
    expect(host.querySelector(".voice-error")?.textContent).toContain("25 MB");
    stubServer({ polls: [{ ok: true, state: "done", text: "ok" }] });
    await press(host, "retry transcription");
    await wait();
    expect(calls[0].url).toBe("/api/attachments/audio");
  });

  test("offline mid-upload: plain message (no raw TypeError), recording kept, Retry re-uploads it", async () => {
    stubServer({});
    globalThis.fetch = (async () => {
      throw new TypeError("Failed to fetch");
    }) as unknown as typeof fetch;
    const { host } = mount();
    await recordFor(host, 3_000);
    await wait();
    const shown = host.querySelector(".voice-error")?.textContent ?? "";
    expect(shown).toContain("Check your connection");
    expect(shown).not.toContain("TypeError");
    stubServer({ polls: [{ ok: true, state: "done", text: "back online" }] });
    const texts: string[] = [];
    await press(host, "retry transcription");
    await wait();
    expect(calls[0].url).toBe("/api/attachments/audio");
    expect(texts.length).toBe(0);
    expect(host.querySelector(".voice-error")).toBeNull();
  });

  test("Vietnamese transcript with diacritics arrives intact", async () => {
    const spoken = "Xin chào, tôi là Trung. Đây là bản ghi thử nghiệm: ạ ệ ữ ơ";
    stubServer({ polls: [{ ok: true, state: "done", text: spoken }] });
    const texts: string[] = [];
    const { host } = mount((t) => texts.push(t));
    await recordFor(host, 3_000);
    await wait();
    expect(texts).toEqual([spoken]);
  });

  test("gives up with a plain message when it never finishes", async () => {
    stubServer({ polls: [{ ok: true, state: "pending" }] });
    const { host } = mount(() => {}, 40);
    await recordFor(host, 3_000);
    await wait(120);
    expect(host.querySelector(".voice-error")?.textContent).toBe(TIMEOUT_MESSAGE);
  });

  test("Record again after a failure starts a fresh recording", async () => {
    stubServer({ polls: [{ ok: true, state: "failed", error: "nope" }] });
    const { host } = mount();
    await recordFor(host, 3_000);
    await wait();
    await press(host, "record again");
    expect(host.querySelector(".voice-dot")).toBeTruthy();
    expect(host.querySelector(".voice-error")).toBeNull();
  });

  test("a blank transcript is reported, not inserted", async () => {
    stubServer({ polls: [{ ok: true, state: "done", text: "  " }] });
    const texts: string[] = [];
    const { host } = mount((t) => texts.push(t));
    await recordFor(host, 3_000);
    await wait();
    expect(texts).toEqual([]);
    expect(host.querySelector(".voice-error")?.textContent).toContain("No speech");
  });
});

describe("in the message box", () => {
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

  test("transcript lands after the typed draft; nothing is sent", async () => {
    stubServer({ polls: [{ ok: true, state: "done", text: "and run the tests" }] });
    const host = document.createElement("div");
    document.body.appendChild(host);
    const root = createRoot(host);
    act(() =>
      root.render(
        <MantineProvider theme={theme}>
          <Composer rows={[row]} initialText="fix the login bug" onToast={() => {}} />
        </MantineProvider>,
      ),
    );
    await press(host, "record voice message");
    await wait(750); // the Composer uses the real clock: outlast the 0.7s minimum
    await press(host, "stop recording");
    await wait(1800); // default 1.5s poll cadence
    const input = host.querySelector('input[type="text"], input:not([type])') as HTMLInputElement;
    expect(input.value).toBe("fix the login bug and run the tests");
    expect(calls.some((c) => c.url.includes("/api/sessions") || c.url.includes("message"))).toBe(false);
    act(() => root.unmount());
  });

  test("the last target ending mid-recording keeps Stop reachable (mic never stranded)", async () => {
    stubServer({});
    const host = document.createElement("div");
    document.body.appendChild(host);
    const root = createRoot(host);
    const render = (rows: BoardRow[]) =>
      act(() =>
        root.render(
          <MantineProvider theme={theme}>
            <Composer rows={rows} onToast={() => {}} />
          </MantineProvider>,
        ),
      );
    render([row]);
    await press(host, "record voice message");
    render([]);
    expect(host.querySelector('button[aria-label="stop recording"]')).toBeTruthy();
    act(() => root.unmount());
  });

  test("no mic when there is no one to message", () => {
    const host = document.createElement("div");
    document.body.appendChild(host);
    const root = createRoot(host);
    act(() =>
      root.render(
        <MantineProvider theme={theme}>
          <Composer rows={[]} onToast={() => {}} />
        </MantineProvider>,
      ),
    );
    expect(host.querySelector('button[aria-label="record voice message"]')).toBeNull();
    act(() => root.unmount());
  });
});
