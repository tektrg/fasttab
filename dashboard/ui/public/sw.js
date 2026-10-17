// AgentBar PWA service worker — app-shell cache ONLY.
//
// This dashboard's whole point is live data (agent state, terminal panes,
// remote writes), so caching anything under /api/ or /remote/ would show a
// phone a stale board, or a stale queued action, without any indication it
// was stale. This worker therefore caches nothing except the static shell
// (the HTML/JS/CSS bundle + icons) needed to paint something before the
// network responds, and every /api/*, /remote/*, and non-GET request is
// left completely untouched — those hit the network directly, every time,
// same as with no service worker installed at all.
const SHELL_CACHE = "agentbar-shell-v1";
const SHELL_URLS = [
  "/",
  "/manifest.webmanifest",
  "/icons/icon-192.png",
  "/icons/icon-512.png",
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(SHELL_CACHE)
      .then((cache) => cache.addAll(SHELL_URLS))
      .then(() => self.skipWaiting()),
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(
          keys
            .filter((key) => key !== SHELL_CACHE)
            .map((key) => caches.delete(key)),
        ),
      )
      .then(() => self.clients.claim()),
  );
});

function isNeverCached(url) {
  return url.pathname.startsWith("/api/") || url.pathname.startsWith("/remote/");
}

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return; // never intercept writes
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  if (isNeverCached(url)) return; // live data — always network, never cached

  // Network-first for the shell: a stale cached bundle after a deploy is
  // worse than one extra round trip, and this dashboard is never offline
  // long enough for cache-first to matter. Cache is the fallback for a
  // flaky connection, not the primary source.
  event.respondWith(
    fetch(req)
      .then((res) => {
        if (res.ok) {
          const copy = res.clone();
          caches.open(SHELL_CACHE).then((cache) => cache.put(req, copy));
        }
        return res;
      })
      .catch(() => caches.match(req)),
  );
});

// Web Push: new customer feedback, sent by theindie-api (not this Mac), so it
// arrives with the app closed and the Mac asleep. Payload (encrypted by the
// sender, decrypted by the browser): {title, body, url, tag}. iOS revokes push
// for a web app that receives a push without showing a notification, so every
// push shows one, even a malformed payload.
self.addEventListener("push", (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch {
    data = {};
  }
  const title = typeof data.title === "string" ? data.title : "New feedback";
  event.waitUntil(
    self.registration.showNotification(title, {
      body: typeof data.body === "string" ? data.body : "",
      tag: typeof data.tag === "string" ? data.tag : "feedback",
      icon: "/icons/icon-192.png",
      data: { url: safeOpenPath(data.url) },
    }),
  );
});

// Only same-origin paths: a push payload must never open another site.
function safeOpenPath(url) {
  return typeof url === "string" && url.startsWith("/") && !url.startsWith("//") ? url : "/?tab=feedback";
}

// Tap: reuse an open AgentBar window (tell it to switch tabs), else open one.
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = safeOpenPath(event.notification.data && event.notification.data.url);
  const tab = new URL(url, self.location.origin).searchParams.get("tab") || "feedback";
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((windows) => {
      const open = windows.find((w) => new URL(w.url).origin === self.location.origin);
      if (open) {
        open.postMessage({ type: "agentbar-open-tab", tab });
        return open.focus();
      }
      return self.clients.openWindow(url);
    }),
  );
});
