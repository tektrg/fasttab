import { describe, expect, test } from "bun:test";
import { createToastStore, TOAST_MS, type Scheduler } from "../ui/toastStore";

function fakeClock() {
  let now = 0;
  const tasks = new Map<number, { at: number; fn: () => void }>();
  let id = 0;
  const scheduler: Scheduler = {
    set: (fn, ms) => { tasks.set(++id, { at: now + ms, fn }); return id; },
    clear: (h) => void tasks.delete(h as number),
  };
  const advance = (ms: number) => {
    now += ms;
    for (const [k, t] of [...tasks]) if (t.at <= now) { tasks.delete(k); t.fn(); }
  };
  return { scheduler, advance };
}

describe("toast store", () => {
  test("auto-dismisses after 5s, not before", () => {
    const c = fakeClock();
    const s = createToastStore(c.scheduler);
    s.show({ message: "hi" });
    c.advance(TOAST_MS - 1);
    expect(s.get()?.message).toBe("hi");
    c.advance(1);
    expect(s.get()).toBeNull();
  });
  test("a newer toast replaces the old one and restarts the clock", () => {
    const c = fakeClock();
    const s = createToastStore(c.scheduler);
    s.show({ message: "a" });
    c.advance(3000);
    s.show({ message: "b" });
    c.advance(3000);
    expect(s.get()?.message).toBe("b");
    c.advance(2000);
    expect(s.get()).toBeNull();
  });
  test("undo runs the action once and dismisses", () => {
    const c = fakeClock();
    const s = createToastStore(c.scheduler);
    let calls = 0;
    const id = s.show({ message: "x", actionLabel: "Undo", onAction: () => calls++ });
    s.triggerAction(id);
    s.triggerAction(id);
    expect(calls).toBe(1);
    expect(s.get()).toBeNull();
  });
  test("undo after expiry or on a replaced toast does nothing", () => {
    const c = fakeClock();
    const s = createToastStore(c.scheduler);
    let calls = 0;
    const old = s.show({ message: "x", onAction: () => calls++ });
    s.show({ message: "y" });
    s.triggerAction(old);
    expect(calls).toBe(0);
    expect(s.get()?.message).toBe("y");
  });
  test("subscribers are notified on show and dismiss", () => {
    const c = fakeClock();
    const s = createToastStore(c.scheduler);
    let n = 0;
    s.subscribe(() => n++);
    s.show({ message: "x" });
    c.advance(TOAST_MS);
    expect(n).toBe(2);
  });
});
