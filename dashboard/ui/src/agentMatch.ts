/** Shared "type to filter" matcher for the agent list (phone inbox, and any
 *  desktop search box that reuses it — one matcher, not a duplicate per
 *  surface). Case- and diacritic-insensitive, multi-word AND: every
 *  whitespace-separated word in the query must appear somewhere in the
 *  agent's searchable fields, in any order. */
export interface SearchableAgent {
  name: string;
  machine?: string | null;
  project?: string | null;
  status?: string | null;
  latestLine?: string | null;
}

function normalize(s: string): string {
  return s
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "") // strip combining diacritics
    .toLowerCase();
}

/** Splits a raw query into the AND-ed search words (empty query → no words,
 *  meaning "match everything"). Exported so a search box can decide whether
 *  it currently has an active filter. */
export function queryWords(query: string): string[] {
  return normalize(query).trim().split(/\s+/).filter(Boolean);
}

export function matchesQuery(agent: SearchableAgent, query: string): boolean {
  const words = queryWords(query);
  if (words.length === 0) return true;
  const haystack = normalize(
    [agent.name, agent.machine, agent.project, agent.status, agent.latestLine]
      .filter((v): v is string => !!v)
      .join(" \n "),
  );
  return words.every((w) => haystack.includes(w));
}

export function filterAgents<T extends SearchableAgent>(agents: T[], query: string): T[] {
  const words = queryWords(query);
  if (words.length === 0) return agents;
  return agents.filter((a) => matchesQuery(a, query));
}
