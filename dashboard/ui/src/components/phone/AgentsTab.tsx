import { useState } from "react";
import { TextInput, UnstyledButton } from "@mantine/core";
import { fmtAge } from "../../api";
import { filterAgents } from "../../agentMatch";
import { AgentRow } from "../../ui/AgentRow";
import { groupByFolder, persistGroupBy, readGroupBy } from "./folderGrouping";
import {
  agentSearchable,
  agentSections,
  agentsEmptyText,
  filterCounts,
  initialsOf,
  type AgentFilter,
  type PhoneAgent,
} from "./phoneModel";

const CHIPS: { id: AgentFilter; label: string }[] = [
  { id: "all", label: "All" },
  { id: "working", label: "Working" },
  { id: "parked", label: "Parked" },
  { id: "sleeping", label: "Sleeping" },
  { id: "folder", label: "Folder" },
];

/** Agents tab: every session — search, filter chips with counts (Folder
 *  groups instead of filtering), then Working / Parked / Ended / Sleeping. */
export function AgentsTab({ agents, onOpen }: { agents: PhoneAgent[]; onOpen: (a: PhoneAgent) => void }) {
  const [query, setQuery] = useState("");
  const [filter, setFilter] = useState<AgentFilter>(() => (readGroupBy() === "folder" ? "folder" : "all"));
  // Ended is the long tail: collapsed until asked for.
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>({ ended: true });

  const searching = query.trim().length > 0;
  const matched = filterAgents(
    agents.map((a) => ({ ...agentSearchable(a), _a: a })),
    query,
  ).map((x) => x._a as PhoneAgent);
  const counts = filterCounts(matched);
  const countOf = (id: AgentFilter) => (id === "folder" ? null : counts[id]);

  const pick = (id: AgentFilter) => {
    setFilter(id);
    persistGroupBy(id === "folder" ? "folder" : "status");
  };

  const row = (a: PhoneAgent) => (
    <AgentRow
      key={a.rowId}
      initials={initialsOf(a.name)}
      name={a.name}
      subtitle={a.subtitle}
      age={fmtAge(a.ageSec)}
      status={a.ui}
      onPress={() => onOpen(a)}
    />
  );

  const sections = agentSections(matched, filter);
  const folders = filter === "folder" ? groupByFolder(matched) : [];
  const nothing = filter === "folder" ? folders.length === 0 : sections.length === 0;

  return (
    <div>
      <div className="phone-search-bar">
        <TextInput
          value={query}
          onChange={(e) => setQuery(e.currentTarget.value)}
          placeholder="Search agents, folders"
          aria-label="Search agents"
          enterKeyHint="search"
          className="phone-search-input"
          // Mantine defaults sections to pointer-events:none, which made the
          // clear button (and its 44px hit area) untappable.
          rightSectionPointerEvents="auto"
          rightSection={
            query ? (
              <UnstyledButton aria-label="clear filter" onClick={() => setQuery("")} className="phone-search-clear">
                ✕
              </UnstyledButton>
            ) : null
          }
        />
        <div className="phone-chips" role="group" aria-label="Filter agents">
          {CHIPS.map((c) => (
            <button key={c.id} type="button" className="phone-chip" aria-pressed={filter === c.id} onClick={() => pick(c.id)}>
              {c.label}
              {countOf(c.id) !== null && <span className="phone-chip__n">{countOf(c.id)}</span>}
            </button>
          ))}
        </div>
      </div>

      <div className="phone-list">
        {nothing && <div className="phone-empty">{agentsEmptyText(filter, searching)}</div>}
        {filter !== "folder" &&
          sections.map((s) => {
            const closed = !searching && !!collapsed[s.bucket];
            return (
              <section key={s.bucket} data-section={s.bucket}>
                <UnstyledButton
                  className="phone-section-head"
                  aria-expanded={!closed}
                  onClick={() => setCollapsed((c) => ({ ...c, [s.bucket]: !c[s.bucket] }))}
                >
                  <span>{s.title}</span>
                  <span className="phone-section-head__count">{s.rows.length}</span>
                  <span className="phone-section-head__chev" aria-hidden="true">{closed ? "▸" : "▾"}</span>
                </UnstyledButton>
                {!closed && <div className="phone-section-body">{s.rows.map(row)}</div>}
              </section>
            );
          })}
        {folders.map((g) => (
          <section key={g.key} data-section={g.key}>
            <div className="phone-section-head" title={g.folderPath}>
              <span>{g.machine !== "local" ? `${g.machine} · ${g.folderName}` : g.folderName}</span>
              <span className="phone-section-head__count">{g.rows.length}</span>
            </div>
            <div className="phone-section-body">{g.rows.map(row)}</div>
          </section>
        ))}
      </div>
    </div>
  );
}
