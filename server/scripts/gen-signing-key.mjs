#!/usr/bin/env node
// Generates an Ed25519 access-token signing key as a private JWK with a kid.
// Pipe it straight into wrangler so it never lands in a file or the shell history:
//   npm run --silent gen-signing-key | npx wrangler secret put TOKEN_SIGNING_KEY --env production
// For rotation, `--public` prints the public half of a key read from stdin, for TOKEN_VERIFY_KEYS.
import { createPrivateKey, createPublicKey, generateKeyPairSync, randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";

if (process.argv.includes("--public")) {
  const jwk = JSON.parse(readFileSync(0, "utf8"));
  const { kid } = jwk;
  const publicJwk = createPublicKey(createPrivateKey({ key: jwk, format: "jwk" })).export({ format: "jwk" });
  process.stdout.write(JSON.stringify({ ...publicJwk, kid }));
} else {
  const { privateKey } = generateKeyPairSync("ed25519");
  const kid = `${new Date().toISOString().slice(0, 10)}-${randomUUID().slice(0, 8)}`;
  process.stdout.write(JSON.stringify({ ...privateKey.export({ format: "jwk" }), kid }));
}
