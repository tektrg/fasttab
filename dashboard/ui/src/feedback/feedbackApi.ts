/** Feedback tab data: dashboard server proxy (`server/lib/feedback_admin_proxy.py`)
 *  -> theindie-api admin routes. The admin secret stays on the server. */
import { useCallback, useEffect, useState } from "react";
import type { FeedbackThread } from "./feedbackTableView";

export interface FeedbackMessage {
  messageID?: string;
  id?: string;
  author: string;
  body: string;
  createdAt?: number;
}

type Reply<T> = T & { ok: boolean; error?: string };

async function feedbackRequest<T>(url: string, method = "GET", body?: unknown): Promise<Reply<T>> {
  try {
    const response = await fetch(url, {
      method,
      headers: body === undefined ? undefined : { "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const parsed = await response.json().catch(() => ({}));
    return { ok: response.ok && parsed.ok !== false, ...parsed } as Reply<T>;
  } catch (error) {
    return { ok: false, error: String(error) } as Reply<T>;
  }
}

const THREADS_URL = "/api/feedback/threads";
export const FEEDBACK_PAGE_LIMIT = 200;

export function fetchFeedbackThreads() {
  return feedbackRequest<{ threads: FeedbackThread[]; hasMore: boolean }>(`${THREADS_URL}?scope=all&limit=${FEEDBACK_PAGE_LIMIT}`);
}

export function fetchFeedbackThread(threadID: string) {
  return feedbackRequest<{ thread: FeedbackThread; messages: FeedbackMessage[] }>(`${THREADS_URL}/${encodeURIComponent(threadID)}`);
}

export function resolveFeedbackThread(threadID: string, input: { message?: string; shippedInVersion?: string } = {}) {
  return feedbackRequest<{ messageID: string | null }>(`${THREADS_URL}/${encodeURIComponent(threadID)}/resolve`, "POST", input);
}

/** Resolve pushes a real message to a customer: one request per thread at a time. */
export function createResolveGuard() {
  const inFlight = new Set<string>();
  return {
    start: (threadID: string) => (inFlight.has(threadID) ? false : (inFlight.add(threadID), true)),
    finish: (threadID: string) => void inFlight.delete(threadID),
    has: (threadID: string) => inFlight.has(threadID),
  };
}

/** Thread list + refetch. `error` is shown verbatim (the proxy writes it for people). */
export function useFeedbackThreads() {
  const [threads, setThreads] = useState<FeedbackThread[] | null>(null);
  const [hasMore, setHasMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const reload = useCallback(async () => {
    const reply = await fetchFeedbackThreads();
    if (!reply.ok) {
      setError(reply.error || "could not load feedback");
      return;
    }
    setError(null);
    setThreads(reply.threads);
    setHasMore(!!reply.hasMore);
  }, []);
  useEffect(() => {
    void reload();
  }, [reload]);
  return { threads, hasMore, error, reload };
}
