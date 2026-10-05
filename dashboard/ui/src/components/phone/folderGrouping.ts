/** Pure grouping/sorting logic for the phone inbox's "Group: Folder" mode —
 *  kept free of React/DOM so it's directly unit-testable. */
import { evaluateAgentView, folderBasename, folderGroupKey } from "./agentTableView";

export type NeedsYouKind = "blocked" | "question" | "feed-broken" | null;

export interface FolderGroupable {
  rowId: string;
  cwd: string | null;
  machine: string;
  needsYouKind: NeedsYouKind;
}

export interface FolderGroup<T> {
  key: string;
  /** Basename of the folder — what's shown as the section title. */
  folderName: string;
  /** Full path — shown as secondary text (long-press / subtitle). */
  folderPath: string;
  machine: string;
  rows: T[];
  hasNeedsYou: boolean;
}

export { folderBasename, folderGroupKey } from "./agentTableView";

/** Groups rows by working folder. Sort order: folders with at least one
 *  Needs-you agent first (alphabetical within each half), and within a
 *  folder, blocked agents before questions before feed-broken before
 *  anything else (server order otherwise). Ordering + grouping run on the
 *  shared table engine via `FOLDER_VIEW_SPEC` (see agentTableView.ts). */
export function groupByFolder<T extends FolderGroupable>(rows: T[]): FolderGroup<T>[] {
  const rowsById = new Map(rows.map((row) => [row.rowId, row]));
  return evaluateAgentView(rows).map((leaf) => {
    const groupRows = (leaf.rows ?? []).map((source) => rowsById.get(source.id as FolderGroupable["rowId"])!);
    const first = groupRows[0]!;
    const folderPath = first.cwd || "(no folder)";
    return {
      key: folderGroupKey(first.machine, first.cwd),
      folderName: folderBasename(folderPath),
      folderPath,
      machine: first.machine,
      rows: groupRows,
      hasNeedsYou: groupRows.some((row) => !!row.needsYouKind),
    };
  });
}

const GROUP_BY_KEY = "chief-dashboard-phone-group-by";
export type GroupBy = "status" | "folder";

export function readGroupBy(): GroupBy {
  try {
    const raw = window.localStorage.getItem(GROUP_BY_KEY);
    return raw === "folder" ? "folder" : "status";
  } catch {
    return "status"; // private mode
  }
}

export function persistGroupBy(value: GroupBy): void {
  try {
    window.localStorage.setItem(GROUP_BY_KEY, value);
  } catch {
    /* private mode — the choice simply does not survive the reload */
  }
}
