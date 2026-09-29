import { AgentRow } from "./AgentRow";
import { ActionButton, type ActionVariant } from "./ActionButton";
import { Sheet } from "./Sheet";
import { StatusBadge } from "./StatusBadge";
import { ALL_STATUSES, STATUS_META } from "./status";
import { ToastProvider, useToast } from "./Toast";
import { useState } from "react";
import "./UiKitPage.css";

const VARIANTS: ActionVariant[] = ["primary", "secondary", "danger", "ask"];

function Kit() {
  const [open, setOpen] = useState(false);
  const { show } = useToast();
  return (
    <main className="ui-kit">
      <h1>AgentBar UI kit</h1>
      <p>Dev reference for the P1 primitives. Not linked from any production screen.</p>

      <h2>StatusBadge</h2>
      <div className="ui-kit__wrap">{ALL_STATUSES.map((s) => <StatusBadge key={s} status={s} />)}</div>

      <h2>AgentRow</h2>
      <div className="ui-kit__group">
        {ALL_STATUSES.map((s) => (
          <AgentRow
            key={s}
            initials={STATUS_META[s].label.slice(0, 2).toUpperCase()}
            name={"agent-" + s}
            subtitle="A deliberately long one-line subtitle that must truncate with an ellipsis"
            age="2m"
            status={s}
            needsYou={s === "need" || s === "ask"}
            onPress={() => show({ message: "Pressed agent-" + s })}
          />
        ))}
      </div>

      <h2>ActionButton</h2>
      {(["md", "sm"] as const).map((size) => (
        <div className="ui-kit__wrap" key={size}>
          {VARIANTS.map((v) => <ActionButton key={v} variant={v} size={size}>{v} {size}</ActionButton>)}
          <ActionButton size={size} disabled>disabled</ActionButton>
        </div>
      ))}

      <h2>Sheet</h2>
      <ActionButton variant="primary" onClick={() => setOpen(true)}>Open sheet</ActionButton>
      <Sheet
        open={open}
        onOpenChange={setOpen}
        title="chief-aptus"
        header={<><strong>chief-aptus</strong><StatusBadge status="ask" /></>}
        footer={<ActionButton variant="ask" onClick={() => setOpen(false)}>Send answer</ActionButton>}
      >
        {Array.from({ length: 14 }, (_, i) => <p key={i}>Body line {i + 1}. Drag the handle up for full height.</p>)}
      </Sheet>

      <h2>Toast</h2>
      <div className="ui-kit__wrap">
        <ActionButton onClick={() => show({ message: "Saved" })}>Plain toast</ActionButton>
        <ActionButton onClick={() => show({ message: "Parked agentbar-pwa", actionLabel: "Undo", onAction: () => show({ message: "Undone" }) })}>Toast with Undo</ActionButton>
      </div>
    </main>
  );
}

export default function UiKitPage() {
  return <ToastProvider><Kit /></ToastProvider>;
}
