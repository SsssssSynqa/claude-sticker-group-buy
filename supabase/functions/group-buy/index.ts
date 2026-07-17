import {
  createClient,
  type SupabaseClient,
} from "https://esm.sh/@supabase/supabase-js@2.57.4";

import {
  type ActiveAccount,
  authenticateAccount,
  corsHeaders,
  jsonResponse,
  publicErrorMessage,
  requireEnvironment,
} from "../_shared/edge-auth.ts";
import {
  parseAddress,
  parseBooleanFlag,
  parseExpectedVersion,
  parseOrderItems,
  parsePaymentKind,
  parseRoundId,
  parseTeam,
} from "../_shared/round4-contract.ts";

function accountDisplayName(value: unknown): string {
  const relation = Array.isArray(value) ? value[0] : value;
  if (!relation || typeof relation !== "object") return "";
  const displayName = (relation as Record<string, unknown>).display_name;
  return typeof displayName === "string" ? displayName : "";
}

function parseOrderId(value: unknown): string {
  const id = String(value ?? "").trim();
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
      .test(id)
  ) {
    throw new Error("订单编号无效");
  }
  return id;
}

function parseOptionalCents(value: unknown, label: string): number | null {
  if (value === null || value === undefined || value === "") return null;
  const cents = Number(value);
  if (!Number.isSafeInteger(cents) || cents < 0 || cents > 100_000_000) {
    throw new Error(`${label}无效`);
  }
  return cents;
}

function parseRequiredCents(value: unknown, label: string): number {
  const cents = parseOptionalCents(value, label);
  if (cents === null) throw new Error(`${label}不能为空`);
  return cents;
}

async function loadCatalog(client: SupabaseClient, roundId: string) {
  const { data: round, error: roundError } = await client
    .from("group_buy_rounds")
    .select(
      "id,title,shipping_group_id,status,team_count,exchange_rate,processing_fee_rate,shipping_config,order_opens_at,order_deadline,payment_deadline,updated_at",
    )
    .eq("id", roundId)
    .maybeSingle();
  if (roundError) throw roundError;
  if (!round) return null;
  const { data: products, error: productsError } = await client
    .from("group_buy_products")
    .select(
      "product_id,name,product_type,size_label,item_url,image_url,sort_order,price_tiers,active,updated_at",
    )
    .eq("round_id", roundId)
    .eq("active", true)
    .order("sort_order");
  if (productsError) throw productsError;
  return { round, products: products || [] };
}

async function loadBootstrap(
  client: SupabaseClient,
  roundId: string,
  account: ActiveAccount,
) {
  const catalog = await loadCatalog(client, roundId);
  if (!catalog) return null;
  const { data: orders, error: ordersError } = await client
    .from("group_buy_orders")
    .select(
      "id,account_id,team,status,version,locked_at,created_at,account:accounts(display_name)",
    )
    .eq("round_id", roundId)
    .order("created_at");
  if (ordersError) throw ordersError;

  const { data: items, error: itemsError } = await client
    .from("group_buy_order_items")
    .select("order_id,product_id,quantity")
    .eq("round_id", roundId);
  if (itemsError) throw itemsError;

  const orderIds = (orders || []).map((order) => order.id);
  const { data: payments, error: paymentsError } = orderIds.length
    ? await client.from("group_buy_payments").select(
      "order_id,kind,expected_cents,paid_cents,refunded_cents,member_confirmed_at,leader_confirmed_at",
    ).in("order_id", orderIds)
    : { data: [], error: null };
  if (paymentsError) throw paymentsError;
  const { data: shipmentStates, error: shipmentStateError } = orderIds.length
    ? await client.from("group_buy_shipments").select(
      "order_id,shipping_cents,shipped_at",
    ).in("order_id", orderIds)
    : { data: [], error: null };
  if (shipmentStateError) throw shipmentStateError;

  const ownOrder =
    (orders || []).find((order) => order.account_id === account.id) || null;
  const { data: ownAddress, error: addressError } = await client
    .from("account_addresses")
    .select(
      "id,shipping_group_id,label,recipient,phone,address,is_default,updated_at",
    )
    .eq("account_id", account.id)
    .eq("shipping_group_id", catalog.round.shipping_group_id)
    .eq("is_default", true)
    .maybeSingle();
  if (addressError) throw addressError;

  const { data: ownShipment, error: shipmentError } = ownOrder
    ? await client.from("group_buy_shipments").select(
      "shipping_cents,tracking_number,shipped_at,address_snapshot,updated_at",
    ).eq("order_id", ownOrder.id).maybeSingle()
    : { data: null, error: null };
  if (shipmentError) throw shipmentError;

  const itemsByOrder = new Map<
    string,
    Array<{ product_id: string; quantity: number }>
  >();
  for (const item of items || []) {
    const list = itemsByOrder.get(item.order_id) || [];
    list.push({ product_id: item.product_id, quantity: item.quantity });
    itemsByOrder.set(item.order_id, list);
  }
  const paymentsByOrder = new Map<string, unknown[]>();
  for (const payment of payments || []) {
    const list = paymentsByOrder.get(payment.order_id) || [];
    list.push(payment);
    paymentsByOrder.set(payment.order_id, list);
  }
  const shipmentByOrder = new Map(
    (shipmentStates || []).map((shipment) => [shipment.order_id, shipment]),
  );

  return {
    ...catalog,
    members: (orders || []).map((order) => ({
      order_id: order.id,
      display_name: accountDisplayName(order.account),
      team: order.team,
      status: order.status,
      items: itemsByOrder.get(order.id) || [],
      payment_statuses: paymentsByOrder.get(order.id) || [],
      shipping: shipmentByOrder.get(order.id) || null,
    })),
    me: {
      account: {
        display_name: account.display_name,
        team: account.team,
        role: account.role,
      },
      order: ownOrder
        ? {
          id: ownOrder.id,
          team: ownOrder.team,
          status: ownOrder.status,
          version: ownOrder.version,
          locked_at: ownOrder.locked_at,
          items: itemsByOrder.get(ownOrder.id) || [],
        }
        : null,
      address: ownAddress,
      shipment: ownShipment,
    },
  };
}

