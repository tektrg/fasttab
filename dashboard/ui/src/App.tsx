import { useCallback } from "react";
import { Notification } from "@mantine/core";
import { focusPane, useDashboardState, useToast } from "./api";
import { useQuestionAlerts, ensureNotiPerm } from "./alerts";
import { FeedStrip } from "./components/FeedStrip";
import { NeedsYou } from "./components/NeedsYou";
import { BoardSection } from "./components/BoardSection";

export default function App() {
  const state = useDashboardState();
  const { toast, show } = useToast();
  useQuestionAlerts(state?.computed.needsYou);

  const onFocus = useCallback(
    async (paneId: string, label: string) => {
      ensureNotiPerm();
      const res = await focusPane(paneId);
      show(
        res.ok ? "focused: " + (label || paneId) : "focus failed: " + (res.error || "?"),
        !!res.ok,
      );
    },
    [show],
  );

  const onToast = useCallback(
    (msg: string, ok: boolean) => show(msg, ok),
    [show],
  );

  if (!state) {
    return (
      <div>
        <header>
          <h1>CHIEF DASHBOARD</h1>
          <div className="meta" id="clock">
            connecting…
          </div>
        </header>
      </div>
    );
  }

  const c = state.computed;

  return (
    <div onClick={ensureNotiPerm}>
      <header>
        <h1>CHIEF DASHBOARD</h1>
        <div className="meta" id="clock">
          {new Date(state.serverTimeTs * 1000).toLocaleTimeString()} · live
        </div>
      </header>

      <FeedStrip state={state} />

      <section>
        <h2>
          <span>NEEDS YOU</span>
          <span id="needsyou-count" className="small">
            {c.needsYou.length}
          </span>
        </h2>
        <NeedsYou rows={c.needsYou} onFocus={onFocus} onToast={onToast} />
      </section>

      <section>
        <h2>
          <span>BOARD</span>
          <span id="board-count" className="small"></span>
        </h2>
        <BoardSection onToast={onToast} onFocus={onFocus} />
      </section>

      <footer>
        Editable only for custom board columns plus two existing buttons: row
        click focuses a pane, and a QUESTION row&apos;s Confirm sends one staged
        answer into that pane. Nothing here can push, tag, deploy, merge, or
        delete anything. Raw JSON:{" "}
        <a className="link" href="/api/state">
          /api/state
        </a>
      </footer>

      {toast && (
        <Notification
          id="toast"
          color={toast.ok ? "green" : "red"}
          title={toast.ok ? "Done" : "Action failed"}
          withCloseButton={false}
          style={{ position: "fixed", bottom: 16, right: 16, zIndex: 100, minWidth: 240 }}
        >
          {toast.msg}
        </Notification>
      )}
    </div>
  );
}
