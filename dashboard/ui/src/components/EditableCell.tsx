import { useRef, useState } from "react";
import {
  Button,
  Checkbox,
  MultiSelect,
  NumberInput,
  Select,
  TextInput,
} from "@mantine/core";
import type { BoardProperty, BoardRow, BoardValue } from "../types";
import { fmtAge, setCellValue, updateProperty } from "../api";
import { MEMORY_CAVEAT, fmtCtx, fmtMem } from "../sessionActions";
import { MachineBadge, StateBadge } from "./Severity";
import { CardMenu } from "./CardMenu";
import { screenClassOf, stClassOf } from "./stateClasses";

/** One shared editable cell for BOTH the board table and the agent table.
 *  Enter saves, Escape cancels, blur saves, Tab saves and moves to the next
 *  cell. Each column type gets its Mantine input: TextInput (text/date),
 *  NumberInput (number), Select (select), MultiSelect (multi_select),
 *  Checkbox (checkbox).
 *
 *  Poll-safety: the draft lives in this component's state and is only
 *  (re)seeded when the editor opens — a 2s SSE/board refresh re-renders
 *  without remounting, so focus and half-typed text survive. The `td`
 *  keeps its `editable-cell` / `editing` classes for the regression test. */

export function DerivedCell({
  property,
  row,
  width,
  lead,
  onToast,
  onDone,
  wrap,
  stickyLeft,
}: {
  property: BoardProperty;
  row: BoardRow;
  width?: number;
  lead?: React.ReactNode;
  /** Present only where the caller wants row actions on this cell — the
   *  label cell renders the same ⋯ CardMenu the kanban card uses. Absent
   *  callers (e.g. the Agents table) keep the plain label, no menu. */
  onToast?: (msg: string, ok: boolean) => void;
  onDone?: () => void;
  /** Wrap long text onto multiple lines (per-column view pref). */
  wrap?: boolean;
  /** Non-null pins the cell to the left edge at this offset. */
  stickyLeft?: number | null;
}) {
  const value = row.values[property.id] ?? null;
  const agent = row.derived;
  const style: React.CSSProperties | undefined =
    width != null || stickyLeft != null
      ? {
          ...(width != null ? { width, minWidth: width } : undefined),
          ...(stickyLeft != null
            ? {
                position: "sticky",
                left: stickyLeft,
                zIndex: 2,
                background: "var(--paper)",
              }
            : undefined),
        }
      : undefined;
  let cls = "derived-cell";
  let content: React.ReactNode = formatValue(value, property);

  if (property.id === "derived:state") {
    cls = `derived-cell ${stClassOf(agent.hookState)}`;
  } else if (property.id === "derived:screen") {
    cls = `derived-cell ${screenClassOf(agent.screenState)}`;
  } else if (property.id === "derived:since") {
    cls = "derived-cell small";
    content = fmtAge(typeof value === "number" ? value : null);
  } else if (property.id === "derived:cwd") {
    cls = "derived-cell wrap small";
  } else if (property.id === "derived:herdr") {
    cls = agent.disagree ? "derived-cell disagree" : "derived-cell agree";
  } else if (property.id === "derived:disagreement") {
    cls = agent.disagree ? "derived-cell disagree" : "derived-cell agree";
    content = agent.disagree ? "yes" : "";
  } else if (property.id === "derived:memory") {
    // Numeric bytes underneath (sorts correctly, null sorts last); rendered
    // `2.1 GB`, or `—` when unmeasurable — never `0`.
    cls = "derived-cell small";
    content = (
      <span title={MEMORY_CAVEAT}>
        {fmtMem(typeof value === "number" ? value : null)}
      </span>
    );
  } else if (property.id === "derived:context") {
    // Phase 9: numeric % underneath (sorts correctly, null sorts last);
    // rendered `21%`, or `—` when unreadable — never `0`. The column orders
    // by the real number; the countdown badge lives on the kanban card.
    cls = "derived-cell small";
    content = (
      <span title="% of the context window in use, parsed off the pane's status line — ranks honestly, not an absolute">
        {fmtCtx(typeof value === "number" ? value : null)}
      </span>
    );
  } else if (property.id === "derived:machine") {
    cls = "derived-cell small";
    content = (
      <MachineBadge
        machine={typeof value === "string" ? value : "local"}
        dup={agent.duplicateOfSession}
      />
    );
  } else if (property.id === "archived") {
    // Board-only flag: hiding a row frees nothing and touches no process.
    cls = "derived-cell small";
    content = (
      <span title="Board-only: hides the row from the default view, frees nothing, touches no process">
        {formatValue(value, property)}
      </span>
    );
  } else if (property.id === "derived:label" && onToast && onDone) {
    content = (
      <>
        {formatValue(value, property)}{" "}
        <CardMenu row={row} onToast={onToast} onDone={onDone} />
      </>
    );
  } else if (typeof value === "string" && /^https?:\/\//.test(value)) {
    // Any derived text that is a URL renders clickable — generic, not per-column.
    cls = "derived-cell small";
    content = (
      <a className="link" href={value} target="_blank" rel="noreferrer" onClick={(e) => e.stopPropagation()}>
        open ↗
      </a>
    );
  }

  // State/screen cells render as severity badges (same st-* meaning, louder).
  const badgeCls = cls.match(/st-(blocked|working|idle|unknown)/)?.[0];

  const tdClass = [
    cls,
    wrap ? "cellwrap" : "",
    stickyLeft != null ? "colsticky" : "",
  ]
    .filter(Boolean)
    .join(" ");

  return (
    <td className={tdClass} style={style}>
      {lead}
      {lead ? " " : null}
      {badgeCls ? <StateBadge cls={badgeCls}>{content}</StateBadge> : content}
    </td>
  );
}

