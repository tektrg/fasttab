import { useState } from "react";
import {
  Button,
  Group,
  Menu,
  Modal,
  Select,
  Stack,
  Text,
  TextInput,
} from "@mantine/core";
import type { BoardProperty, PropertyOption, PropertyType } from "../types";
import { createProperty, deleteProperty, updateProperty } from "../api";

const COLUMN_TYPES: PropertyType[] = [
  "text",
  "select",
  "multi_select",
  "number",
  "checkbox",
  "date",
];

/** Shared column-management dialogs + menus. Every previously hand-rolled
 *  `<details>`/`<summary>` disclosure and `window.prompt` chain lives here
 *  now as a real floating Mantine Menu / Modal (Escape + click-outside work,
 *  nothing expands inline and shoves the header taller). */

export function mergeOptionNames(
  propertyOptions: PropertyOption[],
  input: string,
): PropertyOption[] {
  const byName = new Map(
    propertyOptions.map((option) => [option.name.toLowerCase(), option]),
  );
  return input
    .split(",")
    .map((name) => {
      const clean = name.trim();
      const existing = byName.get(clean.toLowerCase());
      return (
        existing ?? { id: crypto.randomUUID(), name: clean, color: "gray" }
      );
    })
    .filter((option) => option.name);
}

export function AddColumnModal({
  opened,
  rowKind,
  onClose,
  onToast,
  onCreated,
}: {
  opened: boolean;
  rowKind?: string;
  onClose: () => void;
  onToast: (msg: string, ok: boolean) => void;
  onCreated?: () => void;
}) {
  const [name, setName] = useState("");
  const [type, setType] = useState<PropertyType>("text");
  const [optionsText, setOptionsText] = useState("todo, doing, done");
  const [saving, setSaving] = useState(false);

  const close = () => {
    if (!saving) {
      setName("");
      setType("text");
      setOptionsText("todo, doing, done");
      onClose();
    }
  };

  const save = async () => {
    const clean = name.trim();
    if (!clean) {
      onToast("column needs a name", false);
      return;
    }
    setSaving(true);
    const options =
      type === "select" || type === "multi_select"
        ? optionsText
            .split(",")
            .map((s) => ({ name: s.trim(), color: "gray" as const }))
            .filter((o) => o.name)
        : [];
    const res = await createProperty({ name: clean, type, options, rowKind });
    setSaving(false);
    if (!res.ok) {
      onToast(`column failed: ${res.error || "?"}`, false);
      return;
    }
    onToast(`column created: ${clean}`, true);
    setName("");
    setType("text");
    setOptionsText("todo, doing, done");
    onClose();
    onCreated?.();
  };

  return (
    <Modal opened={opened} onClose={close} title="New column" centered>
      <Stack gap="sm">
        <TextInput
          label="Name"
          placeholder="e.g. Dev status or Owner"
          value={name}
          onChange={(e) => setName(e.currentTarget.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") void save();
          }}
        />
        <Select
          label="Type"
          value={type}
          onChange={(v) => v && setType(v as PropertyType)}
          data={COLUMN_TYPES}
        />
        {(type === "select" || type === "multi_select") && (
          <TextInput
            label="Options"
            description="Comma separated"
            value={optionsText}
            onChange={(e) => setOptionsText(e.currentTarget.value)}
          />
        )}
        <Group justify="flex-end">
          <Button variant="subtle" onClick={close}>
            Cancel
          </Button>
          <Button onClick={() => void save()} loading={saving}>
            Create column
          </Button>
        </Group>
      </Stack>
    </Modal>
  );
}

export function RenameColumnModal({
  prop,
  opened,
  onClose,
  onToast,
}: {
  prop: BoardProperty;
  opened: boolean;
  onClose: () => void;
  onToast: (msg: string, ok: boolean) => void;
}) {
  const [name, setName] = useState(prop.name);
  const [saving, setSaving] = useState(false);

  const save = async () => {
    const clean = name.trim();
    if (!clean || clean === prop.name) {
      onClose();
      return;
    }
    setSaving(true);
    const res = await updateProperty(prop.id, { name: clean });
    setSaving(false);
    onToast(
      res.ok ? "column renamed" : `rename failed: ${res.error || "?"}`,
      res.ok,
    );
    onClose();
  };

  return (
    <Modal
      opened={opened}
      onClose={onClose}
      title={`Rename ${prop.name}`}
      centered
    >
      <Stack gap="sm">
        <TextInput
          label="Column name"
          value={name}
          onChange={(e) => setName(e.currentTarget.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") void save();
            if (e.key === "Escape") onClose();
          }}
        />
        <Group justify="flex-end">
          <Button variant="subtle" onClick={onClose}>
            Cancel
          </Button>
          <Button onClick={() => void save()} loading={saving}>
            Rename
          </Button>
        </Group>
      </Stack>
    </Modal>
  );
}

