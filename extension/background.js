// FastTab Companion — MV3 background service worker.
//
// Talks to the FastTab Mac app over Chrome native messaging. The app's host
// (`FastTabNativeHost`) is a pure relay to the app's Unix socket, so this file
// speaks the app's JSON protocol directly:
//
//   {v, type, seq, payload}
//
// Outbound tab data uses an incrementing `seq`; the app requests a fresh full
// snapshot when it spots a gap. `pong`/`commandResult` replies use seq 0.
//
// MV3 lifetime: the worker is killed when idle. Every wake re-runs the top-level
// `init()`, which reconnects the port and sends a *full* snapshot — so a killed
// worker costs one reconnect and never leaves stale state. The app's 20s ping
// keeps the worker warm while connected.

const PROTOCOL_VERSION = 1;
// Native-messaging host names must be lowercase alphanumerics + "_" + "."
// (uppercase is rejected with "Invalid native messaging host name specified").
const HOST_NAME = 'com.trungluong.fasttab';

let port = null;
let seq = 0;
let reconnectTimer = null;
let activeTabByWindow = new Map(); // windowId -> active tabId
let lastError = ''; // surfaced to the options page for diagnostics

// Extension-side mirror of what the app sees. Rebuilt on wake; updated by
// tab events; used to attach windowIndex / windowName / groupTitle to deltas.
const state = {
  windows: [],            // normal windows, focused first (windowIndex = idx+1)
  focusedWindowId: null,
  tabs: new Map(),        // tabId -> chrome.tabs.Tab
  groups: new Map()       // groupId -> chrome.tabGroups.TabGroup
};

// -- Wire helpers -------------------------------------------------------------

function sendMessage(type, payload) {
  if (!port) return;
  try {
    port.postMessage({ v: PROTOCOL_VERSION, type, seq: ++seq, payload: payload || {} });
  } catch (e) {
    // Port died mid-send; onDisconnect will reconnect.
  }
}

function sendResponse(type, payload) {
  if (!port) return;
  try {
    port.postMessage({ v: PROTOCOL_VERSION, type, seq: 0, payload: payload || {} });
  } catch (e) {}
}

// -- Browser detection ----------------------------------------------------------

