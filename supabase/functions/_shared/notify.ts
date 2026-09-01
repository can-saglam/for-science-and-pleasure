// Partner-save notifications: push "X added: …" to the other member's
// iPhones via APNs (apns_tokens, written by the iOS app after sign-in).
// Web push is retired — the PWA isn't used anymore.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { apnsConfigured, sendApnsAlert } from "./apns.ts";

export interface SaveNotification {
  itemId: string;
  title: string;
  venue: string | null;
  adderUserId?: string | null;
  adderEmail?: string | null;
}

export async function notifyPartnersOfSave(
  admin: SupabaseClient,
  save: SaveNotification,
): Promise<{ sent: number; failed: number }> {
  if (!apnsConfigured()) return { sent: 0, failed: 0 };

  let name = save.adderEmail?.split("@")[0] ?? "Someone";
  if (save.adderEmail) {
    const { data: member } = await admin
      .from("members")
      .select("display_name")
      .eq("email", save.adderEmail)
      .maybeSingle();
    if (member?.display_name) name = member.display_name;
  }

  const { data: tokens } = await admin
    .from("apns_tokens")
    .select("token, email");
  const adderEmail = save.adderEmail?.toLowerCase();
  const iphones = (tokens ?? []).filter(
    (t: { token: string; email: string }) =>
      !adderEmail || t.email.toLowerCase() !== adderEmail,
  );

  const body = `${name} added: ${save.title}${save.venue ? ` — ${save.venue}` : ""}`;
  let sent = 0;
  let failed = 0;
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

  return { sent, failed };
}