export function EditableCell({
  rowId,
  property,
  value,
  onToast,
  rowKind = "session",
  width,
  lead,
  wrap,
  stickyLeft,
}: {
  rowId: string;
  property: BoardProperty;
  value: BoardValue;
  onToast: (msg: string, ok: boolean) => void;
  rowKind?: string;
  width?: number;
  lead?: React.ReactNode;
  /** Wrap long text onto multiple lines (per-column view pref). */
  wrap?: boolean;
  /** Non-null pins the cell to the left edge at this offset. */
  stickyLeft?: number | null;
}) {
  const cellStyle: React.CSSProperties | undefined =
    width != null || stickyLeft != null
      ? {
          ...(width != null ? { width, minWidth: width } : undefined),
          ...(stickyLeft != null
            ? {
                position: "sticky",
                left: stickyLeft,
                zIndex: 2,
                background: "var(--paper)",
              }
            : undefined),
        }
      : undefined;
  const cellClass = [
    "editable-cell",
    wrap ? "cellwrap" : "",
    stickyLeft != null ? "colsticky" : "",
  ]
    .filter(Boolean)
    .join(" ");
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(valueToDraft(value, property));
  // Tab fires save AND then moves focus (which blurs, which would save
  // again); Enter fires save and the ensuing blur would too. One commit max.
  const doneRef = useRef(false);

  const open = () => {
    doneRef.current = false;
    setDraft(valueToDraft(value, property));
    setEditing(true);
  };

  const save = async (nextDraft = draft) => {
    if (doneRef.current) return;
    doneRef.current = true;
    const nextValue = draftToValue(nextDraft, property);
    const res = await setCellValue({ rowKind, rowId, propertyId: property.id, value: nextValue });
    onToast(res.ok ? "cell saved" : `save failed: ${res.error || "?"}`, res.ok);
    setEditing(false);
  };

  const cancel = () => {
    if (doneRef.current) return;
    doneRef.current = true;
    setDraft(valueToDraft(value, property));
    setEditing(false);
  };

  // Tab commits this cell then opens the neighbour, so keyboard entry can
  // walk a row without touching the mouse.
  const moveToSibling = (dir: 1 | -1) => {
    const td = (document.activeElement as HTMLElement | null)?.closest("td");
    const tr = td?.closest("tr");
    if (!tr || !td) return;
    const cells = Array.from(tr.querySelectorAll("td.editable-cell"));
    const next = cells[cells.indexOf(td) + dir] as HTMLElement | undefined;
    if (next) next.click();
    else (document.activeElement as HTMLElement | null)?.blur?.();
  };

  const onKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Escape") {
      e.stopPropagation();
      cancel();
    } else if (e.key === "Enter") {
      void save();
    } else if (e.key === "Tab") {
      e.preventDefault();
      const dir = e.shiftKey ? -1 : 1;
      void save().then(() => moveToSibling(dir));
    }
  };

  if (!editing) {
    return (
      <td
        className={cellClass}
        style={cellStyle}
        onClick={(e) => {
          e.stopPropagation();
          open();
        }}
      >
        {lead}
        {lead ? " " : null}
        {formatValue(value, property)}
      </td>
    );
  }

  const stop = (e: React.MouseEvent) => e.stopPropagation();

  if (property.type === "select") {
    return (
      <td className={`${cellClass} editing`} style={cellStyle} onClick={stop}>
        <Select
          autoFocus
          clearable
          value={draft || null}
          data={property.options.map((o) => ({ value: o.id, label: o.name }))}
          onChange={(v) => {
            const next = v ?? "";
            setDraft(next);
            void save(next);
          }}
          onKeyDown={onKeyDown}
          comboboxProps={{ onClose: () => setEditing(false) }}
        />
        <OptionCreator property={property} onToast={onToast} />
      </td>
    );
  }

  if (property.type === "multi_select") {
    return (
      <td className={`${cellClass} editing`} style={cellStyle} onClick={stop}>
        <MultiSelect
          autoFocus
          clearable
          value={draft.split(",").filter(Boolean)}
          data={property.options.map((o) => ({ value: o.id, label: o.name }))}
          onChange={(vals) => setDraft(vals.join(","))}
          onBlur={() => void save()}
          onKeyDown={onKeyDown}
        />
        <OptionCreator property={property} onToast={onToast} />
      </td>
    );
  }

  if (property.type === "checkbox") {
    return (
      <td className={`${cellClass} editing`} style={cellStyle} onClick={stop}>
        <Checkbox
          autoFocus
          label={formatValue(value, property) || "no"}
          checked={draft === "true"}
          onChange={(e) => {
            const next = String(e.currentTarget.checked);
            setDraft(next);
            void save(next);
          }}
          onBlur={() => void save()}
          onKeyDown={onKeyDown}
        />
      </td>
    );
  }

  if (property.type === "number") {
    return (
      <td className={`${cellClass} editing`} style={cellStyle} onClick={stop}>
        <NumberInput
          autoFocus
          value={draft}
          onChange={(v) => setDraft(String(v))}
          onBlur={() => void save()}
          onKeyDown={onKeyDown}
        />
      </td>
    );
  }

  return (
    <td className={`${cellClass} editing`} style={cellStyle} onClick={stop}>
      <TextInput
        autoFocus
        type={property.type === "date" ? "date" : "text"}
        value={draft}
        onChange={(e) => setDraft(e.currentTarget.value)}
        onBlur={() => void save()}
        onKeyDown={onKeyDown}
      />
    </td>
  );
}

