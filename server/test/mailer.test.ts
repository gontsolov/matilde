import { env } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import { CloudflareMailer, createMailer, MemoryMailer, ResendMailer, signInMail } from "../src/auth/mailer";
import type { Env } from "../src/env";

const withVars = (vars: Partial<Env>): Env => ({ ...env, ...vars }) as Env;

afterEach(() => vi.restoreAllMocks());

describe("mailer selection", () => {
  it("picks the provider from MAIL_PROVIDER", () => {
    const binding = { send: vi.fn() } as unknown as SendEmail;
    expect(createMailer(withVars({ MAIL_PROVIDER: "cloudflare", EMAIL: binding }))).toBeInstanceOf(CloudflareMailer);
    expect(createMailer(withVars({ MAIL_PROVIDER: "resend", RESEND_API_KEY: "re_test" }))).toBeInstanceOf(ResendMailer);
    expect(createMailer(withVars({ MAIL_PROVIDER: "memory" }))).toBeInstanceOf(MemoryMailer);
  });

  it("refuses dev/test mailers and missing configuration in deployed environments", () => {
    expect(() => createMailer(withVars({ MAIL_PROVIDER: "console", ENVIRONMENT: "production" }))).toThrow();
    expect(() => createMailer(withVars({ MAIL_PROVIDER: "memory", ENVIRONMENT: "staging" }))).toThrow();
    expect(() => createMailer(withVars({ MAIL_PROVIDER: "cloudflare", EMAIL: undefined }))).toThrow();
    expect(() => createMailer(withVars({ MAIL_PROVIDER: "resend", RESEND_API_KEY: undefined }))).toThrow();
    expect(() => createMailer(withVars({ MAIL_PROVIDER: "carrier-pigeon" }))).toThrow();
  });

  it("sends through the Cloudflare Email Service binding", async () => {
    const send = vi.fn().mockResolvedValue({ messageId: "m1" });
    await new CloudflareMailer({ send } as unknown as SendEmail, "Matilde <sign-in@matilde.page>").send(signInMail("a@example.com", "123456"));
    expect(send).toHaveBeenCalledWith(
      expect.objectContaining({ from: { name: "Matilde", email: "sign-in@matilde.page" }, to: "a@example.com", text: expect.stringContaining("123456") }),
    );
  });

  it("reports a Cloudflare send failure by its error code only", async () => {
    const send = vi.fn().mockRejectedValue(Object.assign(new Error("recipient a@example.com rejected"), { code: "E_SENDER_DOMAIN_NOT_AVAILABLE" }));
    const failure = new CloudflareMailer({ send } as unknown as SendEmail, "Matilde <sign-in@matilde.page>").send(signInMail("a@example.com", "123456"));
    await expect(failure).rejects.toThrow("cloudflare email failed: E_SENDER_DOMAIN_NOT_AVAILABLE");
    await expect(failure).rejects.not.toThrow("a@example.com");
  });

  it("reports a recipient refusal by its code", async () => {
    // E_RECIPIENT_NOT_ALLOWED: a destination restriction on the binding, or the sender domain
    // isn't onboarded for Email Sending yet (then only verified destination addresses work).
    const send = vi.fn().mockRejectedValue(Object.assign(new Error("a@example.com not allowed"), { code: "E_RECIPIENT_NOT_ALLOWED" }));
    const failure = new CloudflareMailer({ send } as unknown as SendEmail, "Matilde <sign-in@matilde.page>").send(signInMail("a@example.com", "123456"));
    await expect(failure).rejects.toThrow("cloudflare email failed: E_RECIPIENT_NOT_ALLOWED");
    await expect(failure).rejects.not.toThrow("a@example.com");
  });

  it("sends through Resend", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("{}", { status: 200 }));
    await new ResendMailer("re_test", "Matilde <sign-in@matilde.page>").send(signInMail("a@example.com", "123456"));
    const [url, init] = fetchSpy.mock.calls[0]!;
    expect(url).toBe("https://api.resend.com/emails");
    expect((init!.headers as Record<string, string>).Authorization).toBe("Bearer re_test");
    expect(JSON.parse(init!.body as string)).toMatchObject({ to: ["a@example.com"], from: "Matilde <sign-in@matilde.page>" });
  });

  it("reports a failed send", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("nope", { status: 422 }));
    await expect(new ResendMailer("re_test", "x@matilde.page").send(signInMail("a@example.com", "1"))).rejects.toThrow("422");
  });
});

describe("deployed mail configuration (wrangler.jsonc)", () => {
  type DeployedMail = { name: string; mailProvider?: string; mailFrom?: string; sendEmail: Record<string, unknown>[] };
  const deployed = JSON.parse(env.TEST_DEPLOYED_MAIL_CONFIG) as DeployedMail[];

  it("covers staging and production", () => {
    expect(deployed.map((e) => e.name).sort()).toEqual(["production", "staging"]);
  });

  for (const environment of deployed.filter((e) => e.mailProvider === "cloudflare")) {
    it(`${environment.name}: EMAIL binding can mail any recipient from MAIL_FROM`, () => {
      const bindings = environment.sendEmail.filter((b) => b.name === "EMAIL");
      expect(bindings).toHaveLength(1);
      const binding = bindings[0]!;
      // Either attribute limits who can receive a sign-in code (E_RECIPIENT_NOT_ALLOWED).
      expect(binding).not.toHaveProperty("destination_address");
      expect(binding).not.toHaveProperty("allowed_destination_addresses");
      const from = /<([^>]+)>/.exec(environment.mailFrom ?? "")?.[1] ?? environment.mailFrom;
      // A sender outside the allowlist fails with E_SENDER_NOT_VERIFIED.
      if (binding.allowed_sender_addresses !== undefined) expect(binding.allowed_sender_addresses).toContain(from);
    });
  }
});
