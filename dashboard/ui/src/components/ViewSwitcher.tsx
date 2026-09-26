import { useState } from "react";
import {
  Button,
  Group,
  Modal,
  SegmentedControl,
  Stack,
  Tabs,
  Text,
  TextInput,
} from "@mantine/core";
import type { BoardView } from "../types";

/** View tabs + layout toggle + view actions on Mantine chrome. Same
 *  behaviour: selecting persists the last-opened view id, layout PATCHes
 *  the view, duplicate copies columns/sort/filters/groupBy. */
export function ViewSwitcher({
  views,
  active,
  onSelect,
  onNew,
  onRename,
  onDuplicate,
  onDelete,
  onLayout,
}: {
  views: BoardView[];
  active: BoardView | null;
  onSelect: (id: string) => void;
  onNew: (name: string) => void;
  onRename: (name: string) => void;
  onDuplicate: () => void;
  onDelete: () => void;
  onLayout: (layout: "table" | "kanban") => void;
}) {
  const [newOpen, setNewOpen] = useState(false);
  const [newName, setNewName] = useState("");
  const [renameOpen, setRenameOpen] = useState(false);
  const [renameName, setRenameName] = useState("");
  const [deleteOpen, setDeleteOpen] = useState(false);

  const submitNew = () => {
    const clean = newName.trim();
    if (!clean) return;
    setNewName("");
    setNewOpen(false);
    onNew(clean);
  };

  const submitRename = () => {
    const clean = renameName.trim();
    setRenameOpen(false);
    if (clean && active && clean !== active.name) onRename(clean);
  };

  return (
    <div className="viewbar">
      <Tabs
        value={active?.id ?? null}
        onChange={(v) => v && onSelect(v)}
      >
        <Group justify="space-between" align="center" wrap="nowrap">
          <Tabs.List>
            {views.map((v) => (
              <Tabs.Tab key={v.id} value={v.id}>
                {v.name}
              </Tabs.Tab>
            ))}
          </Tabs.List>
          <Button
            variant="outline"
            size="xs"
            color="green"
            onClick={() => setNewOpen(true)}
            title="New view"
          >
            + New view
          </Button>
        </Group>
      </Tabs>
      {active && (
        <Group gap="xs" align="center">
          <SegmentedControl
            size="xs"
            aria-label="Layout"
            value={active.layout}
            onChange={(v) => onLayout(v as "table" | "kanban")}
            data={[
              { value: "table", label: "Table" },
              { value: "kanban", label: "Kanban" },
            ]}
          />
          <Button
            variant="subtle"
            size="xs"
            onClick={() => {
              setRenameName(active.name);
              setRenameOpen(true);
            }}
          >
            Rename
          </Button>
          <Button variant="subtle" size="xs" onClick={onDuplicate}>
            Duplicate
          </Button>
          <Button
            variant="subtle"
            size="xs"
            color="red"
            onClick={() => setDeleteOpen(true)}
          >
            Delete
          </Button>
        </Group>
      )}
      <Modal opened={newOpen} onClose={() => setNewOpen(false)} title="New view" centered>
        <Stack gap="sm">
          <TextInput
            label="View name"
            value={newName}
            onChange={(e) => setNewName(e.currentTarget.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") submitNew();
            }}
          />
          <Group justify="flex-end">
            <Button variant="subtle" onClick={() => setNewOpen(false)}>
              Cancel
            </Button>
            <Button onClick={submitNew} disabled={!newName.trim()}>
              Create view
            </Button>
          </Group>
        </Stack>
      </Modal>
      <Modal opened={renameOpen} onClose={() => setRenameOpen(false)} title="Rename view" centered>
        <Stack gap="sm">
          <TextInput
            label="View name"
            value={renameName}
            onChange={(e) => setRenameName(e.currentTarget.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") submitRename();
            }}
          />
          <Group justify="flex-end">
            <Button variant="subtle" onClick={() => setRenameOpen(false)}>
              Cancel
            </Button>
            <Button onClick={submitRename}>Rename</Button>
          </Group>
        </Stack>
      </Modal>
      <Modal opened={deleteOpen} onClose={() => setDeleteOpen(false)} title={`Delete view ${active?.name}?`} centered>
        <Stack gap="sm">
          <Text size="sm">The view is removed; columns and values stay.</Text>
          <Group justify="flex-end">
            <Button variant="subtle" onClick={() => setDeleteOpen(false)}>
              Keep
            </Button>
            <Button
              color="red"
              onClick={() => {
                setDeleteOpen(false);
                onDelete();
              }}
            >
              Delete view
            </Button>
          </Group>
        </Stack>
      </Modal>
    </div>
  );
}
