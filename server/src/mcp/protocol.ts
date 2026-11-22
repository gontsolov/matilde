// The MCP endpoint (/mcp): Streamable HTTP, stateless, JSON responses (no SSE, no sessions).
// Only reached through the OAuth provider, which has already validated the bearer token.

import { RateLimitError } from "../auth/ratelimit";
import type { Env } from "../env";
import { base64ToBytes, HttpError } from "../util";
import { activeGrant, audit, enforceGrantLimits, type GrantProps, grantRing } from "./grants";
import { Notes, ToolError } from "./notes";
import { type Tool, toolsFor } from "./tools";

export const PROTOCOL_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
export const SERVER_INFO = { name: "matilde", title: "Matilde", version: "1.0.0" };
const MAX_REQUEST_BYTES = 2 * 1024 * 1024;

const INSTRUCTIONS =
  "Matilde is the user's writing app. These tools read and change the user's own notes (Markdown). " +
  "Find notes with list_notes or search_notes, then read_note. Prefer add_comment for suggestions; use edit_note only when the user asks for changes in the note itself. " +
  "Use leave_feedback only when the user asks to send feedback about Matilde.";

interface RpcRequest {
  jsonrpc: "2.0";
  id?: string | number | null;
  method: string;
  params?: Record<string, unknown>;
}

type RpcResponse = { jsonrpc: "2.0"; id: string | number | null; result?: unknown; error?: { code: number; message: string; data?: unknown } };

const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...headers } });

function rpcError(id: RpcRequest["id"], code: number, message: string): RpcResponse {
  return { jsonrpc: "2.0", id: id ?? null, error: { code, message } };
}

export interface McpRequestContext {
  props: GrantProps;
}

export async function handleMcp(request: Request, env: Env, ctx: McpRequestContext, nowMs = Date.now()): Promise<Response> {
  if (request.method === "GET" || request.method === "DELETE") {
    return new Response(null, { status: 405, headers: { Allow: "POST" } });
  }
  if (request.method !== "POST") return new Response(null, { status: 405, headers: { Allow: "POST" } });
  if (Number(request.headers.get("Content-Length") ?? 0) > MAX_REQUEST_BYTES) return json(rpcError(null, -32600, "request too large"), 413);
  const text = await request.text();
  if (text.length > MAX_REQUEST_BYTES) return json(rpcError(null, -32600, "request too large"), 413);
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    return json(rpcError(null, -32700, "parse error"), 400);
  }

  // Every call checks the grant in D1: revoked or expired connections stop at once.
  const grant = await activeGrant(env, ctx.props, nowMs);
  const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
  const scopes = grant.scopes.split(" ").filter((s) => ctx.props.scopes.includes(s));

  const messages = Array.isArray(body) ? body : [body];
  const responses: RpcResponse[] = [];
  for (const message of messages) {
    const response = await handleMessage(message, { env, grant, props: ctx.props, scopes, ip, nowMs });
    if (response) responses.push(response);
  }
  if (responses.length === 0) return new Response(null, { status: 202 });
  return json(Array.isArray(body) ? responses : responses[0]);
}

interface MessageContext {
  env: Env;
  grant: Awaited<ReturnType<typeof activeGrant>>;
  props: GrantProps;
  scopes: string[];
  ip: string;
  nowMs: number;
}

