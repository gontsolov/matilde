import type { Env } from "../env";

export interface MailMessage {
  to: string;
  subject: string;
  text: string;
}

/** Sends sign-in mail. Selected by MAIL_PROVIDER; see README.md. */
export interface Mailer {
  send(message: MailMessage): Promise<void>;
}

/**
 * Cloudflare Email Service (Email Sending) via the `send_email` binding. No API key. Public beta
 * at the time of writing; needs Workers Paid and the sender domain onboarded for Email Sending.
 */
export class CloudflareMailer implements Mailer {
  constructor(
    private readonly binding: SendEmail,
    private readonly from: string,
  ) {}

  async send(message: MailMessage): Promise<void> {
    try {
      await this.binding.send({ from: parseAddress(this.from), to: message.to, subject: message.subject, text: message.text });
    } catch (error) {
      // Only the error code (e.g. E_SENDER_DOMAIN_NOT_AVAILABLE) reaches the logs: the message may name the recipient.
      const code = (error as { code?: unknown } | null)?.code;
      throw new Error(`cloudflare email failed: ${typeof code === "string" ? code : error instanceof TypeError ? "invalid_message" : "unknown"}`);
    }
  }
}

/** Resend HTTP API: documented fallback, not in the default config (needs the RESEND_API_KEY secret and a verified sender domain). */
export class ResendMailer implements Mailer {
  constructor(
    private readonly apiKey: string,
    private readonly from: string,
  ) {}

  async send(message: MailMessage): Promise<void> {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${this.apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: this.from, to: [message.to], subject: message.subject, text: message.text }),
    });
    if (!res.ok) throw new Error(`resend responded ${res.status}`);
  }
}

/** Local development only: prints the message (including the code) to the wrangler dev console. */
export class ConsoleMailer implements Mailer {
  async send(message: MailMessage): Promise<void> {
    console.log(`[dev mail] to=${message.to} subject=${message.subject}\n${message.text}`);
  }
}

/** Tests only: keeps messages in memory, readable through `memoryOutbox()`. */
export class MemoryMailer implements Mailer {
  async send(message: MailMessage): Promise<void> {
    memoryOutbox().push(message);
  }
}

export function memoryOutbox(): MailMessage[] {
  const store = globalThis as { __matildeOutbox?: MailMessage[] };
  store.__matildeOutbox ??= [];
  return store.__matildeOutbox;
}

function parseAddress(value: string): string | EmailAddress {
  const match = /^\s*(.+?)\s*<([^>]+)>\s*$/.exec(value);
  return match ? { name: match[1]!, email: match[2]! } : value.trim();
}

export function createMailer(env: Env): Mailer {
  const deployed = env.ENVIRONMENT === "production" || env.ENVIRONMENT === "staging";
  switch (env.MAIL_PROVIDER) {
    case "cloudflare":
      if (!env.EMAIL) throw new Error("MAIL_PROVIDER=cloudflare needs the EMAIL send_email binding");
      return new CloudflareMailer(env.EMAIL, env.MAIL_FROM);
    case "resend":
      if (!env.RESEND_API_KEY) throw new Error("MAIL_PROVIDER=resend needs the RESEND_API_KEY secret");
      return new ResendMailer(env.RESEND_API_KEY, env.MAIL_FROM);
    case "console":
      if (deployed) throw new Error("MAIL_PROVIDER=console is for local development only");
      return new ConsoleMailer();
    case "memory":
      if (deployed) throw new Error("MAIL_PROVIDER=memory is for tests only");
      return new MemoryMailer();
    default:
      throw new Error(`unknown MAIL_PROVIDER ${env.MAIL_PROVIDER}`);
  }
}

export function signInMail(to: string, code: string): MailMessage {
  return {
    to,
    subject: `${code} is your Matilde sign-in code`,
    text: [
      `Your Matilde sign-in code is ${code}.`,
      "",
      "Enter it in Matilde within 10 minutes. If you didn't ask for it, you can ignore this email.",
    ].join("\n"),
  };
}
