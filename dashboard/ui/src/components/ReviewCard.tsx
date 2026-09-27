import { useRef, useState } from "react";
import { Button, Group, Text } from "@mantine/core";
import type { PermissionOption, PermissionPrompt } from "../types";
import { answerPermission } from "../api";
import { Block } from "./Block";
import { MarkdownInline } from "./Markdown";

type Choice = "allow" | "deny" | "allow-always";

/** A "Yes" row that grants more than this one call — the dashboard's own two
 *  phrasings (server contract; mirrors PermissionPrompt.swift's `isAlways`). */
export function isAlwaysLabel(label: string): boolean {
  return label.includes("don't ask again") || label.includes("for this session");
}

/** Which of Allow/Allow always/Deny this box actually offers, read the same
 *  way the server itself will pick them — allow is the first "Yes" row (not
 *  an always-row), deny the last "No" row, allow-always the "Yes" row that
 *  also grants for good. Never guessed: an absent row means no button. */
export function reviewChoices(p: PermissionPrompt): {
  allow: PermissionOption | null;
  allowAlways: PermissionOption | null;
  deny: PermissionOption | null;
} {
  const first = p.options[0] ?? null;
  const last = p.options.length ? p.options[p.options.length - 1] : null;
  const allow = first && first.label.startsWith("Yes") && !isAlwaysLabel(first.label) ? first : null;
  const allowAlways = p.options.find((o) => o.label.startsWith("Yes") && isAlwaysLabel(o.label)) ?? null;
  const deny = last && last.label.startsWith("No") ? last : null;
  return { allow, allowAlways, deny };
}

/** Review card: Allow / Allow always (only when the box actually offers it,
 *  second press to confirm) / Deny — for a row blocked on a plain tool
 *  permission box (`PermissionPrompt.kind !== "plan"`; plan boxes use
 *  `PlanCard` instead, since they offer no allow/deny choice by wording). */
export function ReviewCard({
  paneId,
  permission,
  onToast,
  phone,
}: {
  paneId: string;
  permission: PermissionPrompt;
  onToast: (msg: string, ok: boolean) => void;
  phone?: boolean;
}) {
  const { allow, allowAlways, deny } = reviewChoices(permission);
  const [armed, setArmed] = useState(false);
  const [sending, setSending] = useState<Choice | null>(null);
  const [result, setResult] = useState<{ ok: boolean; msg: string } | null>(null);
  // Guards a same-tick double click: `sending` state alone updates only on
  // the next render, so two clicks dispatched before that commit would
  // otherwise both pass and fire two POSTs (proven in a test — Mantine's
  // `loading`-driven `disabled` isn't up yet for the second one).
  const inFlight = useRef(false);

  const send = async (choice: Choice) => {
    if (inFlight.current) return;
    if (choice === "allow-always" && !armed) {
      setArmed(true);
      return;
    }
    inFlight.current = true;
    setArmed(false);
    setSending(choice);
    const res = await answerPermission(paneId, choice, permission);
    inFlight.current = false;
    setSending(null);
    if (res.ok) {
      setResult({ ok: true, msg: "sent" });
      onToast(choice === "deny" ? "denied" : "approved", true);
    } else {
      setResult({ ok: false, msg: res.error || "unknown error" });
      onToast("not sent: " + (res.error || "?"), false);
    }
  };

  return (
    <Block phone={phone} className="review-card">
      <Text size="xs" c="dimmed" mb={4}>
        {permission.tool}
      </Text>
      <Text mb="xs" style={{ whiteSpace: "pre-wrap" }}>
        <MarkdownInline text={permission.detail || permission.title} />
      </Text>
      <Group gap="sm">
        {allow && (
          <Button color="green" loading={sending === "allow"} onClick={() => void send("allow")}>
            Allow
          </Button>
        )}
        {allowAlways && (
          <Button
            color="teal"
            variant={armed ? "filled" : "light"}
            loading={sending === "allow-always"}
            onClick={() => void send("allow-always")}
          >
            {armed ? "Confirm always allow" : "Allow always"}
          </Button>
        )}
        {deny && (
          <Button color="red" variant="outline" loading={sending === "deny"} onClick={() => void send("deny")}>
            Deny
          </Button>
        )}
      </Group>
      {result && (
        <Text size="xs" c={result.ok ? "dimmed" : "red"} mt="xs">
          {result.ok ? "Sent." : `Not sent: ${result.msg}`}
        </Text>
      )}
    </Block>
  );
}
