import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Built to dist/, served statically by scripts/chief-dashboard-server.py at /.
// Relative base so the same build works under any mount point.
export default defineConfig({
  plugins: [react()],
  base: "./",
  build: {
    outDir: "dist",
    emptyOutDir: true,
  },
});
