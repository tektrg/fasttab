/**
 * Screen states added 2026-09-20 must not render as `st-unknown` (amber "?"):
 * a logged-out pane needs a person (red), a pane parked on its own
 * monitor/agent is calm (its own class), and neither may read as idle.
 */
import { describe, expect, test } from "bun:test";
import { screenClassOf } from "../components/stateClasses";
import { agentStatus } from "../components/Agents";
import type { AgentRow } from "../types";

const row = (over: Partial<AgentRow>) => ({ hookState: null, screenState: null, ...over }) as AgentRow;

describe("screenClassOf", () => {
  test("NEEDS_LOGIN is a needs-human red", () => {
    expect(screenClassOf("NEEDS_LOGIN")).toBe("st-blocked");
  });
  test("WAITING_ON_BACKGROUND has its own calm class", () => {
    expect(screenClassOf("WAITING_ON_BACKGROUND")).toBe("st-parked");
  });
  test("existing states are unchanged", () => {
    expect(screenClassOf("NEEDS_HUMAN")).toBe("st-blocked");
    expect(screenClassOf("CRASHED")).toBe("st-blocked");
    expect(screenClassOf("ACTIVE")).toBe("st-working");
    expect(screenClassOf("WAITING")).toBe("st-idle");
    expect(screenClassOf("UNKNOWN")).toBe("st-unknown");
    expect(screenClassOf(null)).toBe("st-unknown");
  });
});

describe("agentStatus", () => {
  test("a login wall reads blocked", () => {
    expect(agentStatus(row({ hookState: "idle", screenState: "NEEDS_LOGIN" }))).toBe("blocked");
  });
  test("parked on background work reads working, not idle", () => {
    expect(agentStatus(row({ hookState: "idle", screenState: "WAITING_ON_BACKGROUND" }))).toBe("working");
  });
  test("parked past the 2h ceiling no longer reads working", () => {
    expect(
      agentStatus(row({ hookState: "working", screenState: "WAITING_ON_BACKGROUND", backgroundWaitExpired: true })),
    ).toBe("idle");
  });
});
