/** Pure toast queue: one toast at a time, auto-dismiss after 5s, Undo action.
 *  Timers are injected so the timing is testable without real clocks. */
export const TOAST_MS = 5000;

export interface ToastInput {
  message: string;
  actionLabel?: string;
  onAction?: () => void;
}
export interface ToastItem extends ToastInput {
  id: number;
}
export interface Scheduler {
  set: (fn: () => void, ms: number) => unknown;
  clear: (handle: unknown) => void;
}

export function createToastStore(scheduler: Scheduler = { set: (fn, ms) => setTimeout(fn, ms), clear: (h) => clearTimeout(h as ReturnType<typeof setTimeout>) }) {
  let current: ToastItem | null = null;
  let timer: unknown = null;
  let nextId = 1;
  const listeners = new Set<() => void>();
  const emit = () => listeners.forEach((l) => l());

  const dismiss = () => {
    if (timer !== null) scheduler.clear(timer);
    timer = null;
    if (current) {
      current = null;
      emit();
    }
  };

  return {
    /** A newer toast replaces the current one and restarts the 5s clock. */
    show(input: ToastInput): number {
      if (timer !== null) scheduler.clear(timer);
      const item = { ...input, id: nextId++ };
      current = item;
      timer = scheduler.set(dismiss, TOAST_MS);
      emit();
      return item.id;
    },
    /** Runs the action once, then dismisses. No-op if the toast already went. */
    triggerAction(id: number) {
      if (!current || current.id !== id) return;
      const action = current.onAction;
      dismiss();
      action?.();
    },
    dismiss,
    get: () => current,
    subscribe(listener: () => void) {
      listeners.add(listener);
      return () => void listeners.delete(listener);
    },
  };
}
export type ToastStore = ReturnType<typeof createToastStore>;