function getBrowserId() {
  const ua = navigator.userAgent;
  if (typeof navigator.brave !== 'undefined') return 'brave';
  if (/Edg\//.test(ua)) return 'edge';
  return 'chrome';
}

// -- Snapshot / delta building --------------------------------------------------

function buildTabRecord(tab) {
  if (!tab || !tab.url) return null;
  const winIdx = state.windows.findIndex((w) => w.id === tab.windowId);
  if (winIdx < 0) return null;
  const activeTitle = state.tabs.get(activeTabByWindow.get(tab.windowId))?.title || '';
  return {
    id: tab.id,
    windowId: tab.windowId,
    windowIndex: winIdx + 1,
    tabIndex: (tab.index ?? 0) + 1,
    title: tab.title || '',
    url: tab.url,
    windowName: activeTitle,
    active: tab.active || false,
    audible: tab.audible || false,
    muted: !!(tab.mutedInfo && tab.mutedInfo.muted),
    pinned: tab.pinned || false,
    discarded: tab.discarded || false,
    groupTitle: state.groups.get(tab.groupId)?.title || ''
  };
}

// A "full snapshot" has to be authoritative, so it re-reads the browser's own
// tab list instead of serializing this worker's mirror. Any event class the
// mirror misses (see `chrome.tabs.onReplaced` below) would otherwise be re-sent
// as truth on every snapshot and never heal: the keepalive alarm deliberately
// keeps this worker — and its mirror — alive for the whole browser session, so
// a worker restart can no longer be relied on to rebuild it.
async function sendFullSnapshot() {
  if (!port) return;
  try {
    await syncTabsFromBrowser();
  } catch (e) {
    lastError = 'tab requery failed: ' + e;
  }
  const tabs = [];
  for (const tab of state.tabs.values()) {
    const record = buildTabRecord(tab);
    if (record) tabs.push(record);
  }
  sendMessage('snapshot', { tabs, capturedAt: Date.now() });
}

function sendTabDelta(tabId) {
  if (!port) return;
  const record = buildTabRecord(state.tabs.get(tabId));
  if (record) sendMessage('tabUpdated', { tab: record });
}

// Rebuilds the tab mirror from the browser's own list, discarding whatever it
// held. The single source of truth for `state.tabs` — every full snapshot goes
// through here, so a stale entry can never outlive one snapshot.
async function syncTabsFromBrowser() {
  const tabs = await chrome.tabs.query({});
  state.tabs = new Map(tabs.map((t) => [t.id, t]));

  activeTabByWindow = new Map();
  for (const t of tabs) {
    if (t.active) activeTabByWindow.set(t.windowId, t.id);
  }
}

async function refreshAll() {
  const windows = await chrome.windows.getAll({ windowTypes: ['normal'] });
  const focused = await chrome.windows.getLastFocused({});
  state.focusedWindowId = focused.id;
  windows.sort((a, b) => {
    if (a.id === focused.id) return -1;
    if (b.id === focused.id) return 1;
    return a.id - b.id;
  });
  state.windows = windows;

  const groups = await chrome.tabGroups.query({});
  state.groups = new Map(groups.map((g) => [g.id, g]));

  await syncTabsFromBrowser();
}

// Window ordering changed (created/removed/focused) → windowIndex remaps, so a
// full snapshot is the simplest correct fix. Focus changes are frequent, but
// the snapshot is small (tab records only).
async function refreshWindows() {
  const windows = await chrome.windows.getAll({ windowTypes: ['normal'] });
  const focused = state.focusedWindowId;
  windows.sort((a, b) => {
    if (focused != null && focused !== -1) {
      if (a.id === focused) return -1;
      if (b.id === focused) return 1;
    }
    return a.id - b.id;
  });
  state.windows = windows;
  await sendFullSnapshot();
}

// -- Keepalive ---------------------------------------------------------------
//
// A profile's service worker is suspended by Chrome whenever that window
// isn't the one you're actively using — normal MV3 behavior, but it silently
// stops answering the app's pings, so the app (correctly) stops trusting that
// profile's data and the whole browser's enrichment falls back to AppleScript
// until the worker happens to wake up again (a tab event, a manual switch).
// A recurring alarm is the standard, reliable way to keep a service worker
// from going idle in the first place — each firing resets Chrome's idle timer
// for this extension, independent of tab activity.
const KEEPALIVE_ALARM = 'fasttab-keepalive';

function startKeepalive() {
  // Chrome enforces a 1-minute floor on repeating alarms for packed
  // (Web Store) extensions — sub-minute periods only work unpacked, so this
  // uses the floor directly rather than relying on dev-only behavior.
  chrome.alarms.create(KEEPALIVE_ALARM, { periodInMinutes: 1 });
}

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name !== KEEPALIVE_ALARM) return;
  if (!port) { connect(); return; }
  // Waking the worker isn't enough on its own — the app only trusts a
  // connection it has actually heard from recently. Without this, a port
  // that's still open but idle (profile not in focus) ages out and the app
  // stops trusting this profile's data, even though nothing failed.
  sendResponse('heartbeat', {});
});

// -- Native port lifecycle -------------------------------------------------------

function connect() {
  if (port) return;
  try {
    port = chrome.runtime.connectNative(HOST_NAME);
  } catch (e) {
    lastError = 'connectNative threw: ' + e;
    port = null;
    return;
  }
  port.onMessage.addListener(onNativeMessage);
  port.onDisconnect.addListener(() => {
    // chrome.runtime.lastError explains *why* the port died: manifest not
    // found, extension not in allowed_origins, host failed to launch, etc.
    lastError = chrome.runtime.lastError ? (chrome.runtime.lastError.message || 'unknown error') : 'port closed';
    if (port) port = null;
    if (reconnectTimer) clearTimeout(reconnectTimer);
    // Retry while the app is (re)starting. connectNative failure also lands
    // here, so this covers "FastTab not running yet".
    reconnectTimer = setTimeout(connect, 5000);
  });
  sendMessage('hello', { app: getBrowserId(), extensionVersion: chrome.runtime.getManifest().version });
  sendFullSnapshot();
}

