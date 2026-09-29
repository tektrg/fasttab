// agentbar-status-plugin-marker v1 — installed by command-bar-macos dashboard/integrations/install.py
// OpenCode plugin: forwards session status / permission / question events and
// token usage to the AgentBar dashboard (POST /api/hook/tui-event). It never
// decides a permission or question itself: for a pending one it REPORTS the
// request (id + what is asked), and while one is pending it long-polls the
// dashboard for a reply job. A default OpenCode TUI has no TCP listener, so the
// reply is run here through the plugin's own in-process `client` (a real server
// started with --port is reached the same way). The job is built and validated
// by the dashboard; this side only runs an allowlisted permission/question
// route, and only for an id it saw pending itself.
// Fails open: every send is fire-and-forget with a short timeout; errors are
// swallowed; the event handler never awaits the network.
// Env: AGENTBAR_DASHBOARD_URL (default http://127.0.0.1:4711).

const DASHBOARD_URL = (process.env.AGENTBAR_DASHBOARD_URL || "http://127.0.0.1:4711").replace(/\/+$/, "");
const EVENT_URL = DASHBOARD_URL + "/api/hook/tui-event";
const POST_TIMEOUT_MS = 800;
const HEARTBEAT_MS = 30000;
const JOB_WAIT_URL = DASHBOARD_URL + "/api/hook/tui-job/wait";
const JOB_POLL_SEC = 20;
const JOB_RETRY_MS = 3000;
// The only OpenCode routes a job may call (v1 and v2 families, list + reply).
const JOB_PATH_ALLOWED = [
  /^\/(permission|question)(\?directory=[^&\s]*)?$/,
  /^\/(permission|question)\/[A-Za-z0-9_]{1,80}\/(reply|reject)$/,
  /^\/api\/session\/[A-Za-z0-9_]{1,80}\/(permission|question)$/,
  /^\/api\/session\/[A-Za-z0-9_]{1,80}\/(permission|question)\/[A-Za-z0-9_]{1,80}\/(reply|reject)$/,
];
const FORWARDED = new Set([
  "session.status", "session.idle", "session.error", "session.deleted",
  "permission.asked", "permission.replied",
  "question.asked", "question.replied", "question.rejected",
  // v2 event family (OpenCode 1.18 serves both; same meaning, other field names)
  "permission.v2.asked", "permission.v2.replied",
  "question.v2.asked", "question.v2.replied", "question.v2.rejected",
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

const TEXT_MAX = 2000;
const clip = (v, n = TEXT_MAX) => (typeof v === "string" ? v.slice(0, n) : "");
const clipList = (v, n = 20) => (Array.isArray(v) ? v.slice(0, n).map((x) => clip(x, 300)) : []);

// What is being asked, as the dashboard shows it. Only fields the OpenCode
// server's own /permission and /question lists define (checked against GET /doc).
function requestOf(type, p) {
  if ((type === "permission.asked" || type === "permission.v2.asked") && typeof p?.id === "string") {
    const v2 = type === "permission.v2.asked";
    return {
      id: p.id, kind: "permission", permission: clip(v2 ? p.action : p.permission, 200),
      patterns: clipList(v2 ? p.resources : p.patterns), always: clipList(v2 ? p.save : p.always),
      detail: clip(p.metadata?.command || p.metadata?.filepath || p.metadata?.description || "", 1000),
    };
  }
  if ((type === "question.asked" || type === "question.v2.asked") && typeof p?.id === "string" && Array.isArray(p.questions)) {
    return {
      id: p.id, kind: "question",
      questions: p.questions.slice(0, 8).map((q) => ({
        question: clip(q?.question), header: clip(q?.header, 120),
        multiple: !!q?.multiple, custom: q?.custom !== false,
        options: (Array.isArray(q?.options) ? q.options : []).slice(0, 20)
          .map((o) => ({ label: clip(o?.label, 300), description: clip(o?.description, 500) })),
      })),
    };
  }
  return null;
}

function titleOf(type, p) {
  if (type === "permission.asked") return p?.title || p?.permission || p?.type || "";
  if (type === "permission.v2.asked") return p?.action || "";
  if (type === "question.asked" || type === "question.v2.asked") return p?.questions?.[0]?.question || p?.question || "";
  return "";
}

const agentbarStatusPlugin = async ({ serverUrl, directory, client }) => {
  const base = {
    tool: "opencode",
    pid: process.pid,
    cwd: directory || process.cwd(),
    paneId: process.env.HERDR_PANE_ID || null,
    serverUrl: serverUrl?.origin || null,
    relay: typeof client?._client?.get === "function" && typeof client?._client?.post === "function",
  };
  const pendingIds = new Set(); // request ids this plugin saw asked and not yet answered
  let jobLoopRunning = false;
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

  async function runJob(job) {
    const okShape = job && (job.method === "GET" || job.method === "POST") && typeof job.path === "string"
      && JOB_PATH_ALLOWED.some((re) => re.test(job.path));
    const idInPath = /\/(?:per|que)_[A-Za-z0-9_]+/.exec(job?.path || "")?.[0]?.slice(1);
    const unseenReply = /\/(reply|reject)$/.test(job?.path || "") && !(idInPath && pendingIds.has(idInPath));
    let result = { status: 400, body: null };
    if (okShape && !unseenReply) {
      try {
        const call = client._client[job.method.toLowerCase()];
        const r = await call.call(client._client, {
          url: job.path, headers: { "Content-Type": "application/json" },
          ...(job.body !== null && job.body !== undefined ? { body: job.body } : {}),
        });
        result = { status: r?.response?.status ?? (r?.error ? 502 : 200), body: r?.data ?? null };
      } catch { result = { status: 502, body: null }; }
    }
    try {
      await fetch(`${DASHBOARD_URL}/api/hook/tui-job/${encodeURIComponent(job.id)}/result`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify(result), signal: AbortSignal.timeout(2000),
      }).then((r) => r.body?.cancel?.());
    } catch {}
  }

  // Runs only while a prompt of this process is pending; stops when none is.
  async function jobLoop() {
    if (jobLoopRunning || !base.relay) return;
    jobLoopRunning = true;
    try {
      while (pendingIds.size > 0) {
        try {
          const r = await fetch(`${JOB_WAIT_URL}?pid=${process.pid}&timeout=${JOB_POLL_SEC}`,
            { signal: AbortSignal.timeout((JOB_POLL_SEC + 5) * 1000) });
          const data = await r.json();
          if (data?.job) await runJob(data.job);
        } catch { await new Promise((res) => setTimeout(res, JOB_RETRY_MS)); }
      }
    } finally { jobLoopRunning = false; }
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
    const request = requestOf(type, p);
    if (request) { body.request = request; pendingIds.add(request.id); jobLoop(); }
    if (p.requestID && /^(permission|question)\.(v2\.)?(replied|rejected)$/.test(type)) {
      body.requestId = String(p.requestID);
      pendingIds.delete(body.requestId);
    }
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
