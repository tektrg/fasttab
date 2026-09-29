import React, { lazy, Suspense } from "react";
import ReactDOM from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import "@mantine/core/styles.css";
import App from "./App";
import { cssVariablesResolver, theme } from "./theme";
import "./index.css";

// `/#ui-kit` renders the P1 primitives in every state. Lazy chunk: never
// fetched unless the hash is present, and no production screen links to it.
const UiKitPage = lazy(() => import("./ui/UiKitPage"));
const showUiKit = window.location.hash === "#ui-kit";

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    {/* Light by default, dark when the OS says dark (see the
        [data-mantine-color-scheme='dark'] block in index.css and the
        token mapping in theme.ts). */}
    <MantineProvider defaultColorScheme="auto" theme={theme} cssVariablesResolver={cssVariablesResolver}>
      {showUiKit ? (
        <Suspense fallback={null}>
          <UiKitPage />
        </Suspense>
      ) : (
        <App />
      )}
    </MantineProvider>
  </React.StrictMode>,
);

// PWA app-shell cache (phase 2a) — HTTPS only (loopback dev over plain http
// never registers one; iOS's install prompt needs https anyway, and a
// service worker on the loopback dev server would only risk masking a
// local code change behind a stale cache).
if ("serviceWorker" in navigator && window.location.protocol === "https:") {
  window.addEventListener("load", () => {
    void navigator.serviceWorker.register("/sw.js");
  });
}
