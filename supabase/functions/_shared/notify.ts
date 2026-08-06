// Partner-save notifications: push "X added: …" to every device except the
// adder's own. Used by notify-save (in-app saves) and ingest (shortcut saves).
// Web devices get web push (push_subscriptions); iPhones get APNs
// (apns_tokens, written by the iOS app after sign-in).
import { buildPushHTTPRequest } from "npm:@pushforge/builder@2.0.5";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { apnsConfigured, sendApnsAlert } from "./apns.ts";

interface SubscriptionRow {
  id: string;
  endpoint: string;
  p256dh: string;
  auth: string;
  user_id: string | null;
}

function isAllowedPushEndpoint(endpoint: string): boolean {
  try {
    const { hostname, protocol } = new URL(endpoint);
    if (protocol !== "https:") return false;
    return (
      hostname === "fcm.googleapis.com" ||
      hostname.endsWith(".push.apple.com") ||
      hostname.endsWith(".push.services.mozilla.com")
    );
  } catch {
    return false;
  }
}

export interface SaveNotification {
  itemId: string;
  title: string;
  venue: string | null;
  /** Prefer the auth user id; fall back to email lookup for ingest. */
  adderUserId?: string | null;
  adderEmail?: string | null;
}

export async function notifyPartnersOfSave(
  admin: SupabaseClient,
  save: SaveNotification,
): Promise<{ sent: number; failed: number }> {
  let adderId = save.adderUserId ?? null;
  if (!adderId && save.adderEmail) {
    const { data } = await admin.auth.admin.listUsers();
    adderId =
      data?.users.find(
        (u) => u.email?.toLowerCase() === save.adderEmail!.toLowerCase(),
      )?.id ?? null;
  }

  const { data: subscriptions, error } = await admin
    .from("push_subscriptions")
    .select("id, endpoint, p256dh, auth, user_id");
  if (error) throw error;

  const targets = ((subscriptions ?? []) as SubscriptionRow[]).filter(
    (s) => !adderId || s.user_id !== adderId,
  );

  let name = save.adderEmail?.split("@")[0] ?? "Someone";
  if (save.adderEmail) {
    const { data: member } = await admin
      .from("members")
      .select("display_name")
      .eq("email", save.adderEmail)
      .maybeSingle();
    if (member?.display_name) name = member.display_name;
  }

  const privateJWK = JSON.parse(Deno.env.get("VAPID_PRIVATE_JWK")!);
  const adminContact = Deno.env.get("VAPID_SUBJECT")!;
  const appUrl =
    `https://can-saglam.github.io/for-science-and-pleasure/?item=${save.itemId}`;

  let sent = 0;
  let failed = 0;
  for (const subscription of targets) {
    if (!isAllowedPushEndpoint(subscription.endpoint)) {
      failed++;
      continue;
    }
    try {
      const pushRequest = await buildPushHTTPRequest({
        privateJWK,
        subscription: {
          endpoint: subscription.endpoint,
          keys: { p256dh: subscription.p256dh, auth: subscription.auth },
        },
        message: {
          payload: {
            title: "Can We Go?",
            body: `${name} added: ${save.title}${save.venue ? ` — ${save.venue}` : ""}`,
            icon:
              "https://can-saglam.github.io/for-science-and-pleasure/icon-192.png",
            tag: "partner-save",
            data: { url: appUrl },
          },
          adminContact,
          options: { ttl: 86400, urgency: "normal" },
        },
      });
      const response = await fetch(pushRequest.endpoint, {
        method: "POST",
        headers: pushRequest.headers,
        body: pushRequest.body,
        redirect: "error",
      });
      if (response.ok) {
        sent++;
      } else if (response.status === 404 || response.status === 410) {
        await admin.from("push_subscriptions").delete().eq("id", subscription.id);
      } else {
        failed++;
        console.error("partner push failed", response.status, await response.text());
      }
    } catch (error) {
      failed++;
      console.error("partner push error", error);
    }
  }

  // Native iOS devices, keyed by member email rather than auth user id.
  if (apnsConfigured()) {
    const { data: tokens } = await admin
      .from("apns_tokens")
      .select("token, email");
    const adderEmail = save.adderEmail?.toLowerCase();
    const iphones = (tokens ?? []).filter(
      (t: { token: string; email: string }) =>
        !adderEmail || t.email.toLowerCase() !== adderEmail,
    );
    const body = `${name} added: ${save.title}${save.venue ? ` — ${save.venue}` : ""}`;
    for (const device of iphones) {
      try {
        const result = await sendApnsAlert(device.token, body);
        if (result === "sent") {
          sent++;
        } else if (result === "gone") {
          await admin.from("apns_tokens").delete().eq("token", device.token);
        } else {
          failed++;
        }
      } catch (error) {
        failed++;
        console.error("apns error", error);
      }
    }
  }

  return { sent, failed };
}
