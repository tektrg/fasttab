import React from "react";
import ReactDOM from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import "@mantine/core/styles.css";
import App from "./App";
import { theme } from "./theme";
import "./index.css";

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    {/* Light by default, dark when the OS says dark (see the
        [data-mantine-color-scheme='dark'] block in index.css and the
        light/dark primaryShade split in theme.ts). */}
    <MantineProvider defaultColorScheme="auto" theme={theme}>
      <App />
    </MantineProvider>
  </React.StrictMode>,
);
