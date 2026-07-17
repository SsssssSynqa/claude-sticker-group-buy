export type OrderItemInput = { product_id: string; quantity: number };
export type AddressInput = {
  label: string;
  recipient: string;
  phone: string;
  address: string;
};

const ROUND_ID_RE = /^[a-z0-9][a-z0-9_-]{1,31}$/;
const PRODUCT_ID_RE = /^[a-z0-9][a-z0-9_-]{0,63}$/;

export function parseRoundId(value: unknown): string {
  const roundId = String(value ?? "").trim().toLowerCase();
  if (!ROUND_ID_RE.test(roundId)) throw new Error("轮次参数无效");
  return roundId;
}

export function parseTeam(value: unknown, maximum = 20): number {
  const team = Number(value);
  if (!Number.isInteger(team) || team < 1 || team > maximum) {
    throw new Error("团号无效");
  }
  return team;
}

export function parseExpectedVersion(value: unknown): number {
  const version = Number(value);
  if (!Number.isSafeInteger(version) || version < 0) {
    throw new Error("订单版本无效");
  }
  return version;
}

export function parseOrderItems(value: unknown): OrderItemInput[] {
  if (!Array.isArray(value) || value.length > 200) {
    throw new Error("订单商品格式无效");
  }
  const seen = new Set<string>();
  return value.map((entry) => {
    if (!entry || typeof entry !== "object") {
      throw new Error("订单商品格式无效");
    }
    const productId = String(
      (entry as Record<string, unknown>).product_id ?? "",
    ).trim().toLowerCase();
    const quantity = Number((entry as Record<string, unknown>).quantity);
    if (!PRODUCT_ID_RE.test(productId)) throw new Error("商品编号无效");
    if (!Number.isInteger(quantity) || quantity < 0 || quantity > 10000) {
      throw new Error("商品数量无效");
    }
    if (seen.has(productId)) throw new Error("订单中存在重复商品");
    seen.add(productId);
    return { product_id: productId, quantity };
  });
}

export function parseAddress(value: unknown): AddressInput {
  if (!value || typeof value !== "object") throw new Error("地址格式无效");
  const record = value as Record<string, unknown>;
  const label = String(record.label ?? "默认地址").trim().slice(0, 30) ||
    "默认地址";
  const recipient = String(record.recipient ?? "").trim();
  const phone = String(record.phone ?? "").replace(/[\s-]/g, "");
  const address = String(record.address ?? "").trim();
  if (recipient.length < 1 || recipient.length > 50) {
    throw new Error("收件人格式无效");
  }
  if (!/^\+?\d{7,15}$/.test(phone)) throw new Error("手机号格式无效");
  if (address.length < 5 || address.length > 300) {
    throw new Error("详细地址格式无效");
  }
  return { label, recipient, phone, address };
}

export function parsePaymentKind(value: unknown): "product" | "shipping" {
  if (value === "product" || value === "shipping") return value;
  throw new Error("付款类型无效");
}

export function parseBooleanFlag(value: unknown, label = "状态"): boolean {
  if (value === true || value === 1) return true;
  if (value === false || value === 0) return false;
  throw new Error(`${label}无效`);
}
