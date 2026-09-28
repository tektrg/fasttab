// agentbar-status-plugin-marker v1 — installed by command-bar-macos dashboard/integrations/install.py
// OpenCode plugin: forwards session status / permission / question events and
// token usage to the AgentBar dashboard (POST /api/hook/tui-event). STATUS ONLY:
// it never replies to a permission or question.
// Fails open: every send is fire-and-forget with a short timeout; errors are
// swallowed; the event handler never awaits the network.
// Env: AGENTBAR_DASHBOARD_URL (default http://127.0.0.1:4711).

const DASHBOARD_URL = (process.env.AGENTBAR_DASHBOARD_URL || "http://127.0.0.1:4711").replace(/\/+$/, "");
const EVENT_URL = DASHBOARD_URL + "/api/hook/tui-event";
const POST_TIMEOUT_MS = 800;
const HEARTBEAT_MS = 30000;
const FORWARDED = new Set([
  "session.status", "session.idle", "session.error", "session.deleted",
  "permission.asked", "permission.replied",
  "question.asked", "question.replied", "question.rejected",
  "message.updated",
]);

function post(body) {
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), POST_TIMEOUT_MS);
    if (timer.unref) timer.unref();
    fetch(EVENT_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal: controller.signal,
    }).then((r) => r.body?.cancel?.()).catch(() => {}).finally(() => clearTimeout(timer));
  } catch {}
}

function sessionOf(p) {
  return p?.sessionID || p?.info?.sessionID || p?.part?.sessionID || "";
}

function titleOf(type, p) {
  if (type === "permission.asked") return p?.title || p?.permission || p?.type || "";
  if (type === "question.asked") return p?.questions?.[0]?.question || p?.question || "";
  return "";
}

const agentbarStatusPlugin = async ({ serverUrl, directory }) => {
  const base = {
    tool: "opencode",
    pid: process.pid,
    cwd: directory || process.cwd(),
    paneId: process.env.HERDR_PANE_ID || null,
    serverUrl: serverUrl?.origin || null,
  };
  const contextLimits = new Map(); // "provider/model" -> limit | null

  async function contextLimit(providerID, modelID) {
    const key = `${providerID}/${modelID}`;
    if (contextLimits.has(key) || !base.serverUrl) return contextLimits.get(key) ?? null;
    contextLimits.set(key, null);
    try {
      const r = await fetch(`${base.serverUrl}/config/providers`, { signal: AbortSignal.timeout(POST_TIMEOUT_MS) });
      const data = await r.json();
      const providers = Array.isArray(data?.providers) ? data.providers : [];
      const limit = providers.find((p) => p?.id === providerID)?.models?.[modelID]?.limit?.context;
      if (typeof limit === "number" && limit > 0) contextLimits.set(key, limit);
    } catch {}
    return contextLimits.get(key);
  }

  async function forward(event) {
    const type = event?.type;
    if (!FORWARDED.has(type)) return;
    const p = event.properties || {};
    const sessionId = sessionOf(p);
    if (!sessionId) return;
    const body = { ...base, event: type, sessionId };
    if (type === "session.status") body.statusType = p?.status?.type || null;
    const title = titleOf(type, p);
    if (title) body.title = String(title).slice(0, 120);
    if (type === "message.updated") {
      const info = p.info || {};
      if (info.role !== "assistant" || !info.tokens) return;
      body.tokens = info.tokens;
      body.contextLimit = await contextLimit(info.providerID, info.modelID);
    }
    post(body);
  }

  const heartbeat = setInterval(() => post({ ...base, event: "heartbeat" }), HEARTBEAT_MS);
  if (heartbeat.unref) heartbeat.unref();

  return {
    event: async ({ event }) => {
      forward(event).catch(() => {});
    },
  };
};

export default {
  id: "agentbar-status",
  server: agentbarStatusPlugin,
};
