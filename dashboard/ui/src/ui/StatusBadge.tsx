import { STATUS_META, type UiStatus } from "./status";
import "./StatusBadge.css";

/** The shape mark alone (used as the avatar corner dot in AgentRow). */
export function StatusMark({ status }: { status: UiStatus }) {
  const meta = STATUS_META[status];
  return (
    <i
      className="ui-mark"
      data-shape={meta.shape}
      data-pulse={meta.pulses || undefined}
      aria-hidden="true"
    />
  );
}

export function StatusBadge({ status }: { status: UiStatus }) {
  const meta = STATUS_META[status];
  return (
    <span className="ui-status" data-status={status} style={{ "--c": `var(${meta.colorVar})` } as React.CSSProperties}>
      <StatusMark status={status} />
      {meta.label}
    </span>
  );
}
