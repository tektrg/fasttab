/** Feedback tab: one component, two layouts over the same engine result —
 *  desktop `table`, phone `cards`. Status change -> proxy -> refetch. */
import { useEffect, useMemo, useState, type KeyboardEvent } from "react";
import type { SourceRow } from "@tektrg/table-core";
import { createResolveGuard, fetchFeedbackThread, resolveFeedbackThread, useFeedbackThreads, type FeedbackMessage } from "./feedbackApi";
import {
  DEFAULT_FEEDBACK_FILTER,
  FEEDBACK_STATUSES,
  detectOwnerFields,
  evaluateFeedback,
  feedbackFields,
  type FeedbackFilterInput,
} from "./feedbackTableView";
import "./feedback.css";

type Layout = "table" | "cards";
type Notify = (message: string, ok: boolean) => void;

function shortDate(iso: unknown): string {
  return typeof iso === "string" ? new Date(iso).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" }) : "—";
}

function FilterBar({ filter, apps, onChange }: { filter: FeedbackFilterInput; apps: string[]; onChange: (next: FeedbackFilterInput) => void }) {
  return (
    <div className="feedback-filters">
      <select aria-label="Status filter" value={filter.status} onChange={(e) => onChange({ ...filter, status: e.currentTarget.value })}>
        <option value="">All statuses</option>
        {FEEDBACK_STATUSES.map((status) => <option key={status} value={status}>{status}</option>)}
      </select>
      <select aria-label="App filter" value={filter.app} onChange={(e) => onChange({ ...filter, app: e.currentTarget.value })}>
        <option value="">All apps</option>
        {apps.map((app) => <option key={app} value={app}>{app}</option>)}
      </select>
      <input aria-label="Search feedback" type="search" placeholder="Search feedback…" value={filter.text} onChange={(e) => onChange({ ...filter, text: e.currentTarget.value })} />
    </div>
  );
}

/** Only open -> resolved exists upstream; reopen happens when the user writes again. */
function StatusControl({ row, busy, onResolve }: { row: SourceRow; busy: boolean; onResolve: (threadID: string) => void }) {
  return (
    <select
      aria-label="Thread status"
      value={String(row.status)}
      disabled={busy || row.status !== "open"}
      title={row.status !== "open" ? "Reopens automatically when the user replies" : undefined}
      onClick={(e) => e.stopPropagation()}
      onKeyDown={(e) => e.stopPropagation()}
      onChange={(e) => e.currentTarget.value === "resolved" && onResolve(String(row.id))}
    >
      {FEEDBACK_STATUSES.map((status) => <option key={status} value={status}>{status}</option>)}
    </select>
  );
}

function ThreadMessages({ threadID }: { threadID: string }) {
  const [messages, setMessages] = useState<FeedbackMessage[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    let live = true;
    void fetchFeedbackThread(threadID).then((reply) => {
      if (!live) return;
      if (reply.ok) setMessages(reply.messages);
      else setError(reply.error || "could not load thread");
    });
    return () => {
      live = false;
    };
  }, [threadID]);
  if (error) return <div className="feedback-error">{error}</div>;
  if (!messages) return <div className="small">loading…</div>;
  return (
    <ol className="feedback-messages">
      {messages.map((message, index) => (
        <li key={message.messageID ?? message.id ?? index} data-author={message.author}>
          <span className="small">{message.author}</span> {message.body}
        </li>
      ))}
    </ol>
  );
}

