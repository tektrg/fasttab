/** Adapter: phone agent rows -> the shared table engine (`@tektrg/table-core`,
 *  github.com/tektrg/table-core). The "Group: Folder" list is expressed as a
 *  ViewSpec and ordered/grouped by the engine's in-memory `evaluate()`.
 *
 *  Folder names use the engine's "natural" collation (case/accent-insensitive,
 *  numeric-aware); rows tie in server order via `tieBreak: "sourceOrder"`.
 *  `folderFirstSeen` stays: same-named folders (two machines, two parents)
 *  are ordered by first appearance, which no collation can express. */
import { evaluate, type FieldDefinition, type FieldRoleMap, type GroupNode, type SourceRow, type ViewSpec } from "@tektrg/table-core";
import type { FolderGroupable, NeedsYouKind } from "./folderGrouping";

/** Optional display data; present on real phone agents, absent in bare fixtures. */
export interface AgentTableInput extends FolderGroupable {
  name?: string;
  bucket?: string;
  ageSec?: number | null;
}

export const AGENT_FIELDS: FieldDefinition[] = [
  { id: "name", label: "Agent", type: "text" },
  { id: "status", label: "State", type: "text" },
  { id: "lastActivityAt", label: "Last activity", type: "date" },
  { id: "folderKey", label: "Folder", type: "text" },
  { id: "folderHasNeedsYou", label: "Folder needs you", type: "boolean" },
  { id: "folderName", label: "Folder name", type: "text" },
  { id: "folderFirstSeen", label: "Folder first seen", type: "number" },
  { id: "needsYouRank", label: "Needs-you rank", type: "number" },
];

export const AGENT_DEFAULT_ROLES: FieldRoleMap = { title: "name", status: "status", date: "lastActivityAt" };

/** Today's "Group: Folder" list: needs-you folders first, then folder name,
 *  then first appearance; inside a folder blocked > question > feed-broken > rest. */
export const FOLDER_VIEW_SPEC: ViewSpec = {
  specVersion: 1,
  viewType: "list",
  groupBy: [
    { fieldId: "folderHasNeedsYou", direction: "desc" },
    { fieldId: "folderName", direction: "asc", collation: "natural" },
    { fieldId: "folderFirstSeen", direction: "asc" },
  ],
  sort: [{ fieldId: "needsYouRank", direction: "asc" }],
  tieBreak: "sourceOrder",
};

const NEEDSYOU_RANK: Record<Exclude<NeedsYouKind, null>, number> = { blocked: 0, question: 1, "feed-broken": 2 };
const NOT_NEEDED_RANK = 99;
const NO_FOLDER = "(no folder)";

function folderOf(cwd: string | null): string {
  return cwd || NO_FOLDER;
}

export function folderBasename(path: string): string {
  const trimmed = path.replace(/\/+$/, "");
  if (!trimmed) return "/";
  const parts = trimmed.split("/");
  return parts[parts.length - 1] || trimmed;
}

/** Air (remote-machine) rows are keyed by machine+folder. */
export function folderGroupKey(machine: string, cwd: string | null): string {
  const folder = folderOf(cwd);
  return machine && machine !== "local" ? `${machine}::${folder}` : folder;
}

/** Rows -> engine rows. Row id = the session/pane row id (stable across polls). */
export function toAgentSourceRows(agents: AgentTableInput[], nowMs: number = Date.now()): SourceRow[] {
  const firstSeen = new Map<string, number>();
  const needsYouFolders = new Set<string>();
  agents.forEach((agent) => {
    const key = folderGroupKey(agent.machine, agent.cwd);
    if (!firstSeen.has(key)) firstSeen.set(key, firstSeen.size);
    if (agent.needsYouKind) needsYouFolders.add(key);
  });
  return agents.map((agent) => {
    const key = folderGroupKey(agent.machine, agent.cwd);
    return {
      id: agent.rowId,
      name: agent.name ?? null,
      status: agent.bucket ?? null,
      lastActivityAt: agent.ageSec == null ? null : new Date(nowMs - agent.ageSec * 1000).toISOString(),
      folderKey: key,
      folderHasNeedsYou: needsYouFolders.has(key),
      folderName: folderBasename(folderOf(agent.cwd)),
      folderFirstSeen: firstSeen.get(key)!,
      needsYouRank: agent.needsYouKind ? NEEDSYOU_RANK[agent.needsYouKind] : NOT_NEEDED_RANK,
    };
  });
}

/** Leaf groups of a group tree, in order. */
export function leafGroups(nodes: GroupNode[]): GroupNode[] {
  return nodes.flatMap((node) => (node.children ? leafGroups(node.children) : [node]));
}

/** Runs the spec; returns ordered leaf groups of source rows. Throws on an invalid spec (a programming error). */
export function evaluateAgentView(agents: AgentTableInput[], spec: ViewSpec = FOLDER_VIEW_SPEC): GroupNode[] {
  const result = evaluate(spec, toAgentSourceRows(agents), AGENT_FIELDS);
  if (!result.ok) throw new Error(`agent view spec invalid: ${result.errors.map((e) => e.message).join("; ")}`);
  return leafGroups(result.groups);
}