/** Inline "+ New option" under select editors — no prompt dialog. */
function OptionCreator({
  property,
  onToast,
}: {
  property: BoardProperty;
  onToast: (msg: string, ok: boolean) => void;
}) {
  const [open, setOpen] = useState(false);
  const [name, setName] = useState("");
  const [saving, setSaving] = useState(false);

  if (!open) {
    return (
      <Button
        variant="subtle"
        size="compact-xs"
        onClick={(e) => {
          e.stopPropagation();
          setOpen(true);
        }}
      >
        + New option
      </Button>
    );
  }

  const create = async () => {
    const clean = name.trim();
    if (!clean) {
      setOpen(false);
      return;
    }
    setSaving(true);
    const options = [
      ...property.options,
      { id: crypto.randomUUID(), name: clean, color: "gray" },
    ];
    const res = await updateProperty(property.id, { options });
    setSaving(false);
    onToast(res.ok ? "option created" : `option failed: ${res.error || "?"}`, res.ok);
    setName("");
    setOpen(false);
  };

  return (
    <TextInput
      autoFocus
      placeholder={`New option for ${property.name}`}
      value={name}
      onChange={(e) => setName(e.currentTarget.value)}
      onBlur={() => {
        if (!name.trim()) setOpen(false);
      }}
      onKeyDown={(e) => {
        e.stopPropagation();
        if (e.key === "Enter") void create();
        if (e.key === "Escape") setOpen(false);
      }}
      rightSection={
        <Button
          variant="subtle"
          size="compact-xs"
          loading={saving}
          onClick={() => void create()}
        >
          Add
        </Button>
      }
    />
  );
}

function valueToDraft(value: BoardValue, property: BoardProperty): string {
  if (value === null || value === undefined) return "";
  if (property.type === "multi_select" && Array.isArray(value)) return value.join(",");
  return String(value);
}

function draftToValue(draft: string, property: BoardProperty): BoardValue {
  if (!draft) return null;
  if (property.type === "number") return Number(draft);
  if (property.type === "checkbox") return draft === "true";
  if (property.type === "multi_select") return draft.split(",").filter(Boolean);
  return draft;
}

export function formatValue(value: BoardValue, property: BoardProperty): string {
  if (value === null || value === undefined || value === "") return "";
  if (property.type === "checkbox") return value ? "yes" : "no";
  if (property.type === "select") return optionName(property, String(value));
  if (property.type === "multi_select" && Array.isArray(value)) {
    return value.map((id) => optionName(property, id)).join(", ");
  }
  return String(value);
}

export function optionName(property: BoardProperty, optionId: string): string {
  return property.options.find((o) => o.id === optionId)?.name ?? optionId;
}