export function FeedbackTab({ layout, onToast }: { layout: Layout; onToast: Notify }) {
  const { threads, hasMore, error, reload } = useFeedbackThreads();
  const [filter, setFilter] = useState<FeedbackFilterInput>(DEFAULT_FEEDBACK_FILTER);
  const [openThreadID, setOpenThreadID] = useState<string | null>(null);
  const allThreads = useMemo(() => threads ?? [], [threads]);
  const groups = useMemo(() => evaluateFeedback(allThreads, filter, layout === "table" ? "table" : "card"), [allThreads, filter, layout]);
  const ownerFields = useMemo(() => detectOwnerFields(allThreads), [allThreads]);
  const apps = useMemo(() => feedbackFields(allThreads).find((field) => field.id === "app")?.options ?? [], [allThreads]);

  const [guard] = useState(createResolveGuard);
  const [, setBusyTick] = useState(0);
  const resolve = async (threadID: string) => {
    if (guard.has(threadID)) return;
    if (!window.confirm("Mark resolved? The customer gets a \"solved\" push notification right away.")) return;
    if (!guard.start(threadID)) return;
    setBusyTick((n) => n + 1);
    try {
      const reply = await resolveFeedbackThread(threadID);
      onToast(reply.ok ? "feedback resolved" : "resolve failed: " + (reply.error || "?"), reply.ok);
      await reload();
    } finally {
      guard.finish(threadID);
      setBusyTick((n) => n + 1);
    }
  };
  const toggle = (threadID: string) => setOpenThreadID((current) => (current === threadID ? null : threadID));
  /** Click / Enter / Space opens a thread; the row says whether it is open. */
  const rowProps = (row: SourceRow) => ({
    tabIndex: 0,
    "aria-expanded": openThreadID === row.id,
    onClick: () => toggle(String(row.id)),
    onKeyDown: (e: KeyboardEvent) => {
      if (e.key !== "Enter" && e.key !== " ") return;
      e.preventDefault();
      toggle(String(row.id));
    },
  });

  const errorBanner = error && <div className="feedback-error" role="alert">{error} <button type="button" onClick={() => void reload()}>Retry</button></div>;
  if (!threads) return errorBanner || <div className="small">loading feedback…</div>;

  return (
    <div className={`feedback-tab feedback-tab--${layout}`}>
      {errorBanner}
      <FilterBar filter={filter} apps={apps} onChange={setFilter} />
      {groups.length === 0 && <div className="small">No feedback matches.</div>}
      {groups.map((group) => (
        <section key={group.app} className="feedback-group">
          <h3>{group.app || "(no app)"} <span className="small">{group.rows.length}</span></h3>
          {layout === "table" ? (
            <table className="feedback-table">
              <thead>
                <tr>
                  <th>Feedback</th><th>Status</th><th>Last activity</th><th>Shipped in</th>
                  {ownerFields.map((id) => <th key={id}>{id}</th>)}
                </tr>
              </thead>
              <tbody>
                {group.rows.map((row) => [
                  <tr key={row.id} {...rowProps(row)} data-waiting={row.waitingOnYou || undefined}>
                    <td>{String(row.title)}</td>
                    <td><StatusControl row={row} busy={guard.has(String(row.id))} onResolve={resolve} /></td>
                    <td>{shortDate(row.lastActivityAt)}</td>
                    <td>{row.shippedInVersion ?? ""}</td>
                    {ownerFields.map((id) => <td key={id}>{row[id] == null ? "" : String(row[id])}</td>)}
                  </tr>,
                  openThreadID === row.id && (
                    <tr key={`${row.id}-detail`}><td colSpan={4 + ownerFields.length}><ThreadMessages threadID={String(row.id)} /></td></tr>
                  ),
                ])}
              </tbody>
            </table>
          ) : (
            <ul className="feedback-cards">
              {group.rows.map((row) => (
                <li key={row.id} className="feedback-card" data-waiting={row.waitingOnYou || undefined} {...rowProps(row)}>
                  <div className="feedback-card__title">{String(row.title)}</div>
                  <div className="feedback-card__meta">
                    <StatusControl row={row} busy={guard.has(String(row.id))} onResolve={resolve} />
                    <span className="small">{shortDate(row.lastActivityAt)}</span>
                    {ownerFields.map((id) => row[id] != null && <span key={id} className="small">{id}: {String(row[id])}</span>)}
                  </div>
                  {openThreadID === row.id && <ThreadMessages threadID={String(row.id)} />}
                </li>
              ))}
            </ul>
          )}
        </section>
      ))}
      {hasMore && <div className="small">Showing the first {allThreads.length} threads.</div>}
    </div>
  );
}
