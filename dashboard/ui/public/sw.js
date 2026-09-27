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
