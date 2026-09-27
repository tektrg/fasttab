/**
 * FormCard (multi-question AskUserQuestion form — dashboard-move phase 2b).
 * Submits via the existing /api/answer path, one question at a time (the
 * dashboard's own /api/answer only ever answers the question on screen).
 * Radio vs checkbox per question follows isMultiSelect; typed "Other" text
 * replaces the option picks for that question, same precedence as
 * NeedsYou's QuestionBox.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { FormCard } from "../components/FormCard";
import { theme } from "../theme";
import type { PendingQuestionForm, PickerQuestion } from "../types";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

function form(): PendingQuestionForm {
  return {
    toolUseId: "toolu_1",
    questions: [
      {
        header: "Approach",
        question: "Which approach should I take?",
        isMultiSelect: false,
        options: [
          { label: "Rewrite", description: "start clean" },
          { label: "Patch", description: "smallest diff" },
        ],
      },
    ],
  };
}

// The screen-parsed copy of `form()`'s single question — same shape
// classify_pane.parse_question_block returns and NeedsYou's QuestionBox
// already sends. This is what `/api/answer`'s fresh re-read actually
// compares against, never the transcript's raw header/question strings.
function screenQuestion(): PickerQuestion {
  return {
    title: "Approach",
    question: "Which approach should I take?",
    multi: false,
    options: [
      { index: 1, label: "Rewrite", checked: false, other: false },
      { index: 2, label: "Patch", checked: false, other: false },
    ],
    cursorIndex: 1,
    otherIndex: null,
    hasSubmit: false,
  };
}

// Screen-parsed copy of multiQuestionForm()'s FIRST tab (Q1) — what the
// board sweep sees before anything is answered.
function multiScreenQuestion(): PickerQuestion {
  return {
    title: "Which files should change?",
    question: "Which files should change?",
    multi: true,
    options: [
      { index: 1, label: "a.ts", checked: false, other: false },
      { index: 2, label: "b.ts", checked: false, other: false },
      { index: 3, label: "c.ts", checked: false, other: false },
    ],
    cursorIndex: 1,
    otherIndex: null,
    hasSubmit: true,
  };
}

// Screen-parsed copy of multiQuestionForm()'s SECOND tab (Q2) — what the
// server hands back as `next` once Q1 lands, per `_settle_after_submit`.
function multiScreenQuestion2(): PickerQuestion {
  return {
    title: "Ship now?",
    question: "Ship now?",
    multi: false,
    options: [
      { index: 1, label: "Yes", checked: false, other: false },
      { index: 2, label: "No", checked: false, other: false },
    ],
    cursorIndex: 1,
    otherIndex: null,
    hasSubmit: false,
  };
}

function multiQuestionForm(): PendingQuestionForm {
  return {
    toolUseId: "toolu_2",
    questions: [
      {
        header: "",
        question: "Which files should change?",
        isMultiSelect: true,
        options: [{ label: "a.ts" }, { label: "b.ts" }, { label: "c.ts" }],
      },
      {
        header: "",
        question: "Ship now?",
        isMultiSelect: false,
        options: [{ label: "Yes" }, { label: "No" }],
      },
    ],
  };
}

function stubFetch(reply: unknown = { ok: true }) {
  const calls: { url: unknown; body: unknown }[] = [];
  globalThis.fetch = (async (url: unknown, init: unknown) => {
    let body: unknown = null;
    try {
      body = JSON.parse((init as { body: string }).body as string);
    } catch {
      /* no body */
    }
    calls.push({ url, body });
    return { json: async () => reply };
  }) as typeof fetch;
  return calls;
}

// One reply per call, in order (repeats the last once exhausted) — for a
// multi-question submit where each /api/answer response hands back the
// NEXT tab's screen-parsed question, and the test needs to see it used.
function stubFetchSequence(replies: unknown[]) {
  const calls: { url: unknown; body: unknown }[] = [];
  let n = 0;
  globalThis.fetch = (async (url: unknown, init: unknown) => {
    let body: unknown = null;
    try {
      body = JSON.parse((init as { body: string }).body as string);
    } catch {
      /* no body */
    }
    calls.push({ url, body });
    const reply = replies[Math.min(n, replies.length - 1)];
    n++;
    return { json: async () => reply };
  }) as typeof fetch;
  return calls;
}

function mount(node: React.ReactNode) {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  act(() => {
    root.render(<MantineProvider theme={theme}>{node}</MantineProvider>);
  });
  return {
    host,
    unmount: () => {
      act(() => root.unmount());
      host.remove();
    },
  };
}

async function settle() {
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
}

function click(el: Element | null | undefined) {
  if (!el) throw new Error("element not found");
  act(() => {
    el.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  });
}

function buttonWithText(host: HTMLElement, text: string): HTMLButtonElement | null {
  return (
    ([...host.querySelectorAll("button")].find((b) => b.textContent?.trim() === text) as
      | HTMLButtonElement
      | undefined) ?? null
  );
}

