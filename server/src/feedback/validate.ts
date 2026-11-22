import { EMAIL_RE } from "../auth/email";
import { HttpError } from "../util";

export const FEEDBACK_KINDS = ["bug", "idea", "other"] as const;
export type FeedbackKind = (typeof FEEDBACK_KINDS)[number];

/** Field limits. Mirrored in PROTOCOL.md ("Feedback"); change both together. */
export const FEEDBACK_LIMITS = {
  /** Max request body. */
  maxRequestBytes: 32 * 1024,
  messageMaxChars: 5000,
  replyEmailMaxChars: 254,
  appVersionMaxChars: 32,
  buildMaxChars: 32,
  osVersionMaxChars: 64,
  deviceModelMaxChars: 64,
  localeMaxChars: 35,
} as const;

export interface FeedbackDiagnostics {
  app: "macos" | "ios";
  appVersion: string;
  build: string;
  osVersion: string;
  deviceModel?: string;
  locale?: string;
}

export interface FeedbackInput {
  kind: FeedbackKind;
  message: string;
  replyEmail?: string;
  /** Present when includeDiagnostics is true (the apps always send it since 0.3.2). */
  diagnostics?: FeedbackDiagnostics;
}

const TOP_LEVEL_KEYS = new Set(["message", "replyEmail", "includeDiagnostics", "diagnostics", "kind"]);
const DIAGNOSTIC_KEYS = new Set(["app", "appVersion", "build", "osVersion", "deviceModel", "locale"]);

const invalid = (message: string) => new HttpError(400, "invalid_request", message);

// Conservative character sets: diagnostics are short machine values, never prose.
const VERSION_RE = /^[0-9A-Za-z.+\-]+$/;
const BUILD_RE = /^[0-9A-Za-z.]+$/;
const OS_RE = /^[0-9A-Za-z .,()+\-]+$/;
const MODEL_RE = /^[0-9A-Za-z ,.()_\-]+$/;
const LOCALE_RE = /^[A-Za-z0-9_\-@=.]+$/;

function requiredString(value: unknown, name: string, max: number, pattern: RegExp): string {
  if (typeof value !== "string") throw invalid(`${name} must be a string`);
  const trimmed = value.trim();
  if (trimmed.length === 0 || trimmed.length > max || !pattern.test(trimmed)) throw invalid(`${name} is malformed (at most ${max} characters)`);
  return trimmed;
}

function optionalString(value: unknown, name: string, max: number, pattern: RegExp): string | undefined {
  if (value === undefined || value === null || value === "") return undefined;
  return requiredString(value, name, max, pattern);
}

/** Characters that are invisible or reorder text; stripped from the message and title. */
const CONTROL_RE = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F\u200B-\u200F\u202A-\u202E\u2066-\u2069]/g;

/**
 * Validates a feedback body. Unknown fields are rejected so a client can't send
 * more than the documented shape; diagnostics are dropped unless opted into.
 */
export function parseFeedback(body: unknown): FeedbackInput {
  if (typeof body !== "object" || body === null || Array.isArray(body)) throw invalid("body must be an object");
  const raw = body as Record<string, unknown>;
  for (const key of Object.keys(raw)) if (!TOP_LEVEL_KEYS.has(key)) throw invalid(`unknown field ${key}`);

  if (typeof raw.message !== "string") throw invalid("message must be a string");
  const message = raw.message.replace(/\r\n?/g, "\n").replace(CONTROL_RE, "").trim();
  // Count user-perceived characters roughly as code points, like the apps do.
  const length = [...message].length;
  if (length < 1 || length > FEEDBACK_LIMITS.messageMaxChars) throw invalid(`message must have 1 to ${FEEDBACK_LIMITS.messageMaxChars} characters`);

  let kind: FeedbackKind = "other";
  if (raw.kind !== undefined && raw.kind !== null) {
    if (typeof raw.kind !== "string" || !(FEEDBACK_KINDS as readonly string[]).includes(raw.kind)) throw invalid("kind must be bug, idea or other");
    kind = raw.kind as FeedbackKind;
  }

  let replyEmail: string | undefined;
  if (raw.replyEmail !== undefined && raw.replyEmail !== null && raw.replyEmail !== "") {
    if (typeof raw.replyEmail !== "string") throw new HttpError(400, "invalid_email", "replyEmail must be an email address");
    const email = raw.replyEmail.trim();
    if (email.length > FEEDBACK_LIMITS.replyEmailMaxChars || !EMAIL_RE.test(email)) {
      throw new HttpError(400, "invalid_email", "replyEmail must be an email address");
    }
    replyEmail = email;
  }

  if (typeof raw.includeDiagnostics !== "boolean") throw invalid("includeDiagnostics must be true or false");
  let diagnostics: FeedbackDiagnostics | undefined;
  if (raw.includeDiagnostics) {
    const d = raw.diagnostics;
    if (typeof d !== "object" || d === null || Array.isArray(d)) throw invalid("diagnostics are required when includeDiagnostics is true");
    const rd = d as Record<string, unknown>;
    for (const key of Object.keys(rd)) if (!DIAGNOSTIC_KEYS.has(key)) throw invalid(`unknown field diagnostics.${key}`);
    if (rd.app !== "macos" && rd.app !== "ios") throw invalid("diagnostics.app must be macos or ios");
    diagnostics = {
      app: rd.app,
      appVersion: requiredString(rd.appVersion, "diagnostics.appVersion", FEEDBACK_LIMITS.appVersionMaxChars, VERSION_RE),
      build: requiredString(rd.build, "diagnostics.build", FEEDBACK_LIMITS.buildMaxChars, BUILD_RE),
      osVersion: requiredString(rd.osVersion, "diagnostics.osVersion", FEEDBACK_LIMITS.osVersionMaxChars, OS_RE),
    };
    const deviceModel = optionalString(rd.deviceModel, "diagnostics.deviceModel", FEEDBACK_LIMITS.deviceModelMaxChars, MODEL_RE);
    const locale = optionalString(rd.locale, "diagnostics.locale", FEEDBACK_LIMITS.localeMaxChars, LOCALE_RE);
    if (deviceModel) diagnostics.deviceModel = deviceModel;
    if (locale) diagnostics.locale = locale;
  }
  // includeDiagnostics false: whatever arrived in `diagnostics` is ignored and never stored.

  return { kind, message, ...(replyEmail ? { replyEmail } : {}), ...(diagnostics ? { diagnostics } : {}) };
}
