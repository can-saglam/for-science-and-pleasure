// Every scheduled job leaves a row in job_runs (0055) when it finishes, so
// job-health can tell a job that stopped from one with nothing to do.
// Recording never fails the job: a missing row reads as a missed run,
// which is the right alarm anyway.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.117.3";

export async function recordRun(
  db: SupabaseClient,
  job: string,
  startedAt: Date,
  ok: boolean,
  detail: Record<string, unknown>,
): Promise<void> {
  try {
    const { error } = await db.from("job_runs").insert({
      job,
      started_at: startedAt.toISOString(),
      finished_at: new Date().toISOString(),
      ok,
      detail,
    });
    if (error) console.error("job_runs", job, error.message);
  } catch (e) {
    console.error("job_runs", job, e);
  }
}

/// Records the run from the response a job is about to send: ok when it
/// succeeded, the body as the summary.
export async function recordResponse(db: SupabaseClient, job: string, startedAt: Date, res: Response): Promise<Response> {
  const detail = await res.clone().json().catch(() => ({})) as Record<string, unknown>;
  await recordRun(db, job, startedAt, res.ok && !detail.error, detail);
  return res;
}

/// How long each job may go without a good run before someone hears,
/// in minutes: three missed turns for the frequent ones, a missed night
/// with some slack for the nightly one. send-reminders isn't here: it's
/// only called for groups with something due, so quiet is normal; the
/// reminders tick that decides is. Its failures still count.
export const EXPECTED: Record<string, number> = {
  "reminders-tick": 60,
  "warm-cities": 60,
  "verify-entitlements": 3 * 60,
  "purge-nightly": 26 * 60,
};

export interface RunRow {
  job: string;
  ok: boolean;
  finished_at: string;
  detail: Record<string, unknown> | null;
}

/// What's wrong, one line per job, from the last day's runs: a job with no
/// good run inside its window, and failures since the last check.
export function problems(runs: RunRow[], now: Date, expected = EXPECTED): string[] {
  const out: string[] = [];
  const jobs = [...new Set([...Object.keys(expected), ...runs.map((r) => r.job)])];
  for (const job of jobs) {
    const minutes = expected[job];
    const mine = runs.filter((r) => r.job === job);
    const lastOk = mine.filter((r) => r.ok).map((r) => Date.parse(r.finished_at)).sort((a, b) => b - a)[0];
    const failures = mine
      .filter((r) => !r.ok && now.getTime() - Date.parse(r.finished_at) <= 24 * 3_600_000)
      .sort((a, b) => Date.parse(b.finished_at) - Date.parse(a.finished_at));
    if (minutes !== undefined && (lastOk === undefined || now.getTime() - lastOk > minutes * 60_000)) {
      out.push(lastOk === undefined ? `${job} hasn't finished a run in a day` : `${job} last finished ${ago(now.getTime() - lastOk)} ago`);
    } else if (failures.length > 0) {
      const what = failures[0].detail?.error;
      out.push(`${job} failed ${failures.length === 1 ? "once" : `${failures.length} times`}${typeof what === "string" ? `: ${what.slice(0, 80)}` : ""}`);
    }
  }
  return out;
}

function ago(ms: number): string {
  const hours = Math.floor(ms / 3_600_000);
  return hours >= 1 ? `${hours} h` : `${Math.max(1, Math.round(ms / 60_000))} min`;
}
