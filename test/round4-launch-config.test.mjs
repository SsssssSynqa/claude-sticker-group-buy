import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const projectUrl = new URL('../', import.meta.url);

async function readProjectFile(path) {
  return readFile(new URL(path, projectUrl), 'utf8');
}

function round3Catalog(source) {
  const match = source.match(/const S = (\[[\s\S]*?\n\]);/);
  assert.ok(match, 'Round3 product catalog must be present');
  return vm.runInNewContext(`(${match[1]})`);
}

function seededRound4Catalog(source) {
  const rowPattern = /\('round4',\s*'([^']+)',\s*'([^']+)',\s*'(dc|holo|glt|other)',\s*'([^']*)',\s*'([^']+)',\s*'([^']+)',\s*(\d+),\s*'(\[\[.*?\]\])'::jsonb,\s*true\)/g;
  return [...source.matchAll(rowPattern)].map((match) => ({
    id: match[1],
    name: match[2],
    type: match[3],
    size: match[4],
    itemUrl: match[5],
    imageUrl: match[6],
    sortOrder: Number(match[7]),
    tiers: JSON.parse(match[8]),
  }));
}

test('Round4 服务端目录逐项继承 Round3 的 25 款商品与价格档', async () => {
  const [round3Source, seedSource] = await Promise.all([
    readProjectFile('round3.html'),
    readProjectFile('supabase/migrations/20260717002500_round4_launch_config.sql'),
  ]);
  const expected = JSON.parse(JSON.stringify(round3Catalog(round3Source).map((product, index) => ({
    id: product.id.replace(/^r3_/, ''),
    name: product.name,
    type: product.type,
    size: product.size,
    itemUrl: `https://www.stickermule.com/claudecode/item/${product.itemId}?origin=PUBLIC_PROFILE`,
    imageUrl: product.img,
    sortOrder: index + 1,
    tiers: product.t,
  }))));

  assert.equal(expected.length, 25);
  assert.deepEqual(seededRound4Catalog(seedSource), expected);
});

test('Round4 使用六团旧规则并按北京时间 7 月 20 日至 24 日开放', async () => {
  const [seedSource, pageSource, edgeSource] = await Promise.all([
    readProjectFile('supabase/migrations/20260717002500_round4_launch_config.sql'),
    readProjectFile('round4.html'),
    readProjectFile('supabase/functions/group-buy/index.ts'),
  ]);

  assert.match(seedSource, /'round4_drop4'/);
  assert.match(seedSource, /\n\s*6,\n\s*7\.1000,/);
  assert.match(seedSource, /'2026-07-20 00:00:00\+08'::timestamptz/);
  assert.match(seedSource, /'2026-07-24 23:59:59\+08'::timestamptz/);
  assert.match(seedSource, /group_buy_order_window_guard/);
  assert.match(edgeSource, /shipping_config,order_opens_at,order_deadline/);
  assert.match(pageSource, /Round 4 意向登记中 · 开团时间暂定/);
  assert.doesNotMatch(pageSource, /7 月 20 日开始 · 7 月 24 日截团/);
  assert.match(pageSource, /timeZone:\s*'Asia\/Shanghai'/);
  assert.match(pageSource, /orderWindowState\(round\)\.editable/);
  assert.match(pageSource, /数量 \$\{compactValue\(tier\[0\]\)\} · USD 总价 \$\$\{compactValue\(tier\[1\]\)\}/);
  assert.match(pageSource, /<img src="r2-pay-5\.png" alt="Round 4 一至六团付款码">/);
  assert.match(pageSource, /paymentQrButton['"]\)\.disabled[\s\S]{0,220}Number\(cents\) > 0/);
  assert.doesNotMatch(pageSource, /最终商品、日期与视觉仍待 Synqa 确认/);
});

test('Round4 意向登记模式：迁移开放填写、汇率 7.0、开团时间留空暂定', async () => {
  const [intentSource, pageSource] = await Promise.all([
    readProjectFile('supabase/migrations/20261104000000_round4_intent_mode.sql'),
    readProjectFile('round4.html'),
  ]);

  // 后端迁移把第四团拨到意向模式：开放态、汇率 7.0、时间留空
  assert.match(intentSource, /UPDATE public\.group_buy_rounds/);
  assert.match(intentSource, /status\s*=\s*'open'/);
  assert.match(intentSource, /exchange_rate\s*=\s*7\.0000/);
  assert.match(intentSource, /order_opens_at\s*=\s*NULL/);
  assert.match(intentSource, /order_deadline\s*=\s*NULL/);
  assert.match(intentSource, /payment_deadline\s*=\s*NULL/);
  assert.match(intentSource, /WHERE id = 'round4'/);

  // 前端进入意向模式：总开关开启，状态条显示暂定
  assert.match(pageSource, /const INTENT_MODE = true/);
  assert.match(pageSource, /意向登记中/);
  assert.match(pageSource, /开团时间：暂定/);
});