function onNativeMessage(msg) {
  if (!msg || msg.v !== PROTOCOL_VERSION) return; // mismatched protocol: stay silent
  const p = msg.payload || {};
  switch (msg.type) {
    case 'ping':
      sendResponse('pong', {});
      break;
    case 'resnapshot':
      sendFullSnapshot();
      break;
    case 'activateTab':
      handleActivate(p.requestID, p.tabId);
      break;
    case 'closeTab':
      handleClose(p.requestID, p.tabId);
      break;
    case 'setMuted':
      handleSetMuted(p.requestID, p.tabId, !!p.muted);
      break;
    case 'deleteBookmark':
      handleDeleteBookmark(p.requestID, p.bookmarkId, p.url);
      break;
    case 'deleteHistoryItem':
      handleDeleteHistoryItem(p.requestID, p.url);
      break;
    case 'getBookmarks':
      handleGetBookmarks(p.requestID);
      break;
    case 'searchHistory':
      handleSearchHistory(p.requestID, p.query, p.maxResults);
      break;
    default:
      break; // ignore unknown
  }
}

async function handleActivate(requestID, tabId) {
  try {
    const tab = await chrome.tabs.get(tabId);
    await chrome.tabs.update(tabId, { active: true });
    await chrome.windows.update(tab.windowId, { focused: true });
    sendResponse('commandResult', { requestID, ok: true });
  } catch (e) {
    sendResponse('commandResult', { requestID, ok: false, error: String(e) });
  }
}

async function handleClose(requestID, tabId) {
  try {
    await chrome.tabs.remove(tabId);
    sendResponse('commandResult', { requestID, ok: true });
  } catch (e) {
    sendResponse('commandResult', { requestID, ok: false, error: String(e) });
  }
}

async function handleSetMuted(requestID, tabId, muted) {
  try {
    await chrome.tabs.update(tabId, { muted });
    sendResponse('commandResult', { requestID, ok: true });
  } catch (e) {
    sendResponse('commandResult', { requestID, ok: false, error: String(e) });
  }
}

async function handleDeleteBookmark(requestID, bookmarkId, url) {
  try {
    if (bookmarkId) {
      await chrome.bookmarks.remove(String(bookmarkId));
      sendResponse('commandResult', { requestID, ok: true });
      return;
    }
    if (url) {
      const results = await chrome.bookmarks.search({ url });
      for (const bm of results) {
        await chrome.bookmarks.remove(bm.id);
      }
      sendResponse('commandResult', { requestID, ok: results.length > 0 });
      return;
    }
    sendResponse('commandResult', { requestID, ok: false, error: 'No bookmarkId or url provided' });
  } catch (e) {
    sendResponse('commandResult', { requestID, ok: false, error: String(e) });
  }
}

async function handleDeleteHistoryItem(requestID, url) {
  try {
    if (url) {
      await chrome.history.deleteUrl({ url });
      sendResponse('commandResult', { requestID, ok: true });
    } else {
      sendResponse('commandResult', { requestID, ok: false, error: 'No url provided' });
    }
  } catch (e) {
    sendResponse('commandResult', { requestID, ok: false, error: String(e) });
  }
}

async function handleGetBookmarks(requestID) {
  try {
    const tree = await chrome.bookmarks.getTree();
    sendResponse('commandResult', { requestID, ok: true, tree });
  } catch (e) {
    sendResponse('commandResult', { requestID, ok: false, error: String(e) });
  }
}

async function handleSearchHistory(requestID, query, maxResults) {
  try {
    const results = await chrome.history.search({ text: query || '', maxResults: maxResults || 100 });
    sendResponse('commandResult', { requestID, ok: true, results });
  } catch (e) {
    sendResponse('commandResult', { requestID, ok: false, error: String(e) });
  }
}

// -- Options page (status + reconnect) ------------------------------------------

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg && msg.type === 'getStatus') {
    sendResponse({ connected: !!port, error: lastError });
    return false;
  }
  if (msg && msg.type === 'reconnect') {
    if (port) {
      try { port.disconnect(); } catch (e) {}
      port = null;
    }
    connect();
    sendResponse({ ok: true });
    return false;
  }
  return false;
});

