import { describe, expect, test } from "bun:test";
import { AGENT_DEFAULT_ROLES, AGENT_FIELDS, FOLDER_VIEW_SPEC, toAgentSourceRows, type AgentTableInput } from "../components/phone/agentTableView";
import { groupByFolder, type FolderGroupable, type NeedsYouKind } from "../components/phone/folderGrouping";
import { validateSpec } from "@tektrg/table-core";

function agent(over: Partial<AgentTableInput> & { rowId: string }): AgentTableInput {
  return { cwd: null, machine: "local", needsYouKind: null, ...over };
}

/** Frozen copy of the pre-engine groupByFolder — the parity oracle. */
function legacyGroupByFolder<T extends FolderGroupable>(rows: T[]) {
  const rank: Record<string, number> = { blocked: 0, question: 1, "feed-broken": 2 };
  const base = (p: string) => { const t = p.replace(/\/+$/, ""); if (!t) return "/"; const s = t.split("/"); return s[s.length - 1] || t; };
  const map = new Map<string, { key: string; folderName: string; folderPath: string; machine: string; rows: T[]; hasNeedsYou: boolean }>();
  for (const row of rows) {
    const folder = row.cwd || "(no folder)";
    const key = row.machine && row.machine !== "local" ? `${row.machine}::${folder}` : folder;
    let g = map.get(key);
    if (!g) { g = { key, folderName: base(folder), folderPath: folder, machine: row.machine, rows: [], hasNeedsYou: false }; map.set(key, g); }
    g.rows.push(row);
    if (row.needsYouKind) g.hasNeedsYou = true;
  }
  const groups = [...map.values()];
  for (const g of groups) g.rows = [...g.rows].sort((a, b) => (a.needsYouKind ? rank[a.needsYouKind] : 99) - (b.needsYouKind ? rank[b.needsYouKind] : 99));
  // One deliberate change vs the frozen original (`a.folderName.localeCompare(b.folderName)`): names that differ
  // only by case ("Zeta" / "zeta") now order by code point (uppercase first), as table-core "natural" collation
  // does; localeCompare put lowercase first. Every other ordering is unchanged.
  const byName = (a: string, b: string) => a.localeCompare(b, undefined, { sensitivity: "base" }) || (a < b ? -1 : a > b ? 1 : 0);
  groups.sort((a, b) => (a.hasNeedsYou !== b.hasNeedsYou ? (a.hasNeedsYou ? -1 : 1) : byName(a.folderName, b.folderName)));
  return groups;
}

describe("agent adapter", () => {
  test("row id is the session row id; default roles map title/status/date", () => {
    const [row] = toAgentSourceRows([agent({ rowId: "w1:p2", name: "chief", bucket: "working", ageSec: 60, cwd: "/a" })], Date.parse("2026-10-04T00:01:00Z"));
    expect(row.id).toBe("w1:p2");
    expect(AGENT_DEFAULT_ROLES).toEqual({ title: "name", status: "status", date: "lastActivityAt" });
    expect(row[AGENT_DEFAULT_ROLES.title!]).toBe("chief");
    expect(row[AGENT_DEFAULT_ROLES.status!]).toBe("working");
    expect(row[AGENT_DEFAULT_ROLES.date!]).toBe("2026-10-04T00:00:00.000Z");
  });
  test("missing display data becomes empty, not a crash", () => {
    const [row] = toAgentSourceRows([agent({ rowId: "x" })]);
    expect(row.name).toBeNull();
    expect(row.lastActivityAt).toBeNull();
    expect(row.folderKey).toBe("(no folder)");
  });
  test("default spec is valid against the adapter fields", () => {
    expect(validateSpec(FOLDER_VIEW_SPEC, AGENT_FIELDS)).toEqual([]);
  });
});

const KINDS: NeedsYouKind[] = [null, null, "blocked", "question", "feed-broken"];
const FOLDERS = ["/p/AptusFit", "/p/apple", "/p/Zeta", "/p/zeta/", "/p/Đơn", "/q/AptusFit", null];
const MACHINES = ["local", "local", "Air"];

function fixture(seed: number, size: number): AgentTableInput[] {
  let s = seed;
  const next = (n: number) => { s = (s * 1103515245 + 12345) % 2147483648; return s % n; };
  return Array.from({ length: size }, (_, i) => agent({
    rowId: `r${next(1000)}-${i}`,
    cwd: FOLDERS[next(FOLDERS.length)]!,
    machine: MACHINES[next(MACHINES.length)]!,
    needsYouKind: KINDS[next(KINDS.length)]!,
  }));
}

describe("engine path matches the pre-engine folder list", () => {
  const shape = (groups: ReturnType<typeof legacyGroupByFolder>) =>
    groups.map((g) => ({ ...g, rows: g.rows.map((r) => r.rowId) }));
  test("empty", () => expect(groupByFolder([])).toEqual([]));
  test("hand-picked: case/locale names, same name on two machines, ties keep server order", () => {
    const rows = [
      agent({ rowId: "b", cwd: "/p/beta" }),
      agent({ rowId: "A1", cwd: "/p/Alpha" }),
      agent({ rowId: "air", cwd: "/p/Alpha", machine: "Air" }),
      agent({ rowId: "a0", cwd: "/p/Alpha" }),
      agent({ rowId: "q", cwd: "/p/beta", needsYouKind: "question" }),
    ];
    expect(shape(groupByFolder(rows))).toEqual(shape(legacyGroupByFolder(rows)));
  });
  for (let seed = 1; seed <= 40; seed++) {
    test(`random fixture ${seed}`, () => {
      const rows = fixture(seed, 1 + (seed % 25));
      expect(shape(groupByFolder(rows))).toEqual(shape(legacyGroupByFolder(rows)));
    });
  }
});
