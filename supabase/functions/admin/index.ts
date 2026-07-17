import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.4";

import {
  authenticateAccount,
  corsHeaders,
  jsonResponse,
  publicErrorMessage,
  requireEnvironment,
} from "../_shared/edge-auth.ts";
import {
  parseBooleanFlag,
  parseCnyCents,
  parseLegacyOrderItems,
  parseLegacyTargetName,
  parseLegacyTeam,
} from "../_shared/legacy-contract.ts";

const { supabaseUrl, serviceRoleKey, customJwtSecret } = requireEnvironment();
const client = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false },
});
const jwtSecret = new TextEncoder().encode(customJwtSecret);
const SETTING_RULES: Record<string, (value: unknown) => string> = {
  r3_rate: positiveNumber,
  drop_r3_rate: positiveNumber,
  r3_actual_usd: nonnegativeNumber,
  r3_tax_cny: nonnegativeNumber,
  r3_packing_fee_t1: nonnegativeNumber,
  r3_packing_fee_t2: nonnegativeNumber,
  r3_packing_fee_t3: nonnegativeNumber,
  r3_locked: binarySetting,
};

function positiveNumber(value: unknown): string {
  const number = Number(value);
  if (!Number.isFinite(number) || number <= 0 || number > 100) {
    throw new Error("设置值无效");
  }
  return String(number);
}

function nonnegativeNumber(value: unknown): string {
  const number = Number(value);
  if (!Number.isFinite(number) || number < 0 || number > 1_000_000) {
    throw new Error("设置值无效");
  }
  return String(number);
}

function binarySetting(value: unknown): string {
  const normalized = String(value);
  if (normalized !== "0" && normalized !== "1") throw new Error("设置值无效");
  return normalized;
}

async function targetAccount(name: string) {
  const { data, error } = await client.from("accounts").select(
    "id,name_key,team,status",
  ).eq("name_key", name).maybeSingle();
  if (error) throw error;
  return data;
}

async function setMarker(
  name: string,
  stickerId: string,
  set: boolean,
  accountId?: string | null,
) {
  if (set) {
    const { error } = await client.from("orders").upsert({
      name,
      sticker_id: stickerId,
      quantity: 1,
      account_id: accountId || null,
      updated_at: new Date().toISOString(),
    }, { onConflict: "name,sticker_id" });
    if (error) throw error;
  } else {
    const { error } = await client.from("orders").delete().eq("name", name).eq(
      "sticker_id",
      stickerId,
    );
    if (error) throw error;
  }
}

