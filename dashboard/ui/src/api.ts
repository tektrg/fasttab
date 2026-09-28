import { useCallback, useEffect, useRef, useState } from "react";
import type {
  AnswerChoice,
  BoardProperty,
  BoardState,
  BoardValue,
  BoardView,
  FullState,
  HookAnswer,
  PaneScreenResponse,
  PermissionPrompt,
  PickerQuestion,
  PropertyOption,
  PropertyType,
  SessionHistoryResponse,
  SessionLatestResponse,
  SessionPlanResponse,
  ViewFilter,
  ViewLayout,
  ViewSort,
} from "./types";

export function fmtAge(sec: number | null | undefined): string {
  if (sec === null || sec === undefined) return "—";
  const s = Math.round(sec);
  if (s < 60) return s + "s";
  if (s < 3600) return Math.round(s / 60) + "m";
  if (s < 86400) return Math.round(s / 3600) + "h";
  return Math.round(s / 86400) + "d";
}

/** A stale/rotated remote-listener session (see REMOTE.md) makes every
 *  /api/* call answer 401 instead of the redirect-to-/remote/login that a
 *  plain page navigation gets — the remote listener only redirects a raw
 *  page GET, not an XHR/fetch/EventSource one (chief-dashboard-server.py
 *  `_is_remote_listener`/`_remote_authenticated`). On localhost (no
 *  `remote.enabled`) this path never fires — auth isn't enforced there. */
function goToRemoteLogin() {
  window.location.assign("/remote/login");
}

/** What a write shows when the remote session expired mid-flow (401). The
 *  page itself goes to the login once its event stream notices (above). */
export const LOGGED_OUT_ERROR = "logged out on this phone — log in again, then retry";

/** One SSE subscription to /api/events (2s full state) + a /api/state fetch
 *  on load — identical shape to what the legacy page consumes. */
export function useDashboardState(): FullState | null {
  const [state, setState] = useState<FullState | null>(null);
  useEffect(() => {
    let dead = false;
    fetch("/api/state")
      .then((r) => {
        if (r.status === 401) {
          goToRemoteLogin();
          return null;
        }
        return r.json();
      })
      .then((s) => {
        if (!dead && s) setState(s);
      })
      .catch(() => {});
    // `answerSurface=web`: this build renders and answers hook prompts
    // (HookRequestCard), so the dashboard may hold them while only this page
    // — e.g. the phone's web remote — is open (server/lib/agentbar_presence.py).
    const es = new EventSource("/api/events?answerSurface=web");
    es.onmessage = (ev) => {
      try {
        setState(JSON.parse(ev.data));
      } catch {
        /* EventSource auto-reconnects */
      }
    };
    es.onerror = () => {
      // Per the EventSource spec, a non-200 response (our 401 on an
      // expired/rotated session) fails the connection PERMANENTLY —
      // readyState lands on CLOSED and the browser does not retry, unlike
      // every other transient error (which leaves it CONNECTING). Left
      // alone, the phone would sit frozen on the last-known board forever
      // with no way back in; treat a CLOSED readyState as "the session is
      // gone" and send the user to log in again instead.
      if (!dead && es.readyState === EventSource.CLOSED) {
        goToRemoteLogin();
      }
    };
    return () => {
      dead = true;
      es.close();
    };
  }, []);
  return state;
}

export interface Toast {
  msg: string;
  ok: boolean;
}

export function useToast() {
  const [toast, setToast] = useState<Toast | null>(null);
  const timer = useRef<number | null>(null);
  // Stable identity: the SSE push re-renders App every 2s, and an unstable
  // `show` propagates down as a new onToast -> new memo deps -> remounted
  // cells, which steals focus from whatever the PO is typing in.
  const show = useCallback((msg: string, ok: boolean) => {
    setToast({ msg, ok });
    if (timer.current) window.clearTimeout(timer.current);
    timer.current = window.setTimeout(() => setToast(null), 2500);
  }, []);
  useEffect(
    () => () => {
      if (timer.current) window.clearTimeout(timer.current);
    },
    [],
  );
  return { toast, show };
}

export async function focusPane(
  paneId: string,
): Promise<{ ok: boolean; error?: string }> {
  try {
    const r = await fetch("/api/focus", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ paneId }),
    });
    return await r.json();
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

export async function answerQuestion(
  paneId: string,
  choice: AnswerChoice,
  question: PickerQuestion,
): Promise<{ ok: boolean; error?: string; next?: PickerQuestion | null }> {
  try {
    const r = await fetch("/api/answer", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        paneId,
        choice,
        question: { title: question.title, question: question.question },
      }),
    });
    return await r.json();
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

/** POST /api/hook/permission/<id>/answer — answers a prompt the
 *  PermissionRequest hook holds for a pane-less (Desktop / CLI) session.
 *  First decision wins: 409 once answered in Claude or elsewhere. */
export async function answerHookRequest(
  requestId: string,
  answer: HookAnswer,
): Promise<{ ok: boolean; error?: string }> {
  return requestJson(`/api/hook/permission/${encodeURIComponent(requestId)}/answer`, "POST", answer);
}

