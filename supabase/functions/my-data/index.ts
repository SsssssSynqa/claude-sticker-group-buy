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
  parseLegacyOrderItems,
  parseLegacyTeam,
} from "../_shared/legacy-contract.ts";

const { supabaseUrl, serviceRoleKey, customJwtSecret } = requireEnvironment();
const client = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false },
});
const jwtSecret = new TextEncoder().encode(customJwtSecret);
const SAFE_SETTING_KEYS = [
  "r3_rate",
  "r3_actual_usd",
  "r3_tax_cny",
  "r3_locked",
  "r3_packing_fee_t1",
  "r3_packing_fee_t2",
  "r3_packing_fee_t3",
  "drop_r3_rate",
];

function shippingCents(address: string) {
  if (address.includes("新疆") || address.includes("西藏")) return 2150;
  if (address.includes("北京") || address.includes("上海")) return 950;
  return 850;
}

async function loadAllLegacyOrders() {
  const rows: unknown[] = [];
  const pageSize = 1000;
  for (let offset = 0;; offset += pageSize) {
    const { data, error } = await client.from("orders").select(
      "id,name,sticker_id,quantity,updated_at",
    ).or("sticker_id.like.r3_%,sticker_id.like.drop_r3_%").order("id").range(
      offset,
      offset + pageSize - 1,
    );
    if (error) throw error;
    rows.push(...(data || []));
    if (!data || data.length < pageSize) break;
  }
  return rows;
}

async function loadLegacySnapshot(accountId: string) {
  const [orders, settingsResult, ownAddressResult, addressSummaryResult] =
    await Promise.all([
      loadAllLegacyOrders(),
      client.from("settings").select("key,value,updated_at").in(
        "key",
        SAFE_SETTING_KEYS,
      ),
      client.from("addresses").select(
        "name,recipient,phone,address,team,tracking_number,updated_at",
      ).eq("account_id", accountId),
      client.from("addresses").select("name,address").like("name", "r3__%"),
    ]);
  if (settingsResult.error) throw settingsResult.error;
  if (ownAddressResult.error) throw ownAddressResult.error;
  if (addressSummaryResult.error) throw addressSummaryResult.error;
  const shippingSummaries = (addressSummaryResult.data || []).map((row) => {
    const address = String(row.address || "").trim();
    return {
      name: String(row.name || "").slice(4),
      has_address: Boolean(address),
      shipping_cents: address ? shippingCents(address) : null,
    };
  });
  return {
    orders,
    settings: settingsResult.data || [],
    my_addresses: ownAddressResult.data || [],
    shipping_summaries: shippingSummaries,
  };
}

async function loadLegacyRevision(): Promise<number> {
  const { data, error } = await client.from("legacy_change_state")
    .select("revision").eq("id", true).single();
  if (error) throw error;
  const revision = Number(data.revision);
  if (!Number.isSafeInteger(revision) || revision < 1) {
    throw new Error("数据版本无效");
  }
  return revision;
}

async function loadStableLegacySnapshot(accountId: string) {
  let startRevision = await loadLegacyRevision();
  let snapshot = await loadLegacySnapshot(accountId);
  let endRevision = await loadLegacyRevision();
  if (endRevision === startRevision) {
    return { ...snapshot, revision: endRevision };
  }

  // A write landed during the multi-query snapshot. Retry once; if writes keep
  // arriving, omit the revision so the browser will request a full snapshot on
  // its next poll rather than caching a potentially mixed view as current.
  startRevision = endRevision;
  snapshot = await loadLegacySnapshot(accountId);
  endRevision = await loadLegacyRevision();
  return {
    ...snapshot,
    revision: endRevision === startRevision ? endRevision : null,
  };
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

  try {
    const body = await request.json();
    const action = String(body.action || "get_bootstrap");
    const accountId = account.id;
    const nameKey = account.name_key;

    if (action === "get_bootstrap" || action === "get_legacy_snapshot") {
      const knownRevision = body.known_revision === null ||
          body.known_revision === undefined
        ? null
        : Number(body.known_revision);
      if (
        knownRevision !== null &&
        (!Number.isSafeInteger(knownRevision) || knownRevision < 1)
      ) {
        throw new Error("数据版本无效");
      }
      const currentRevision = await loadLegacyRevision();
      if (knownRevision === currentRevision) {
        return jsonResponse(request, {
          ok: true,
          not_modified: true,
          revision: currentRevision,
        });
      }
      return jsonResponse(request, {
        ok: true,
        ...(await loadStableLegacySnapshot(accountId)),
      });
    }

    if (action === "save_address") {
      const recipient = String(body.recipient || "").trim();
      const phone = String(body.phone || "").replace(/[\s-]/g, "");
      const address = String(body.address || "").trim();
      const team = parseLegacyTeam(body.team ?? account.team);
      if (recipient.length < 1 || recipient.length > 50) {
        throw new Error("收件人格式无效");
      }
      if (!/^\+?\d{7,15}$/.test(phone)) throw new Error("手机号格式无效");
      if (address.length < 5 || address.length > 300) {
        throw new Error("详细地址格式无效");
      }
      const { data, error } = await client.from("addresses").upsert({
        name: "r3__" + nameKey,
        account_id: accountId,
        team,
        recipient,
        phone,
        address,
        updated_at: new Date().toISOString(),
      }, { onConflict: "name" }).select(
        "name,recipient,phone,address,team,tracking_number,updated_at",
      ).single();
      if (error) throw error;
      return jsonResponse(request, { ok: true, address: data });
    }

    if (action === "submit_order" || action === "submit_orders") {
      const items = action === "submit_order"
        ? parseLegacyOrderItems([{
          sticker_id: body.sticker_id,
          quantity: body.quantity,
        }])
        : parseLegacyOrderItems(body.items);
      const { data, error } = await client.rpc("save_legacy_order_items", {
        p_account_id: accountId,
        p_items: items,
      });
      if (error) throw error;
      return jsonResponse(request, {
        ok: true,
        saved: Number(data?.saved ?? items.length),
      });
    }

    if (action === "set_drop_lock") {
      const { error } = await client.rpc("lock_legacy_drop_order", {
        p_account_id: accountId,
      });
      if (error) throw error;
      return jsonResponse(request, { ok: true });
    }

    if (action === "confirm_my_payment" || action === "confirm_my_shipfee") {
      const which = String(body.which || "r3");
      if (which !== "r3" && which !== "drop") throw new Error("付款类型无效");
      const kind = action === "confirm_my_shipfee" ? "shipfee" : which;
      const { error } = await client.rpc("set_legacy_member_confirmation", {
        p_account_id: accountId,
        p_kind: kind,
        p_set: parseBooleanFlag(body.set),
      });
      if (error) throw error;
      return jsonResponse(request, { ok: true });
    }

    return jsonResponse(request, { error: "不支持的操作" }, 400);
  } catch (error) {
    const message = publicErrorMessage(error);
    console.error("my-data request failed", {
      message: error instanceof Error ? error.message : String(error),
    });
    const validation = message !== "服务器处理失败";
    return jsonResponse(request, { error: message }, validation ? 400 : 500);
  }
});
