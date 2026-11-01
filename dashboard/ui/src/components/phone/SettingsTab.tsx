import { useState } from "react";
import { useComputedColorScheme } from "@mantine/core";
import type { FullState } from "../../types";
import pkg from "../../../package.json";
import { brokenFeeds } from "./phoneModel";
import { FONT_SCALES, getFontPref, getFontScale, setFontPref, setFontScale, type FontPref } from "../../fontPref";

/** Settings tab: read-only for now — theme, connection, version. */
export function SettingsTab({ state }: { state: FullState }) {
  const scheme = useComputedColorScheme("light");
  const broken = brokenFeeds(state.feeds);
  const [font, setFont] = useState<FontPref>(getFontPref());
  const [scale, setScale] = useState<number>(getFontScale());
  return (
    <div className="phone-settings">
      <h2>Appearance</h2>
      <dl>
        <div>
          <dt>Theme</dt>
          <dd>{scheme === "dark" ? "Dark" : "Light"} · follows your phone</dd>
        </div>
        <div>
          <dt>Font</dt>
          <dd>
            <select
              aria-label="Font"
              value={font}
              onChange={(e) => {
                const next = e.target.value as FontPref;
                setFont(next);
                setFontPref(next);
              }}
            >
              <option value="avenir">Avenir Next</option>
              <option value="system">System</option>
            </select>
          </dd>
        </div>
        <div>
          <dt>Text size</dt>
          <dd>
            <select
              aria-label="Text size"
              value={scale}
              onChange={(e) => {
                const next = Number(e.target.value);
                setScale(next);
                setFontScale(next);
              }}
            >
              {FONT_SCALES.map((s) => (
                <option key={s} value={s}>{Math.round(s * 100)}%</option>
              ))}
            </select>
          </dd>
        </div>
      </dl>
      <h2>Connection</h2>
      <dl>
        <div>
          <dt>Status</dt>
          <dd>{broken.length === 0 ? "Live" : `Live · ${broken.length} feed${broken.length === 1 ? "" : "s"} down`}</dd>
        </div>
        <div>
          <dt>Last update</dt>
          <dd>{new Date(state.serverTimeTs * 1000).toLocaleTimeString()}</dd>
        </div>
        {broken.length > 0 && (
          <div>
            <dt>Down</dt>
            <dd>{broken.join(", ")}</dd>
          </div>
        )}
      </dl>
      <h2>About</h2>
      <dl>
        <div>
          <dt>Version</dt>
          <dd>{pkg.version}</dd>
        </div>
      </dl>
    </div>
  );
}