/** POST /api/permission — Review (Allow / Allow always / Deny) and the plan
 *  card's "select" (row.index, optional feedback text on the "Tell Claude
 *  what to change" row). The dashboard re-reads the pane fresh and refuses
 *  unless `permission` still matches letter-for-letter (server contract,
 *  chief-dashboard-server.py ~L109-160) — send the exact object the state
 *  carried, never a hand-built one. */
export async function answerPermission(
  paneId: string,
  choice: "allow" | "deny" | "allow-always" | "select",
  permission: PermissionPrompt,
  opts: { index?: number; text?: string } = {},
): Promise<{ ok: boolean; error?: string; next?: PermissionPrompt | null }> {
  try {
    const r = await fetch("/api/permission", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        paneId,
        choice,
        permission: {
          tool: permission.tool,
          detail: permission.detail,
          title: permission.title,
          options: permission.options,
          cursorIndex: permission.cursorIndex,
          ...(permission.kind !== undefined ? { kind: permission.kind } : {}),
          ...(permission.planPath !== undefined ? { planPath: permission.planPath } : {}),
        },
        ...(opts.index !== undefined ? { index: opts.index } : {}),
        ...(opts.text !== undefined ? { text: opts.text } : {}),
      }),
    });
    return await r.json();
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

/** GET /api/session/latest?rowId= — last assistant text + a pending
 *  multi-question AskUserQuestion form, read from the session's transcript
 *  (works for a row on a remote machine too — see session_transcript.py). */
export async function fetchSessionLatest(
  rowId: string,
): Promise<SessionLatestResponse> {
  return requestJson<SessionLatestResponse>(
    `/api/session/latest?rowId=${encodeURIComponent(rowId)}`,
    "GET",
  );
}

/** GET /api/session/plan?rowId= — the plan file text for a row currently
 *  blocked on a plan-approval box (re-reads the pane fresh server-side). */
export async function fetchSessionPlan(
  rowId: string,
): Promise<SessionPlanResponse> {
  return requestJson<SessionPlanResponse>(
    `/api/session/plan?rowId=${encodeURIComponent(rowId)}`,
    "GET",
  );
}

export async function createProperty(input: {
  name: string;
  type: PropertyType;
  options?: Pick<PropertyOption, "name" | "color">[];
  rowKind?: string;
}): Promise<{ ok: boolean; property?: BoardProperty; error?: string }> {
  const { rowKind = "session", ...rest } = input;
  return requestJson("/api/properties", "POST", { rowKind, ...rest });
}

export async function updateProperty(
  propertyId: string,
  input: Partial<{
    name: string;
    type: PropertyType;
    options: PropertyOption[];
  }>,
): Promise<{
  ok: boolean;
  property?: BoardProperty & {
    migration?: {
      from: string;
      to: string;
      migrated: number;
      dropped: number;
      createdOptions: number;
    };
  };
  error?: string;
}> {
  return requestJson(`/api/properties/${propertyId}`, "PATCH", input);
}

export async function deleteProperty(
  propertyId: string,
): Promise<{ ok: boolean; error?: string }> {
  return requestJson(`/api/properties/${propertyId}`, "DELETE");
}

export async function setCellValue(input: {
  rowId: string;
  propertyId: string;
  value: BoardValue;
  rowKind?: string;
}): Promise<{ ok: boolean; value?: BoardValue; error?: string }> {
  const { rowKind = "session", ...rest } = input;
  return requestJson("/api/values", "PUT", { rowKind, ...rest });
}

const VIEW_STORAGE_KEY = "chief-dashboard-view";
const VIEW_STORAGE_PREFIX = "chief-dashboard-view:";

export function storedViewId(rowKind = "session"): string | null {
  try {
    return (
      window.localStorage.getItem(VIEW_STORAGE_PREFIX + rowKind) ??
      (rowKind === "session"
        ? window.localStorage.getItem(VIEW_STORAGE_KEY)
        : null)
    );
  } catch {
    return null;
  }
}

export function persistViewId(id: string | null, rowKind = "session") {
  try {
    if (id) window.localStorage.setItem(VIEW_STORAGE_PREFIX + rowKind, id);
    else window.localStorage.removeItem(VIEW_STORAGE_PREFIX + rowKind);
  } catch {
    /* private mode — the board still works, it just forgets */
  }
}

export async function listViews(rowKind = "session"): Promise<BoardView[]> {
  const r = await fetch(`/api/views?rowKind=${encodeURIComponent(rowKind)}`);
  const parsed = await r.json();
  return parsed.views ?? [];
}

export async function fetchBoard(
  viewId?: string | null,
  rowKind = "session",
): Promise<BoardState> {
  const r = await fetch(
    `/api/board?rowKind=${encodeURIComponent(rowKind)}` +
      (viewId ? `&view=${encodeURIComponent(viewId)}` : ""),
  );
  if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || "board failed");
  return await r.json();
}

