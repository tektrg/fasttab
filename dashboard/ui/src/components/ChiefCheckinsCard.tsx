import { useCallback, useEffect, useRef, useState } from "react";
import { Badge, SegmentedControl, Switch, UnstyledButton } from "@mantine/core";
import { LOGGED_OUT_ERROR } from "../api";
import {
  PACES,
  TRACKED_ONLY_NOTE,
  checkInSummary,
  lastWakeText,
  toneColor,
  type CheckIn,
  type ChiefEntry,
  type ChiefPace,
} from "../chiefCheckins";

const POLL_MS = 30_000;

type Json<T> = T & { ok: boolean; error?: string };

async function call<T>(url: string, method: string, body?: unknown): Promise<Json<T>> {
  try {
    const r = await fetch(url, {
      method,
      headers: body === undefined ? undefined : { "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    if (r.status === 401) return { ok: false, error: LOGGED_OUT_ERROR } as Json<T>;
    const parsed = await r.json();
    return { ...parsed, ok: r.ok && parsed.ok !== false };
  } catch (e) {
    return { ok: false, error: String(e) } as Json<T>;
  }
}

export function fetchChiefCheckins() {
  return call<{ chiefs?: ChiefEntry[] }>("/api/chief/checkins", "GET");
}

export function saveChiefSettings(input: { chief: string; pace?: ChiefPace; sleepCheckins?: boolean }) {
  return call<{ settings?: unknown; checkIn?: CheckIn }>("/api/chief/settings", "POST", input);
}

/** Per-chief check-in timers: when each chief last checked in, when it's next
 *  due, and its pace / sleep-time settings. Renders nothing with no chiefs. */
export function ChiefCheckinsCard({ collapsible = false }: { collapsible?: boolean }) {
  const [chiefs, setChiefs] = useState<ChiefEntry[]>([]);
  const [open, setOpen] = useState(!collapsible);
  const [nowSec, setNowSec] = useState(() => Date.now() / 1000);
  const alive = useRef(true);

  const load = useCallback(async () => {
    const r = await fetchChiefCheckins();
    if (!alive.current) return;
    if (r.ok && Array.isArray(r.chiefs)) setChiefs(r.chiefs);
    setNowSec(Date.now() / 1000);
  }, []);

  useEffect(() => {
    alive.current = true;
    void load();
    const t = window.setInterval(load, POLL_MS);
    return () => {
      alive.current = false;
      window.clearInterval(t);
    };
  }, [load]);

  if (chiefs.length === 0) return null;

  const summaries = chiefs.map((c) => checkInSummary(c.checkIn, nowSec));
  const late = summaries.filter((s) => s.tone === "danger" || s.tone === "warn").length;

  return (
    <section className="chief-checkins" style={{ padding: "8px 12px", borderBottom: "1px solid var(--line, rgba(128,128,128,.25))" }}>
      <UnstyledButton
        aria-expanded={open}
        onClick={() => collapsible && setOpen((o) => !o)}
        style={{ display: "flex", alignItems: "center", gap: 8, width: "100%", fontWeight: 600, minHeight: 32 }}
      >
        <span>Chief check-ins</span>
        <span style={{ opacity: 0.6, fontWeight: 400 }}>{chiefs.length}</span>
        {late > 0 && (
          <Badge size="sm" color="red" variant="light">
            {late} late
          </Badge>
        )}
        {collapsible && (
          <span aria-hidden="true" style={{ marginLeft: "auto" }}>
            {open ? "▾" : "▸"}
          </span>
        )}
      </UnstyledButton>
      {open &&
        chiefs.map((c) => (
          <ChiefItem
            key={c.key}
            chief={c}
            nowSec={nowSec}
            onSaved={(checkIn) => {
              setChiefs((list) => list.map((x) => (x.key === c.key ? { ...x, checkIn } : x)));
              setNowSec(Date.now() / 1000);
              void load();
            }}
          />
        ))}
    </section>
  );
}

function ChiefItem({
  chief,
  nowSec,
  onSaved,
}: {
  chief: ChiefEntry;
  nowSec: number;
  onSaved: (c: CheckIn) => void;
}) {
  const ci = chief.checkIn;
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const s = checkInSummary(ci, nowSec);
  const wake = lastWakeText(ci?.lastWake, nowSec);

  const save = async (patch: { pace?: ChiefPace; sleepCheckins?: boolean }) => {
    setBusy(true);
    setError(null);
    const r = await saveChiefSettings({ chief: chief.key, ...patch });
    setBusy(false);
    if (r.ok && r.checkIn) onSaved(r.checkIn);
    else setError(`Not saved: ${r.error ?? "unknown error"} — setting unchanged`);
  };

  return (
    <div data-chief={chief.key} style={{ padding: "8px 0", display: "flex", flexDirection: "column", gap: 6 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
        <span style={{ fontWeight: 500 }}>{chief.label || chief.name}</span>
        <Badge size="sm" color={toneColor(s.tone)} variant="light" style={{ textTransform: "none" }}>
          {s.text}
        </Badge>
      </div>
      {ci?.schedule && <div className="small" style={{ opacity: 0.7 }}>{ci.schedule}</div>}
      {ci && !ci.wakeEnabled && <div className="small" style={{ opacity: 0.7 }}>{TRACKED_ONLY_NOTE}</div>}
      {wake && <div className="small" style={{ opacity: 0.7 }}>{wake}</div>}
      {ci && (
        <>
          <SegmentedControl
            size="xs"
            fullWidth
            disabled={busy}
            aria-label={`Check-in pace for ${chief.label || chief.name}`}
            value={ci.pace}
            data={PACES}
            onChange={(v) => void save({ pace: v as ChiefPace })}
          />
          <Switch
            size="sm"
            disabled={busy}
            label="Sleep-time check-ins"
            checked={ci.sleepCheckins}
            onChange={(e) => void save({ sleepCheckins: e.currentTarget.checked })}
          />
        </>
      )}
      {error && (
        <div role="alert" className="small" style={{ color: "var(--mantine-color-red-6)" }}>
          {error}
        </div>
      )}
    </div>
  );
}
