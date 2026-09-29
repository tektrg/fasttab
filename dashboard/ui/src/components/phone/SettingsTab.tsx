import { useComputedColorScheme } from "@mantine/core";
import type { FullState } from "../../types";
import pkg from "../../../package.json";
import { brokenFeeds } from "./phoneModel";

/** Settings tab: read-only for now — theme, connection, version. */
export function SettingsTab({ state }: { state: FullState }) {
  const scheme = useComputedColorScheme("light");
  const broken = brokenFeeds(state.feeds);
  return (
    <div className="phone-settings">
      <h2>Appearance</h2>
      <dl>
        <div>
          <dt>Theme</dt>
          <dd>{scheme === "dark" ? "Dark" : "Light"} · follows your phone</dd>
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
