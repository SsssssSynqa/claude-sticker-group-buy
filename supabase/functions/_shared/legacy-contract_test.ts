import { assertEquals, assertThrows } from "jsr:@std/assert@1.0.14";
import {
  parseBooleanFlag,
  parseCnyCents,
  parseLegacyOrderItems,
  parseLegacyTargetName,
  parseLegacyTeam,
} from "./legacy-contract.ts";

Deno.test("legacy items accept only known Round3 and Drop2 products", () => {
  assertEquals(
    parseLegacyOrderItems([
      { sticker_id: "r3_clawd", quantity: 2 },
      { sticker_id: "drop_r3_clawd", quantity: 0 },
    ]),
    [
      { sticker_id: "r3_clawd", quantity: 2 },
      { sticker_id: "drop_r3_clawd", quantity: 0 },
    ],
  );
  assertThrows(() =>
    parseLegacyOrderItems([{ sticker_id: "r3__actual_paid", quantity: 1 }])
  );
  assertThrows(() =>
    parseLegacyOrderItems([
      { sticker_id: "r3_clawd", quantity: 1 },
      { sticker_id: "r3_clawd", quantity: 2 },
    ])
  );
});

Deno.test("legacy scalar validation rejects coercion surprises", () => {
  assertEquals(parseBooleanFlag("0"), false);
  assertEquals(parseBooleanFlag(true), true);
  assertThrows(() => parseBooleanFlag("false"));
  assertEquals(parseCnyCents("12.30"), 1230);
  assertEquals(parseCnyCents(1.5), 150);
  assertThrows(() => parseCnyCents("1.005"));
  assertThrows(() => parseCnyCents(1.005));
  assertThrows(() => parseCnyCents("1e3"));
  assertThrows(() => parseCnyCents(-1));
  assertEquals(parseLegacyTeam("6"), 6);
  assertThrows(() => parseLegacyTeam(7));
  assertEquals(parseLegacyTargetName(" Alice "), "Alice");
});
