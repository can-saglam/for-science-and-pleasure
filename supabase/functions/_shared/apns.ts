// Minimal APNs client for edge functions: ES256 provider token + HTTP/2
// alert pushes. Configured by three secrets (all from one .p8 auth key):
//   APNS_KEY_ID       — the key's 10-char id
//   APNS_TEAM_ID      — the developer team id
//   APNS_PRIVATE_KEY  — the .p8 file contents (PKCS#8 PEM)
import { importPKCS8, SignJWT } from "npm:jose@5";

const TOPIC = "com.cansaglam.CanWeGo";

export function apnsConfigured(): boolean {
  return Boolean(
    Deno.env.get("APNS_KEY_ID") &&
      Deno.env.get("APNS_TEAM_ID") &&
      Deno.env.get("APNS_PRIVATE_KEY"),
  );
}

let cached: { token: string; expires: number } | null = null;

async function providerToken(): Promise<string> {
  // APNs accepts tokens for up to an hour; refresh at 50 minutes.
  if (cached && Date.now() < cached.expires) return cached.token;
  const key = await importPKCS8(Deno.env.get("APNS_PRIVATE_KEY")!, "ES256");
  const token = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: Deno.env.get("APNS_KEY_ID")! })
    .setIssuer(Deno.env.get("APNS_TEAM_ID")!)
    .setIssuedAt()
    .sign(key);
  cached = { token, expires: Date.now() + 50 * 60 * 1000 };
  return token;
}

export type ApnsResult = "sent" | "gone" | "failed";

/** Sends one alert push. Tries production first, then the sandbox so
 * Xcode-installed dev builds get pushes too (TestFlight uses production). */
export async function sendApnsAlert(
  deviceToken: string,
  body: string,
  title = "Can We Go?",
): Promise<ApnsResult> {
  const payload = JSON.stringify({
    aps: { alert: { title, body }, sound: "default" },
  });
  const auth = await providerToken();

  for (const host of ["api.push.apple.com", "api.sandbox.push.apple.com"]) {
    const response = await fetch(`https://${host}/3/device/${deviceToken}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${auth}`,
        "apns-topic": TOPIC,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "content-type": "application/json",
      },
      body: payload,
    });
    if (response.ok) return "sent";
    if (response.status === 410) return "gone";

    const text = await response.text();
    // Wrong environment: production rejects sandbox device tokens as bad,
    // and environment-restricted keys as 403 — retry the sandbox host.
    if (response.status === 400 && text.includes("BadDeviceToken")) continue;
    if (response.status === 403 && text.includes("BadEnvironmentKeyInToken")) continue;
    console.error("apns push failed", host, response.status, text);
    return "failed";
  }
  return "gone"; // bad token in both environments — safe to prune
}
