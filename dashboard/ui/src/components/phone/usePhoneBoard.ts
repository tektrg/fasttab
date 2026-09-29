import { useCallback, useEffect, useState } from "react";
import type { BoardState } from "../../types";
import { fetchBoard } from "../../api";

/** The session board (`/api/board`, default view), polled every 5s — the
 *  phone's Agents tab and row sheets read Working/Parked/Ended rows from it. */
export function usePhoneBoard(): { board: BoardState | null; reload: () => Promise<void> } {
  const [board, setBoard] = useState<BoardState | null>(null);

  const reload = useCallback(async () => {
    try {
      setBoard(await fetchBoard(null, "session"));
    } catch {
      /* keep the last good board rather than blanking the screen on one missed poll */
    }
  }, []);

  useEffect(() => {
    void reload();
    const t = window.setInterval(reload, 5000);
    return () => window.clearInterval(t);
  }, [reload]);

  return { board, reload };
}