export async function createView(input: {
  name: string;
  layout?: ViewLayout;
  groupBy?: string | null;
  rowKind?: string;
}): Promise<{ ok: boolean; view?: BoardView; error?: string }> {
  const { rowKind = "session", ...rest } = input;
  return requestJson("/api/views", "POST", { rowKind, ...rest });
}

export async function patchView(
  viewId: string,
  input: ViewPatch,
): Promise<{ ok: boolean; view?: BoardView; error?: string }> {
  return requestJson(`/api/views/${viewId}`, "PATCH", input);
}

export type ViewPatch = Partial<{
  name: string;
  layout: ViewLayout;
  columns: { propertyId: string; hidden: boolean; width?: number | null; wrap?: boolean | null; sticky?: boolean | null }[];
  sort: ViewSort[];
  filters: ViewFilter[];
  groupBy: string | null;
  groupOrder: string[] | null;
}>;

export async function deleteView(
  viewId: string,
): Promise<{ ok: boolean; error?: string }> {
  return requestJson(`/api/views/${viewId}`, "DELETE");
}

export interface ManualLink {
  workRowId: string;
  targetKind: "session" | "branch" | "worktree";
  targetId: string;
  source: string;
}

/** Manual work-item links: the only phase-3 write besides board cells. */
export async function createLink(input: {
  workRowId: string;
  targetKind: ManualLink["targetKind"];
  targetId: string;
}): Promise<{ ok: boolean; link?: ManualLink; error?: string }> {
  return requestJson("/api/links", "POST", input);
}

export async function deleteLink(input: {
  workRowId: string;
  targetKind: ManualLink["targetKind"];
  targetId: string;
}): Promise<{ ok: boolean; error?: string }> {
  return requestJson("/api/links", "DELETE", input);
}

async function requestJson<T>(
  url: string,
  method: string,
  body?: unknown,
): Promise<T & { ok: boolean; error?: string }> {
  try {
    const r = await fetch(url, {
      method,
      headers: body === undefined ? undefined : { "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    if (r.status === 401) return { ok: false, error: LOGGED_OUT_ERROR } as T & { ok: boolean; error?: string };
    const parsed = await r.json();
    return { ok: r.ok && parsed.ok !== false, ...parsed };
  } catch (e) {
    return { ok: false, error: String(e) } as T & { ok: boolean; error?: string };
  }
}

/** Reach history for one row — every message and ladder action the board
 *  ever sent it, newest first. Cheap and safe to re-fetch after a send. */
export async function fetchSessionHistory(
  rowId: string,
  limit = 50,
): Promise<SessionHistoryResponse> {
  return requestJson<SessionHistoryResponse>(
    `/api/session/history?rowId=${encodeURIComponent(rowId)}&limit=${limit}`,
    "GET",
  );
}

/** One pane screen SNAPSHOT. This call blocks ~2.5s server-side (it reads a
 *  live terminal), so it must only ever be fired on demand — panel open or
 *  an explicit Refresh. Never put it on a timer: the dashboard's 2s SSE
 *  cadence would pin the machine reading panes nobody is looking at. */
export async function fetchPaneScreen(
  paneId: string,
  lines = 100,
): Promise<PaneScreenResponse> {
  return requestJson<PaneScreenResponse>(
    `/api/pane/screen?paneId=${encodeURIComponent(paneId)}&lines=${lines}`,
    "GET",
  );
}

/** GET /api/personas — one row per offered persona. The remote listener
 *  sends only these fields (no folder paths; server/lib/persona_remote.py);
 *  localhost sends more. `mainRowId` = the persona's running main
 *  session's row id, if any. Null on failure. */
export interface PersonaSummary {
  name: string;
  description: string;
  idleStart?: "resume" | "fresh";
  offline?: boolean;
  mainRowId?: string | null;
}

export async function listPersonas(): Promise<PersonaSummary[] | null> {
  try {
    const r = await fetch("/api/personas");
    if (r.status === 401) {
      goToRemoteLogin();
      return null;
    }
    const parsed = await r.json();
    return Array.isArray(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

/** POST /api/persona/start — opens a new Claude session for the persona
 *  (server/lib/persona_start.py). Call only after the user's confirm press:
 *  the remote listener refuses a start without `confirm: true`. The new row
 *  shows up through the normal feeds; nothing to refetch here. */
export async function startPersona(input: {
  persona: string;
  text: string;
  fresh: boolean;
}): Promise<{ ok: boolean; error?: string; paneId?: string; mode?: "started" | "resumed" }> {
  return requestJson("/api/persona/start", "POST", { ...input, confirm: true });
}

/** POST /api/jev/route — the server asks Jev (OpenRouter) which persona a
 *  message is for; the key stays on the Mac (server/lib/jev_route.py).
 *  Nothing is sent: the caller shows the pick and waits for a confirm. */
export async function routeWithJev(
  text: string,
): Promise<{ ok: boolean; error?: string; persona?: string; confidence?: number }> {
  return requestJson("/api/jev/route", "POST", { text });
}
