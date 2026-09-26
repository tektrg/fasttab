import { useEffect, useRef, useState } from "react";
import { Button, Menu, Modal, Text } from "@mantine/core";
import type { BoardRow } from "../types";
import { focusPane } from "../api";
import { Composer } from "./Composer";
import {
  resolveEndStage,
  rowActions,
  rowLabel,
  sessionAction,
  type SessionActionName,
} from "../sessionActions";

/** Card menu entries: the unified End option (Stop agent → Close pane)
 *  plus Relaunch. Archive/unarchive render as one toggle row: whichever
 *  the server offers. */
const MENU_ORDER: SessionActionName[] = [
  "relaunch",
  "archive",
  "unarchive",
];
const MENU_LABEL: Record<SessionActionName, string> = {
  stop: "Stop agent",
  close: "Close pane",
  relaunch: "Relaunch here",
  archive: "Archive (hide, frees nothing)",
  unarchive: "Unarchive (restore)",
};

/** The ladder + reach menu on a kanban card: server-resolved ladder entries
 *  below, reach items (Open pane / Send message) above, separated. Same
 *  confirm rule — idle acts on one click; anything else arms to Confirm
 *  with the reason and reverts after ~5s. A drag may archive; a drag may
 *  never stop or close (see resolveKanbanDrop) — this menu is the only
 *  destructive path on a card, and the only path to message. */
