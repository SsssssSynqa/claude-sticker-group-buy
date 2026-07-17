import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.4";
import * as jose from "https://esm.sh/jose@5.9.6";

import {
  corsHeaders,
  jsonResponse,
  publicErrorMessage,
  requireEnvironment,
} from "../_shared/edge-auth.ts";
import { parseBooleanFlag } from "../_shared/legacy-contract.ts";

type Namespace = "badge" | "plush";
type CounterAccount = {
  id: string;
  namespace: Namespace;
  sequence: number;
  display_name: string;
  token_version: number;
  status: string;
};
type CounterClaims = {
  counter_account_id: string;
  namespace: Namespace;
  ver: number;
};

const BADGE_PRODUCTS = new Set([
  "badge_clawd",
  "badge_ultrathink",
  "badge_clawd_happy",
  "badge_vibing_dc",
  "badge_clawd_shiny",
  "badge_claudecode",
  "badge_vibing_holo",
  "badge_reticulating",
  "badge_shipping",
  "badge_manifesting_holo",
  "badge_baking",
  "badge_clawd_wave",
  "badge_manifesting_glt",
  "badge_clawd_heart",
  "badge_clawd_headphones",
  "badge_clawd_wand",
  "badge_clawd_bubble",
  "badge_clawd_coffee",
  "badge_clawd_skateboard",
  "badge_clawd_book",
  "badge_clawd_cape",
  "badge_clawd_dizzy",
  "badge_clawd_kite",
  "badge_clawd_lightbulb",
  "badge_clawd_magnifier",
]);
const PLUSH_PRODUCTS = new Set(["plush__sound_qty", "plush__silent_qty"]);

const { supabaseUrl, serviceRoleKey, customJwtSecret } = requireEnvironment();
const client = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false },
});
const jwtSecret = new TextEncoder().encode(customJwtSecret);

function parseNamespace(value: unknown): Namespace {
  if (value === "badge" || value === "plush") return value;
  throw new Error("计数器类型无效");
}

function parsePin(value: unknown): string {
  const pin = String(value ?? "");
  if (!/^\d{6}$/.test(pin)) throw new Error("密码必须是 6 位数字");
  return pin;
}

function parseDisplayName(value: unknown): string {
  const name = String(value ?? "").trim();
  if (name.length < 1 || name.length > 50) throw new Error("昵称格式无效");
  return name;
}

function fullName(account: Pick<CounterAccount, "sequence" | "display_name">) {
  return `${String(account.sequence).padStart(3, "0")}-${account.display_name}`;
}

function parseItems(namespace: Namespace, value: unknown) {
  const allowed = namespace === "badge" ? BADGE_PRODUCTS : PLUSH_PRODUCTS;
  if (!Array.isArray(value) || value.length > allowed.size) {
    throw new Error("订单商品格式无效");
  }
  const seen = new Set<string>();
  return value.map((entry) => {
    if (!entry || typeof entry !== "object") {
      throw new Error("订单商品格式无效");
    }
    const row = entry as Record<string, unknown>;
    const productId = String(row.product_id || "").trim();
    const quantity = Number(row.quantity);
    if (!allowed.has(productId)) throw new Error("不允许修改该商品");
    if (!Number.isInteger(quantity) || quantity < 0 || quantity > 10000) {
      throw new Error("商品数量无效");
    }
    if (seen.has(productId)) throw new Error("订单中存在重复商品");
    seen.add(productId);
    return { product_id: productId, quantity };
  });
}

async function signToken(account: CounterAccount) {
  return await new jose.SignJWT({
    counter_account_id: account.id,
    namespace: account.namespace,
    ver: account.token_version,
  }).setProtectedHeader({ alg: "HS256", typ: "JWT" }).setIssuedAt()
    .setJti(crypto.randomUUID()).setExpirationTime("30d").sign(jwtSecret);
}

async function authenticate(request: Request, namespace: Namespace) {
  const match = (request.headers.get("Authorization") || "").match(
    /^Bearer\s+(.+)$/,
  );
  if (!match) return null;
  let claims: CounterClaims;
  try {
    const { payload } = await jose.jwtVerify(match[1], jwtSecret, {
      algorithms: ["HS256"],
    });
    claims = payload as CounterClaims;
  } catch {
    return null;
  }
  if (
    typeof claims.counter_account_id !== "string" ||
    claims.namespace !== namespace || !Number.isSafeInteger(claims.ver)
  ) return null;
  const { data, error } = await client.from("counter_accounts").select(
    "id,namespace,sequence,display_name,token_version,status",
  ).eq("id", claims.counter_account_id).eq("namespace", namespace)
    .maybeSingle();
  if (
    error || !data || data.status !== "active" ||
    data.token_version !== claims.ver
  ) return null;
  return data as CounterAccount;
}

