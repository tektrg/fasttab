import { useEffect, useState } from "react";
import { Text } from "@mantine/core";
import type { SessionLatestResponse } from "../types";
import { fetchSessionLatest } from "../api";
import { Markdown } from "./Markdown";
import { Block } from "./Block";
import { FormCard } from "./FormCard";

/** Latest assistant message (`GET /api/session/latest`) plus, when the
 *  agent is sitting on an unanswered multi-question AskUserQuestion turn,
 *  the form card. Nothing renders until the fetch settles (no flash of an
 *  empty card); an `ok:false` reply shows its reason instead of nothing. */
export function LatestMessage({
  rowId,
  paneId,
  onToast,
  phone,
}: {
  rowId: string;
  paneId: string | null;
  onToast: (msg: string, ok: boolean) => void;
  phone?: boolean;
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
      {latest.pendingQuestion && paneId && (
        <FormCard paneId={paneId} form={latest.pendingQuestion} onToast={onToast} phone={phone} />
      )}
    </>
  );
}
