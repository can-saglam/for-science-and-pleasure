// Sign in with Apple token revocation, for account deletion. Apple wants
// the app's access revoked when an account goes; the app asks Apple for a
// fresh authorization code at delete time and this trades it for a
// refresh token and revokes that. Configured by three secrets (one .p8
// key with Sign in with Apple enabled):
//   SIWA_KEY_ID       — the key's 10-char id
//   SIWA_TEAM_ID      — the developer team id
//   SIWA_PRIVATE_KEY  — the .p8 file contents (PKCS#8 PEM)
import { decodeJwt, importPKCS8, SignJWT } from "npm:jose@5";

const CLIENT_ID = "com.cansaglam.CanWeGo";
const APPLE = "https://appleid.apple.com";

export function siwaConfigured(): boolean {
  return Boolean(
    Deno.env.get("SIWA_KEY_ID") &&
      Deno.env.get("SIWA_TEAM_ID") &&
      Deno.env.get("SIWA_PRIVATE_KEY"),
  );
}

async function clientSecret(): Promise<string> {
  const key = await importPKCS8(Deno.env.get("SIWA_PRIVATE_KEY")!, "ES256");
  return await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: Deno.env.get("SIWA_KEY_ID")! })
    .setIssuer(Deno.env.get("SIWA_TEAM_ID")!)
    .setIssuedAt()
    .setExpirationTime("5m")
    .setAudience(APPLE)
    .setSubject(CLIENT_ID)
    .sign(key);
}

export type RevokeOutcome = "revoked" | "not_configured" | "wrong_account" | "failed";

/**
 * Trades `code` for the app's refresh token and revokes it, but only when
 * the code belongs to `appleSub` (the Apple ID the account signed in
 * with), so one account's deletion can never revoke someone else's.
 */
export async function revokeAppleAccess(code: string, appleSub: string | null): Promise<RevokeOutcome> {
  if (!siwaConfigured()) return "not_configured";
  if (!appleSub) return "wrong_account";
  const signal = AbortSignal.timeout(8000);
  const secret = await clientSecret();

  const exchange = await fetch(`${APPLE}/auth/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: CLIENT_ID,
      client_secret: secret,
      code,
      grant_type: "authorization_code",
    }),
    signal,
  });
  if (!exchange.ok) {
    console.error("siwa exchange", exchange.status, await exchange.text().catch(() => ""));
    return "failed";
  }
  const tokens = await exchange.json() as { refresh_token?: string; access_token?: string; id_token?: string };

  let sub: string | undefined;
  try {
    sub = tokens.id_token ? decodeJwt(tokens.id_token).sub : undefined;
  } catch {
    sub = undefined;
  }
  if (sub !== appleSub) return "wrong_account";

  const token = tokens.refresh_token ?? tokens.access_token;
  if (!token) return "failed";
  const revoke = await fetch(`${APPLE}/auth/revoke`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: CLIENT_ID,
      client_secret: secret,
      token,
      token_type_hint: tokens.refresh_token ? "refresh_token" : "access_token",
    }),
    signal,
  });
  if (!revoke.ok) {
    console.error("siwa revoke", revoke.status, await revoke.text().catch(() => ""));
    return "failed";
  }
  return "revoked";
}
