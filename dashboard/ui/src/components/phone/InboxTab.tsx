import type { NeedsYouRow } from "../../types";
import { fmtAge } from "../../api";
import { AgentRow } from "../../ui/AgentRow";
import { QuickAnswerBar } from "./QuickAnswerBar";
import { emptyInboxText, groupInbox, initialsOf, needsYouUiStatus } from "./phoneModel";

/** Inbox tab: agents waiting on you — Questions, then Blocked (then feed
 *  outage notices). Never blank: the empty state says how many agents work. */
export function InboxTab({
  needsYou,
  workingCount,
  onOpen,
  onGoAgents,
  onToast,
}: {
  needsYou: NeedsYouRow[];
  workingCount: number;
  onOpen: (n: NeedsYouRow) => void;
  onGoAgents: () => void;
  onToast: (msg: string, ok: boolean) => void;
}) {
  const g = groupInbox(needsYou);
  const sections: [string, string, NeedsYouRow[]][] = [
    ["questions", "Questions", g.questions],
    ["blocked", "Blocked", g.blocked],
    ["feed", "Feed problems", g.feed],
  ];
  if (needsYou.length === 0) {
    return (
      <div className="phone-empty" data-testid="inbox-empty">
        <div>{emptyInboxText(workingCount)}</div>
        <button type="button" className="phone-link" onClick={onGoAgents}>
          See Agents
        </button>
      </div>
    );
  }
  return (
    <div className="phone-list">
      {sections
        .filter(([, , rows]) => rows.length > 0)
        .map(([id, title, rows]) => (
          <section key={id} data-section={id}>
            <div className="phone-section-head">
              <span>{title}</span>
              <span className="phone-section-head__count">{rows.length}</span>
            </div>
            <div className="phone-section-body">
              {rows.map((n) => (
                <div key={(n.paneId ?? n.agentSession ?? n.label) + "::" + n.kind + "::" + (n.hookRequest?.requestId ?? "")}>
                  <AgentRow
                    initials={initialsOf(n.label)}
                    name={n.label}
                    subtitle={n.machine && n.machine !== "local" ? `${n.machine} · ${n.detail}` : n.detail}
                    age={fmtAge(n.sinceSec)}
                    status={needsYouUiStatus(n.kind)}
                    needsYou={n.kind !== "feed-broken"}
                    onPress={n.kind === "feed-broken" ? undefined : () => onOpen(n)}
                  />
                  <QuickAnswerBar key={n.hookRequest?.requestId} request={n.hookRequest} onToast={onToast} />
                </div>
              ))}
            </div>
          </section>
        ))}
    </div>
  );
}
