export const R3_PRODUCT_IDS = [
  "r3_clawd",
  "r3_ultrathink",
  "r3_clawd-happy",
  "r3_vibing-dc",
  "r3_clawd-shiny",
  "r3_claudecode",
  "r3_vibing-holo",
  "r3_reticulating",
  "r3_shipping",
  "r3_manifesting-holo",
  "r3_baking",
  "r3_clawd-wave",
  "r3_manifesting-glt",
  "r3_clawd-heart",
  "r3_clawd-headphones",
  "r3_clawd-wand",
  "r3_clawd-bubble",
  "r3_clawd-coffee",
  "r3_clawd-skateboard",
  "r3_clawd-book",
  "r3_clawd-cape",
  "r3_clawd-dizzy",
  "r3_clawd-kite",
  "r3_clawd-lightbulb",
  "r3_clawd-magnifier",
] as const;

export const R3_PRODUCT_ID_SET = new Set<string>(R3_PRODUCT_IDS);
export const DROP_PRODUCT_IDS = R3_PRODUCT_IDS.map((id) =>
  "drop_r3_" + id.slice(3)
);
export const LEGACY_PRODUCT_ID_SET = new Set<string>([
  ...R3_PRODUCT_IDS,
  ...DROP_PRODUCT_IDS,
]);

export function parseLegacyOrderItems(value: unknown) {
  if (
    !Array.isArray(value) || value.length === 0 ||
    value.length > LEGACY_PRODUCT_ID_SET.size
  ) {
    throw new Error("订单商品格式无效");
  }
  const seen = new Set<string>();
  return value.map((entry) => {
    if (!entry || typeof entry !== "object") {
      throw new Error("订单商品格式无效");
    }
    const row = entry as Record<string, unknown>;
    const stickerId = String(row.sticker_id || "").trim();
    const quantity = Number(row.quantity);
    if (!LEGACY_PRODUCT_ID_SET.has(stickerId)) {
      throw new Error("不允许修改该商品");
    }
    if (!Number.isInteger(quantity) || quantity < 0 || quantity > 10000) {
      throw new Error("数量无效");
    }
    if (seen.has(stickerId)) throw new Error("订单中存在重复商品");
    seen.add(stickerId);
    return { sticker_id: stickerId, quantity };
  });
}

export function parseLegacyTargetName(value: unknown): string {
  const name = String(value ?? "").trim();
  if (name.length < 1 || name.length > 50) throw new Error("昵称格式无效");
  return name;
}

export function parseBooleanFlag(value: unknown): boolean {
  if (value === true || value === 1 || value === "1") return true;
  if (value === false || value === 0 || value === "0") return false;
  throw new Error("状态参数无效");
}

export function parseCnyCents(value: unknown): number {
  if (typeof value !== "string" && typeof value !== "number") {
    throw new Error("金额无效");
  }
  const normalized = String(value).trim();
  const match = /^(\d+)(?:\.(\d{1,2}))?$/.exec(normalized);
  if (!match) throw new Error("金额最多保留两位小数");
  const yuan = Number(match[1]);
  if (!Number.isSafeInteger(yuan) || yuan > 1_000_000) {
    throw new Error("金额无效");
  }
  const cents = Number((match[2] || "").padEnd(2, "0"));
  return yuan * 100 + cents;
}

export function parseLegacyTeam(value: unknown): number {
  const team = Number(value);
  if (!Number.isInteger(team) || team < 1 || team > 6) {
    throw new Error("团号无效");
  }
  return team;
}
