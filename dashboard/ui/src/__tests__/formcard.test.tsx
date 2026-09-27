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
import type { PendingQuestionForm } from "../types";

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
    const m = mount(<FormCard paneId="w8:p1" form={form()} onToast={() => {}} />);
    const submit = buttonWithText(m.host, "Submit")!;
    expect(submit.disabled).toBe(true);
    click(radioLabeled(m.host, "Rewrite"));
    await settle();
    expect(buttonWithText(m.host, "Submit")!.disabled).toBe(false);
    m.unmount();
  });

  test("single-question submit posts /api/answer with the question shape", async () => {
    const calls = stubFetch({ ok: true });
    const m = mount(<FormCard paneId="w8:p1" form={form()} onToast={() => {}} />);
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
    expect(body.question.question).toBe("Which approach should I take?");
    m.unmount();
  });

  test("typed Other text replaces the option pick for that question", async () => {
    const calls = stubFetch({ ok: true });
    const m = mount(<FormCard paneId="w8:p1" form={form()} onToast={() => {}} />);
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

  test("multi-select checkboxes answer one question, submitting sends each question in order", async () => {
    const calls = stubFetch({ ok: true });
    const m = mount(<FormCard paneId="w8:p1" form={multiQuestionForm()} onToast={() => {}} />);
    click(checkboxLabeled(m.host, "a.ts"));
    click(checkboxLabeled(m.host, "c.ts"));
    click(radioLabeled(m.host, "Yes"));
    await settle();
    click(buttonWithText(m.host, "Submit"));
    await settle();
    const posts = calls.filter((c) => c.url === "/api/answer");
    expect(posts.length).toBe(2);
    const first = posts[0].body as { choice: { indices: number[] } };
    expect(first.choice.indices).toEqual([1, 3]); // a.ts, c.ts
    const second = posts[1].body as { choice: { indices: number[] } };
    expect(second.choice.indices).toEqual([1]); // Yes
    m.unmount();
  });

  test("a refusal on any question stops the batch and reports it", async () => {
    stubFetch({ ok: false, error: "question changed or gone — re-check the pane" });
    const m = mount(<FormCard paneId="w8:p1" form={form()} onToast={() => {}} />);
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
    const m = mount(<FormCard paneId="w8:p1" form={form()} onToast={() => {}} />);
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
