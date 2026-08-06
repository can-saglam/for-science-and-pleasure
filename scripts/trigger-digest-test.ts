// Manual digest push test: reads the cron secret from Vault, then invokes
// send-digest with force=true and prints per-push results.
// Run: deno run -A scripts/trigger-digest-test.ts
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
const rows = await sql`
  select decrypted_secret from vault.decrypted_secrets
  where name = 'weekly_digest_cron_secret'
`;
await sql.end();
const secret = rows[0]?.decrypted_secret;
if (!secret) throw new Error("cron secret not found in vault");

const res = await fetch(`${get("SUPABASE_URL")}/functions/v1/send-digest`, {
  method: "POST",
  headers: {
    "x-cron-secret": secret,
    "Content-Type": "application/json",
    Authorization: `Bearer ${get("SUPABASE_ANON_KEY")}`,
  },
  body: JSON.stringify({ force: true }),
});
console.log("HTTP", res.status);
console.log(JSON.stringify(await res.json(), null, 2));
