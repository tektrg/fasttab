/** Feedback "new" dot: threads waiting on the owner (customer wrote last) that
 *  the owner has not looked at yet. Seen marks live on the dashboard server
 *  (`server/lib/feedback_seen.py`), so every browser agrees. */
import { useCallback, useEffect, useRef, useState } from "react";
import type { FeedbackThread } from "./feedbackTableView";

export const FEEDBACK_POLL_MS = 60_000;
const WAITING_URL = "/api/feedback/threads?scope=waiting&limit=200";
const SEEN_URL = "/api/feedback/seen";
type SeenMap = Record<string, number>;

/** Waiting threads with a customer message newer than the seen mark. */
export function unseenWaiting(waiting: FeedbackThread[], seen: SeenMap): FeedbackThread[] {
  return waiting.filter((t) => t.lastMessageAt > (seen[t.threadID.toLowerCase()] ?? 0));
}

/** "(3) Chief Dashboard" — or the plain title when nothing is new. */
export function titleWithCount(base: string, count: number): string {
  return count > 0 ? `(${count}) ${base}` : base;
}

type BadgeNavigator = Navigator & { setAppBadge?: (n?: number) => Promise<void>; clearAppBadge?: () => Promise<void> };

/** Home Screen icon badge (installed web app; no-op where unsupported). */
export function syncAppBadge(count: number, nav: BadgeNavigator = navigator): void {
  const call = count > 0 ? nav.setAppBadge?.(count) : nav.clearAppBadge?.();
  call?.catch(() => {}); // refused (no permission, not installed): the tab badge still shows
}

async function getJson<T>(url: string, init?: RequestInit): Promise<T | null> {
  try {
    const response = await fetch(url, init);
    const body = await response.json();
    return response.ok && body.ok !== false ? (body as T) : null;
  } catch {
    return null;
  }
}

/** Count of unseen waiting threads. While `viewing` (Feedback tab on screen,
 *  window focused) every waiting thread is marked seen, so the count drops to 0. Polls every
 *  minute and on window focus; also keeps `document.title` and the app icon badge in step. */
export function useFeedbackUnread(viewing: boolean): number {
  const [count, setCount] = useState(0);
  const viewingRef = useRef(viewing);
  viewingRef.current = viewing;
  const baseTitle = useRef(document.title);

  const refresh = useCallback(async () => {
    const [list, seenReply] = await Promise.all([
      getJson<{ threads: FeedbackThread[] }>(WAITING_URL),
      getJson<{ seen: SeenMap }>(SEEN_URL),
    ]);
    // Keep the last known count on a failed or malformed poll.
    if (!Array.isArray(list?.threads) || typeof seenReply?.seen !== "object" || !seenReply.seen) return;
    const unseen = unseenWaiting(list.threads, seenReply.seen);
    // Mark seen only when the owner can actually see the list: tab open AND
    // this browser window in front (a background tab must keep the dot).
    const looking = viewingRef.current && document.visibilityState === "visible" && document.hasFocus();
    if (looking && unseen.length > 0) {
      const marks = Object.fromEntries(unseen.map((t) => [t.threadID.toLowerCase(), t.lastMessageAt]));
      const saved = await getJson<{ seen: SeenMap }>(SEEN_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ seen: marks }),
      });
      setCount(saved?.seen ? unseenWaiting(list.threads, saved.seen).length : unseen.length);
      return;
    }
    setCount(unseen.length);
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh, viewing]);
  useEffect(() => {
    const id = window.setInterval(() => void refresh(), FEEDBACK_POLL_MS);
    const onFocus = () => void refresh();
    window.addEventListener("focus", onFocus);
    return () => {
      window.clearInterval(id);
      window.removeEventListener("focus", onFocus);
    };
  }, [refresh]);
  useEffect(() => {
    document.title = titleWithCount(baseTitle.current, count);
    syncAppBadge(count);
  }, [count]);
  return count;
}