async function loadAdminDetails(client: SupabaseClient, roundId: string) {
  const { data: round, error: roundError } = await client.from(
    "group_buy_rounds",
  ).select("shipping_group_id").eq("id", roundId).maybeSingle();
  if (roundError) throw roundError;
  if (!round) throw new Error("轮次不存在");
  const { data: orders, error: ordersError } = await client.from(
    "group_buy_orders",
  ).select("id,account_id").eq("round_id", roundId);
  if (ordersError) throw ordersError;
  const orderIds = (orders || []).map((order) => order.id);
  const accountIds = (orders || []).map((order) => order.account_id);
  const [addresses, shipments, payments] = await Promise.all([
    accountIds.length
      ? client.from("account_addresses").select(
        "id,account_id,shipping_group_id,label,recipient,phone,address,is_default,updated_at",
      ).in("account_id", accountIds).eq(
        "shipping_group_id",
        round.shipping_group_id,
      )
      : Promise.resolve({ data: [], error: null }),
    orderIds.length
      ? client.from("group_buy_shipments").select("*").in("order_id", orderIds)
      : Promise.resolve({ data: [], error: null }),
    orderIds.length
      ? client.from("group_buy_payments").select("*").in("order_id", orderIds)
      : Promise.resolve({ data: [], error: null }),
  ]);
  if (addresses.error) throw addresses.error;
  if (shipments.error) throw shipments.error;
  if (payments.error) throw payments.error;
  return {
    addresses: addresses.data || [],
    shipments: shipments.data || [],
    payments: payments.data || [],
  };
}

