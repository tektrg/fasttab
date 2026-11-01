import { useEffect, useRef, type KeyboardEvent } from "react";
import { IconButton } from "./IconButton";
import "./ActionMenu.css";

export interface MenuItem {
  key: string;
  label: string;
  /** danger = destructive styling. */
  tone?: "danger";
  disabled?: boolean;
  onSelect: () => void;
}

/** A "•••" button that opens a small list of 44px actions. Controlled: the
 *  owner decides when it closes (a destructive item may stay open to show
 *  its confirm step). Escape / outside press close it and focus returns to
 *  the button; Arrow keys move between items. */
export function ActionMenu({
  label,
  open,
  onOpenChange,
  items,
}: {
  label: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  items: MenuItem[];
}) {
  const root = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    root.current?.querySelector<HTMLButtonElement>('[role="menuitem"]:not(:disabled)')?.focus();
    const away = (e: PointerEvent) => {
      if (!root.current?.contains(e.target as Node)) onOpenChange(false);
    };
    document.addEventListener("pointerdown", away, true);
    return () => document.removeEventListener("pointerdown", away, true);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);

  const onKeyDown = (e: KeyboardEvent) => {
    if (!open) return;
    if (e.key === "Escape") {
      e.stopPropagation();
      onOpenChange(false);
      root.current?.querySelector<HTMLElement>(".ui-icon-btn")?.focus();
    } else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      const els = Array.from(root.current?.querySelectorAll<HTMLButtonElement>('[role="menuitem"]:not(:disabled)') ?? []);
      const at = els.indexOf(document.activeElement as HTMLButtonElement);
      const next = e.key === "ArrowDown" ? at + 1 : at - 1;
      els[(next + els.length) % els.length]?.focus();
    }
  };

  return (
    <div className="ui-menu" ref={root} onKeyDown={onKeyDown}>
      <IconButton
        aria-label={label}
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => onOpenChange(!open)}
      >
        <span aria-hidden="true">•••</span>
      </IconButton>
      {open && (
        <div className="ui-menu__list" role="menu" aria-label={label}>
          {items.map((it) => (
            <button
              key={it.key}
              type="button"
              role="menuitem"
              className="ui-menu__item"
              data-tone={it.tone}
              disabled={it.disabled}
              onClick={it.onSelect}
            >
              {it.label}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