export function CardMenu({
  row,
  onToast,
  onDone,
}: {
  row: BoardRow;
  onToast: (msg: string, ok: boolean) => void;
  onDone: () => void;
}) {
  const actions = rowActions(row);
  const [opened, setOpened] = useState(false);
  const [armed, setArmed] = useState<SessionActionName | "end" | null>(null);
  const [busy, setBusy] = useState(false);
  const [composeOpen, setComposeOpen] = useState(false);
  const timer = useRef<number | null>(null);

  useEffect(
    () => () => {
      if (timer.current) window.clearTimeout(timer.current);
    },
    [],
  );
  useEffect(() => {
    if (!opened) setArmed(null);
  }, [opened]);
  useEffect(() => {
    setArmed(null);
  }, [row.rowId, row.status]);

  if (!actions) return null;
  // Reach items render from server-provided facts (live row? pane id?),
  // never from a client-side safety verdict — the endpoints refuse loudly
  // when wrong (gone pane, dev pane, picker open).
  const live = row.status !== "ended";
  const paneId = row.derived.paneId;
  const entries = MENU_ORDER.filter((n) => {    const st = actions[n];
    if (!st) return false;
    // Toggle pair: show whichever the server offers.
    if ((n === "archive" || n === "unarchive") && !st.enabled) return false;
    if (n === "relaunch" && !st.enabled) return false;
    return true;
  });
  if (entries.length === 0 && !resolveEndStage(actions ?? undefined) && !paneId && !live) return null;

  const disarm = () => {
    if (timer.current) window.clearTimeout(timer.current);
    timer.current = null;
    setArmed(null);
  };
  const arm = (name: SessionActionName | "end") => {
    if (timer.current) window.clearTimeout(timer.current);
    setArmed(name);
    timer.current = window.setTimeout(disarm, 5000);
  };

  const clickOpen = async () => {
    const paneId = row.derived.paneId;
    if (!paneId || busy) return;
    setBusy(true);
    const res = await focusPane(paneId);
    setBusy(false);
    onToast(
      res.ok ? `focused: ${rowLabel(row)}` : `focus failed: ${res.error || "?"}`,
      !!res.ok,
    );
    if (res.ok) setOpened(false);
  };

  // (live/paneId are defined above, next to the ladder entries.)

  /** The unified two-stage End option: stage 1 stops the agent, and once
   *  stopped the same entry becomes stage 2 closing the pane. The POST
   *  still hits the matching /api/session/{stop,close}. */
  const endStage = resolveEndStage(actions ?? undefined);

  const clickEnd = async () => {
    if (!endStage || busy) {
      if (endStage && !endStage.state.enabled)
        onToast(endStage.state.reason || "refused", false);
      return;
    }
    const { verb, state: st, label } = endStage;
    if (st.needsConfirm && armed !== "end") {
      arm("end");
      return;
    }
    disarm();
    setBusy(true);
    const res = await sessionAction(verb, row.rowId, {
      confirm: st.needsConfirm,
    });
    setBusy(false);
    if (res.ok) {
      onToast(`${label}: ${res.state ?? "done"}`, true);
      setOpened(false);
      onDone();
    } else if (res.needsConfirm && res.reason) {
      arm("end");
      onToast(res.reason, false);
    } else {
      onToast(`${label} refused: ${res.error || res.reason || "?"}`, false);
    }
  };

  const click = async (name: SessionActionName) => {
    const st = actions[name];
    if (!st || !st.enabled || busy) {
      if (st && !st.enabled) onToast(st.reason || "refused", false);
      return;
    }
    if (st.needsConfirm && armed !== name) {
      arm(name);
      return;
    }
    disarm();
    setBusy(true);
    const res = await sessionAction(name, row.rowId, {
      confirm: st.needsConfirm,
    });
    setBusy(false);
    if (res.ok) {
      onToast(`${MENU_LABEL[name]}: ${res.state ?? "done"}`, true);
      setOpened(false);
      onDone();
    } else if (res.needsConfirm && res.reason) {
      arm(name);
      onToast(res.reason, false);
    } else {
      onToast(`${MENU_LABEL[name]} refused: ${res.error || res.reason || "?"}`, false);
    }
  };

  return (
    <>
      <Menu
        opened={opened}
        onChange={setOpened}
        position="bottom-end"
        closeOnItemClick={false}
      >
      <Menu.Target>
        {/* stopPropagation twice: the click must not focus the pane, and the
            pointer-down must not start a card drag. */}
        <Button
          variant="subtle"
          size="compact-xs"
          title={`Actions for ${rowLabel(row)}`}
          onClick={(e) => e.stopPropagation()}
          onPointerDown={(e) => e.stopPropagation()}
        >
          ⋯
        </Button>
      </Menu.Target>
      <Menu.Dropdown onClick={(e) => e.stopPropagation()}>
        <Menu.Label>{rowLabel(row)}</Menu.Label>
        {paneId && (
          <Menu.Item
            disabled={busy}
            title="move terminal focus here — sends no keystrokes"
            onClick={(e) => {
              e.stopPropagation();
              void clickOpen();
            }}
          >
            Open pane
          </Menu.Item>
        )}
        {live && (
          <Menu.Item
            disabled={busy}
            title="write to this pane — opens the one-line composer"
            onClick={(e) => {
              e.stopPropagation();
              setOpened(false);
              setComposeOpen(true);
            }}
          >
            Send message…
          </Menu.Item>
        )}
        {(paneId || live) && (endStage || entries.length > 0) && <Menu.Divider />}
        {endStage && (
          <Menu.Item
            color={endStage.verb === "stop" ? "red" : undefined}
            disabled={!endStage.state.enabled || busy}
            title={endStage.state.reason}
            onClick={(e) => {
              e.stopPropagation();
              void clickEnd();
            }}
          >
            {armed === "end" ? `Confirm — ${endStage.state.reason}` : endStage.label}
          </Menu.Item>
        )}
        {entries.map((name) => {
          const st = actions[name]!;
          const isArmed = armed === name;
          return (
            <Menu.Item
              key={name}
              color={name === "stop" ? "red" : undefined}
              disabled={!st.enabled || busy}
              title={st.reason}
              onClick={(e) => {
                e.stopPropagation();
                void click(name);
              }}
            >
              {isArmed ? `Confirm — ${st.reason}` : MENU_LABEL[name]}
            </Menu.Item>
          );
        })}
        {armed === "end"
          ? (endStage && (
            <Text size="xs" c="dimmed" px="sm" py={4} style={{ maxWidth: 260 }}>
              {endStage.state.reason} — reverts in ~5s
            </Text>
          ))
          : (armed &&
            actions[armed as SessionActionName] && (
            <Text size="xs" c="dimmed" px="sm" py={4} style={{ maxWidth: 260 }}>
              {actions[armed as SessionActionName]!.reason} — reverts in ~5s
            </Text>
          ))}
      </Menu.Dropdown>
      </Menu>
      <Modal
        opened={composeOpen}
        onClose={() => setComposeOpen(false)}
        title={`Send message to ${rowLabel(row)}`}
        size="lg"
      >
        <Composer rows={[row]} onToast={onToast} onDone={onDone} />
      </Modal>
    </>
  );
}
