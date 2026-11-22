import type { Env } from "../env";
import type { FeedbackInput, FeedbackKind } from "./validate";

export const LINEAR_API_URL = "https://api.linear.app/graphql";

/** What is stored in `feedback.payload` and turned into the issue. */
export interface FeedbackPayload extends FeedbackInput {
  signedIn: boolean;
}

export class LinearError extends Error {
  /** Short code for logs and `feedback.last_error`; never contains feedback content. */
  constructor(readonly code: string) {
    super(code);
  }
}

const KIND_TITLES: Record<FeedbackKind, string> = { bug: "Bug", idea: "Idea", other: "Other" };
const KIND_LABELS: Record<FeedbackKind, string> = { bug: "Bug", idea: "Idea", other: "Something else" };
const TITLE_MESSAGE_CHARS = 60;

export function linearConfigured(env: Env): boolean {
  return Boolean(env.LINEAR_API_KEY && env.LINEAR_TEAM_ID);
}

/** Issue title: "[Feedback]", the kind and the first ~60 characters of the message on one line. Plain text in Linear. */
export function issueTitle(payload: FeedbackPayload): string {
  const oneLine = payload.message.replace(/\s+/g, " ").trim();
  const chars = [...oneLine];
  const excerpt = chars.length > TITLE_MESSAGE_CHARS ? `${chars.slice(0, TITLE_MESSAGE_CHARS).join("").trimEnd()}…` : oneLine;
  return `[Feedback] ${KIND_TITLES[payload.kind]}: ${excerpt}`;
}

/**
 * Escapes text so Linear's Markdown renders it literally: no links, images,
 * headings, lists, HTML, mentions-by-markup or code. Newlines are kept as hard
 * breaks so the message reads as typed.
 */
export function escapeMarkdown(text: string): string {
  return text
    .split("\n")
    .map((line) => {
      // Inline markup characters anywhere in the line.
      let out = line.replace(/[\\`*_{}\[\]()<>#+\-!|~=.:@&]/g, (ch) => `\\${ch}`);
      // Leading spaces would turn into an indented code block; keep them visible as non-breaking.
      out = out.replace(/^( +)/, (spaces) => "\u00a0".repeat(spaces.length));
      return out;
    })
    .join("  \n");
}

export function issueDescription(payload: FeedbackPayload): string {
  const lines: string[] = [];
  lines.push(escapeMarkdown(payload.message));
  lines.push("", "---", "");
  lines.push(`**Kind:** ${KIND_LABELS[payload.kind]}  `);
  lines.push(`**Reply to:** ${payload.replyEmail ? escapeMarkdown(payload.replyEmail) : "no email given"}  `);
  lines.push(`**Signed in:** ${payload.signedIn ? "yes" : "no"}`);
  const d = payload.diagnostics;
  if (d) {
    lines.push("", "**Diagnostics** (the user opted in)", "");
    lines.push(`- App: ${d.app === "macos" ? "Mac" : "iPhone"} ${escapeMarkdown(d.appVersion)} (build ${escapeMarkdown(d.build)})`);
    lines.push(`- OS: ${escapeMarkdown(d.osVersion)}`);
    if (d.deviceModel) lines.push(`- Device: ${escapeMarkdown(d.deviceModel)}`);
    if (d.locale) lines.push(`- Locale: ${escapeMarkdown(d.locale)}`);
  } else {
    lines.push("", "No diagnostics (the user turned them off).");
  }
  lines.push("", "_Sent from Matilde's in\\-app feedback._");
  return lines.join("\n");
}

/** The kind's label plus the optional label for all feedback; unset ones are skipped. */
export function labelIds(env: Env, kind: FeedbackKind): string[] {
  const kindLabel = { bug: env.LINEAR_LABEL_BUG, idea: env.LINEAR_LABEL_IDEA, other: env.LINEAR_LABEL_OTHER }[kind];
  const ids = [kindLabel, env.LINEAR_LABEL_FEEDBACK].map((id) => id?.trim() ?? "").filter((id) => id.length > 0);
  return [...new Set(ids)];
}

const ISSUE_CREATE = `mutation MatildeFeedback($input: IssueCreateInput!) {
  issueCreate(input: $input) { success issue { id identifier } }
}`;

/**
 * Creates the Linear issue and returns its identifier (e.g. "GON-12"). Throws LinearError.
 * The optional project and (Triage) state are dropped in a second try if Linear
 * rejects the first one, so a stale id never loses feedback.
 */
export async function createLinearIssue(env: Env, payload: FeedbackPayload, fetcher: typeof fetch = fetch): Promise<string> {
  if (!linearConfigured(env)) throw new LinearError("not_configured");
  const labels = labelIds(env, payload.kind);
  const input: Record<string, unknown> = {
    teamId: env.LINEAR_TEAM_ID!.trim(),
    title: issueTitle(payload),
    description: issueDescription(payload),
  };
  if (labels.length) input.labelIds = labels;
  const projectId = env.LINEAR_PROJECT_ID?.trim();
  const stateId = env.LINEAR_STATE_ID?.trim();
  const placement: Record<string, string> = {};
  if (projectId) placement.projectId = projectId;
  if (stateId) placement.stateId = stateId;

  if (Object.keys(placement).length === 0) return issueCreate(env, input, fetcher);
  try {
    return await issueCreate(env, { ...input, ...placement }, fetcher);
  } catch (error) {
    if (!(error instanceof LinearError) || !(error.code === "graphql_error" || error.code === "http_400")) throw error;
    console.warn(JSON.stringify({ event: "linear_placement_rejected", code: error.code, fields: Object.keys(placement) }));
    return issueCreate(env, input, fetcher);
  }
}

async function issueCreate(env: Env, input: Record<string, unknown>, fetcher: typeof fetch): Promise<string> {
  let response: Response;
  try {
    response = await fetcher(LINEAR_API_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        // Personal API keys go in Authorization without a "Bearer" prefix.
        Authorization: env.LINEAR_API_KEY!.trim(),
      },
      body: JSON.stringify({ query: ISSUE_CREATE, variables: { input } }),
      signal: AbortSignal.timeout(10_000),
    });
  } catch {
    throw new LinearError("network");
  }
  if (!response.ok) throw new LinearError(`http_${response.status}`);
  let json: { data?: { issueCreate?: { success?: boolean; issue?: { identifier?: string } } }; errors?: unknown[] };
  try {
    json = await response.json();
  } catch {
    throw new LinearError("bad_response");
  }
  if (json.errors?.length) throw new LinearError("graphql_error");
  const result = json.data?.issueCreate;
  if (!result?.success || !result.issue?.identifier) throw new LinearError("not_created");
  return result.issue.identifier.slice(0, 32);
}
