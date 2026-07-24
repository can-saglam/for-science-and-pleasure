import { supabase } from "./supabase";

const VAPID_PUBLIC_KEY =
  "BD76JGnqvEiDqNejfDEN16tge69miGkc6cw9_NjuNauHwRDClxT3BivPSThvMKxo2fx6BW8Wz3Hij6yXUR-oJD4";

export type PushStatus = "unsupported" | "denied" | "off" | "subscribed";

function applicationServerKey(value: string): Uint8Array<ArrayBuffer> {
  const padding = "=".repeat((4 - (value.length % 4)) % 4);
  const binary = atob((value + padding).replace(/-/g, "+").replace(/_/g, "/"));
  const bytes = new Uint8Array(new ArrayBuffer(binary.length));
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export function supportsPush(): boolean {
  return (
    "serviceWorker" in navigator &&
    "PushManager" in window &&
    "Notification" in window
  );
}

export async function registerServiceWorker(): Promise<ServiceWorkerRegistration | null> {
  if (!("serviceWorker" in navigator)) return null;
  return navigator.serviceWorker.register(`${import.meta.env.BASE_URL}sw.js`, {
    scope: import.meta.env.BASE_URL,
  });
}

export async function getPushStatus(): Promise<PushStatus> {
  if (!supportsPush()) return "unsupported";
  if (Notification.permission === "denied") return "denied";
  const registration = await registerServiceWorker();
  const subscription = await registration?.pushManager.getSubscription();
  return subscription ? "subscribed" : "off";
}

export async function enablePush(): Promise<void> {
  if (!supportsPush()) throw new Error("Push notifications are not supported here.");

  const permission = await Notification.requestPermission();
  if (permission !== "granted") {
    throw new Error(
      permission === "denied"
        ? "Notifications are blocked in your device settings."
        : "Notification permission was not granted.",
    );
  }

  const registration = await registerServiceWorker();
  if (!registration) throw new Error("The notification service could not start.");

  let subscription = await registration.pushManager.getSubscription();
  subscription ??= await registration.pushManager.subscribe({
    userVisibleOnly: true,
    applicationServerKey: applicationServerKey(VAPID_PUBLIC_KEY),
  });

  const json = subscription.toJSON();
  if (!json.endpoint || !json.keys?.p256dh || !json.keys.auth) {
    throw new Error("The browser returned an incomplete push subscription.");
  }

  const { data: userData, error: userError } = await supabase.auth.getUser();
  if (userError || !userData.user) throw userError ?? new Error("You are signed out.");

  const { error } = await supabase.from("push_subscriptions").upsert(
    {
      user_id: userData.user.id,
      endpoint: json.endpoint,
      p256dh: json.keys.p256dh,
      auth: json.keys.auth,
      user_agent: navigator.userAgent,
    },
    { onConflict: "endpoint" },
  );
  if (error) {
    await subscription.unsubscribe();
    throw error;
  }
}

export async function disablePush(): Promise<void> {
  if (!supportsPush()) return;
  const registration = await registerServiceWorker();
  const subscription = await registration?.pushManager.getSubscription();
  if (!subscription) return;

  const { error } = await supabase
    .from("push_subscriptions")
    .delete()
    .eq("endpoint", subscription.endpoint);
  if (error) throw error;
  await subscription.unsubscribe();
}
