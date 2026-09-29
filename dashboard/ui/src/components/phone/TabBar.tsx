import type { ReactNode } from "react";
import type { PhoneTab } from "./phoneModel";

const ICONS: Record<PhoneTab, ReactNode> = {
  inbox: <path d="M4 13l2-7h12l2 7v5H4v-5zm0 0h5a3 3 0 006 0h5" />,
  agents: <path d="M4 7h16M4 12h16M4 17h16" />,
  settings: (
    <>
      <circle cx="12" cy="12" r="3" />
      <path d="M12 3v3M12 18v3M3 12h3M18 12h3M5.6 5.6l2.1 2.1M16.3 16.3l2.1 2.1M18.4 5.6l-2.1 2.1M7.7 16.3l-2.1 2.1" />
    </>
  ),
};

const LABEL: Record<PhoneTab, string> = { inbox: "Inbox", agents: "Agents", settings: "Settings" };
const ORDER: PhoneTab[] = ["inbox", "agents", "settings"];

/** Bottom navigation: three tabs, safe-area padded, 44pt+ targets. The Inbox
 *  badge is the number of agents waiting on you. */
export function TabBar({ tab, onTab, inboxBadge }: { tab: PhoneTab; onTab: (t: PhoneTab) => void; inboxBadge: number }) {
  return (
    <nav className="phone-tabbar" aria-label="Main">
      {ORDER.map((t) => (
        <button
          key={t}
          type="button"
          className="phone-tabbar__item"
          aria-current={t === tab ? "page" : undefined}
          aria-label={t === "inbox" && inboxBadge > 0 ? `Inbox, ${inboxBadge} waiting on you` : LABEL[t]}
          onClick={() => onTab(t)}
        >
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
            {ICONS[t]}
          </svg>
          <span aria-hidden="true">{LABEL[t]}</span>
          {t === "inbox" && inboxBadge > 0 && <span className="phone-tabbar__badge" aria-hidden="true">{inboxBadge}</span>}
        </button>
      ))}
    </nav>
  );
}
