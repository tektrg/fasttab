import { Badge } from "@mantine/core";

/** Severity badges. The `kind-*` / `st-*` colour vocabulary predates Mantine
 *  and encodes real meaning (blocked = red, question = blue, …) — every
 *  mapping below preserves it, only the presentation is louder. The original
 *  class is kept on the Badge so any remaining CSS/legend keeps working. */

// NEEDS YOU carries exactly three kinds since 2026-09-06: a pane stopped at a
// permission prompt, a pane stopped at a picker, and the list admitting it is
// blind. Everything else moved to the BOARD — see build_needs_you().
const KIND_COLOR: Record<string, string> = {
  blocked: "red",
  "feed-broken": "red",
  question: "blue",
};

export function KindBadge({ kind, children }: { kind: string; children: React.ReactNode }) {
  return (
    <Badge
      size="sm"
      variant="light"
      color={KIND_COLOR[kind] ?? "gray"}
      className={"kind-" + kind}
    >
      {children}
    </Badge>
  );
}

const STATE_COLOR: Record<string, string> = {
  "st-blocked": "red",
  "st-working": "green",
  "st-idle": "gray",
  "st-unknown": "yellow",
};

export function StateBadge({ cls, children }: { cls: string; children: React.ReactNode }) {
  return (
    <Badge size="sm" variant="light" color={STATE_COLOR[cls] ?? "gray"} className={cls}>
      {children}
    </Badge>
  );
}

/** R1/R21: every row now carries `machine` ("local" or a configured remote
 *  name like "air-m1"). `local` is the overwhelming majority, so it stays
 *  plain text — a badge would be noise on every single row. Any other value
 *  gets a colored pill so a remote worker is visually obvious at a glance.
 *  `dup` renders alongside it when this row is the second (or later) copy
 *  of an agent session seen live on another machine — flagged, never
 *  merged, per R6. */
export function MachineBadge({
  machine,
  dup,
}: {
  machine: string;
  dup?: string | null;
}) {
  if (machine === "local" || !machine) {
    return <span className="small">local</span>;
  }
  return (
    <span style={{ display: "inline-flex", alignItems: "center", gap: 4 }}>
      <Badge size="sm" variant="light" color="grape" className="st-machine-remote">
        {machine}
      </Badge>
      {dup && (
        <span
          className="small st-machine-dup"
          title={`Same agent session is also live as ${dup} on another machine — both rows are kept, never merged (R6)`}
        >
          ⚠ dup
        </span>
      )}
    </span>
  );
}
