import { describe, expect, test } from "bun:test";
import { ALL_STATUSES, STATUS_META } from "../ui/status";

describe("status language", () => {
  test("every state has a unique shape and a unique label", () => {
    const shapes = new Set(ALL_STATUSES.map((s) => STATUS_META[s].shape));
    const labels = new Set(ALL_STATUSES.map((s) => STATUS_META[s].label));
    expect(shapes.size).toBe(ALL_STATUSES.length);
    expect(labels.size).toBe(ALL_STATUSES.length);
  });
  test("only run pulses", () => {
    expect(ALL_STATUSES.filter((s) => STATUS_META[s].pulses)).toEqual(["run"]);
  });
  test("colours are tokens", () => {
    for (const s of ALL_STATUSES) expect(STATUS_META[s].colorVar).toMatch(/^--[a-z0-9-]+$/);
  });
});
