import type { BoardRow } from "../types";

/** Phase 2a slot: a sibling agent is adding `GET /api/session/latest` (the
 *  worker's latest message) + a plan card in parallel — this component is
 *  where that UI lands inside the phone sheet once it ships. Deliberately a
 *  no-op today (renders nothing) so this phase's phone layout doesn't race
 *  or duplicate that work; wire it up here rather than inlining a fetch in
 *  `PhoneSheet` when it's ready. Server endpoints already exist
 *  (`handle_session_latest`/`handle_session_plan` in
 *  chief-dashboard-server.py) — only the UI consumer is pending. */
export function RowDetailExtras({ row: _row }: { row: BoardRow }) {
  return null;
}
