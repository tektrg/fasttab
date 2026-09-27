import { describe, expect, test } from "bun:test";
import {
  folderBasename,
  folderGroupKey,
  groupByFolder,
  persistGroupBy,
  readGroupBy,
  type FolderGroupable,
} from "../components/phone/folderGrouping";

function row(over: Partial<FolderGroupable> & { rowId: string }): FolderGroupable {
  return { cwd: null, machine: "local", needsYouKind: null, ...over };
}

describe("folderBasename", () => {
  test("returns the last path segment", () => {
    expect(folderBasename("/Users/po/01_Project/AptusFit")).toBe("AptusFit");
  });
  test("handles a trailing slash", () => {
    expect(folderBasename("/Users/po/01_Project/AptusFit/")).toBe("AptusFit");
  });
  test("root path", () => {
    expect(folderBasename("/")).toBe("/");
  });
});

describe("folderGroupKey", () => {
  test("local machine keys by folder alone", () => {
    expect(folderGroupKey("local", "/a/b")).toBe("/a/b");
  });
  test("a remote (Air) machine is keyed by machine+folder — same folder, different machine, different group", () => {
    const a = folderGroupKey("Air", "/a/b");
    const b = folderGroupKey("local", "/a/b");
    expect(a).not.toBe(b);
    expect(a).toBe("Air::/a/b");
  });
});

describe("groupByFolder", () => {
  test("groups rows sharing a cwd together", () => {
    const rows = [
      row({ rowId: "1", cwd: "/proj/A" }),
      row({ rowId: "2", cwd: "/proj/A" }),
      row({ rowId: "3", cwd: "/proj/B" }),
    ];
    const groups = groupByFolder(rows);
    expect(groups.length).toBe(2);
    const a = groups.find((g) => g.folderPath === "/proj/A")!;
    expect(a.rows.map((r) => r.rowId).sort()).toEqual(["1", "2"]);
  });

  test("folders containing a Needs-you agent sort first", () => {
    const rows = [
      row({ rowId: "1", cwd: "/proj/Zzz" }),
      row({ rowId: "2", cwd: "/proj/Aaa", needsYouKind: "blocked" }),
    ];
    const groups = groupByFolder(rows);
    expect(groups[0].folderPath).toBe("/proj/Aaa");
    expect(groups[0].hasNeedsYou).toBe(true);
  });

  test("within a folder, blocked sorts before question before feed-broken before plain rows", () => {
    const rows = [
      row({ rowId: "1", cwd: "/proj", needsYouKind: null }),
      row({ rowId: "2", cwd: "/proj", needsYouKind: "feed-broken" }),
      row({ rowId: "3", cwd: "/proj", needsYouKind: "blocked" }),
      row({ rowId: "4", cwd: "/proj", needsYouKind: "question" }),
    ];
    const groups = groupByFolder(rows);
    expect(groups[0].rows.map((r) => r.rowId)).toEqual(["3", "4", "2", "1"]);
  });

  test("Air rows in the same folder as a local row form a separate group", () => {
    const rows = [
      row({ rowId: "1", cwd: "/proj", machine: "local" }),
      row({ rowId: "2", cwd: "/proj", machine: "Air" }),
    ];
    const groups = groupByFolder(rows);
    expect(groups.length).toBe(2);
  });

  test("no folder falls back to a labeled group instead of throwing", () => {
    const groups = groupByFolder([row({ rowId: "1", cwd: null })]);
    expect(groups.length).toBe(1);
    expect(groups[0].folderPath).toBe("(no folder)");
  });
});

describe("group-by persistence", () => {
  test("defaults to status when nothing is stored", () => {
    try {
      window.localStorage.removeItem("chief-dashboard-phone-group-by");
    } catch {
      /* ignore */
    }
    expect(readGroupBy()).toBe("status");
  });

  test("persists and reads back folder", () => {
    persistGroupBy("folder");
    expect(readGroupBy()).toBe("folder");
    persistGroupBy("status");
    expect(readGroupBy()).toBe("status");
  });

  test("an invalid stored value falls back to status", () => {
    try {
      window.localStorage.setItem("chief-dashboard-phone-group-by", "garbage");
    } catch {
      /* ignore */
    }
    expect(readGroupBy()).toBe("status");
  });
});
