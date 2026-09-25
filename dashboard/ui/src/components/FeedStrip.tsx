import { Alert, Badge } from "@mantine/core";
import { FEED_ORDER, type FeedName, type FullState } from "../types";
import { fmtAge } from "../api";

export function FeedStrip({ state }: { state: FullState }) {
  return (
    <>
      <div id="banners">
        {state.feeds.machinesConfigError && (
          <Alert
            color="red"
            variant="filled"
            title="⛔ MACHINES CONFIG BROKEN — .claude/dashboard-machines.json"
            style={{ margin: "10px 16px" }}
          >
            {state.feeds.machinesConfigError} — remote-machine rows are
            silently off until this is fixed.
          </Alert>
        )}
        {FEED_ORDER.filter(
          (name: FeedName) =>
            state.feeds[name].broken && !state.feeds[name].warming,
        ).map((name: FeedName) => {
          const f = state.feeds[name];
          return (
            <Alert
              key={name}
              color="red"
              variant="filled"
              title={`⛔ FEED BROKEN — ${name}`}
              style={{ margin: "10px 16px" }}
            >
              {f.lastSuccessTs
                ? "last good " + fmtAge(f.ageSec) + " ago"
                : "never succeeded"}
              {f.error ? " — " + f.error : ""}
            </Alert>
          );
        })}
      </div>
      <div className="feedstrip" id="feedstrip">
        {FEED_ORDER.map((name: FeedName) => {
          const f = state.feeds[name];
          const color = f.warming ? "gray" : f.broken ? "red" : "green";
          return (
            <Badge
              key={name}
              size="sm"
              variant={f.broken && !f.warming ? "filled" : "light"}
              color={color}
              className={f.broken ? "bad" : "ok"}
            >
              {name}{" "}
              {f.warming
                ? "◌ warming up"
                : (f.broken ? "✖ BROKEN " : "●") +
                  " " +
                  fmtAge(f.ageSec) +
                  " ago"}
            </Badge>
          );
        })}
      </div>
    </>
  );
}
