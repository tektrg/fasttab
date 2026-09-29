// Test harness (test_tui_jobs.py): loads the REAL plugin with a FAKE in-process
// client, fires a permission.asked event, waits for the fake dashboard's jobs to
// be handled, prints the client calls as one JSON line.
import plugin from "../integrations/opencode/agentbar-status.js";

const calls = [];
const record = (method) => async (opts) => {
  calls.push({ method, url: opts.url, body: opts.body ?? null });
  return { data: true, response: { status: 200 } };
};
const client = { _client: { get: record("get"), post: record("post") } };
const hooks = await plugin.server({ serverUrl: new URL("http://localhost:4096"), directory: "/scratch", client });
await hooks.event({ event: { type: "permission.asked", properties: {
  sessionID: "ses_1", id: "per_seen", permission: "bash", patterns: ["ls"], always: [], metadata: {} } } });
// Wait until the fake dashboard has every job result (poll, no fixed sleep), 20s at most.
const expected = Number(process.env.AGENTBAR_TEST_RESULTS || 0);
for (let waited = 0; waited < 20000; waited += 100) {
  const seen = await fetch(process.env.AGENTBAR_DASHBOARD_URL + "/api/test/results-count").then((r) => r.json()).catch(() => ({}));
  if ((seen.count ?? 0) >= expected) break;
  await new Promise((resolve) => setTimeout(resolve, 100));
}
console.log(JSON.stringify(calls));
process.exit(0);