export function OptionsModal({
  prop,
  opened,
  onClose,
  onToast,
}: {
  prop: BoardProperty;
  opened: boolean;
  onClose: () => void;
  onToast: (msg: string, ok: boolean) => void;
}) {
  const [text, setText] = useState(prop.options.map((o) => o.name).join(", "));
  const [saving, setSaving] = useState(false);

  const save = async () => {
    setSaving(true);
    const options = mergeOptionNames(prop.options, text);
    const res = await updateProperty(prop.id, { options });
    setSaving(false);
    onToast(
      res.ok ? "options updated" : `options failed: ${res.error || "?"}`,
      res.ok,
    );
    onClose();
  };

  return (
    <Modal
      opened={opened}
      onClose={onClose}
      title={`Options for ${prop.name}`}
      centered
    >
      <Stack gap="sm">
        <TextInput
          label="Options"
          description="Comma separated. Removing an option clears it from cells using it."
          value={text}
          onChange={(e) => setText(e.currentTarget.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") void save();
            if (e.key === "Escape") onClose();
          }}
        />
        <Group justify="flex-end">
          <Button variant="subtle" onClick={onClose}>
            Cancel
          </Button>
          <Button onClick={() => void save()} loading={saving}>
            Save options
          </Button>
        </Group>
      </Stack>
    </Modal>
  );
}

export function DeleteColumnConfirm({
  prop,
  opened,
  onClose,
  onToast,
}: {
  prop: BoardProperty;
  opened: boolean;
  onClose: () => void;
  onToast: (msg: string, ok: boolean) => void;
}) {
  const [deleting, setDeleting] = useState(false);

  const run = async () => {
    setDeleting(true);
    const res = await deleteProperty(prop.id);
    setDeleting(false);
    onToast(
      res.ok ? "column deleted" : `delete failed: ${res.error || "?"}`,
      res.ok,
    );
    onClose();
  };

  return (
    <Modal
      opened={opened}
      onClose={onClose}
      title={`Delete ${prop.name}?`}
      centered
    >
      <Stack gap="sm">
        <Text size="sm">Its values go with it. This cannot be undone.</Text>
        <Group justify="flex-end">
          <Button variant="subtle" onClick={onClose}>
            Keep
          </Button>
          <Button color="red" onClick={() => void run()} loading={deleting}>
            Delete column
          </Button>
        </Group>
      </Stack>
    </Modal>
  );
}

function typeConsequence(to: PropertyType): string {
  if (to === "select" || to === "multi_select") {
    return "Matching values become options (created when absent). A multi-valued cell cannot pick one option for select and is cleared.";
  }
  if (to === "number" || to === "checkbox") {
    return "Values that cannot map to the new type are cleared.";
  }
  return "All values are kept as text.";
}

/** Stored-column type change with migration (same semantics as before: the
 *  modal's Apply/Cancel buttons ARE the confirmation — no window.confirm). */
export function ChangeTypeModal({
  prop,
  opened,
  onClose,
  onToast,
}: {
  prop: BoardProperty;
  opened: boolean;
  onClose: () => void;
  onToast: (msg: string, ok: boolean) => void;
}) {
  const [target, setTarget] = useState<PropertyType>(prop.type);
  const [applying, setApplying] = useState(false);

  const apply = async () => {
    if (target === prop.type) {
      onClose();
      return;
    }
    setApplying(true);
    const res = await updateProperty(prop.id, { type: target });
    setApplying(false);
    if (!res.ok || !res.property) {
      onToast(`type change failed: ${res.error || "?"}`, false);
      onClose();
      return;
    }
    const m = res.property.migration;
    if (m) {
      onToast(
        `type → ${m.to}: ${m.migrated} kept` +
          (m.createdOptions
            ? `, ${m.createdOptions} option${m.createdOptions === 1 ? "" : "s"} created`
            : "") +
          (m.dropped ? `, ${m.dropped} cleared (no mapping)` : ", none cleared"),
        true,
      );
    } else {
      onToast("type changed", true);
    }
    onClose();
  };

  return (
    <Modal
      opened={opened}
      onClose={onClose}
      title={`Change ${prop.name} (${prop.type} → ${target})`}
      centered
    >
      <Stack gap="sm">
        <Select label="New type" value={target} onChange={(v) => v && setTarget(v as PropertyType)} data={COLUMN_TYPES} />
        <Text size="sm" c="dimmed">
          {typeConsequence(target)}
        </Text>
        <Group justify="flex-end">
          <Button variant="subtle" onClick={onClose}>
            Cancel
          </Button>
          <Button
            disabled={target === prop.type}
            onClick={() => void apply()}
            loading={applying}
          >
            Apply type change
          </Button>
        </Group>
      </Stack>
    </Modal>
  );
}

/** The floating column menu: one target button, everything else in a real
 *  Menu dropdown (Escape + click-outside close, floats above the header). */
export function ColumnMenuItems({
  prop,
  onRename,
  onEditOptions,
  onChangeType,
  onDelete,
  extra,
}: {
  prop: BoardProperty;
  onRename: () => void;
  onEditOptions: () => void;
  onChangeType: () => void;
  onDelete: () => void;
  extra?: React.ReactNode;
}) {
  return (
    <>
      {extra}
      {prop.editable ? (
        <>
          <Menu.Item onClick={onRename}>Rename…</Menu.Item>
          {(prop.type === "select" || prop.type === "multi_select") && (
            <Menu.Item onClick={onEditOptions}>Edit options…</Menu.Item>
          )}
          <Menu.Item onClick={onChangeType}>Change type…</Menu.Item>
          <Menu.Divider />
          <Menu.Item color="red" onClick={onDelete}>
            Delete column…
          </Menu.Item>
        </>
      ) : (
        <Menu.Label>Derived column — read-only</Menu.Label>
      )}
    </>
  );
}
