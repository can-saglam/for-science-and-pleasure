// Diagnostic: read the digest cron job state and recent run results.
// Run: deno run -A scripts/read-cron-state.ts   (reads .supabase.env)
import postgres from "npm:postgres@3.4.5";

const env = new TextDecoder().decode(await Deno.readFile(".supabase.env"));
const get = (name: string) =>
  env.match(new RegExp(`^${name}=(.*)$`, "m"))?.[1]?.trim();

const sql = postgres({
  host: "aws-1-eu-west-2.pooler.supabase.com",
  port: 5432,
  database: "postgres",
  username: `postgres.${get("SUPABASE_PROJECT_REF")}`,
  password: get("SUPABASE_DB_PASSWORD"),
  ssl: "require",
  prepare: false,
});

const jobs = await sql`select jobid, jobname, schedule, active from cron.job`;
console.log("jobs:", JSON.stringify(jobs, null, 2));

const runs = await sql`
  select jobid, status, return_message, start_time
  from cron.job_run_details
  order by start_time desc
  limit 8
`;
console.log("recent runs:", JSON.stringify(runs, null, 2));

await sql.end();
