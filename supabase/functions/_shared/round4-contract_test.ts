import { assertEquals, assertThrows } from "jsr:@std/assert@1.0.13";
import {
  parseAddress,
  parseBooleanFlag,
  parseExpectedVersion,
  parseOrderItems,
  parsePaymentKind,
  parseRoundId,
  parseTeam,
} from "./round4-contract.ts";

Deno.test("round id and team validation", () => {
  assertEquals(parseRoundId(" Round4 "), "round4");
  assertEquals(parseTeam("6", 6), 6);
  assertThrows(() => parseRoundId("../round4"));
  assertThrows(() => parseTeam(7, 6));
});

Deno.test("order items are normalized and reject duplicates", () => {
  assertEquals(parseOrderItems([{ product_id: " CLAWD ", quantity: "2" }]), [{
    product_id: "clawd",
    quantity: 2,
  }]);
  assertThrows(() =>
    parseOrderItems([
      { product_id: "clawd", quantity: 1 },
      { product_id: "clawd", quantity: 2 },
    ])
  );
  assertThrows(() => parseOrderItems([{ product_id: "clawd", quantity: -1 }]));
});

Deno.test("address validation keeps only normalized fields", () => {
  assertEquals(
    parseAddress({
      label: " 家 ",
      recipient: " 测试用户 ",
      phone: "138-0000-0000",
      address: " 北京市朝阳区测试路 1 号 ",
      ignored: "x",
    }),
    {
      label: "家",
      recipient: "测试用户",
      phone: "13800000000",
      address: "北京市朝阳区测试路 1 号",
    },
  );
  assertThrows(() =>
    parseAddress({ recipient: "A", phone: "123", address: "短" })
  );
});

Deno.test("version and payment kind validation", () => {
  assertEquals(parseExpectedVersion(0), 0);
  assertEquals(parsePaymentKind("shipping"), "shipping");
  assertEquals(parseBooleanFlag(1), true);
  assertEquals(parseBooleanFlag(false), false);
  assertThrows(() => parseExpectedVersion(-1));
  assertThrows(() => parsePaymentKind("all"));
  assertThrows(() => parseBooleanFlag("false"));
});