async function setAmountMarker(name: string, stickerId: string, cents: number) {
  if (cents <= 0) {
    const { error } = await client.from("orders").delete().eq("name", name).eq(
      "sticker_id",
      stickerId,
    );
    if (error) throw error;
    return;
  }
  const account = await targetAccount(name);
  const { error } = await client.from("orders").upsert({
    name,
    sticker_id: stickerId,
    quantity: cents,
    account_id: account?.id || null,
    updated_at: new Date().toISOString(),
  }, { onConflict: "name,sticker_id" });
  if (error) throw error;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders(request) });
  }
  if (request.method !== "POST") {
    return jsonResponse(request, { error: "POST only" }, 405);
  }

  const account = await authenticateAccount(client, request, jwtSecret);
  if (!account) {
    return jsonResponse(request, { error: "未登录或登录已过期" }, 401);
  }
  if (account.role !== "admin") {
    return jsonResponse(request, { error: "仅管理员可操作" }, 403);
  }

  try {
    const body = await request.json();
    const action = String(body.action || "");

    if (action === "overview") {
      const { data: addresses, error } = await client.from("addresses").select(
        "name,account_id,team,recipient,phone,address,tracking_number,updated_at",
      ).like("name", "r3__%").order("name");
      if (error) throw error;
      return jsonResponse(request, { ok: true, addresses: addresses || [] });
    }

    if (action === "save_address_for") {
      const targetName = parseLegacyTargetName(body.target_name);
      const recipient = String(body.recipient || "").trim();
      const phone = String(body.phone || "").replace(/[\s-]/g, "");
      const address = String(body.address || "").trim();
      const team = parseLegacyTeam(body.team);
      if (recipient.length < 1 || recipient.length > 50) {
        throw new Error("收件人格式无效");
      }
      if (!/^\+?\d{7,15}$/.test(phone)) throw new Error("手机号格式无效");
      if (address.length < 5 || address.length > 300) {
        throw new Error("详细地址格式无效");
      }
      const target = await targetAccount(targetName);
      if (!target) throw new Error("目标账号不存在");
      const { data, error } = await client.from("addresses").upsert({
        name: "r3__" + target.name_key,
        account_id: target.id,
        team,
        recipient,
        phone,
        address,
        updated_at: new Date().toISOString(),
      }, { onConflict: "name" }).select(
        "name,account_id,team,recipient,phone,address,tracking_number,updated_at",
      ).single();
      if (error) throw error;
      return jsonResponse(request, { ok: true, address: data });
    }

    if (action === "save_tracking") {
      const targetName = parseLegacyTargetName(body.target_name);
      const value = String(body.value || "").trim();
      if (value.length > 100) throw new Error("快递单号格式无效");
      const { data, error } = await client.from("addresses").update({
        tracking_number: value || null,
        updated_at: new Date().toISOString(),
      }).eq("name", "r3__" + targetName).select("name").maybeSingle();
      if (error) throw error;
      if (!data) throw new Error("目标地址不存在");
      return jsonResponse(request, { ok: true });
    }

    if (action === "mark_shipped" || action === "unmark_shipped") {
      const targetName = parseLegacyTargetName(body.target_name);
      const target = await targetAccount(targetName);
      await setMarker(
        targetName,
        "r3__shipped",
        action === "mark_shipped",
        target?.id,
      );
      return jsonResponse(request, { ok: true });
    }

    if (action === "set_actual_paid") {
      const targetName = parseLegacyTargetName(body.target_name);
      const which = String(body.which || "r3");
      const marker = which === "drop"
        ? "drop_r3__actual_paid"
        : which === "r2"
        ? "r2__actual_paid"
        : which === "r3"
        ? "r3__actual_paid"
        : null;
      if (!marker) throw new Error("付款类型无效");
      const { error } = await client.rpc("set_legacy_actual_paid", {
        p_name: targetName,
        p_marker: marker,
        p_cents: parseCnyCents(body.value),
      });
      if (error) throw error;
      return jsonResponse(request, { ok: true });
    }

    if (action === "set_payment_leader") {
      const targetName = parseLegacyTargetName(body.target_name);
      const which = String(body.which || "r3");
      const set = parseBooleanFlag(body.set);
      if (which !== "r3" && which !== "drop") throw new Error("付款类型无效");
      const { error } = await client.rpc("set_legacy_leader_confirmation", {
        p_name: targetName,
        p_kind: which,
        p_set: set,
      });
      if (error) throw error;
      return jsonResponse(request, { ok: true });
    }

    if (action === "set_shipfee_leader") {
      const targetName = parseLegacyTargetName(body.target_name);
      const set = parseBooleanFlag(body.set);
      const { error } = await client.rpc("set_legacy_leader_confirmation", {
        p_name: targetName,
        p_kind: "shipfee",
        p_set: set,
      });
      if (error) throw error;
      return jsonResponse(request, { ok: true });
    }

    if (action === "set_refunded") {
      const targetName = parseLegacyTargetName(body.target_name);
      await setAmountMarker(
        targetName,
        "r3__refunded",
        parseCnyCents(body.value),
      );
      return jsonResponse(request, { ok: true });
    }

    if (action === "set_setting") {
      const key = String(body.key || "").trim();
      const parser = SETTING_RULES[key];
      if (!parser) throw new Error("不允许修改该设置");
      const value = parser(body.value);
      const { error } = await client.from("settings").upsert({
        key,
        value,
        updated_at: new Date().toISOString(),
      }, { onConflict: "key" });
      if (error) throw error;
      return jsonResponse(request, { ok: true, key, value });
    }

    if (action === "clear_drop_user") {
      const targetName = parseLegacyTargetName(body.target_name);
      const { error } = await client.rpc("clear_legacy_drop_user", {
        p_name: targetName,
      });
      if (error) throw error;
      return jsonResponse(request, { ok: true });
    }

    if (action === "set_member_team") {
      const targetName = parseLegacyTargetName(body.target_name);
      const team = parseLegacyTeam(body.team);
      const target = await targetAccount(targetName);
      if (!target) throw new Error("目标账号不存在");
      const { error } = await client.rpc("change_group_buy_team", {
        p_account_id: target.id,
        p_team: team,
      });
      if (error) throw error;
      return jsonResponse(request, { ok: true });
    }

    if (action === "import_legacy_orders") {
      if (!Array.isArray(body.people) || body.people.length > 1000) {
        throw new Error("导入数据格式无效");
      }
      const rows: Array<Record<string, unknown>> = [];
      for (const entry of body.people) {
        if (!entry || typeof entry !== "object") {
          throw new Error("导入数据格式无效");
        }
        const person = entry as Record<string, unknown>;
        const name = parseLegacyTargetName(person.name);
        const orderObject = person.orders;
        if (
          !orderObject || typeof orderObject !== "object" ||
          Array.isArray(orderObject)
        ) {
          throw new Error("导入订单格式无效");
        }
        const items = parseLegacyOrderItems(
          Object.entries(orderObject as Record<string, unknown>).map(
            ([sticker_id, quantity]) => ({ sticker_id, quantity }),
          ),
        );
        for (const item of items) rows.push({ name, ...item });
        if (person.team !== undefined && person.team !== null) {
          rows.push({
            name,
            sticker_id: "r3__team",
            quantity: parseLegacyTeam(person.team),
          });
        }
      }
      if (rows.length > 10_000) throw new Error("导入记录过多");
      const rate = body.rate === undefined ? null : positiveNumber(body.rate);
      const { data, error } = await client.rpc("admin_import_legacy_orders", {
        p_rows: rows,
        p_rate: rate,
      });
      if (error) throw error;
      return jsonResponse(request, {
        ok: true,
        imported: Number(data?.imported ?? rows.length),
      });
    }

    return jsonResponse(request, { error: "不支持的操作" }, 400);
  } catch (error) {
    const message = publicErrorMessage(error);
    console.error("admin request failed", {
      message: error instanceof Error ? error.message : String(error),
    });
    const validation = message !== "服务器处理失败";
    return jsonResponse(request, { error: message }, validation ? 400 : 500);
  }
});
