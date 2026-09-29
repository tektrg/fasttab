import { useState } from "react";
import type { HookRequest } from "../../types";
import { answerHookRequest } from "../../api";
import { quickAnswerBody, quickAnswerKind, quickAnswerToast } from "../../quickAnswer";
import { ActionButton } from "../../ui/ActionButton";

/** Inline Yes / No under an Inbox question row — only for a simple prompt
 *  (`quickAnswerKind`); anything else renders nothing and the row opens the
 *  sheet. Same answer POST as the prompt card; never retried. */
export function QuickAnswerBar({
  request,
  onToast,
}: {
  request: HookRequest | null | undefined;
  onToast: (msg: string, ok: boolean) => void;
}) {
  const kind = quickAnswerKind(request);
  const [state, setState] = useState<{ status: "idle" | "sending" | "sent" } | { status: "error"; error: string }>({
    status: "idle",
  });
  if (!kind || !request) return null;
  const locked = state.status === "sending" || state.status === "sent";
  const answer = async (choice: "yes" | "no") => {
    if (locked) return;
    setState({ status: "sending" });
    const res = await answerHookRequest(request.requestId, quickAnswerBody(kind, choice));
    if (res.ok) {
      setState({ status: "sent" });
      onToast(quickAnswerToast(kind, choice), true);
    } else {
      const error = res.error || "no reason given";
      setState({ status: "error", error });
      onToast("answer not sent: " + error, false);
    }
  };
  const yesLabel = kind.kind === "yesno" ? kind.yes : "Allow once";
  const noLabel = kind.kind === "yesno" ? kind.no : "Deny";
  return (
    <div className="phone-quick-answer" data-testid="quick-answer">
      <ActionButton size="sm" variant="primary" disabled={locked} onClick={() => void answer("yes")}>
        {state.status === "sending" ? "Sending…" : yesLabel}
      </ActionButton>
      <ActionButton size="sm" variant="secondary" disabled={locked} onClick={() => void answer("no")}>
        {noLabel}
      </ActionButton>
      {state.status === "error" && <span className="phone-quick-answer__error">Not sent: {state.error}</span>}
    </div>
  );
}
