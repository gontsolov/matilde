// Entry for the MCP host (mcp.matilde.page / mcp-staging.matilde.page). The sync Worker routes
// requests for env.MCP_ORIGIN here. OAuth 2.1 (authorization code + PKCE, dynamic client
// registration, Client ID Metadata Documents, refresh tokens) is @cloudflare/workers-oauth-provider,
// stored in D1 through the KV adapter. See docs/mcp.md.

import { getOAuthApi, type OAuthHelpers, OAuthProvider, type OAuthProviderOptions } from "@cloudflare/workers-oauth-provider";
import { errorResponse } from "../app";
import type { Env } from "../env";
import { HttpError } from "../util";
import { consentFetch, type McpEnv } from "./consent";
import { type GrantProps, SCOPES } from "./grants";
import { d1Kv } from "./kv";
import { handleMcp } from "./protocol";

export const MCP_TOKEN_TTL = {
  accessSeconds: 3600,
  /** Longest connection (90 days); the connection's own expiry in D1 is checked on every call. */
  refreshSeconds: 90 * 86400,
  refreshIdleSeconds: 30 * 86400,
} as const;

function options(origin: string): OAuthProviderOptions<McpEnv> {
  return {
    apiRoute: "/mcp",
    apiHandler: {
      async fetch(request, env, ctx) {
        try {
          return await handleMcp(request, env, { props: (ctx as ExecutionContext & { props: GrantProps }).props });
        } catch (error) {
          if (error instanceof HttpError) return errorResponse(error);
          console.error(JSON.stringify({ event: "mcp_error", name: error instanceof Error ? error.name : "unknown" }));
          return errorResponse(new HttpError(500, "internal_error"));
        }
      },
    },
    defaultHandler: { fetch: (request, env) => consentFetch(request, env as McpEnv) },
    authorizeEndpoint: "/authorize",
    tokenEndpoint: "/oauth/token",
    clientRegistrationEndpoint: "/oauth/register",
    scopesSupported: [...SCOPES],
    accessTokenTTL: MCP_TOKEN_TTL.accessSeconds,
    refreshTokenTTL: MCP_TOKEN_TTL.refreshSeconds,
    refreshTokenIdleTTL: MCP_TOKEN_TTL.refreshIdleSeconds,
    clientIdMetadataDocumentEnabled: true,
    cookiePrefix: "__Host-matilde-",
    resourceMetadata: { resource: `${origin}/mcp`, resource_name: "Matilde" },
  } as OAuthProviderOptions<McpEnv>;
}

const providers = new Map<string, OAuthProvider<McpEnv>>();

function mcpEnv(env: Env): McpEnv {
  return { ...env, OAUTH_KV: d1Kv(env.DB) } as McpEnv;
}

/** A request for the MCP host. While MCP_ENABLED isn't "1" the host answers 404 (see mcpFetch). */
export function isMcpRequest(request: Request, env: Env): boolean {
  return !!env.MCP_ORIGIN && new URL(request.url).origin === env.MCP_ORIGIN;
}

export function mcpFetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  if (env.MCP_ENABLED !== "1") return Promise.resolve(errorResponse(new HttpError(404, "not_found")));
  const origin = env.MCP_ORIGIN;
  let provider = providers.get(origin);
  if (!provider) {
    provider = new OAuthProvider<McpEnv>(options(origin));
    providers.set(origin, provider);
  }
  return provider.fetch(request, mcpEnv(env), ctx);
}

/** The OAuth library's helpers outside a request on the MCP host (revocation from the apps). */
export function oauthHelpers(env: Env): OAuthHelpers {
  return getOAuthApi(options(env.MCP_ORIGIN), mcpEnv(env));
}