// Mantine's Radio/Checkbox render the <input> as a PRECEDING sibling of the
// <label>, linked only by id/for — never nested inside it.
function inputForLabel(host: HTMLElement, label: string): HTMLInputElement | null {
  const el = [...host.querySelectorAll("label")].find((l) => l.textContent?.trim() === label);
  const forId = el?.getAttribute("for");
  if (!forId) return null;
  return host.querySelector(`#${CSS.escape(forId)}`) as HTMLInputElement | null;
}

function radioLabeled(host: HTMLElement, label: string): HTMLInputElement | null {
  return inputForLabel(host, label);
}

function checkboxLabeled(host: HTMLElement, label: string): HTMLInputElement | null {
  return inputForLabel(host, label);
}

describe("FormCard", () => {
  test("Submit is disabled until every question is answered", async () => {
    stubFetch();
    const m = mount(
      <FormCard paneId="w8:p1" form={form()} screenQuestion={screenQuestion()} onToast={() => {}} />,
    );
    const submit = buttonWithText(m.host, "Submit")!;
    expect(submit.disabled).toBe(true);
    click(radioLabeled(m.host, "Rewrite"));
    await settle();
    expect(buttonWithText(m.host, "Submit")!.disabled).toBe(false);
    m.unmount();
  });

  test("single-question submit posts /api/answer with the SCREEN-parsed question, not the transcript copy", async () => {
    const calls = stubFetch({ ok: true });
    const m = mount(
      <FormCard paneId="w8:p1" form={form()} screenQuestion={screenQuestion()} onToast={() => {}} />,
    );
    click(radioLabeled(m.host, "Patch"));
    await settle();
    click(buttonWithText(m.host, "Submit"));
    await settle();
    const post = calls.find((c) => c.url === "/api/answer");
    expect(post).toBeDefined();
    const body = post!.body as {
      paneId: string;
      choice: { type: string; indices?: number[] };
      question: { title: string; question: string };
    };
    expect(body.paneId).toBe("w8:p1");
    expect(body.choice.type).toBe("select");
    expect(body.choice.indices).toEqual([2]); // "Patch" is option 2
    // Posted title/question is the screen-parsed copy (matches what the
    // server's fresh re-read will see) — same object, not rebuilt from
    // form.questions[i].header/question (the transcript's raw copy, which
    // `answer_pane_question`'s exact-match gate never reliably accepts).
    expect(body.question.title).toBe("Approach");
    expect(body.question.question).toBe("Which approach should I take?");
    m.unmount();
  });

  test("real screen parse (single-select adds a trailing 'Type something' row the transcript never has): submit still succeeds", async () => {
    // classify_pane.parse_question_block always appends a free-text "Type
    // something" row after a single-select's real options — the transcript
    // form's options (built from the raw AskUserQuestion tool input) never
    // include it. A structural check that demanded equal option COUNTS
    // between the two refused every single-select submit in production
    // (caught by hand-tracing the parser's own fixtures, not by this
    // file's other screenQuestion() helpers, which omit the row).
    const withOtherRow: PickerQuestion = {
      ...screenQuestion(),
      options: [
        ...screenQuestion().options,
        { index: 3, label: "Type something.", checked: false, other: true },
      ],
      otherIndex: 3,
    };
    const calls = stubFetch({ ok: true });
    const m = mount(
      <FormCard paneId="w8:p1" form={form()} screenQuestion={withOtherRow} onToast={() => {}} />,
    );
    click(radioLabeled(m.host, "Patch"));
    await settle();
    click(buttonWithText(m.host, "Submit"));
    await settle();
    const post = calls.find((c) => c.url === "/api/answer");
    expect(post).toBeDefined();
    const body = post!.body as { choice: { type: string; indices?: number[] } };
    expect(body.choice.type).toBe("select");
    expect(body.choice.indices).toEqual([2]); // "Patch" is screen index 2
    expect(m.host.textContent).not.toContain("changed or gone");
    m.unmount();
  });

  test("no screenQuestion yet: Submit refuses instead of posting the transcript copy", async () => {
    const calls = stubFetch({ ok: true });
    const m = mount(
      <FormCard paneId="w8:p1" form={form()} screenQuestion={null} onToast={() => {}} />,
    );
    click(radioLabeled(m.host, "Patch"));
    await settle();
    click(buttonWithText(m.host, "Submit"));
    await settle();
    expect(calls.find((c) => c.url === "/api/answer")).toBeUndefined();
    expect(m.host.textContent).toContain("hasn't loaded yet");
    m.unmount();
  });

  test("typed Other text replaces the option pick for that question", async () => {
    const calls = stubFetch({ ok: true });
    const m = mount(
      <FormCard paneId="w8:p1" form={form()} screenQuestion={screenQuestion()} onToast={() => {}} />,
    );
    const other = m.host.querySelector('input[placeholder^="type free text"]') as HTMLInputElement;
    act(() => {
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
      setter.call(other, "do neither, ask the user first");
      other.dispatchEvent(new Event("input", { bubbles: true }));
    });
    await settle();
    click(buttonWithText(m.host, "Submit"));
    await settle();
    const post = calls.find((c) => c.url === "/api/answer");
    const body = post!.body as { choice: { type: string; value?: string } };
    expect(body.choice.type).toBe("text");
    expect(body.choice.value).toBe("do neither, ask the user first");
    m.unmount();
  });

  test("multi-select checkboxes answer one question, submitting sends each question in order using the server's returned `next` question", async () => {
    // First /api/answer lands and hands back Q2's screen-parsed question
    // (same shape `_settle_after_submit` returns) — the second POST must
    // use THAT, not a second copy built from the transcript.
    const calls = stubFetchSequence([{ ok: true, next: multiScreenQuestion2() }, { ok: true }]);
    const m = mount(
      <FormCard
        paneId="w8:p1"
        form={multiQuestionForm()}
        screenQuestion={multiScreenQuestion()}
        onToast={() => {}}
      />,
    );
    click(checkboxLabeled(m.host, "a.ts"));
    click(checkboxLabeled(m.host, "c.ts"));
    click(radioLabeled(m.host, "Yes"));
    await settle();
    click(buttonWithText(m.host, "Submit"));
    await settle();
    const posts = calls.filter((c) => c.url === "/api/answer");
    expect(posts.length).toBe(2);
    const first = posts[0].body as {
      choice: { indices: number[] };
      question: { title: string; question: string };
    };
    expect(first.choice.indices).toEqual([1, 3]); // a.ts, c.ts
    expect(first.question.question).toBe("Which files should change?");
    const second = posts[1].body as {
      choice: { indices: number[] };
      question: { title: string; question: string };
    };
    expect(second.choice.indices).toEqual([1]); // Yes
    // The second question posted is Q2's SCREEN-parsed copy (from `next`),
    // proving the loop advanced with the server's fresh question rather
    // than falling back to the transcript's title/question for it.
    expect(second.question.title).toBe("Ship now?");
    expect(second.question.question).toBe("Ship now?");
    m.unmount();
  });

  test("screenQuestion belongs to a different tab than form.questions[0]: refuses instead of mis-answering", async () => {
    // The terminal already moved past this tab (answered directly, or a
    // stale form) — the sweep's screenQuestion is some OTHER open tab, one
    // that happens to have a different option count/mode than
    // form.questions[0]. Sending indices built from form.questions[0].options
    // against it would silently target the wrong options on the wrong tab.
    const calls = stubFetch({ ok: true });
    const otherTab: PickerQuestion = {
      title: "Ship now?",
      question: "Ship now?",
      multi: false,
      options: [
        { index: 1, label: "Yes", checked: false, other: false },
        { index: 2, label: "No", checked: false, other: false },
      ],
      cursorIndex: 1,
      otherIndex: null,
      hasSubmit: false,
    };
    const m = mount(
      <FormCard
        paneId="w8:p1"
        form={multiQuestionForm()} // questions[0] is multi-select, 3 options
        screenQuestion={otherTab} // single-select, 2 options — shape mismatch
        onToast={() => {}}
      />,
    );
    click(checkboxLabeled(m.host, "a.ts"));
    click(radioLabeled(m.host, "Yes"));
    await settle();
    click(buttonWithText(m.host, "Submit"));
    await settle();
    expect(calls.find((c) => c.url === "/api/answer")).toBeUndefined();
    expect(m.host.textContent).toContain("question changed or gone");
    m.unmount();
  });

  test("a refusal on any question stops the batch and reports it", async () => {
    stubFetch({ ok: false, error: "question changed or gone — re-check the pane" });
    const m = mount(
      <FormCard paneId="w8:p1" form={form()} screenQuestion={screenQuestion()} onToast={() => {}} />,
    );
    click(radioLabeled(m.host, "Rewrite"));
    await settle();
    click(buttonWithText(m.host, "Submit"));
    await settle();
    expect(m.host.textContent).toContain("question changed or gone");
    m.unmount();
  });

  // Threat model: each button types into a real terminal. Two clicks
  // dispatched in the same event-loop turn (a fast real-world double tap)
  // land before React re-renders the button as disabled, so `sending`
  // state alone does not stop a second, duplicate /api/answer POST.
  test("a same-tick double tap on Submit sends only one round of answers", async () => {
    const calls = stubFetch({ ok: true });
    const m = mount(
      <FormCard paneId="w8:p1" form={form()} screenQuestion={screenQuestion()} onToast={() => {}} />,
    );
    click(radioLabeled(m.host, "Rewrite"));
    await settle();
    const submit = buttonWithText(m.host, "Submit")!;
    act(() => {
      submit.dispatchEvent(new MouseEvent("click", { bubbles: true }));
      submit.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    await settle();
    const posts = calls.filter((c) => c.url === "/api/answer");
    expect(posts.length).toBe(1);
    m.unmount();
  });
});
