import { describe, expect, test } from "bun:test";
import type { BoardRow, NeedsYouRow, SleepingSession } from "../types";
import {
  agentSections,
  agentsEmptyText,
  brokenFeeds,
  buildAgents,
  defaultSheetTab,
  emptyInboxText,
  filterCounts,
  groupInbox,
  inboxBadgeCount,
  initialsOf,
  sheetStatus,
  sheetTabs,
} from "../components/phone/phoneModel";
import { groupByFolder } from "../components/phone/folderGrouping";

function ny(kind: NeedsYouRow["kind"], label: string, paneId: string | null = null): NeedsYouRow {
  return { kind, urgency: 1, label, paneId, detail: "d", sinceSec: 5, identity: null };
}

function row(rowId: string, over: Partial<BoardRow> = {}, derived: Partial<BoardRow["derived"]> = {}): BoardRow {
  return {
    rowKind: "session",
    rowId,
    status: "live",
    derived: {
      paneId: "p-" + rowId,
      paneIdSanitized: "p",
      label: rowId,
      cwd: "/work/" + rowId,
      focused: false,
      hookState: "working",
      hookSinceSec: 10,
      herdrStatus: "working",
      disagree: false,
      hasHookData: true,
      screenState: "WORKING",
      ...derived,
    },
    values: {},
    ...over,
  };
}

const sleep = (cli: string | null, label = "asleep"): SleepingSession => ({
  desktopSessionId: "local_" + cli,
  cliSessionId: cli,
  label,
  cwd: "/work/x",
  lastActiveTs: 900,
  openUrl: "claude://code/continue?session=local_" + cli,
});

describe("Inbox", () => {
  test("badge = blocked + questions, feed notices excluded", () => {
    expect(inboxBadgeCount([ny("blocked", "a"), ny("question", "b"), ny("feed-broken", "c"), ny("question", "d")])).toBe(3);
    expect(inboxBadgeCount([])).toBe(0);
  });

  test("groups split questions / blocked / feed, order kept within a group", () => {
    const g = groupInbox([ny("question", "q1"), ny("blocked", "b1"), ny("feed-broken", "f"), ny("question", "q2")]);
    expect(g.questions.map((n) => n.label)).toEqual(["q1", "q2"]);
    expect(g.blocked.map((n) => n.label)).toEqual(["b1"]);
    expect(g.feed.map((n) => n.label)).toEqual(["f"]);
  });

  test("empty-state text names how many agents work", () => {
    expect(emptyInboxText(5)).toBe("Nothing needs you. 5 agents working.");
    expect(emptyInboxText(1)).toBe("Nothing needs you. 1 agent working.");
    expect(emptyInboxText(0)).toBe("Nothing needs you.");
  });

  test("initials", () => {
    expect(initialsOf("chief-aptus")).toBe("CA");
    expect(initialsOf("fasttab")).toBe("FA");
    expect(initialsOf("")).toBe("?");
  });
});

describe("Agents", () => {
  const rows = [
    row("w1"),
    row("w2"),
    row("p1", { archived: true }),
    row("e1", { status: "ended", endedNote: "ended · stopped" }),
    row("s1", { status: "ended" }),
    row("blocked", {}, { paneId: "in-inbox" }),
  ];
  const agents = buildAgents(rows, new Set(["in-inbox"]), [sleep("s1"), sleep("only-desktop", "desktop only")], 1000);

  test("buckets, inbox panes left out, sleeping merged with its ended board row", () => {
    expect(agents.map((a) => `${a.rowId}:${a.bucket}`)).toEqual([
      "w1:working", "w2:working", "p1:parked", "e1:ended", "s1:sleeping", "only-desktop:sleeping",
    ]);
    expect(agents.find((a) => a.rowId === "s1")?.row).not.toBeNull();
    expect(agents.find((a) => a.rowId === "only-desktop")?.row).toBeNull();
    expect(agents.find((a) => a.rowId === "s1")?.ageSec).toBe(100);
  });

  test("filter counts", () => {
    expect(filterCounts(agents)).toEqual({ all: 6, working: 2, parked: 1, sleeping: 2 });
  });

  test("sections: All shows every non-empty bucket in order; a chip shows one", () => {
    expect(agentSections(agents, "all").map((s) => s.title)).toEqual(["Working", "Parked", "Ended", "Sleeping"]);
    expect(agentSections(agents, "parked").map((s) => s.title)).toEqual(["Parked"]);
    expect(agentSections(agents.filter((a) => a.bucket === "working"), "all").map((s) => s.title)).toEqual(["Working"]);
    expect(agentSections(agents, "folder")).toEqual([]);
  });

  test("folder chip groups by working folder", () => {
    const groups = groupByFolder(agents);
    expect(groups.map((g) => g.folderName).sort()).toEqual(["e1", "p1", "s1", "w1", "w2", "x"]);
    expect(groups.find((g) => g.folderName === "x")?.rows.length).toBe(1);
  });

  test("empty-state copy per filter", () => {
    expect(agentsEmptyText("all", true)).toBe("No agents match.");
    expect(agentsEmptyText("sleeping", false)).toBe("No sleeping sessions.");
    expect(agentsEmptyText("parked", false)).toBe("Nothing parked.");
  });
});

describe("Sheet", () => {
  test("tabs: terminal needs a live pane, plan only while pending", () => {
    expect(sheetTabs(row("a"))).toEqual(["activity", "terminal"]);
    expect(sheetTabs(row("a", { status: "ended" }))).toEqual(["activity"]);
    const plan = row("a", {}, { screenPermission: { kind: "plan" } as never });
    expect(sheetTabs(plan)).toEqual(["activity", "terminal", "plan"]);
    expect(defaultSheetTab(plan)).toBe("plan");
    expect(defaultSheetTab(row("a"))).toBe("activity");
  });

  test("header status", () => {
    expect(sheetStatus(row("a"), false)).toBe("run");
    expect(sheetStatus(row("a", { archived: true }), false)).toBe("park");
    expect(sheetStatus(row("a", { status: "ended" }), false)).toBe("end");
    expect(sheetStatus(row("a", { status: "ended" }), true)).toBe("sleep");
    expect(sheetStatus(row("a", {}, { screenPermission: { kind: "tool" } as never }), false)).toBe("need");
  });
});

describe("Settings", () => {
  test("brokenFeeds ignores non-feed keys", () => {
    expect(brokenFeeds({ herdr: { broken: true }, board: { broken: false }, machinesConfigError: null })).toEqual(["herdr"]);
  });
});