// -- Tab / window events ----------------------------------------------------------

chrome.tabs.onCreated.addListener((tab) => {
  if (tab.id == null || !tab.url) return;
  state.tabs.set(tab.id, tab);
  if (tab.active) activeTabByWindow.set(tab.windowId, tab.id);
  sendTabDelta(tab.id);
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (tabId == null || !tab.url) return;
  state.tabs.set(tabId, tab);
  const relevant = changeInfo.url !== undefined || changeInfo.title !== undefined ||
    changeInfo.audible !== undefined || changeInfo.mutedInfo !== undefined ||
    changeInfo.pinned !== undefined || changeInfo.discarded !== undefined;
  if (relevant) sendTabDelta(tabId);
});

chrome.tabs.onActivated.addListener((info) => {
  const oldId = activeTabByWindow.get(info.windowId);
  activeTabByWindow.set(info.windowId, info.tabId);

  const newTab = state.tabs.get(info.tabId);
  if (newTab) newTab.active = true;
  if (oldId !== undefined && oldId !== info.tabId) {
    const oldTab = state.tabs.get(oldId);
    if (oldTab) oldTab.active = false;
    sendTabDelta(oldId);
  }
  sendTabDelta(info.tabId);
  sendMessage('tabActivated', { tabId: info.tabId, windowId: info.windowId, at: Date.now() });
});

chrome.tabs.onRemoved.addListener((tabId, removeInfo) => {
  state.tabs.delete(tabId);
  if (activeTabByWindow.get(removeInfo.windowId) === tabId) {
    activeTabByWindow.delete(removeInfo.windowId);
  }
  sendMessage('tabRemoved', { tabId, windowId: removeInfo.windowId });
});

// Chromium swaps a tab's ID out from under the extension whenever the tab's
// underlying page is replaced rather than navigated: prerender activation, and
// waking a discarded ("sleeping") tab. No `onRemoved` fires for the pre-swap
// ID, so without this the mirror ends up holding two IDs for one physical tab
// — the app then sees the same URL twice and reports a duplicate tab the user
// does not actually have.
chrome.tabs.onReplaced.addListener((addedTabId, removedTabId) => {
  const removedTab = state.tabs.get(removedTabId);
  const windowId = removedTab ? removedTab.windowId : undefined;
  state.tabs.delete(removedTabId);
  if (windowId !== undefined && activeTabByWindow.get(windowId) === removedTabId) {
    activeTabByWindow.set(windowId, addedTabId);
  }
  sendMessage('tabRemoved', { tabId: removedTabId, windowId });
  chrome.tabs.get(addedTabId, (tab) => {
    if (chrome.runtime.lastError || !tab) return;
    state.tabs.set(addedTabId, tab);
    sendTabDelta(addedTabId);
  });
});

chrome.tabs.onMoved.addListener((tabId, moveInfo) => {
  const tab = state.tabs.get(tabId);
  if (tab) {
    tab.index = moveInfo.toIndex;
    sendTabDelta(tabId);
  }
});

chrome.tabs.onDetached.addListener((tabId) => {
  state.tabs.delete(tabId);
});

chrome.tabs.onAttached.addListener((tabId) => {
  chrome.tabs.get(tabId, (tab) => {
    if (chrome.runtime.lastError || !tab) return;
    state.tabs.set(tabId, tab);
    sendTabDelta(tabId);
  });
});

chrome.windows.onCreated.addListener(() => refreshWindows());
chrome.windows.onRemoved.addListener(() => refreshWindows());
chrome.windows.onFocusChanged.addListener((windowId) => {
  state.focusedWindowId = windowId;
  refreshWindows();
});

// -- Boot ------------------------------------------------------------------------

(async function init() {
  // Open the port FIRST so a snapshot/build error can never block the
  // connection — the app sees `hello` and pings even if the snapshot lags.
  connect();
  startKeepalive();
  try {
    await refreshAll();
    sendFullSnapshot();
  } catch (e) {
    lastError = 'snapshot build failed: ' + e;
  }
})();
