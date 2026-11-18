import type { Env } from "../env";

export type IdentityProvider = "email" | "apple";

export interface IdentityInput {
  provider: IdentityProvider;
  /** Normalised email for "email"; Apple's stable `sub` for "apple" (not implemented yet). */
  subject: string;
  email: string | null;
}

/**
 * Finds the account for a sign-in identity or creates one. This is the seam
 * for Sign in with Apple: verify the Apple identity token, then call this with
 * provider "apple". Linking an Apple identity to an existing email account
 * (verified, non-relay, matching address) is a separate, explicit step.
 */
export async function findOrCreateAccount(env: Env, identity: IdentityInput, nowMs = Date.now()): Promise<{ userId: string; created: boolean }> {
  const lookup = env.DB.prepare("SELECT account_id FROM identities WHERE provider = ? AND subject = ?").bind(identity.provider, identity.subject);
  const existing = await lookup.first<{ account_id: string }>();
  if (existing) return { userId: existing.account_id, created: false };

  const userId = crypto.randomUUID();
  await env.DB.batch([
    env.DB.prepare("INSERT INTO accounts (id, created_at) VALUES (?, ?)").bind(userId, nowMs),
    env.DB.prepare(
      "INSERT INTO identities (provider, subject, account_id, email, created_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT DO NOTHING",
    ).bind(identity.provider, identity.subject, userId, identity.email, nowMs),
  ]);
  const winner = await lookup.first<{ account_id: string }>();
  if (!winner) throw new Error("identity insert failed");
  if (winner.account_id !== userId) {
    // Lost a race with a concurrent sign-in for the same identity.
    await env.DB.prepare("DELETE FROM accounts WHERE id = ?").bind(userId).run();
    return { userId: winner.account_id, created: false };
  }
  return { userId, created: true };
}
