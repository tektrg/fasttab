import type { BoardRow } from "../types";
import { ReviewCard } from "./ReviewCard";
import { PlanCard } from "./PlanCard";
import { LatestMessage } from "./LatestMessage";

/** Phase 2b: the Review (permission Allow/Allow always/Deny), plan-mode
 *  approval, and latest-message + form-card views, composed by row state —
 *  mounted in the desktop `RowPanel` here, and in the phone row sheet by
 *  the mobile-layout phase. One row is exactly one of: blocked on a plain
 *  tool permission box (`ReviewCard`), blocked on a plan-approval box
 *  (`PlanCard`), or neither (`LatestMessage`, which itself renders the
 *  pending-question form card when the transcript has one). Ended rows
 *  (no live pane) get nothing — same rule `RowPanel.paneIdOf` already
 *  applies to the pane screen. */
export function RowDetailExtras({
  row,
  onToast,
  phone,
}: {
  row: BoardRow;
  onToast: (msg: string, ok: boolean) => void;
  phone?: boolean;
}) {
  if (row.status === "ended") return null;
  const paneId = row.derived?.paneId ?? null;
  const permission = row.derived?.screenPermission ?? null;

  if (permission && paneId) {
    if (permission.kind === "plan") {
      return (
        <PlanCard rowId={row.rowId} paneId={paneId} permission={permission} onToast={onToast} phone={phone} />
      );
    }
    return <ReviewCard paneId={paneId} permission={permission} onToast={onToast} phone={phone} />;
  }

  return <LatestMessage rowId={row.rowId} paneId={paneId} onToast={onToast} phone={phone} />;
}
