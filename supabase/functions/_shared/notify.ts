// Partner notifications: push "X added: …", "X planned it for …" and "X
// joined / left your group" to the other members of the group (apns_tokens,
// written by the iOS app after sign-in). Scoped by group since 1b — a token
// outside the group never hears about it. Save pings carry the save's id,
// so a tap opens it.
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

export interface PlanNotification {
  itemId: string;
  title: string;
  groupId: string;
  plannerUserId: string;
  plannerEmail?: string | null;
  /** yyyy-MM-dd on the home clock. */
  planOn: string;
  /** HH:MM or HH:MM:SS, when the plan has a time. */
  planTime: string | null;
}

export async function notifyPartnersOfSave(
  admin: SupabaseClient,
  save: SaveNotification,
): Promise<{ sent: number; failed: number }> {
  if (!apnsConfigured()) return { sent: 0, failed: 0 };
  const name = await displayName(admin, save.adderUserId, save.adderEmail);
  const body = `${name} added ${save.title}${save.venue ? ` at ${save.venue}` : ""}`;
  return await pushToGroup(admin, save.groupId, save.adderUserId, "Can We Go?", body, save.itemId);
}

export async function notifyPartnersOfPlan(
  admin: SupabaseClient,
  plan: PlanNotification,
): Promise<{ sent: number; failed: number }> {
  if (!apnsConfigured()) return { sent: 0, failed: 0 };
  const name = await displayName(admin, plan.plannerUserId, plan.plannerEmail);
  const body = `${name} planned it for ${planLine(plan.planOn, plan.planTime)}`;
  return await pushToGroup(admin, plan.groupId, plan.plannerUserId, plan.title, body, plan.itemId);
}

export type MemberChange = "joined" | "left";

/** "Joyce joined your group", and what it means for the library. */
export function memberLine(name: string, change: MemberChange, broughtSaves = false): string {
  if (change === "left") return `${name} left your group. Everything saved stays here.`;
  return broughtSaves
    ? `${name} joined your group. Their saves are in the library now.`
    : `${name} joined your group`;
}

/** Everyone else in `groupId` hears that `userId` came or went. Never
 *  throws: a missed ping mustn't undo a join or a leave. */
export async function notifyGroupOfMember(
  admin: SupabaseClient,
  member: { groupId: string; userId: string; name: string; change: MemberChange; broughtSaves?: boolean },
): Promise<{ sent: number; failed: number }> {
  if (!apnsConfigured()) return { sent: 0, failed: 0 };
  try {
    const body = memberLine(member.name, member.change, member.broughtSaves);
    return await pushToGroup(admin, member.groupId, member.userId, "Can We Go?", body);
  } catch (error) {
    console.error("member ping", error);
    return { sent: 0, failed: 1 };
  }
}

/** "Saturday 17 October", or "Saturday 17 October at 14:00". */
export function planLine(day: string, time: string | null): string {
  const [y, m, d] = day.split("-").map(Number);
  const date = new Date(Date.UTC(y, m - 1, d, 12));
  const weekday = date.toLocaleDateString("en-GB", { weekday: "long", timeZone: "UTC" });
  const month = date.toLocaleDateString("en-GB", { month: "long", timeZone: "UTC" });
  const line = `${weekday} ${d} ${month}`;
  return time ? `${line} at ${time.slice(0, 5)}` : line;
}

async function pushToGroup(
  admin: SupabaseClient,
  groupId: string,
  actorUserId: string | null,
  title: string,
  body: string,
  itemId?: string,
): Promise<{ sent: number; failed: number }> {
  const tokens = await groupTokens(admin, groupId, actorUserId);
  let sent = 0;
  let failed = 0;
  for (const token of tokens) {
    try {
      const result = await sendApnsAlert(token, body, title, itemId ? { itemID: itemId } : {}, groupId);
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
