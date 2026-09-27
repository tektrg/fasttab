import { describe, expect, test } from "bun:test";
import { filterAgents, matchesQuery, queryWords } from "../agentMatch";

describe("agentMatch: matchesQuery", () => {
  const agent = {
    name: "chief-aptus",
    machine: "Air",
    project: "/Users/po/01_Project/AptusFit",
    status: "blocked",
    latestLine: "waiting on you: allow this tool?",
  };

  test("empty query matches everything", () => {
    expect(matchesQuery(agent, "")).toBe(true);
    expect(matchesQuery(agent, "   ")).toBe(true);
  });

  test("matches by name, machine, folder, status, or latest line independently", () => {
    expect(matchesQuery(agent, "chief")).toBe(true);
    expect(matchesQuery(agent, "air")).toBe(true);
    expect(matchesQuery(agent, "aptusfit")).toBe(true);
    expect(matchesQuery(agent, "blocked")).toBe(true);
    expect(matchesQuery(agent, "allow this")).toBe(true);
  });

  test("case-insensitive", () => {
    expect(matchesQuery(agent, "CHIEF-APTUS")).toBe(true);
    expect(matchesQuery(agent, "AIR")).toBe(true);
  });

  test("diacritic-insensitive", () => {
    const a2 = { name: "café-agent" };
    expect(matchesQuery(a2, "cafe")).toBe(true);
    expect(matchesQuery(a2, "café")).toBe(true);
  });

  test("multi-word is AND across all fields, any order", () => {
    expect(matchesQuery(agent, "chief blocked")).toBe(true);
    expect(matchesQuery(agent, "blocked chief")).toBe(true);
    expect(matchesQuery(agent, "chief missing")).toBe(false);
  });

  test("no match when nothing contains the query", () => {
    expect(matchesQuery(agent, "nonexistent")).toBe(false);
  });

  test("queryWords splits and trims", () => {
    expect(queryWords("  foo   bar ")).toEqual(["foo", "bar"]);
    expect(queryWords("")).toEqual([]);
  });
});

describe("agentMatch: filterAgents", () => {
  const agents = [
    { name: "alpha", status: "working" },
    { name: "beta", status: "blocked" },
    { name: "gamma", status: "working" },
  ];

  test("returns all agents for an empty query", () => {
    expect(filterAgents(agents, "").length).toBe(3);
  });

  test("filters down to matches", () => {
    expect(filterAgents(agents, "blocked").map((a) => a.name)).toEqual(["beta"]);
  });

  test("returns empty array when nothing matches", () => {
    expect(filterAgents(agents, "zzz")).toEqual([]);
  });
});
