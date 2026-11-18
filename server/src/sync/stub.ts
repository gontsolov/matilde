import type { Env } from "../env";

/** The user's Durable Object, always addressed by the random account id and pinned to the configured jurisdiction. */
export function userSync(env: Env, userId: string) {
  const namespace = env.DO_JURISDICTION
    ? env.USER_SYNC.jurisdiction(env.DO_JURISDICTION as DurableObjectJurisdiction)
    : env.USER_SYNC;
  return namespace.get(namespace.idFromName(userId));
}
