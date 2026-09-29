import { useRef } from "react";
import type { NeedsYouRow } from "../../types";
import { fmtAge } from "../../api";
import { PanelessPrompt } from "../HookRequestCard";
import { Sheet } from "../../ui/Sheet";
import { StatusBadge } from "../../ui/StatusBadge";
import { needsYouUiStatus } from "./phoneModel";
import { SheetHeader } from "./PhoneSheet";

/** Sheet for a Needs-you entry that has no board row (a Claude Desktop / CLI
 *  session outside herdr): its hook prompt, answerable here, or its
 *  transcript question, display only. */
export function PromptSheet({
  row: current,
  onClose,
  onToast,
}: {
  row: NeedsYouRow | null;
  onClose: () => void;
  onToast: (msg: string, ok: boolean) => void;
}) {
  // Keep the last row while the sheet slides out (answered prompt -> gone).
  const last = useRef<NeedsYouRow | null>(current);
  if (current) last.current = current;
  const row = current ?? last.current;
  if (!row) return null;
  const machine = row.machine || "local";
  const meta = [machine !== "local" ? machine : null, fmtAge(row.sinceSec)].filter(Boolean).join(" · ");
  return (
    <Sheet
      open={!!current}
      onOpenChange={(o) => !o && onClose()}
      title={row.label}
      header={<SheetHeader name={row.label} badge={<StatusBadge status={needsYouUiStatus(row.kind)} />} meta={meta} />}
    >
      <div className="phone-sheet-section">{row.detail}</div>
      {/* Not while sliding out: an answered prompt must not stay tappable. */}
      {current && <PanelessPrompt row={row} onToast={onToast} phone />}
      {!row.hookRequest && !row.transcriptQuestion && (
        <div className="phone-sheet-gate-note">Answer this in Claude on the Mac.</div>
      )}
    </Sheet>
  );
}
