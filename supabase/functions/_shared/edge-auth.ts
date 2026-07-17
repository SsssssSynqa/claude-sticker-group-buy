import * as jose from "https://esm.sh/jose@5.9.6";

type QueryClient = {
  // Kept deliberately minimal so pure JWT/CORS tests do not load supabase-js.
  // deno-lint-ignore no-explicit-any
  from(table: string): any;
};

export type TokenClaims = {
  account_id: string;
  name_key: string;
  role: string;
  team?: number;
  ver: number;
};

export type ActiveAccount = {
  id: string;
  name_key: string;
  display_name: string;
  team: number | null;
  role: string;
  status: string;
  token_version: number;
};

const DEFAULT_ORIGIN = "https://sssssssynqa.github.io";

export function allowedOriginsFromEnvironment(): Set<string> {
  return new Set(
    (Deno.env.get("ALLOWED_ORIGINS") || DEFAULT_ORIGIN)
      .split(",")
      .map((origin) => origin.trim())
      .filter(Boolean),
  );
}

export function corsHeaders(
  request: Request,
  allowedOrigins = allowedOriginsFromEnvironment(),
): HeadersInit {
  const origin = request.headers.get("origin") || "";
  const allowedOrigin = allowedOrigins.has(origin)
    ? origin
    : [...allowedOrigins][0] || DEFAULT_ORIGIN;
  return {
    "Access-Control-Allow-Origin": allowedOrigin,
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Cache-Control": "no-store",
    "Vary": "Origin",
  };
}

export function jsonResponse(
  request: Request,
  body: unknown,
  status = 200,
  allowedOrigins?: Set<string>,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders(request, allowedOrigins),
      "Content-Type": "application/json; charset=utf-8",
    },
  });
}

export function requireEnvironment() {
  const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  const customJwtSecret = Deno.env.get("CUSTOM_JWT_SECRET") || "";
  if (!supabaseUrl || !serviceRoleKey || !customJwtSecret) {
    throw new Error("Edge Function 环境变量未完整配置");
  }
  return { supabaseUrl, serviceRoleKey, customJwtSecret };
}

export function normalizeName(value: unknown): string {
  return String(value ?? "").trim().toLowerCase().replace(/\s+/g, " ");
}

export async function signAccountToken(
  account: ActiveAccount,
  secret: Uint8Array,
): Promise<string> {
  return await new jose.SignJWT({
    account_id: account.id,
    name_key: account.name_key,
    role: account.role,
    team: account.team ?? undefined,
    ver: account.token_version,
  })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setIssuedAt()
    .setJti(crypto.randomUUID())
    .setExpirationTime("30d")
    .sign(secret);
}

export async function verifyAccountToken(
  request: Request,
  secret: Uint8Array,
): Promise<TokenClaims | null> {
  const match = (request.headers.get("Authorization") || "").match(
    /^Bearer\s+(.+)$/,
  );
  if (!match) return null;
  try {
    const { payload } = await jose.jwtVerify(match[1], secret, {
      algorithms: ["HS256"],
    });
    if (
      typeof payload.account_id !== "string" ||
      typeof payload.name_key !== "string" ||
      typeof payload.role !== "string" ||
      !Number.isSafeInteger(payload.ver)
    ) return null;
    return payload as TokenClaims;
  } catch {
    return null;
  }
}

export async function authenticateAccount(
  client: QueryClient,
  request: Request,
  secret: Uint8Array,
): Promise<ActiveAccount | null> {
  const claims = await verifyAccountToken(request, secret);
  if (!claims) return null;
  const { data: account, error } = await client
    .from("accounts")
    .select(
      "id,name_key,display_name,team,role,status,token_version",
    )
    .eq("id", claims.account_id)
    .maybeSingle();
  if (
    error || !account || account.status !== "active" ||
    account.token_version !== claims.ver
  ) return null;
  return account as ActiveAccount;
}

export function publicErrorMessage(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  return /无效|格式|重复|不允许|不能|不存在|不能为空|必须|已锁定|已锁单|已关闭|已过期|已截止|未开放|库存不足|至少选择|请同时提交|退款金额|汇率|导入数据/
      .test(
        message,
      )
    ? message
    : "服务器处理失败";
}
