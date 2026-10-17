/** Phone push for new customer feedback (Web Push). The browser subscribes with the
 *  VAPID key from theindie-api; the dashboard server forwards the subscription to
 *  theindie-api (`server/lib/feedback_push_proxy.py`), which sends the pushes — so
 *  they arrive with the app closed and the Mac asleep. The service worker
 *  (`public/sw.js`) shows them and opens the Feedback tab on tap. */
import { useEffect } from "react";

export type PushState =
  | "insecure" // page not on https (iOS needs the tailscale serve https URL)
  | "needs-install" // iPhone Safari tab: push only works from the Home Screen app
  | "unsupported" // no service worker / PushManager in this browser
  | "denied" // the user blocked notifications for this app
  | "off" // supported, not subscribed here
  | "on"; // this device is subscribed

export interface PushEnv {
  protocol: string;
  hasServiceWorker: boolean;
  hasPushManager: boolean;
  isIOS: boolean;
  standalone: boolean;
  permission: NotificationPermission | "unsupported";
}

export function readPushEnv(): PushEnv {
  const nav = navigator as Navigator & { standalone?: boolean };
  return {
    protocol: window.location.protocol,
    hasServiceWorker: "serviceWorker" in navigator,
    hasPushManager: "PushManager" in window,
    isIOS: /iPhone|iPad|iPod/.test(navigator.userAgent),
    standalone: nav.standalone === true || window.matchMedia?.("(display-mode: standalone)").matches === true,
    permission: "Notification" in window ? Notification.permission : "unsupported",
  };
}

/** What the device can do before asking the push manager whether it is subscribed. */
export function basePushState(env: PushEnv): Exclude<PushState, "on"> {
  if (env.protocol !== "https:") return "insecure";
  if (env.isIOS && !env.standalone) return "needs-install";
  if (!env.hasServiceWorker || !env.hasPushManager || env.permission === "unsupported") return "unsupported";
  if (env.permission === "denied") return "denied";
  return "off";
}

export const PUSH_STATE_TEXT: Record<PushState, string> = {
  insecure: "Phone alerts need the https address (tailscale serve).",
  "needs-install": "Phone alerts work from the Home Screen app: Share → Add to Home Screen, then open it from there.",
  unsupported: "This browser cannot receive push notifications.",
  denied: "Notifications are blocked for this app: allow them in Settings → Notifications → AgentBar.",
  off: "Get a notification for new customer feedback, even with the app closed.",
  on: "Phone alerts on for new customer feedback.",
};

/** VAPID public key (base64url) -> bytes for PushManager.subscribe. */
export function vapidKeyBytes(base64url: string): Uint8Array<ArrayBuffer> {
  const base64 = base64url.replace(/-/g, "+").replace(/_/g, "/");
  const raw = atob(base64 + "=".repeat((4 - (base64.length % 4)) % 4));
  return Uint8Array.from(raw, (char) => char.charCodeAt(0));
}

type Reply = { ok: boolean; error?: string; [key: string]: unknown };

async function pushRequest(path: string, method = "GET", body?: unknown): Promise<Reply> {
  try {
    const response = await fetch(`/api/feedback/push/${path}`, {
      method,
      headers: body === undefined ? undefined : { "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const parsed = await response.json().catch(() => ({}));
    return { ...parsed, ok: response.ok && parsed.ok !== false };
  } catch (error) {
    return { ok: false, error: String(error) };
  }
}

export async function currentSubscription(): Promise<PushSubscription | null> {
  const registration = await navigator.serviceWorker.getRegistration();
  return (await registration?.pushManager.getSubscription()) ?? null;
}

/** Asks permission (needs a tap), subscribes, registers with theindie-api. */
export async function enableFeedbackPush(): Promise<Reply> {
  const config = await pushRequest("config");
  if (!config.ok) return config;
  if (!config.configured || typeof config.publicKey !== "string") {
    return { ok: false, error: "Push is not set up on theindie-api yet (VAPID secrets)." };
  }
  if ((await Notification.requestPermission()) !== "granted") return { ok: false, error: "Notifications were not allowed." };
  const registration = await navigator.serviceWorker.register("/sw.js");
  await navigator.serviceWorker.ready;
  let subscription = await registration.pushManager.getSubscription();
  const key = vapidKeyBytes(config.publicKey);
  if (subscription && !sameKey(subscription, key)) {
    await subscription.unsubscribe(); // server keys changed: the old subscription is dead
    subscription = null;
  }
  subscription ??= await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key });
  const json = subscription.toJSON();
  return pushRequest("subscribe", "POST", { endpoint: json.endpoint, keys: json.keys, label: deviceLabel() });
}

export async function disableFeedbackPush(): Promise<Reply> {
  const subscription = await currentSubscription();
  if (!subscription) return { ok: true };
  const reply = await pushRequest("unsubscribe", "POST", { endpoint: subscription.endpoint });
  await subscription.unsubscribe();
  return reply;
}

export const sendTestPush = () => pushRequest("test", "POST", {});

function sameKey(subscription: PushSubscription, key: Uint8Array<ArrayBuffer>): boolean {
  const current = subscription.options?.applicationServerKey;
  if (!current) return true;
  const bytes = new Uint8Array(current);
  return bytes.length === key.length && bytes.every((byte, index) => byte === key[index]);
}

function deviceLabel(): string {
  return /iPhone/.test(navigator.userAgent) ? "iPhone" : /iPad/.test(navigator.userAgent) ? "iPad" : "Browser";
}

export type OpenTab = "feedback";

/** `?tab=feedback` on launch (a tapped notification opening the app), or a
 *  message from the service worker when the app was already open. */
export function initialTabFromUrl(search: string): OpenTab | null {
  return new URLSearchParams(search).get("tab") === "feedback" ? "feedback" : null;
}

export function useOpenTabRequests(onOpen: (tab: OpenTab) => void) {
  useEffect(() => {
    if (!("serviceWorker" in navigator)) return;
    const onMessage = (event: MessageEvent) => {
      if (event.data?.type === "agentbar-open-tab" && event.data.tab === "feedback") onOpen("feedback");
    };
    navigator.serviceWorker.addEventListener("message", onMessage);
    return () => navigator.serviceWorker.removeEventListener("message", onMessage);
  }, [onOpen]);
}
