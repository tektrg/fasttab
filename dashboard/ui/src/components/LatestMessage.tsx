import { useEffect, useState } from "react";
import { Text } from "@mantine/core";
import type { PickerQuestion, SessionLatestResponse } from "../types";
import { fetchSessionLatest } from "../api";
import { Markdown } from "./Markdown";
import { Block } from "./Block";
import { FormCard } from "./FormCard";

/** Latest assistant message (`GET /api/session/latest`) plus, when the
 *  agent is sitting on an unanswered multi-question AskUserQuestion turn,
 *  the form card. Nothing renders until the fetch settles (no flash of an
 *  empty card); an `ok:false` reply shows its reason instead of nothing.
 *  `screenQuestion` is the board sweep's screen-parsed copy of whatever
 *  picker is CURRENTLY open (`row.derived.screenQuestion`) — passed straight
 *  through to `FormCard`, which needs it (not the transcript copy here) to
 *  post an answer the server's fresh re-read will accept. */
export function LatestMessage({
  rowId,
  paneId,
  screenQuestion,
  onToast,
  phone,
  messageOnly,
}: {
  rowId: string;
  paneId: string | null;
  screenQuestion?: PickerQuestion | null;
  onToast: (msg: string, ok: boolean) => void;
  phone?: boolean;
  /** Skip the pending-question form (a permission/plan card is shown instead). */
  messageOnly?: boolean;
}) {
  const [latest, setLatest] = useState<SessionLatestResponse | null>(null);

  useEffect(() => {
    let dead = false;
    fetchSessionLatest(rowId).then((r) => {
      if (!dead) setLatest(r);
    });
    return () => {
      dead = true;
    };
  }, [rowId]);

  if (latest === null) return null;

  if (!latest.ok) {
    return (
      <Block phone={phone} className="latest-message">
        <Text size="xs" c="dimmed">
          {latest.error || "no transcript to show"}
        </Text>
      </Block>
    );
  }

  return (
    <>
      {latest.latestMessage && (
        <Block phone={phone} className="latest-message">
          <Text size="xs" c="dimmed" mb={4}>
            latest message
          </Text>
          <Markdown text={latest.latestMessage} />
        </Block>
      )}
      {!messageOnly && latest.pendingQuestion && paneId && (
        <FormCard
          paneId={paneId}
          form={latest.pendingQuestion}
          screenQuestion={screenQuestion}
          onToast={onToast}
          phone={phone}
        />
      )}
    </>
  );
}
