// Partner-save notifications: push "X added: …" to the other members of
// the saver's group (apns_tokens, written by the iOS app after sign-in).
// Scoped by group since 1b — a token outside the group never hears about it.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { apnsConfigured, sendApnsAlert } from "./apns.ts";
import { displayName, groupTokens } from "./groups.ts";

export interface SaveNotification {
  itemId: string;
  title: string;
  venue: string | null;
  groupId: string;
  adderUserId: string | null;
  adderEmail?: string | null;
}

export async function notifyPartnersOfSave(
  admin: SupabaseClient,
  save: SaveNotification,
): Promise<{ sent: number; failed: number }> {
  if (!apnsConfigured()) return { sent: 0, failed: 0 };

  const name = await displayName(admin, save.adderUserId, save.adderEmail);
  const tokens = await groupTokens(admin, save.groupId, save.adderUserId);

  const body = `${name} added: ${save.title}${save.venue ? ` — ${save.venue}` : ""}`;
  let sent = 0;
  let failed = 0;
  for (const token of tokens) {
    try {
      const result = await sendApnsAlert(token, body);
      if (result === "sent") {
        sent++;
      } else if (result === "gone") {
        await admin.from("apns_tokens").delete().eq("token", token);
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
