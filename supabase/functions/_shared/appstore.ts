// App Store Server API: the authoritative answer to "is this subscription
// active, and until when?". record-entitlement asks when a phone reports a
// purchase; verify-entitlements asks nightly for every subscriber, so a
// lapse lands within a day even if the subscriber never opens the app.
//
// The phone's own JWS is only used to learn *which* transaction to ask
// about. What gets stored comes from Apple's reply over TLS, so there is
// no certificate chain to check here.
//
// Configured by one In-App Purchase key from App Store Connect
// (Users and Access → Integrations → In-App Purchase):
//   ASC_ISSUER_ID     — the issuer id shown above the keys
//   ASC_KEY_ID        — the key's 10-char id
//   ASC_PRIVATE_KEY   — the .p8 file contents (PKCS#8 PEM)
import { importPKCS8, SignJWT } from "npm:jose@5";

export const BUNDLE_ID = "com.cansaglam.CanWeGo";
export const PLUS_PRODUCTS = new Set([
  "com.cansaglam.CanWeGo.plus.monthly",
  "com.cansaglam.CanWeGo.plus.yearly",
]);

const HOSTS = {
  Production: "https://api.storekit.itunes.apple.com",
  Sandbox: "https://api.storekit-sandbox.itunes.apple.com",
} as const;
export type Environment = keyof typeof HOSTS;

export function appStoreConfigured(): boolean {
  return Boolean(
    Deno.env.get("ASC_ISSUER_ID") && Deno.env.get("ASC_KEY_ID") && Deno.env.get("ASC_PRIVATE_KEY"),
  );
}

let cached: { token: string; expires: number } | null = null;

async function token(): Promise<string> {
  // Apple rejects tokens that live longer than an hour.
  if (cached && Date.now() < cached.expires) return cached.token;
  const key = await importPKCS8(Deno.env.get("ASC_PRIVATE_KEY")!, "ES256");
  const jwt = await new SignJWT({ bid: BUNDLE_ID })
    .setProtectedHeader({ alg: "ES256", kid: Deno.env.get("ASC_KEY_ID")!, typ: "JWT" })
    .setIssuer(Deno.env.get("ASC_ISSUER_ID")!)
    .setAudience("appstoreconnect-v1")
    .setIssuedAt()
    .setExpirationTime("50m")
    .sign(key);
  cached = { token: jwt, expires: Date.now() + 45 * 60 * 1000 };
  return jwt;
}

/** The payload of a JWS, unverified. Only for data that came from Apple
 * over TLS, or to pick out an id that is then looked up with Apple. */
export function jwsPayload<T = Record<string, unknown>>(jws: string): T | null {
  const part = jws.split(".")[1];
  if (!part) return null;
  try {
    const b64 = part.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(part.length / 4) * 4, "=");
    return JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)))) as T;
  } catch {
    return null;
  }
}

type TransactionInfo = {
  originalTransactionId: string;
  productId: string;
  bundleId: string;
  expiresDate?: number;
  revocationDate?: number;
  appAccountToken?: string;
};

type RenewalInfo = { gracePeriodExpiresDate?: number };

export type Subscription = {
  environment: Environment;
  originalTransactionId: string;
  productId: string;
  /** Apple's status: 1 active, 2 expired, 3 billing retry, 4 grace period, 5 revoked. */
  status: number;
  /** When access ends: the paid period, or the grace period if longer. */
  expiresAt: Date | null;
  revoked: boolean;
  /** The account id the app attached at purchase (lowercased), if any. */
  appAccountToken: string | null;
};

/** The subscription behind `transactionId`, asked of production first and
 * then the sandbox (TestFlight and App Review buy in the sandbox). Null if
 * neither environment knows it, or it isn't one of ours. */
export async function subscriptionStatus(transactionId: string): Promise<Subscription | null> {
  for (const environment of ["Production", "Sandbox"] as const) {
    const res = await fetch(`${HOSTS[environment]}/inApps/v1/subscriptions/${encodeURIComponent(transactionId)}`, {
      headers: { Authorization: `Bearer ${await token()}` },
      signal: AbortSignal.timeout(10_000),
    });
    // Production answers 401 until the app's first release is live; the
    // sandbox still knows TestFlight purchases, and a bad key 401s there too.
    if (res.status === 404 || (environment === "Production" && res.status === 401)) continue;
    if (!res.ok) throw new Error(`App Store Server API ${environment} ${res.status}: ${await res.text()}`);
    const body = await res.json() as {
      bundleId?: string;
      data?: { lastTransactions?: { status: number; signedTransactionInfo: string; signedRenewalInfo?: string }[] }[];
    };
    if (body.bundleId && body.bundleId !== BUNDLE_ID) return null;
    const last = (body.data ?? []).flatMap((g) => g.lastTransactions ?? [])
      .map((t) => ({
        status: t.status,
        txn: jwsPayload<TransactionInfo>(t.signedTransactionInfo),
        renewal: t.signedRenewalInfo ? jwsPayload<RenewalInfo>(t.signedRenewalInfo) : null,
      }))
      .filter((t) => t.txn && PLUS_PRODUCTS.has(t.txn.productId) && t.txn.bundleId === BUNDLE_ID);
    if (last.length === 0) return null;
    // One subscription group, so normally one entry; prefer whichever runs latest.
    const best = last.sort((a, b) => (b.txn!.expiresDate ?? 0) - (a.txn!.expiresDate ?? 0))[0];
    const txn = best.txn!;
    const paid = txn.expiresDate ?? 0;
    const grace = best.status === 4 ? best.renewal?.gracePeriodExpiresDate ?? 0 : 0;
    const end = Math.max(paid, grace);
    return {
      environment,
      originalTransactionId: txn.originalTransactionId,
      productId: txn.productId,
      status: best.status,
      expiresAt: end ? new Date(end) : null,
      revoked: best.status === 5 || Boolean(txn.revocationDate),
      appAccountToken: txn.appAccountToken?.toLowerCase() ?? null,
    };
  }
  return null;
}

/** The entitlement row a subscription earns. Revoked means no access, now. */
export function entitlementRow(userId: string, sub: Subscription) {
  const now = new Date();
  return {
    user_id: userId,
    tier: "plus",
    source: "app_store",
    original_transaction_id: sub.originalTransactionId,
    product_id: sub.productId,
    environment: sub.environment,
    expires_at: (sub.revoked ? now : sub.expiresAt ?? now).toISOString(),
    revoked_at: sub.revoked ? now.toISOString() : null,
  };
}
