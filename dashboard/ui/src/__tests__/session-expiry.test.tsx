/**
 * QA pass 2 (phase 2, phone PWA): a remote-listener (Tailscale) session
 * whose cookie/token has expired or rotated mid-session must send the
 * phone to /remote/login instead of freezing on a stale board or crashing
 * on a `{ok:false,error:"unauthenticated"}` body treated as real state.
 *
 * Server contract (chief-dashboard-server.py `_remote_authenticated`): only
 * a raw page GET gets a 302 to /remote/login; every /api/* request instead
 * gets a 401 JSON body. useDashboardState (src/api.ts) is the only reader
 * of /api/state + /api/events, so the redirect has to live there.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { useDashboardState } from "../api";

const realFetch = globalThis.fetch;
const realEventSource = (globalThis as { EventSource?: unknown }).EventSource;
const realAssign = window.location.assign.bind(window.location);

afterEach(() => {
  globalThis.fetch = realFetch;
  (globalThis as { EventSource?: unknown }).EventSource = realEventSource;
  window.location.assign = realAssign;
  document.body.innerHTML = "";
});

async function flush() {
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
  });
}

/** A boxed value, so TS never narrows `.url` to the literal `null` its
 *  initializer used — it's mutated from inside an unrelated closure
 *  (`window.location.assign`), which control-flow narrowing can't see. */
function redirectSpy() {
  const box: { url: string | null } = { url: null };
  window.location.assign = ((url: string) => {
    box.url = url;
  }) as typeof window.location.assign;
  return box;
}

function stubFetch(status: number, body: unknown) {
  globalThis.fetch = (async () => ({
    status,
    json: async () => body,
  })) as unknown as typeof fetch;
}

function mountHook() {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  let seen: unknown = "unset";
  function Probe() {
    seen = useDashboardState();
    return null;
  }
  act(() => {
    root.render(<Probe />);
  });
  return {
    getState: () => seen,
    unmount: () => {
      act(() => root.unmount());
      host.remove();
    },
  };
}

describe("useDashboardState — session expiry", () => {
  test("a 401 from /api/state redirects to /remote/login instead of storing the error body as state", async () => {
    const redirect = redirectSpy();
    stubFetch(401, { ok: false, error: "unauthenticated" });

    class FakeEventSource {
      static readonly CLOSED = 2;
      readyState = 1;
      onmessage: ((ev: { data: string }) => void) | null = null;
      onerror: (() => void) | null = null;
      close() {}
    }
    (globalThis as { EventSource?: unknown }).EventSource = FakeEventSource;

    const { getState, unmount } = mountHook();
    await flush();

    expect(redirect.url).toBe("/remote/login");
    // Never stored the {ok:false,...} error body as if it were FullState —
    // downstream reads like state.computed.needsYou would otherwise throw.
    expect(getState()).toBeNull();
    unmount();
  });

  test("the EventSource closing permanently (readyState CLOSED) after a mid-session 401 also redirects", async () => {
    const redirect = redirectSpy();
    stubFetch(200, { ok: true });

    let liveInstance: FakeEventSource | null = null;
    class FakeEventSource {
      static readonly CLOSED = 2;
      readyState = 1;
      onmessage: ((ev: { data: string }) => void) | null = null;
      onerror: (() => void) | null = null;
      constructor() {
        liveInstance = this;
      }
      close() {}
    }
    (globalThis as { EventSource?: unknown }).EventSource = FakeEventSource;

    const { unmount } = mountHook();
    await flush();

    expect(redirect.url).toBeNull(); // no redirect yet — connection still open

    // Simulate the spec's "fail the connection" outcome for a non-200
    // reconnect attempt (our 401): readyState lands on CLOSED, then onerror
    // fires — unlike a transient network blip, which leaves it CONNECTING.
    liveInstance!.readyState = FakeEventSource.CLOSED;
    liveInstance!.onerror?.();

    expect(redirect.url).toBe("/remote/login");
    unmount();
  });

  test("a transient EventSource error (readyState still CONNECTING) does not redirect", async () => {
    const redirect = redirectSpy();
    stubFetch(200, { ok: true });

    let liveInstance: FakeEventSource | null = null;
    class FakeEventSource {
      static readonly CLOSED = 2;
      static readonly CONNECTING = 0;
      readyState = 0;
      onmessage: ((ev: { data: string }) => void) | null = null;
      onerror: (() => void) | null = null;
      constructor() {
        liveInstance = this;
      }
      close() {}
    }
    (globalThis as { EventSource?: unknown }).EventSource = FakeEventSource;

    const { unmount } = mountHook();
    await flush();

    liveInstance!.onerror?.(); // browser is auto-retrying; readyState stays CONNECTING
    expect(redirect.url).toBeNull();
    unmount();
  });
});
