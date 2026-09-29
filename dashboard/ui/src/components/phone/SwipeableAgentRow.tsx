import type { BoardRow } from "../../types";
import { AgentRow, type AgentRowProps } from "../../ui/AgentRow";
import { SwipeRow, type SwipeAction } from "../../ui/SwipeRow";
import { usePhoneSheetActions } from "./usePhoneSheetActions";

/** An Agents-tab row that swipes left to Park / Done. Reuses the sheet's verb
 *  logic, so a busy session's Done/Park still takes a second press ("Confirm")
 *  and Park still shows Undo. Sleeping / ended rows have no verbs: plain row. */
export function SwipeableAgentRow({
  row,
  onToast,
  onUndo,
  onRefetch,
  ...rowProps
}: AgentRowProps & {
  row: BoardRow;
  onToast: (msg: string, ok: boolean) => void;
  onUndo?: (message: string, undo: () => void) => void;
  onRefetch: () => void;
}) {
  const a = usePhoneSheetActions({ row, onToast, onUndo, onRefetch, onClose: () => {} });
  const actions: SwipeAction[] = [];
  if (a.canPark || a.canUnpark) {
    actions.push({
      label: a.armed === "park" ? "Confirm" : a.canUnpark ? "Unpark" : "Park",
      tone: "neutral",
      disabled: a.busy !== null,
      onPress: () => void a.runPark(),
    });
  }
  if (a.endStage) {
    actions.push({
      label: a.armed === "done" ? "Confirm" : "Done",
      tone: "danger",
      disabled: !a.endStage.state.enabled || a.busy !== null,
      onPress: () => void a.runDone(),
    });
  }
  if (row.status === "ended" || actions.length === 0) return <AgentRow {...rowProps} />;
  return (
    <SwipeRow actions={actions}>
      <AgentRow {...rowProps} />
    </SwipeRow>
  );
}
