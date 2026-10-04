import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { fileURLToPath } from "node:url";

// Built to dist/, served statically by scripts/chief-dashboard-server.py at /.
// Relative base so the same build works under any mount point.
export default defineConfig({
  plugins: [react()],
  base: "./",
  // Shared L1 table engine, consumed from source (same folder layout on both Macs).
  resolve: {
    alias: {
      "@indie/table-core": fileURLToPath(new URL("../../../IndieLibKit/ts/table-core/src/index.ts", import.meta.url)),
    },
  },
  build: {
    outDir: "dist",
    emptyOutDir: true,
  },
});
