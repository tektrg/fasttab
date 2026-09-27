import { useEffect, useState } from "react";
import { Paper, Text } from "@mantine/core";
import type { SessionLatestResponse } from "../types";
import { fetchSessionLatest } from "../api";
import { Markdown } from "./Markdown";
import { FormCard } from "./FormCard";

/** Latest assistant message (`GET /api/session/latest`) plus, when the
 *  agent is sitting on an unanswered multi-question AskUserQuestion turn,
 *  the form card. Nothing renders until the fetch settles (no flash of an
 *  empty card); an `ok:false` reply shows its reason instead of nothing. */
export function LatestMessage({
  rowId,
  paneId,
  onToast,
}: {
  rowId: string;
  paneId: string | null;
  onToast: (msg: string, ok: boolean) => void;
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
      <Paper withBorder radius="xl" shadow="sm" p="sm" className="latest-message">
        <Text size="xs" c="dimmed">
          {latest.error || "no transcript to show"}
        </Text>
      </Paper>
    );
  }

  return (
    <>
      {latest.latestMessage && (
        <Paper withBorder radius="xl" shadow="sm" p="sm" className="latest-message">
          <Text size="xs" c="dimmed" mb={4}>
            latest message
          </Text>
          <Markdown text={latest.latestMessage} />
        </Paper>
      )}
      {latest.pendingQuestion && paneId && (
        <FormCard paneId={paneId} form={latest.pendingQuestion} onToast={onToast} />
      )}
    </>
  );
}
