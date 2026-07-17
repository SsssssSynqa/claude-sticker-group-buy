import { assertEquals, assertRejects } from "jsr:@std/assert@1.0.14";
import {
  corsHeaders,
  normalizeName,
  publicErrorMessage,
  signAccountToken,
  verifyAccountToken,
} from "./edge-auth.ts";

Deno.test("name normalization is deterministic", () => {
  assertEquals(normalizeName("  Alice   Smith "), "alice smith");
});

Deno.test("CORS only echoes an allowlisted origin", () => {
  const allowed = new Set(["https://example.test"]);
  const accepted = corsHeaders(
    new Request("https://api.test", {
      headers: { origin: "https://example.test" },
    }),
    allowed,
  ) as Record<string, string>;
  const rejected = corsHeaders(
    new Request("https://api.test", {
      headers: { origin: "https://evil.test" },
    }),
    allowed,
  ) as Record<string, string>;
  assertEquals(accepted["Access-Control-Allow-Origin"], "https://example.test");
  assertEquals(rejected["Access-Control-Allow-Origin"], "https://example.test");
  assertEquals(rejected.Vary, "Origin");
});

Deno.test("account tokens require the current token version", async () => {
  const secret = new TextEncoder().encode("a-secret-long-enough-for-tests");
  const token = await signAccountToken({
    id: "00000000-0000-4000-8000-000000000001",
    name_key: "alice",
    display_name: "Alice",
    team: 4,
    role: "member",
    status: "active",
    token_version: 7,
  }, secret);
  const claims = await verifyAccountToken(
    new Request("https://api.test", {
      headers: { authorization: `Bearer ${token}` },
    }),
    secret,
  );
  assertEquals(claims?.ver, 7);
  assertEquals(claims?.name_key, "alice");
});

Deno.test("tokens signed with another secret are rejected", async () => {
  const token = await signAccountToken({
    id: "00000000-0000-4000-8000-000000000001",
    name_key: "alice",
    display_name: "Alice",
    team: 4,
    role: "member",
    status: "active",
    token_version: 1,
  }, new TextEncoder().encode("first-secret"));
  const result = await verifyAccountToken(
    new Request("https://api.test", {
      headers: { authorization: `Bearer ${token}` },
    }),
    new TextEncoder().encode("second-secret"),
  );
  assertEquals(result, null);
});

Deno.test("signing rejects an empty HMAC secret", async () => {
  await assertRejects(() =>
    signAccountToken({
      id: "00000000-0000-4000-8000-000000000001",
      name_key: "alice",
      display_name: "Alice",
      team: 4,
      role: "member",
      status: "active",
      token_version: 1,
    }, new Uint8Array())
  );
});

Deno.test("safe business errors stay actionable without leaking internals", () => {
  assertEquals(
    publicErrorMessage(new Error("团长已核实，不能自行撤销")),
    "团长已核实，不能自行撤销",
  );
  assertEquals(
    publicErrorMessage(new Error("relation private_table does not exist")),
    "服务器处理失败",
  );
});
