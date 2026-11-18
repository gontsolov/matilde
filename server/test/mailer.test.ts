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