async function handleMessage(raw: unknown, c: MessageContext): Promise<RpcResponse | null> {
  if (typeof raw !== "object" || raw === null || (raw as RpcRequest).jsonrpc !== "2.0") return rpcError(null, -32600, "invalid request");
  const message = raw as RpcRequest;
  if (typeof message.method !== "string") {
    // A response or something else from the client: nothing to answer.
    return null;
  }
  const isNotification = message.id === undefined;
  if (isNotification) return null;
  const id = message.id ?? null;
  const params = (message.params ?? {}) as Record<string, unknown>;

  switch (message.method) {
    case "initialize": {
      const requested = typeof params.protocolVersion === "string" ? params.protocolVersion : PROTOCOL_VERSIONS[0]!;
      const version = PROTOCOL_VERSIONS.includes(requested) ? requested : PROTOCOL_VERSIONS[0]!;
      return { jsonrpc: "2.0", id, result: { protocolVersion: version, capabilities: { tools: { listChanged: false } }, serverInfo: SERVER_INFO, instructions: INSTRUCTIONS } };
    }
    case "ping":
      return { jsonrpc: "2.0", id, result: {} };
    case "tools/list":
      return {
        jsonrpc: "2.0",
        id,
        result: {
          tools: toolsFor(c.scopes).map((t) => ({ name: t.name, title: t.title, description: t.description, inputSchema: t.inputSchema, annotations: { title: t.title, ...t.annotations } })),
        },
      };
    case "resources/list":
      return { jsonrpc: "2.0", id, result: { resources: [] } };
    case "resources/templates/list":
      return { jsonrpc: "2.0", id, result: { resourceTemplates: [] } };
    case "prompts/list":
      return { jsonrpc: "2.0", id, result: { prompts: [] } };
    case "tools/call":
      return { jsonrpc: "2.0", id, result: await callTool(params, c) };
    default:
      return rpcError(id, -32601, `method not found: ${message.method}`);
  }
}

function toolResult(value: unknown, isError = false) {
  const structured = typeof value === "object" && value !== null && !Array.isArray(value) ? value : { value };
  return { content: [{ type: "text", text: JSON.stringify(value, null, 1) }], structuredContent: structured, isError };
}

async function callTool(params: Record<string, unknown>, c: MessageContext) {
  const name = typeof params.name === "string" ? params.name : "";
  const tool: Tool | undefined = toolsFor(c.scopes).find((t) => t.name === name);
  const auditName = tool ? tool.name : "unknown";
  if (!tool) {
    await audit(c.env, c.grant, auditName, "not_allowed", c.nowMs);
    return toolResult({ error: "not_allowed", message: `This connection can't use ${name || "that tool"}. The user can reconnect Matilde with more permissions.` }, true);
  }
  try {
    await enforceGrantLimits(c.env, c.grant, tool.write, c.nowMs);
  } catch (error) {
    if (error instanceof RateLimitError) {
      await audit(c.env, c.grant, auditName, "rate_limited", c.nowMs);
      return toolResult({ error: "rate_limited", message: `Too many requests; try again in ${error.headers?.["Retry-After"] ?? "60"} seconds.` }, true);
    }
    throw error;
  }
  let notes: Notes | null = null;
  const ring = await grantRing(c.grant, c.props, base64ToBytes).catch(() => null);
  const args = (typeof params.arguments === "object" && params.arguments !== null ? params.arguments : {}) as Record<string, unknown>;
  try {
    const value = await tool.run(args, {
      env: c.env,
      grant: c.grant,
      ip: c.ip,
      nowMs: c.nowMs,
      notes() {
        if (!ring) throw new ToolError("no_notes_access", "This connection has no access to notes.");
        notes ??= new Notes(c.env, ring, c.grant.id);
        return notes;
      },
    });
    await audit(c.env, c.grant, auditName, "ok", c.nowMs);
    console.log(JSON.stringify({ event: "mcp_tool", tool: auditName, outcome: "ok" }));
    return toolResult(value);
  } catch (error) {
    const code = error instanceof ToolError ? error.code : error instanceof HttpError ? error.code : "internal";
    await audit(c.env, c.grant, auditName, code, c.nowMs);
    console.log(JSON.stringify({ event: "mcp_tool", tool: auditName, outcome: code }));
    if (error instanceof ToolError) return toolResult({ error: error.code, message: error.message }, true);
    if (error instanceof HttpError && error.status === 429) return toolResult({ error: "rate_limited", message: "Too many requests; try again later." }, true);
    console.error(JSON.stringify({ event: "mcp_tool_error", tool: auditName, name: error instanceof Error ? error.name : "unknown" }));
    return toolResult({ error: "internal", message: "Something went wrong in Matilde. Try again later." }, true);
  }
}