const { supabaseUrl, serviceRoleKey, customJwtSecret } = requireEnvironment();
const client = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false },
});
const jwtSecret = new TextEncoder().encode(customJwtSecret);

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders(request) });
  }
  if (request.method !== "POST") {
    return jsonResponse(request, { error: "POST only" }, 405);
  }

  try {
    const body = await request.json();
    const action = String(body.action || "catalog");
    const roundId = parseRoundId(body.round_id || "round4");

    if (action === "catalog") {
      const catalog = await loadCatalog(client, roundId);
      if (!catalog || catalog.round.status === "draft") {
        return jsonResponse(request, { error: "该轮次尚未开放" }, 404);
      }
      return jsonResponse(request, { ok: true, ...catalog });
    }

    const account = await authenticateAccount(client, request, jwtSecret);
    if (!account) {
      return jsonResponse(request, { error: "未登录或登录已过期" }, 401);
    }

    if (action === "bootstrap") {
      const result = await loadBootstrap(client, roundId, account);
      if (
        !result || (result.round.status === "draft" && account.role !== "admin")
      ) {
        return jsonResponse(request, { error: "该轮次尚未开放" }, 404);
      }
      return jsonResponse(request, { ok: true, ...result });
    }

    if (action === "save_order" || action === "lock_order") {
      const expectedVersion = parseExpectedVersion(body.expected_version);
      const items = parseOrderItems(body.items);
      const { data: round, error: roundError } = await client.from(
        "group_buy_rounds",
      ).select("team_count").eq("id", roundId).single();
      if (roundError) throw roundError;
      const team = parseTeam(body.team ?? account.team, round.team_count);
      const { data, error } = await client.rpc("save_group_buy_order", {
        p_account_id: account.id,
        p_round_id: roundId,
        p_team: team,
        p_expected_version: expectedVersion,
        p_items: items,
        p_lock: action === "lock_order",
      });
      if (error) {
        const conflict = error.code === "40001";
        return jsonResponse(request, {
          error: conflict
            ? "订单已在其他设备更新，请刷新后重试"
            : publicErrorMessage(error),
          code: error.code,
        }, conflict ? 409 : 400);
      }
      return jsonResponse(request, { ok: true, order: data });
    }

    if (action === "save_address") {
      const address = parseAddress(body.address);
      const { data, error } = await client.rpc("save_group_buy_address", {
        p_account_id: account.id,
        p_round_id: roundId,
        p_label: address.label,
        p_recipient: address.recipient,
        p_phone: address.phone,
        p_address: address.address,
      });
      if (error) throw error;
      return jsonResponse(request, { ok: true, address: data });
    }

    if (action === "confirm_payment") {
      const kind = parsePaymentKind(body.kind);
      const set = parseBooleanFlag(body.set, "付款状态");
      const { data, error } = await client.rpc(
        "set_group_buy_member_payment",
        {
          p_account_id: account.id,
          p_round_id: roundId,
          p_kind: kind,
          p_set: set,
        },
      );
      if (error) throw error;
      return jsonResponse(request, { ok: true, payment: data });
    }

    if (account.role !== "admin") {
      return jsonResponse(request, { error: "仅管理员可操作" }, 403);
    }

    if (action === "admin_bootstrap") {
      return jsonResponse(request, {
        ok: true,
        ...(await loadAdminDetails(client, roundId)),
      });
    }

    if (action === "admin_set_payment") {
      const orderId = parseOrderId(body.order_id);
      const kind = parsePaymentKind(body.kind);
      const confirmed = parseBooleanFlag(body.confirmed, "核实状态");
      if (
        !Object.hasOwn(body, "expected_cents") ||
        !Object.hasOwn(body, "paid_cents") ||
        !Object.hasOwn(body, "refunded_cents")
      ) {
        throw new Error("请同时提交应付、实付和退款金额");
      }
      const expectedCents = parseOptionalCents(body.expected_cents, "应付金额");
      const paidCents = parseRequiredCents(body.paid_cents, "实付金额");
      const refundedCents = parseRequiredCents(body.refunded_cents, "退款金额");
      if (refundedCents > paidCents) {
        throw new Error("退款金额不能大于实付金额");
      }
      const { data: target, error: targetError } = await client.from(
        "group_buy_orders",
      ).select("id").eq("id", orderId).eq("round_id", roundId).maybeSingle();
      if (targetError) throw targetError;
      if (!target) throw new Error("订单不存在");
      const now = new Date().toISOString();
      const { error } = await client.from("group_buy_payments").upsert({
        order_id: orderId,
        kind,
        expected_cents: expectedCents,
        paid_cents: paidCents,
        refunded_cents: refundedCents,
        leader_confirmed_at: confirmed ? now : null,
        updated_at: now,
      }, { onConflict: "order_id,kind" });
      if (error) throw error;
      return jsonResponse(request, { ok: true });
    }

    if (action === "admin_set_shipment") {
      const orderId = parseOrderId(body.order_id);
      const shippingCents = parseOptionalCents(body.shipping_cents, "运费");
      const trackingNumber = String(body.tracking_number || "").trim();
      if (trackingNumber.length > 100) throw new Error("快递单号格式无效");
      const shipped = parseBooleanFlag(body.shipped, "发货状态");
      const { data: target, error: targetError } = await client.from(
        "group_buy_orders",
      ).select("id").eq("id", orderId).eq("round_id", roundId).maybeSingle();
      if (targetError) throw targetError;
      if (!target) throw new Error("订单不存在");
      const { error } = await client.from("group_buy_shipments").upsert({
        order_id: orderId,
        shipping_cents: shippingCents,
        tracking_number: trackingNumber || null,
        shipped_at: shipped ? new Date().toISOString() : null,
        updated_at: new Date().toISOString(),
      }, { onConflict: "order_id" });
      if (error) throw error;
      return jsonResponse(request, { ok: true });
    }

    if (action === "admin_set_round_status") {
      const status = String(body.status || "");
      if (
        !["draft", "open", "locked", "payment", "shipping", "closed"].includes(
          status,
        )
      ) {
        throw new Error("轮次状态无效");
      }
      const { data: updatedRound, error } = await client.from(
        "group_buy_rounds",
      ).update({
        status,
        updated_at: new Date().toISOString(),
      }).eq("id", roundId).select("id").maybeSingle();
      if (error) throw error;
      if (!updatedRound) throw new Error("轮次不存在");
      return jsonResponse(request, { ok: true, status });
    }

    return jsonResponse(request, { error: "不支持的操作" }, 400);
  } catch (error) {
    const message = publicErrorMessage(error);
    console.error("group-buy request failed", {
      message: error instanceof Error ? error.message : String(error),
    });
    const validation = message !== "服务器处理失败";
    return jsonResponse(request, { error: message }, validation ? 400 : 500);
  }
});
