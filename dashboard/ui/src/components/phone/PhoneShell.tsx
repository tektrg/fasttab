import { useCallback, useMemo, useState } from "react";
import type { FullState, NeedsYouRow } from "../../types";
import { useToast } from "../../ui/Toast";
import { TabBar } from "./TabBar";
import { InboxTab } from "./InboxTab";
import { AgentsTab } from "./AgentsTab";
import { SettingsTab } from "./SettingsTab";
import { PhoneSheet } from "./PhoneSheet";
import { PromptSheet } from "./PromptSheet";
import { PersonaMessageSheet } from "./PersonaMessageSheet";
import { usePhoneBoard } from "./usePhoneBoard";
import {
  buildAgents,
  filterCounts,
  inboxBadgeCount,
  sortNeedsYou,
  type PhoneAgent,
  type PhoneTab,
} from "./phoneModel";
import "./phone.css";

const TITLE: Record<PhoneTab, string> = { inbox: "Inbox", agents: "Agents", settings: "Settings" };

// One row per session: the key survives the prompt changing (question -> permission).
const promptKey = (n: NeedsYouRow) => n.agentSession ?? n.label;

/** The phone app: three tabs (Inbox / Agents / Settings) over the same
 *  dashboard state and session board the desktop reads. A row opens a bottom
 *  sheet (peek -> full); the header "+" opens the persona message sheet.
 *  Mounted by App.tsx instead of the desktop chrome below ~640px, inside a
 *  `ToastProvider` (toasts sit above the tab bar via --ui-tabbar-height). */
export function PhoneShell({ state }: { state: FullState }) {
  const ui = useToast();
  const onToast = useCallback((message: string, _ok: boolean) => void ui.show({ message }), [ui]);
  const onUndo = useCallback(
    (message: string, undo: () => void) => void ui.show({ message, actionLabel: "Undo", onAction: undo }),
    [ui],
  );

  const { board, reload } = usePhoneBoard();
  const [tab, setTab] = useState<PhoneTab>("inbox");
  const [openRowId, setOpenRowId] = useState<string | null>(null);
  const [promptId, setPromptId] = useState<string | null>(null);
  const [personaOpen, setPersonaOpen] = useState(false);

  const rows = board?.rows ?? [];
  const needsYou = useMemo(() => sortNeedsYou(state.computed.needsYou), [state.computed.needsYou]);
  const agents = useMemo(() => {
    const panes = new Set<string>();
    for (const n of needsYou) if (n.paneId) panes.add(n.paneId);
    return buildAgents(rows, panes, state.computed.sleepingSessions ?? [], state.serverTimeTs);
  }, [rows, needsYou, state.computed.sleepingSessions, state.serverTimeTs]);
  const workingCount = filterCounts(agents).working;

  const openNeedsYou = (n: NeedsYouRow) => {
    // OpenCode / Codex prompts sit on a pane but carry their own request:
    // only the prompt sheet can answer them (PanelessPrompt).
    if (!n.paneId || n.hookRequest?.tool) {
      setPromptId(promptKey(n));
      return;
    }
    const row = rows.find((r) => r.derived.paneId === n.paneId);
    if (row) setOpenRowId(row.rowId);
    else onToast("still loading detail for this agent — try again in a moment", false);
  };

  const openAgent = (a: PhoneAgent) => {
    if (a.row) setOpenRowId(a.row.rowId);
    else onToast("Asleep — open it in Claude on the Mac", true);
  };

  const openRow = rows.find((r) => r.rowId === openRowId) ?? null;
  const promptRow = needsYou.find((n) => promptKey(n) === promptId) ?? null;

  return (
    <div className="phone-app">
      <header>
        <h1>{TITLE[tab]}</h1>
        {tab !== "settings" && (
          <button
            type="button"
            aria-label="message a persona"
            title="Message a persona (or start one)"
            className="phone-new-session"
            onClick={() => setPersonaOpen(true)}
          >
            +
          </button>
        )}
      </header>

      {tab === "inbox" && (
        <InboxTab
          needsYou={needsYou}
          workingCount={workingCount}
          onOpen={openNeedsYou}
          onGoAgents={() => setTab("agents")}
        />
      )}
      {tab === "agents" && <AgentsTab agents={agents} onOpen={openAgent} />}
      {tab === "settings" && <SettingsTab state={state} />}

      <TabBar tab={tab} onTab={setTab} inboxBadge={inboxBadgeCount(needsYou)} />

      <PhoneSheet
        row={openRow}
        properties={board?.properties ?? []}
        onClose={() => setOpenRowId(null)}
        onToast={onToast}
        onUndo={onUndo}
        onRefetch={reload}
      />
      <PromptSheet row={promptRow} onClose={() => setPromptId(null)} onToast={onToast} />
      <PersonaMessageSheet opened={personaOpen} rows={rows} onClose={() => setPersonaOpen(false)} onToast={onToast} />
    </div>
  );
}
