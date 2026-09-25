import { useEffect, useRef, useState } from "react";
import { Button, Loader } from "@mantine/core";
import { fetchPaneScreen, fmtAge } from "../api";
import type { PaneScreenResponse } from "../types";

/** A pane's terminal output, as a SNAPSHOT.
 *
 *  The read costs ~2.5s server-side (it drives a real terminal), so it is
 *  fired exactly twice: when the paneId changes, and when the PO presses
 *  Refresh. Never on the dashboard's 2s SSE cadence — that would keep the
 *  machine reading panes nobody is looking at.
 *
 *  Because it is a snapshot and not a tail, the age label and the Refresh
 *  button are load-bearing, not decoration: without them the box looks
 *  live, and a PO acting on 4-minute-old output is worse off than one who
 *  knows they are looking at a still. */
export function PaneScreen({ paneId }: { paneId: string | null }) {
  const [res, setRes] = useState<PaneScreenResponse | null>(null);
  const [loading, setLoading] = useState(false);
  const [nonce, setNonce] = useState(0);
  // Ticks only the "read Ns ago" label. No network — the whole point is
  // that nothing here refetches on a timer.
  const [, setTick] = useState(0);
  const boxRef = useRef<HTMLPreElement | null>(null);

  useEffect(() => {
    if (!paneId) {
      setRes(null);
      return;
    }
    let dead = false;
    setLoading(true);
    setRes(null);
    void fetchPaneScreen(paneId).then((r) => {
      if (dead) return;
      setRes(r);
      setLoading(false);
    });
    return () => {
      dead = true;
    };
  }, [paneId, nonce]);

  useEffect(() => {
    const id = window.setInterval(() => setTick((n) => n + 1), 5000);
    return () => window.clearInterval(id);
  }, []);

  // Newest output is at the bottom of a terminal, so that is where the box
  // opens — a screen scrolled to its top shows the PO the oldest thing the
  // pane said, which is never what they came for.
  useEffect(() => {
    const el = boxRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [res]);

  if (!paneId) return null;

  const ageSec =
    res?.readTs !== undefined ? Date.now() / 1000 - res.readTs : null;

  return (
    <div className="rp-screen">
      <div className="rp-screen-head">
        <span className="rp-section-name">screen</span>
        <span className="small">
          {loading
            ? "reading…"
            : res?.readTs !== undefined
              ? `snapshot · read ${fmtAge(ageSec)} ago`
              : "snapshot"}
        </span>
        <Button
          className="rp-hit"
          variant="subtle"
          size="compact-xs"
          disabled={loading}
          title="read the pane again — takes about 2 seconds"
          onClick={() => setNonce((n) => n + 1)}
        >
          Refresh
        </Button>
      </div>
      {loading && (
        <div className="rp-screen-loading">
          <Loader size="xs" />
          <span className="small">reading the pane (~2s)</span>
        </div>
      )}
      {!loading && res && !res.ok && (
        // Verbatim, uninterpreted: the server already says why in plain
        // words, and a friendlier paraphrase here would hide which door
        // actually failed.
        <div className="rp-screen-error">{res.error ?? "screen read failed"}</div>
      )}
      {!loading && res?.ok && (
        <pre className="rp-screen-box" ref={boxRef}>
          {(res.lines ?? []).join("\n")}
        </pre>
      )}
    </div>
  );
}
