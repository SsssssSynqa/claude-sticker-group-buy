import test from "node:test";
import assert from "node:assert/strict";

import {
  calculateSettlement,
  centsToYuan,
  roundToCents,
  shippingCentsForAddress,
  tierStatus,
  unitPriceUsd,
} from "../src/core/settlement.mjs";

const holoTiers = [[10, 17], [50, 63], [100, 76]];

test("低于 MOQ 使用首档单张价，不产生 NaN", () => {
  for (const quantity of [0, 1, 5, 9, 10]) {
    assert.equal(unitPriceUsd(holoTiers, quantity), 1.7);
    assert.equal(Number.isNaN(unitPriceUsd(holoTiers, quantity)), false);
  }
});

test("价格档之间按总价线性插值", () => {
  // 10 张 $17、50 张 $63；30 张的插值总价为 $40。
  assert.equal(unitPriceUsd(holoTiers, 30), 40 / 30);
});

test("超过最高档沿用最高档单张价", () => {
  assert.equal(unitPriceUsd(holoTiers, 200), 0.76);
});

test("MOQ 状态与下一档明确", () => {
  assert.deepEqual(tierStatus(holoTiers, 5), {
    met: false,
    minimum: 10,
    missing: 5,
    next: 10,
  });
  assert.deepEqual(tierStatus(holoTiers, 30), {
    met: true,
    minimum: 10,
    missing: 0,
    next: 50,
  });
  assert.deepEqual(tierStatus(holoTiers, 100), {
    met: true,
    minimum: 10,
    missing: 0,
    next: null,
  });
});

test("运费按地址使用同一套规则", () => {
  assert.equal(shippingCentsForAddress(""), null);
  assert.equal(shippingCentsForAddress("广东省深圳市南山区"), 850);
  assert.equal(shippingCentsForAddress("北京市朝阳区"), 950);
  assert.equal(shippingCentsForAddress("上海市浦东新区"), 950);
  assert.equal(shippingCentsForAddress("新疆乌鲁木齐市"), 2150);
  assert.equal(shippingCentsForAddress("西藏拉萨市"), 2150);
});

test("结算统一包含商品、手续费、税费、运费和包材费", () => {
  const result = calculateSettlement({
    lineItems: [{ quantity: 2, unitUsd: 1.5 }],
    exchangeRate: 6.8,
    taxCents: 120,
    shippingCents: 850,
    packingCents: 50,
    paidCents: 1000,
  });

  assert.equal(result.itemCents, 2040);
  assert.equal(result.processingFeeCents, 2);
  assert.equal(result.expectedCents, 3062);
  assert.equal(result.balanceCents, 2062);
  assert.equal(result.status, "payment_due");
});

test("地址未知时不伪造最终应付金额", () => {
  const result = calculateSettlement({
    lineItems: [{ quantity: 1, unitUsd: 1 }],
    exchangeRate: 6.8,
    shippingCents: null,
  });

  assert.equal(result.status, "shipping_pending");
  assert.equal(result.expectedCents, null);
  assert.equal(result.balanceCents, null);
});

test("退款计入净实付，结清与应退状态一致", () => {
  const settled = calculateSettlement({
    lineItems: [],
    exchangeRate: 6.8,
    shippingCents: 850,
    paidCents: 1000,
    refundedCents: 150,
  });
  assert.equal(settled.netPaidCents, 850);
  assert.equal(settled.status, "settled");

  const refundDue = calculateSettlement({
    lineItems: [],
    exchangeRate: 6.8,
    shippingCents: 850,
    paidCents: 1000,
  });
  assert.equal(refundDue.balanceCents, -150);
  assert.equal(refundDue.status, "refund_due");
});

test("金额转换只在边界取整为分", () => {
  assert.equal(roundToCents(8.505), 851);
  assert.equal(centsToYuan(851), 8.51);
});

test("非法档位和金额被拒绝", () => {
  assert.throws(() => unitPriceUsd([[10, 17], [10, 20]], 10), /递增/);
  assert.throws(
    () =>
      calculateSettlement({ lineItems: [], exchangeRate: 0, shippingCents: 0 }),
    /汇率/,
  );
  assert.throws(
    () =>
      calculateSettlement({
        lineItems: [],
        exchangeRate: 6.8,
        shippingCents: 8.5,
      }),
    /整数分/,
  );
});
