// Connections (grants) of AI tools: creation at consent, loading per request, revocation, audit.
// See docs/mcp.md. Never stores the grant secret or anything decrypted.

import { enforceLimits } from "../auth/ratelimit";
import type { Env } from "../env";
import { HttpError, utcDay } from "../util";
import { type KeyRing, unwrapRing } from "./crypto";

export const SCOPES = ["notes:read", "notes:comment", "notes:create", "notes:edit", "feedback"] as const;
export type Scope = (typeof SCOPES)[number];
export const NOTE_SCOPES: ReadonlySet<string> = new Set(["notes:read", "notes:comment", "notes:create", "notes:edit"]);
/** Pre-ticked on the consent screen. `notes:edit` is off by default. */
export const DEFAULT_SCOPES: readonly Scope[] = ["notes:read", "notes:comment", "notes:create", "feedback"];
export const DURATIONS_DAYS = [1, 7, 30, 90] as const;
export const DEFAULT_DURATION_DAYS = 30;

export const GRANT_LIMITS = {
  perGrantMinute: 60,
  perGrantDay: 1000,
  writesPerGrantHour: 60,
  perUserDay: 2000,
  auditRetentionMs: 90 * 24 * 3600 * 1000,
  endedGrantRetentionMs: 30 * 24 * 3600 * 1000,
  loginTtlMs: 15 * 60 * 1000,
  maxActivePerUser: 20,
} as const;

/** What the OAuth token carries (encrypted by the OAuth library with a key derived from the token). */
export interface GrantProps {
  userId: string;
  grantId: string;
  /** Base64 grant secret G; absent for feedback-only connections. */
  grantSecret?: string;
  scopes: string[];
  clientName: string;
}

export interface GrantRow {
  id: string;
  user_id: string;
  oauth_grant_id: string | null;
  client_id: string;
  client_name: string;
  client_domain: string | null;
  redirect_host: string;
  scopes: string;
  wrapped_ring: ArrayBuffer | null;
  created_at: number;
  expires_at: number;
  last_used_day: string | null;
  revoked_at: number | null;
}

export function parseScopes(value: string): Scope[] {
  return value.split(" ").filter((s): s is Scope => (SCOPES as readonly string[]).includes(s));
}

export function needsKey(scopes: readonly string[]): boolean {
  return scopes.some((s) => NOTE_SCOPES.has(s));
}

/** An active grant, or a 401 the tool answers by reconnecting. */
export async function activeGrant(env: Env, props: GrantProps, nowMs = Date.now()): Promise<GrantRow> {
  const row = await env.DB.prepare("SELECT * FROM mcp_grants WHERE id = ? AND user_id = ?").bind(props.grantId, props.userId).first<GrantRow>();
  if (!row || row.revoked_at !== null || row.expires_at <= nowMs) {
    throw new HttpError(401, "invalid_token", "this connection was revoked or has expired; connect Matilde again", {
      "WWW-Authenticate": 'Bearer error="invalid_token", error_description="connection revoked or expired"',
    });
  }
  return row;
}

/** Unwraps the account key ring for one request. */
export async function grantRing(row: GrantRow, props: GrantProps, base64ToBytes: (s: string) => Uint8Array | null): Promise<KeyRing | null> {
  if (!row.wrapped_ring || !props.grantSecret) return null;
  const secret = base64ToBytes(props.grantSecret);
  if (!secret) return null;
  return unwrapRing(secret, row.user_id, row.id, new Uint8Array(row.wrapped_ring));
}

export async function enforceGrantLimits(env: Env, row: GrantRow, write: boolean, nowMs = Date.now()): Promise<void> {
  const limits = [
    { key: `mcp:g:min:${row.id}`, windowSeconds: 60, max: GRANT_LIMITS.perGrantMinute },
    { key: `mcp:g:day:${row.id}`, windowSeconds: 86400, max: GRANT_LIMITS.perGrantDay },
    { key: `mcp:u:day:${row.user_id}`, windowSeconds: 86400, max: GRANT_LIMITS.perUserDay },
  ];
  if (write) limits.push({ key: `mcp:g:w:${row.id}`, windowSeconds: 3600, max: GRANT_LIMITS.writesPerGrantHour });
  await enforceLimits(env.DB, limits, nowMs);
}

/** One audit row: time, tool name and an outcome code. Never arguments or content. */
export async function audit(env: Env, row: GrantRow, tool: string, outcome: string, nowMs = Date.now()): Promise<void> {
  const day = utcDay(nowMs);
  const statements = [
    env.DB.prepare("INSERT INTO mcp_audit (grant_id, user_id, at, tool, outcome) VALUES (?, ?, ?, ?, ?)").bind(row.id, row.user_id, nowMs, tool.slice(0, 64), outcome.slice(0, 64)),
  ];
  if (row.last_used_day !== day) statements.push(env.DB.prepare("UPDATE mcp_grants SET last_used_day = ? WHERE id = ?").bind(day, row.id));
  await env.DB.batch(statements);
}

/** Revokes a connection: drops the wrapped ring (cryptographic revocation) and marks it revoked. */
export async function revokeGrantRow(env: Env, userId: string, grantId: string, nowMs = Date.now()): Promise<GrantRow | null> {
  const row = await env.DB.prepare(
    "UPDATE mcp_grants SET revoked_at = COALESCE(revoked_at, ?), wrapped_ring = NULL WHERE id = ? AND user_id = ? RETURNING *",
  )
    .bind(nowMs, grantId, userId)
    .first<GrantRow>();
  return row ?? null;
}

export interface ConnectionView {
  id: string;
  clientName: string;
  clientDomain: string | null;
  redirectHost: string;
  scopes: string[];
  createdAt: number;
  expiresAt: number;
  lastUsedDay: string | null;
}

export function connectionView(row: GrantRow): ConnectionView {
  return {
    id: row.id,
    clientName: row.client_name,
    clientDomain: row.client_domain,
    redirectHost: row.redirect_host,
    scopes: row.scopes.split(" ").filter(Boolean),
    createdAt: row.created_at,
    expiresAt: row.expires_at,
    lastUsedDay: row.last_used_day,
  };
}

export async function activeConnections(env: Env, userId: string, nowMs = Date.now()): Promise<GrantRow[]> {
  const rows = await env.DB.prepare("SELECT * FROM mcp_grants WHERE user_id = ? AND revoked_at IS NULL AND expires_at > ? ORDER BY created_at DESC")
    .bind(userId, nowMs)
    .all<GrantRow>();
  return rows.results;
}

/** Daily cron: old audit rows, ended grants, stale logins. */
export async function cleanupGrants(env: Env, nowMs = Date.now()): Promise<void> {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM mcp_audit WHERE at < ?").bind(nowMs - GRANT_LIMITS.auditRetentionMs),
    env.DB.prepare("UPDATE mcp_grants SET wrapped_ring = NULL WHERE wrapped_ring IS NOT NULL AND expires_at <= ?").bind(nowMs),
    env.DB.prepare("DELETE FROM mcp_grants WHERE COALESCE(revoked_at, expires_at) < ?").bind(nowMs - GRANT_LIMITS.endedGrantRetentionMs),
    env.DB.prepare("DELETE FROM mcp_logins WHERE expires_at < ?").bind(nowMs),
  ]);
}
