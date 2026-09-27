import { useCallback, useEffect, useRef, useState } from "react";
import { Notification, TextInput, UnstyledButton } from "@mantine/core";
import { focusPane, useDashboardState, useToast } from "./api";
import { useQuestionAlerts, ensureNotiPerm } from "./alerts";
import { usePhoneLayout } from "./hooks/usePhoneLayout";
import { FeedStrip } from "./components/FeedStrip";
import { NeedsYou } from "./components/NeedsYou";
import { BoardSection } from "./components/BoardSection";
import { PhoneInbox } from "./components/phone/PhoneInbox";
import { filterAgents, type SearchableAgent } from "./agentMatch";
import type { NeedsYouRow } from "./types";

function needsYouSearchable(n: NeedsYouRow): SearchableAgent {
  return { name: n.label, machine: "local", status: n.detail, latestLine: n.detail };
}

export default function App() {
  const state = useDashboardState();
  const { toast, show } = useToast();
  const phone = usePhoneLayout();
  useQuestionAlerts(state?.computed.needsYou);
  const [query, setQuery] = useState("");
  const searchRef = useRef<HTMLInputElement | null>(null);

  // Desktop-only: "/" focuses the search field (unless already typing
  // somewhere else), Escape clears it — same shortcut convention as most
  // filterable lists.
  useEffect(() => {
    if (phone) return;
    const onKey = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      const typing = target && /^(input|textarea|select)$/i.test(target.tagName);
      if (e.key === "/" && !typing) {
        e.preventDefault();
        searchRef.current?.focus();
      } else if (e.key === "Escape" && target === searchRef.current) {
        setQuery("");
        searchRef.current?.blur();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [phone]);

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

  // Phone layout (phase 2a): a completely separate tree, not CSS-hidden
  // desktop chrome — the table/kanban/bulk-bar/column-menus/view-switcher
  // are simply never mounted below this width, rather than hidden and
  // still paying their render/poll cost.
  if (phone) {
    return (
      <div onClick={ensureNotiPerm} className="phone-app">
        <header>
          <h1>AGENTBAR</h1>
          <div className="meta" id="clock">
            {new Date(state.serverTimeTs * 1000).toLocaleTimeString()} · live
          </div>
        </header>
        <PhoneInbox state={state} onToast={onToast} />
        {toast && (
          <Notification
            id="toast"
            color={toast.ok ? "green" : "red"}
            title={toast.ok ? "Done" : "Action failed"}
            withCloseButton={false}
            style={{ position: "fixed", bottom: 16, left: 16, right: 16, zIndex: 300 }}
          >
            {toast.msg}
          </Notification>
        )}
      </div>
    );
  }

  return (
    <div onClick={ensureNotiPerm}>
      <header>
        <h1>CHIEF DASHBOARD</h1>
        <div className="meta" id="clock">
          {new Date(state.serverTimeTs * 1000).toLocaleTimeString()} · live
        </div>
      </header>

      <FeedStrip state={state} />

      <div className="desktop-search-bar">
        <TextInput
          ref={searchRef}
          value={query}
          onChange={(e) => setQuery(e.currentTarget.value)}
          placeholder="Filter agents by name, machine, folder, status… ( / to focus )"
          size="xs"
          rightSection={
            query ? (
              <UnstyledButton aria-label="clear filter" onClick={() => setQuery("")}>
                ✕
              </UnstyledButton>
            ) : null
          }
        />
      </div>

      <section>
        <h2>
          <span>NEEDS YOU</span>
          <span id="needsyou-count" className="small">
            {filterAgents(c.needsYou.map((n) => ({ ...needsYouSearchable(n), _n: n })), query).length}
          </span>
        </h2>
        <NeedsYou
          rows={filterAgents(c.needsYou.map((n) => ({ ...needsYouSearchable(n), _n: n })), query).map(
            (x) => x._n as NeedsYouRow,
          )}
          onFocus={onFocus}
          onToast={onToast}
        />
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
