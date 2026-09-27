/** Pure grouping/sorting logic for the phone inbox's "Group: Folder" mode —
 *  kept free of React/DOM so it's directly unit-testable. */

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

const NEEDSYOU_RANK: Record<Exclude<NeedsYouKind, null>, number> = {
  blocked: 0,
  question: 1,
  "feed-broken": 2,
};

export function folderBasename(path: string): string {
  const trimmed = path.replace(/\/+$/, "");
  if (!trimmed) return "/";
  const parts = trimmed.split("/");
  return parts[parts.length - 1] || trimmed;
}

/** Air (remote-machine) rows are grouped by machine+folder — two agents in
 *  "~/project" on different machines are different groups; two on the same
 *  machine in the same folder are one. */
export function folderGroupKey(machine: string, cwd: string | null): string {
  const folder = cwd || "(no folder)";
  return machine && machine !== "local" ? `${machine}::${folder}` : folder;
}

/** Groups rows by working folder. Sort order: folders with at least one
 *  Needs-you agent first (alphabetical within each half), and within a
 *  folder, blocked agents before questions before feed-broken before
 *  anything else (stable otherwise). */
export function groupByFolder<T extends FolderGroupable>(rows: T[]): FolderGroup<T>[] {
  const map = new Map<string, FolderGroup<T>>();
  for (const row of rows) {
    const folder = row.cwd || "(no folder)";
    const key = folderGroupKey(row.machine, row.cwd);
    let g = map.get(key);
    if (!g) {
      g = {
        key,
        folderName: folderBasename(folder),
        folderPath: folder,
        machine: row.machine,
        rows: [],
        hasNeedsYou: false,
      };
      map.set(key, g);
    }
    g.rows.push(row);
    if (row.needsYouKind) g.hasNeedsYou = true;
  }

  const groups = [...map.values()];
  for (const g of groups) {
    g.rows = [...g.rows].sort((a, b) => {
      const ra = a.needsYouKind ? NEEDSYOU_RANK[a.needsYouKind] : 99;
      const rb = b.needsYouKind ? NEEDSYOU_RANK[b.needsYouKind] : 99;
      return ra - rb;
    });
  }
  groups.sort((a, b) => {
    if (a.hasNeedsYou !== b.hasNeedsYou) return a.hasNeedsYou ? -1 : 1;
    return a.folderName.localeCompare(b.folderName);
  });
  return groups;
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
