import { StatusBadge } from "./StatusBadge";
import { STATUS_META, type UiStatus } from "./status";
import "./AgentRow.css";

export interface AgentRowProps {
  initials: string;
  name: string;
  /** One line: latest activity / the question. Truncated with an ellipsis. */
  subtitle: string;
  /** Pre-formatted age, e.g. "2m". */
  age: string;
  status: UiStatus;
  /** Tints the leading edge for rows that need the user. */
  needsYou?: boolean;
  onPress?: () => void;
}

export function AgentRow({ initials, name, subtitle, age, status, needsYou, onPress }: AgentRowProps) {
  const dim = status === "sleep" || status === "end";
  return (
    <button
      type="button"
      className="ui-row"
      data-needs-you={needsYou || undefined}
      data-dim={dim || undefined}
      style={{ "--c": `var(${STATUS_META[status].colorVar})` } as React.CSSProperties}
      onClick={onPress}
    >
      <span className="ui-row__avatar" aria-hidden="true">
        {initials}
        <span className="ui-row__dot" />
      </span>
      <span className="ui-row__main">
        <span className="ui-row__name">{name}</span>
        <span className="ui-row__sub">{subtitle}</span>
      </span>
      <span className="ui-row__meta">
        <span className="ui-row__age">{age}</span>
        <StatusBadge status={status} />
      </span>
    </button>
  );
}
