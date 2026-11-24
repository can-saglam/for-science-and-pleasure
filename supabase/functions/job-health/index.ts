// job-health: each morning (0055, 08:00 UTC) reads the last day of
// job_runs and, when a job has gone quiet or kept failing, pushes one alert
// to the phones of OPS_ALERT_USER_IDS (comma-separated user ids). Quiet
// when all is well. Also clears run rows after 30 days and MetricKit
// reports after 90.
import { sameSecret } from "../_shared/auth.ts";
import { apnsConfigured, sendApnsAlert } from "../_shared/apns.ts";
import { admin } from "../_shared/groups.ts";
import { problems, type RunRow } from "../_shared/runs.ts";

const DAY = 86_400_000;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  const expected = Deno.env.get("REMINDERS_CRON_SECRET");
  if (!expected || !sameSecret(req.headers.get("x-cron-secret"), expected)) return json({ error: "forbidden" }, 403);

  const db = admin();
  const now = new Date();
  const [runsResult] = await Promise.all([
    db.from("job_runs").select("job, ok, finished_at, detail")
      .gte("finished_at", new Date(now.getTime() - 27 * 3_600_000).toISOString())
      .order("finished_at", { ascending: false })
      .limit(2000),
    db.from("job_runs").delete().lt("finished_at", new Date(now.getTime() - 30 * DAY).toISOString()),
    db.from("metric_reports").delete().lt("received_at", new Date(now.getTime() - 90 * DAY).toISOString()),
  ]);
  const found = runsResult.error
    ? [`job-health couldn't read job_runs: ${runsResult.error.message.slice(0, 80)}`]
    : problems((runsResult.data ?? []) as RunRow[], now);
  if (found.length === 0) return json({ ok: true });

  const recipients = (Deno.env.get("OPS_ALERT_USER_IDS") ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  let sent = 0;
  if (apnsConfigured() && recipients.length > 0) {
    const { data: tokens } = await db.from("apns_tokens").select("token").in("user_id", recipients);
    const title = found.length === 1 ? "A server job needs a look" : `${found.length} server jobs need a look`;
    for (const { token } of (tokens ?? []) as { token: string }[]) {
      try {
        if (await sendApnsAlert(token, found.join("\n"), title, {}, "ops") === "sent") sent++;
      } catch (e) {
        console.error("job-health push", e);
      }
    }
  }
  console.error("job-health:", found.join(" | "));
  return json({ ok: false, problems: found, sent });
});
