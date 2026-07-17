const CENTS_PER_YUAN = 100;

export function roundToCents(yuan) {
  if (!Number.isFinite(yuan)) throw new TypeError("金额必须是有限数字");
  return Math.round(yuan * CENTS_PER_YUAN);
}

export function centsToYuan(cents) {
  if (!Number.isInteger(cents)) throw new TypeError("分必须是整数");
  return cents / CENTS_PER_YUAN;
}

function validateTiers(tiers) {
  if (!Array.isArray(tiers) || tiers.length === 0) {
    throw new TypeError("价格档不能为空");
  }

  let previousQuantity = 0;
  for (const tier of tiers) {
    if (!Array.isArray(tier) || tier.length !== 2) {
      throw new TypeError("每个价格档必须是 [数量, 总价]");
    }
    const [quantity, totalUsd] = tier;
    if (
      !Number.isInteger(quantity) || quantity <= previousQuantity ||
      !Number.isFinite(totalUsd) || totalUsd < 0
    ) {
      throw new RangeError("价格档必须按正整数数量递增，且总价不能为负");
    }
    previousQuantity = quantity;
  }
}

/**
 * Sticker Mule 的档位记录的是“该数量的总美元价”。档位之间按总价线性插值。
 * 低于 MOQ 时仍使用首档的单张价展示预估，但调用方必须同时展示 MOQ 未满足状态。
 */
export function unitPriceUsd(tiers, quantity) {
  validateTiers(tiers);
  if (!Number.isFinite(quantity) || quantity < 0) {
    throw new RangeError("数量不能为负");
  }

  const firstTier = tiers[0];
  if (quantity <= firstTier[0]) return firstTier[1] / firstTier[0];

  let lower = firstTier;
  for (let index = 1; index < tiers.length; index += 1) {
    const upper = tiers[index];
    if (quantity < upper[0]) {
      const ratio = (quantity - lower[0]) / (upper[0] - lower[0]);
      const interpolatedTotal = lower[1] + ratio * (upper[1] - lower[1]);
      return interpolatedTotal / quantity;
    }
    lower = upper;
  }

  return lower[1] / lower[0];
}

export function tierStatus(tiers, quantity) {
  validateTiers(tiers);
  if (!Number.isFinite(quantity) || quantity < 0) {
    throw new RangeError("数量不能为负");
  }

  const minimum = tiers[0][0];
  if (quantity === 0) {
    return { met: false, minimum, missing: minimum, next: minimum };
  }
  if (quantity < minimum) {
    return { met: false, minimum, missing: minimum - quantity, next: minimum };
  }

  const nextTier = tiers.find(([tierQuantity]) => tierQuantity > quantity);
  return {
    met: true,
    minimum,
    missing: 0,
    next: nextTier ? nextTier[0] : null,
  };
}

export function shippingCentsForAddress(address, config = {}) {
  const normalizedAddress = String(address ?? "").trim();
  if (!normalizedAddress) return null;

  const baseCents = config.baseCents ?? 850;
  const municipalityExtraCents = config.municipalityExtraCents ?? 100;
  const remoteExtraCents = config.remoteExtraCents ?? 1300;

  if (
    [baseCents, municipalityExtraCents, remoteExtraCents].some((value) =>
      !Number.isInteger(value) || value < 0
    )
  ) {
    throw new RangeError("运费配置必须是非负整数分");
  }

  if (
    normalizedAddress.includes("新疆") || normalizedAddress.includes("西藏")
  ) {
    return baseCents + remoteExtraCents;
  }
  if (
    normalizedAddress.includes("北京") || normalizedAddress.includes("上海")
  ) {
    return baseCents + municipalityExtraCents;
  }
  return baseCents;
}

function requireCents(value, field) {
  if (!Number.isInteger(value) || value < 0) {
    throw new RangeError(`${field} 必须是非负整数分`);
  }
  return value;
}

export function calculateSettlement({
  lineItems,
  exchangeRate,
  processingFeeRate = 0.001,
  taxCents = 0,
  shippingCents,
  packingCents = 0,
  paidCents = 0,
  refundedCents = 0,
}) {
  if (!Array.isArray(lineItems)) throw new TypeError("lineItems 必须是数组");
  if (!Number.isFinite(exchangeRate) || exchangeRate <= 0) {
    throw new RangeError("汇率必须大于 0");
  }
  if (!Number.isFinite(processingFeeRate) || processingFeeRate < 0) {
    throw new RangeError("手续费率不能为负");
  }

  const normalizedItems = lineItems.map((item) => {
    const quantity = Number(item.quantity);
    const unitUsd = Number(item.unitUsd);
    if (!Number.isInteger(quantity) || quantity < 0) {
      throw new RangeError("商品数量必须是非负整数");
    }
    if (!Number.isFinite(unitUsd) || unitUsd < 0) {
      throw new RangeError("商品美元单价不能为负");
    }
    return { quantity, unitUsd };
  });

  const itemUsd = normalizedItems.reduce(
    (sum, item) => sum + item.quantity * item.unitUsd,
    0,
  );
  const itemCents = Math.round(itemUsd * exchangeRate * CENTS_PER_YUAN);
  const processingFeeCents = Math.round(itemCents * processingFeeRate);
  requireCents(taxCents, "税费");
  requireCents(packingCents, "包材费");
  requireCents(paidCents, "实付");
  requireCents(refundedCents, "已退款");

  if (shippingCents === null || shippingCents === undefined) {
    return {
      status: "shipping_pending",
      itemUsd,
      itemCents,
      processingFeeCents,
      taxCents,
      shippingCents: null,
      packingCents,
      expectedCents: null,
      netPaidCents: paidCents - refundedCents,
      balanceCents: null,
    };
  }

  requireCents(shippingCents, "运费");
  const expectedCents = itemCents + processingFeeCents + taxCents +
    shippingCents + packingCents;
  const netPaidCents = paidCents - refundedCents;
  const balanceCents = expectedCents - netPaidCents;

  return {
    status: balanceCents > 0
      ? "payment_due"
      : balanceCents < 0
      ? "refund_due"
      : "settled",
    itemUsd,
    itemCents,
    processingFeeCents,
    taxCents,
    shippingCents,
    packingCents,
    expectedCents,
    netPaidCents,
    balanceCents,
  };
}
