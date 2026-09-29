import { describe, expect, test } from "bun:test";
import { quickAnswerBody, quickAnswerKind, quickAnswerToast } from "../quickAnswer";
import type { HookRequest } from "../types";

const opts = (...labels: string[]) => labels.map((label) => ({ label, description: "" }));
const question = (options: string[], over: Partial<HookRequest["questions"] extends (infer Q)[] | undefined ? Q : never> = {}): HookRequest => ({
  requestId: "r1",
  kind: "question",
  toolName: "AskUserQuestion",
  questions: [{ question: "Proceed?", header: "", multiSelect: false, options: opts(...options), ...over }],
});
const permission = (toolName: string, suggestions: { index: number; label: string }[] = []): HookRequest => ({
  requestId: "r2",
  kind: "permission",
  toolName,
  permission: { title: "t", detail: "d", suggestions },
});

describe("quickAnswerKind: shown", () => {
  test("Yes / No in either order", () => {
    expect(quickAnswerKind(question(["Yes", "No"]))).toEqual({ kind: "yesno", question: "Proceed?", yes: "Yes", no: "No" });
    expect(quickAnswerKind(question(["No", "Yes"]))).toEqual({ kind: "yesno", question: "Proceed?", yes: "Yes", no: "No" });
  });
  test("punctuation / case tolerant; keeps the original labels", () => {
    expect(quickAnswerKind(question(["Yes!", "No."]))).toMatchObject({ yes: "Yes!", no: "No." });
    expect(quickAnswerKind(question(["approve", "REJECT"]))).toMatchObject({ yes: "approve", no: "REJECT" });
    expect(quickAnswerKind(question(["true", "false"]))).not.toBeNull();
  });
  test("read-only permission (no saved rule)", () => {
    expect(quickAnswerKind(permission("Read"))).toEqual({ kind: "permission" });
    expect(quickAnswerKind(permission("Grep"))).toEqual({ kind: "permission" });
  });
});

describe("quickAnswerKind: excluded", () => {
  test("null / missing", () => {
    expect(quickAnswerKind(null)).toBeNull();
    expect(quickAnswerKind(undefined)).toBeNull();
    expect(quickAnswerKind({ ...permission("Edit"), permission: undefined })).toBeNull();
  });
  test("Bash / command permission, with or without a don't-ask-again rule", () => {
    expect(quickAnswerKind(permission("Bash"))).toBeNull();
    expect(quickAnswerKind(permission("exec_command"))).toBeNull();
    expect(quickAnswerKind(permission("Bash", [{ index: 0, label: "Yes, and don't ask again for ls" }]))).toBeNull();
  });
  test("write / fetch / delegate / plan / MCP / unknown tools and non-Claude tools open the sheet", () => {
    for (const t of ["Edit", "Write", "MultiEdit", "NotebookEdit", "WebFetch", "Task", "ExitPlanMode", "mcp__github__delete_repo", "mcp__shell__run", "apply_patch", "", "read", "Read2"])
      expect(quickAnswerKind(permission(t))).toBeNull();
    expect(quickAnswerKind({ ...permission("Read"), tool: "codex" })).toBeNull();
    expect(quickAnswerKind({ ...permission("Read"), tool: "opencode" })).toBeNull();
  });
  test("labels that merely contain yes/no, non-English, never-ask-again wording", () => {
    for (const pair of [["Yes, and don't ask again", "No"], ["Yes (recommended)", "No"], ["Yes, delete everything", "No, keep"], ["Có", "Không"], ["はい", "いいえ"], ["Yes", "Yes to all"], ["Always yes", "No"], ["Allow always", "Deny"]])
      expect(quickAnswerKind(question(pair))).toBeNull();
  });
  test("swapped order maps Yes and No to the right labels, never by index", () => {
    const k = quickAnswerKind(question(["Reject", "Approve"]))!;
    expect(quickAnswerBody(k, "yes")).toEqual({ behavior: "allow", answers: { "Proceed?": "Approve" } });
    expect(quickAnswerBody(k, "no")).toEqual({ behavior: "allow", answers: { "Proceed?": "Reject" } });
  });
  test("any permission that carries a saved-rule suggestion", () => {
    expect(quickAnswerKind(permission("Read", [{ index: 0, label: "Always allow edits" }]))).toBeNull();
  });
  test("three options, one option, multi-select, multi-question, non-boolean pair", () => {
    expect(quickAnswerKind(question(["Yes", "No", "Maybe"]))).toBeNull();
    expect(quickAnswerKind(question(["Yes"]))).toBeNull();
    expect(quickAnswerKind(question(["Yes", "No"], { multiSelect: true }))).toBeNull();
    expect(quickAnswerKind(question(["Poll", "Push"]))).toBeNull();
    expect(quickAnswerKind(question(["Yes", "Yes"]))).toBeNull();
    expect(quickAnswerKind(question(["No", "Nope"]))).toBeNull();
    const two = question(["Yes", "No"]);
    two.questions = [...two.questions!, ...two.questions!];
    expect(quickAnswerKind(two)).toBeNull();
    expect(quickAnswerKind({ ...two, questions: [] })).toBeNull();
    expect(quickAnswerKind({ ...two, questions: undefined })).toBeNull();
  });
});

describe("quickAnswerBody / toast", () => {
  test("yes/no answer carries the question and the picked original label", () => {
    const k = quickAnswerKind(question(["Yes!", "No."]))!;
    expect(quickAnswerBody(k, "yes")).toEqual({ behavior: "allow", answers: { "Proceed?": "Yes!" } });
    expect(quickAnswerBody(k, "no")).toEqual({ behavior: "allow", answers: { "Proceed?": "No." } });
    expect(quickAnswerToast(k, "no")).toBe('Answered "No."');
  });
  test("permission maps to allow once / deny", () => {
    const k = quickAnswerKind(permission("Read"))!;
    expect(quickAnswerBody(k, "yes")).toEqual({ behavior: "allow" });
    expect(quickAnswerBody(k, "no").behavior).toBe("deny");
    expect(quickAnswerToast(k, "yes")).toBe("Allowed once");
    expect(quickAnswerToast(k, "no")).toBe("Denied once");
  });
});
