import { useState } from "react";
import { Badge, Group, Paper, Text } from "@mantine/core";
import type { WrapUpQuestion } from "../types";
import { sendMessage } from "../sessionActions";
import { MarkdownInline } from "./Markdown";
import { ActionButton } from "../ui/ActionButton";
import { CONSENT_NOTE, mayNeedConfirming } from "../wrapUpConsent";

type SendState = { status: "idle" | "sending" } | { status: "sent"; label: string } | { status: "error"; error: string };

/** Claude Desktop's end-of-turn question (its wrap_up "next step" box, read
 *  from the transcript — server/lib/transcript_wrap_up.py). The turn is
 *  over, so a button just sends that action's message as the next prompt,
 *  through the session inbox (POST /api/session/message, the row id of a
 *  pane-less session is its session id). One send per card: a second tap
 *  could queue a second, contradicting prompt. */
export function WrapUpCard({
  sessionId,
  question,
  onToast,
  phone,
}: {
  sessionId: string;
  question: WrapUpQuestion;
  onToast: (msg: string, ok: boolean) => void;
  phone?: boolean;
}) {
  const [state, setState] = useState<SendState>({ status: "idle" });
  const send = async (label: string, message: string) => {
    setState({ status: "sending" });
    const res = await sendMessage(sessionId, message, { confirm: true, wrapUpAnswer: true });
    setState(res.ok ? { status: "sent", label } : { status: "error", error: res.error || "no reason given" });
    onToast(res.ok ? `sent "${label}"` : "not sent: " + (res.error || "?"), !!res.ok);
  };
  const busy = state.status === "sending" || state.status === "sent";
  return (
    <Paper withBorder radius="xl" p="sm" style={{ margin: 8 }} className="appr-card hook-card wrapup-card">
      <Group gap="xs" mb={4}>
        <Badge size="sm" variant="light" color="orange">ASKS</Badge>
      </Group>
      <Text mb="xs" fw={600}><MarkdownInline text={question.ask} /></Text>
      {question.recap ? <Text size="xs" c="dimmed" mb="xs"><MarkdownInline text={question.recap} /></Text> : null}
      <Group gap="xs" style={phone ? { flexDirection: "column", alignItems: "stretch" } : undefined}>
        {question.actions.map((a, i) => (
          <ActionButton
            key={a.label}
            variant={i === 0 ? "primary" : "secondary"}
            size={phone ? "md" : "sm"}
            disabled={busy}
            title={a.message}
            onClick={() => send(a.label, a.message)}
          >
            {a.label}
          </ActionButton>
        ))}
      </Group>
      {question.actions.some(mayNeedConfirming) && (
        <Text size="xs" c="dimmed" mt={4} className="wrapup-consent-note">
          {CONSENT_NOTE}: {question.actions.filter(mayNeedConfirming).map((a) => a.label).join(", ")}
        </Text>
      )}
      {state.status === "sent" && <Text size="xs" c="dimmed" mt={4}>Sent “{state.label}”.</Text>}
      {state.status === "error" && <Text size="xs" c="red" mt={4}>Not sent: {state.error}</Text>}
    </Paper>
  );
}
