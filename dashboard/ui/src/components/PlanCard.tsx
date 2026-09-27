import { useEffect, useRef, useState } from "react";
import { Button, Group, Loader, Stack, Text, Textarea } from "@mantine/core";
import type { PermissionOption, PermissionPrompt, SessionPlanResponse } from "../types";
import { answerPermission, fetchSessionPlan } from "../api";
import { Markdown } from "./Markdown";
import { Block } from "./Block";

const PRIVILEGE_RE = /auto mode|auto-accept|bypass permissions/i;

/** A row whose label changes what the agent is allowed to do going forward,
 *  not just this one plan (mirrors PermissionPrompt.isPrivilegeChange). */
export function isPrivilegeChangeLabel(label: string): boolean {
  return PRIVILEGE_RE.test(label.replace(/-/g, " ").replace(/\s+/g, " "));
}

/** The feedback row ("Tell Claude what to change") — only this row accepts
 *  typed text; the server refuses `text` on any other option (mirrors
 *  AgentBar's `feedbackOption`: first row starting "Tell Claude", else the
 *  last row unless it reads "Yes"). */
export function feedbackOption(options: PermissionOption[]): PermissionOption | null {
  const tellClaude = options.find((o) => o.label.startsWith("Tell Claude"));
  if (tellClaude) return tellClaude;
  const last = options.length ? options[options.length - 1] : null;
  return last && !last.label.startsWith("Yes") ? last : null;
}

/** Plan card: the plan file rendered as markdown, plus the box's own rows
 *  verbatim (no allow/deny by wording — a plan box offers none, see
 *  Sources/AgentBar/AGENTS.md gotcha 13). A privilege-change row (auto
 *  mode / bypass permissions) needs a second press; the feedback row opens
 *  a text field instead of sending immediately. */
export function PlanCard({
  rowId,
  paneId,
  permission,
  onToast,
  phone,
}: {
  rowId: string;
  paneId: string;
  permission: PermissionPrompt;
  onToast: (msg: string, ok: boolean) => void;
  phone?: boolean;
}) {
  const [plan, setPlan] = useState<SessionPlanResponse | null>(null);
  useEffect(() => {
    let dead = false;
    fetchSessionPlan(rowId).then((r) => {
      if (!dead) setPlan(r);
    });
    return () => {
      dead = true;
    };
  }, [rowId]);

  const [armedIndex, setArmedIndex] = useState<number | null>(null);
  const [feedbackMode, setFeedbackMode] = useState(false);
  const [feedbackText, setFeedbackText] = useState("");
  const [sendingIndex, setSendingIndex] = useState<number | null>(null);
  const [result, setResult] = useState<{ ok: boolean; msg: string } | null>(null);
  // Same-tick double-click guard (see ReviewCard) — `sendingIndex` state
  // only disables the button on the NEXT render, so a fast double tap could
  // otherwise fire this privilege-carrying send twice.
  const inFlight = useRef(false);

  const fb = feedbackOption(permission.options);

  const send = async (index: number, text?: string) => {
    if (inFlight.current) return;
    inFlight.current = true;
    setSendingIndex(index);
    const res = await answerPermission(paneId, "select", permission, {
      index,
      ...(text ? { text } : {}),
    });
    inFlight.current = false;
    setSendingIndex(null);
    if (res.ok) {
      setResult({ ok: true, msg: "sent" });
      onToast("sent", true);
    } else {
      setResult({ ok: false, msg: res.error || "unknown error" });
      onToast("not sent: " + (res.error || "?"), false);
    }
  };

  const pressRow = (opt: PermissionOption) => {
    if (fb && opt.index === fb.index) {
      setFeedbackMode(true);
      return;
    }
    if (isPrivilegeChangeLabel(opt.label) && armedIndex !== opt.index) {
      setArmedIndex(opt.index);
      return;
    }
    setArmedIndex(null);
    void send(opt.index);
  };

  return (
    <Block phone={phone} className="plan-card">
      <Text size="xs" c="dimmed" mb={4}>
        Plan
      </Text>
      {plan === null && <Loader size="xs" />}
      {plan && !plan.ok && (
        <Text size="xs" c="dimmed">
          {plan.error || "plan could not be read"}
        </Text>
      )}
      {plan?.ok && plan.plan?.status === "text" && plan.plan.text && (
        <div className="plan-body">
          <Markdown text={plan.plan.text} />
          {plan.plan.truncated && (
            <Text size="xs" c="dimmed">
              plan file is longer than 200 KB — showing the first part
            </Text>
          )}
        </div>
      )}
      {plan?.ok && plan.plan?.status === "noPath" && (
        <Text size="xs" c="dimmed">
          this plan box names no file
        </Text>
      )}
      {plan?.ok && plan.plan?.status === "unreadable" && (
        <Text size="xs" c="dimmed">
          {plan.plan.reason || "plan file could not be read"}
        </Text>
      )}
      <Stack gap="xs" mt="sm">
        {!feedbackMode &&
          permission.options.map((opt) => (
            <Button
              key={opt.index}
              variant={armedIndex === opt.index ? "filled" : "light"}
              color={armedIndex === opt.index ? "orange" : undefined}
              loading={sendingIndex === opt.index}
              onClick={() => pressRow(opt)}
            >
              {armedIndex === opt.index ? "Press again to confirm" : opt.label}
            </Button>
          ))}
        {feedbackMode && fb && (
          <>
            <Textarea
              placeholder="tell Claude what to change"
              value={feedbackText}
              onChange={(e) => setFeedbackText(e.currentTarget.value)}
              minRows={2}
            />
            <Group gap="sm">
              <Button
                variant="subtle"
                onClick={() => {
                  setFeedbackMode(false);
                  setFeedbackText("");
                }}
              >
                Back
              </Button>
              <Button
                color="blue"
                disabled={!feedbackText.trim()}
                loading={sendingIndex === fb.index}
                onClick={() => void send(fb.index, feedbackText.trim())}
              >
                Send feedback
              </Button>
            </Group>
          </>
        )}
      </Stack>
      {result && (
        <Text size="xs" c={result.ok ? "dimmed" : "red"} mt="xs">
          {result.ok ? "Sent." : `Not sent: ${result.msg}`}
        </Text>
      )}
    </Block>
  );
}