async function snapshot(namespace: Namespace) {
  const { data: accounts, error: accountsError } = await client.from(
    "counter_accounts",
  ).select("id,sequence,display_name,updated_at").eq("namespace", namespace).eq(
    "status",
    "active",
  ).order("sequence");
  if (accountsError) throw accountsError;
  const ids = (accounts || []).map((account) => account.id);
  const [items, payments] = ids.length
    ? await Promise.all([
      client.from("counter_order_items").select(
        "account_id,product_id,quantity,updated_at",
      ).in("account_id", ids),
      client.from("counter_payments").select(
        "account_id,member_confirmed_at,leader_confirmed_at,updated_at",
      ).in("account_id", ids),
    ])
    : [{ data: [], error: null }, { data: [], error: null }];
  if (items.error) throw items.error;
  if (payments.error) throw payments.error;
  const itemsByAccount = new Map<string, unknown[]>();
  for (const item of items.data || []) {
    const list = itemsByAccount.get(item.account_id) || [];
    list.push({ product_id: item.product_id, quantity: item.quantity });
    itemsByAccount.set(item.account_id, list);
  }
  const paymentByAccount = new Map(
    (payments.data || []).map((payment) => [payment.account_id, payment]),
  );
  return (accounts || []).map((account) => ({
    sequence: account.sequence,
    display_name: account.display_name,
    full_name: fullName(account),
    items: itemsByAccount.get(account.id) || [],
    payment: paymentByAccount.get(account.id) || null,
    updated_at: account.updated_at,
  }));
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders(request) });
  }
  if (request.method !== "POST") {
    return jsonResponse(request, { error: "POST only" }, 405);
  }

  try {
    const body = await request.json();
    const action = String(body.action || "snapshot");
    const namespace = parseNamespace(body.namespace);

    if (action === "snapshot") {
      return jsonResponse(request, {
        ok: true,
        namespace,
        members: await snapshot(namespace),
      });
    }

    if (action === "register") {
      const displayName = parseDisplayName(body.display_name);
      const pin = parsePin(body.pin);
      const { data, error } = await client.rpc("register_counter_account", {
        p_namespace: namespace,
        p_display_name: displayName,
        p_pin: pin,
      });
      if (error) throw error;
      const account = data as CounterAccount;
      return jsonResponse(request, {
        ok: true,
        token: await signToken(account),
        account: { ...account, full_name: fullName(account) },
      });
    }

    if (action === "login") {
      const sequence = Number(body.sequence);
      if (!Number.isInteger(sequence) || sequence < 1 || sequence > 999999) {
        throw new Error("编号格式无效");
      }
      const displayName = parseDisplayName(body.display_name);
      const pin = parsePin(body.pin);
      const { data, error } = await client.rpc("authenticate_counter_account", {
        p_namespace: namespace,
        p_sequence: sequence,
        p_display_name: displayName,
        p_pin: pin,
      });
      if (error) throw error;
      if (!data?.ok) {
        if (data?.code === "temporarily_locked") {
          return jsonResponse(request, {
            error: "密码错误次数过多，请 15 分钟后再试",
          }, 429);
        }
        if (data?.code === "account_disabled") {
          return jsonResponse(request, { error: "账号已停用" }, 403);
        }
        return jsonResponse(request, { error: "编号、昵称或密码不对" }, 401);
      }
      const account = data.account as CounterAccount;
      return jsonResponse(request, {
        ok: true,
        token: await signToken(account),
        account: { ...account, full_name: fullName(account) },
      });
    }

    const account = await authenticate(request, namespace);
    if (!account) {
      return jsonResponse(request, { error: "未登录或登录已过期" }, 401);
    }
    if (action === "session") {
      return jsonResponse(request, {
        ok: true,
        token: await signToken(account),
        account: { ...account, full_name: fullName(account) },
      });
    }

    if (action === "save_order") {
      const displayName = parseDisplayName(body.display_name);
      const items = parseItems(namespace, body.items);
      const { data, error } = await client.rpc("save_counter_order", {
        p_account_id: account.id,
        p_display_name: displayName,
        p_items: items,
      });
      if (error) throw error;
      const updated = data as CounterAccount;
      return jsonResponse(request, {
        ok: true,
        account: { ...updated, full_name: fullName(updated) },
      });
    }

    if (action === "set_payment") {
      if (namespace !== "badge") throw new Error("该页面没有付款状态");
      const set = parseBooleanFlag(body.set);
      const { error } = await client.from("counter_payments").upsert({
        account_id: account.id,
        member_confirmed_at: set ? new Date().toISOString() : null,
        updated_at: new Date().toISOString(),
      }, { onConflict: "account_id" });
      if (error) throw error;
      return jsonResponse(request, { ok: true });
    }

    return jsonResponse(request, { error: "不支持的操作" }, 400);
  } catch (error) {
    const message = publicErrorMessage(error);
    console.error("counter request failed", {
      message: error instanceof Error ? error.message : String(error),
    });
    const validation = message !== "服务器处理失败";
    return jsonResponse(request, { error: message }, validation ? 400 : 500);
  }
});
