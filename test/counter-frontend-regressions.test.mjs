import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFile } from 'node:fs/promises';

async function readPage(name) {
  return readFile(new URL(`../${name}`, import.meta.url), 'utf8');
}

function extractFunction(source, name) {
  const signature = new RegExp(`(?:async\\s+)?function\\s+${name}\\s*\\(`);
  const match = signature.exec(source);
  assert.ok(match, `missing ${name}`);
  const start = match.index;
  const bodyStart = source.indexOf('{', start);
  let depth = 0;

  for (let index = bodyStart; index < source.length; index += 1) {
    if (source[index] === '{') depth += 1;
    if (source[index] === '}') depth -= 1;
    if (depth === 0) return source.slice(start, index + 1);
  }

  throw new Error(`unterminated ${name}`);
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

test('Badge 保存使用请求快照，响应期间的新编辑仍保持 dirty', async () => {
  const source = await readPage('badge_counter.html');
  const request = deferred();
  let sentBody;
  const submitButton = { disabled: false, textContent: '' };
  const context = vm.createContext({
    console,
    document: { getElementById: () => submitButton },
    callCounter: (body) => {
      sentBody = body;
      return request.promise;
    },
    setTimeout,
  });

  vm.runInContext(`
    const BADGES = [{id:'badge_one'}];
    let myName = '001-A';
    let myDisplayNick = 'A';
    let currentQty = {badge_one:1};
    let allOrders = {'001-A':{qtyByBadge:{badge_one:0},paymentSelf:false,updatedAt:''}};
    let pending = {qtyByBadge:{badge_one:1}};
    function getOrder(name){return allOrders[name] || {qtyByBadge:{},paymentSelf:false,updatedAt:''};}
    function markDirty(){pending={qtyByBadge:{...currentQty}};}
    function clearDirty(){pending={};}
    function setIdentity(fullName){myName=fullName;myDisplayNick=fullName.replace(/^\\d+-/,'');}
    function render(){}
    ${extractFunction(source, 'captureOrderSnapshot')}
    ${extractFunction(source, 'syncDirtyState')}
    ${extractFunction(source, 'submitOrder')}
  `, context);

  const savePromise = vm.runInContext('submitOrder()', context);
  vm.runInContext('currentQty.badge_one=2;markDirty();', context);
  request.resolve({ account: { full_name: '001-A' } });
  assert.equal(await savePromise, true);

  assert.equal(sentBody.items[0].quantity, 1, '发出的必须是点击保存时的数量');
  assert.equal(vm.runInContext('allOrders[myName].qtyByBadge.badge_one', context), 1);
  assert.equal(vm.runInContext('currentQty.badge_one', context), 2);
  assert.equal(vm.runInContext('pending.qtyByBadge.badge_one', context), 2);
  assert.equal(submitButton.textContent, '保存新修改');
});

test('Plush 保存使用请求快照，新数量与新昵称不会被旧响应覆盖', async () => {
  const source = await readPage('plush_counter.html');
  const request = deferred();
  let sentBody;
  const submitButton = { disabled: false, textContent: '' };
  const context = vm.createContext({
    console,
    document: { getElementById: () => submitButton },
    callCounter: (body) => {
      sentBody = body;
      return request.promise;
    },
    setTimeout,
  });

  vm.runInContext(`
    const NS_SOUND='plush__sound_qty';
    const NS_SILENT='plush__silent_qty';
    let myName='001-A';
    let myDisplayNick='A';
    let draftNick='A';
    let soundQty=1;
    let silentQty=0;
    let allOrders={'001-A':{soundQty:0,silentQty:0,updatedAt:''}};
    let pending={nick:'A',soundQty:1,silentQty:0};
    function getOrder(name){return allOrders[name] || {soundQty:0,silentQty:0,updatedAt:''};}
    function markDirty(){pending={nick:draftNick,soundQty,silentQty};}
    function clearDirty(){pending={};}
    function setIdentity(fullName){myName=fullName;myDisplayNick=fullName.replace(/^\\d+-/,'');draftNick=myDisplayNick;}
    function render(){}
    ${extractFunction(source, 'captureOrderSnapshot')}
    ${extractFunction(source, 'syncDirtyState')}
    ${extractFunction(source, 'submitOrder')}
  `, context);

  const savePromise = vm.runInContext('submitOrder()', context);
  vm.runInContext("soundQty=2;draftNick='B';markDirty();", context);
  request.resolve({ account: { full_name: '001-A' } });
  assert.equal(await savePromise, true);

  assert.equal(sentBody.display_name, 'A');
  assert.equal(sentBody.items.find((item) => item.product_id === 'plush__sound_qty').quantity, 1);
  assert.equal(vm.runInContext('allOrders[myName].soundQty', context), 1);
  assert.equal(vm.runInContext('soundQty', context), 2);
  assert.equal(vm.runInContext('draftNick', context), 'B');
  assert.equal(vm.runInContext('pending.soundQty', context), 2);
  assert.equal(submitButton.textContent, '保存新修改');
});

test('两个 Counter 清空都要确认，失败按返回值回滚而不依赖不可达 catch', async () => {
  for (const page of ['badge_counter.html', 'plush_counter.html']) {
    const source = await readPage(page);
    const clearOrder = extractFunction(source, 'clearMyOrder');
    const submitOrder = extractFunction(source, 'submitOrder');

    assert.match(clearOrder, /confirm\s*\(/, `${page} 清空前必须确认`);
    assert.match(clearOrder, /const\s+saved\s*=\s*await\s+submitOrder\s*\(\s*\)/);
    assert.match(clearOrder, /if\s*\(\s*saved\s*\)\s*return/);
    assert.match(clearOrder, /syncDirtyState\s*\(\s*\)/, `${page} 回滚后必须重算 dirty`);
    assert.doesNotMatch(clearOrder, /try\s*\{[^}]*await\s+submitOrder[\s\S]*?catch/);
    assert.match(submitOrder, /catch\s*\([^)]*\)\s*\{[\s\S]*?return false\s*;/);
  }
});

test('Badge 付款确认失败会给用户可见提示', async () => {
  const source = await readPage('badge_counter.html');
  const markPaid = extractFunction(source, 'markPaid');
  assert.match(markPaid, /catch\s*\([^)]*\)\s*\{[\s\S]*?alert\s*\(/);
  assert.match(markPaid, /付款状态更新失败/);
});

test('Plush 个人与团估算包含整单 ¥4.5 运费，空订单不收运费', async () => {
  const source = await readPage('plush_counter.html');
  const context = vm.createContext({});
  vm.runInContext(`
    const SILENT_UNIT_PRICE=26;
    const SOUND_UNIT_PRICE=26.5;
    const SHIPPING_FEE=4.5;
    ${extractFunction(source, 'estimateOrderTotal')}
    ${extractFunction(source, 'estimateOrderExtra')}
    ${extractFunction(source, 'estimateOrderText')}
  `, context);

  assert.equal(vm.runInContext('estimateOrderTotal(0,0)', context), 0);
  assert.equal(vm.runInContext('estimateOrderTotal(0,1)', context), 30.5);
  assert.equal(vm.runInContext('estimateOrderTotal(1,0)', context), 31);
  assert.equal(vm.runInContext('estimateOrderTotal(1,1)', context), 57);
  assert.equal(vm.runInContext('estimateOrderExtra(0,0)', context), 0);
  assert.equal(vm.runInContext('estimateOrderExtra(1,0)', context), 5);
  assert.equal(vm.runInContext("estimateOrderText(0,1)", context), '¥30.50');

  assert.match(source, /summaryTotal'\)\.textContent\s*=\s*estimateOrderText\(soundQty,\s*silentQty\)/);
  assert.match(source, /summaryExtra'\)\.textContent\s*=\s*'¥'\s*\+\s*estimateOrderExtra\(soundQty,\s*silentQty\)/);
  assert.match(source, /estimatedGrandTotal\s*=\s*entries\.reduce\([\s\S]*?estimateOrderTotal\(order\.soundQty,\s*order\.silentQty\)/);
  assert.match(source, /const estimated\s*=\s*estimateOrderText\(order\.soundQty,\s*order\.silentQty\)/);
  assert.match(source, /estimateOrderExtra\(order\.soundQty,\s*order\.silentQty\)/);
});

test('drop.html 自动与手动入口都惰性跳转到 Drop2', async () => {
  const source = await readPage('drop.html');
  assert.match(source, /http-equiv="refresh"\s+content="0;\s*url=drop2\.html"/i);
  assert.match(source, /<a\s+href="drop2\.html">/i);
  assert.doesNotMatch(source, /(?:url|href)=round3\.html/i);
  assert.doesNotMatch(source, /<script\b/i);
});

test('旧页修复不得恢复 Supabase 直连或明文 PIN 标记', async () => {
  for (const page of ['badge_counter.html', 'plush_counter.html', 'drop.html']) {
    const source = await readPage(page);
    assert.doesNotMatch(source, /(?:@supabase\/supabase-js|\bcreateClient\s*\(|\.\s*from\s*\(|\bpostgres_changes\b|__pin\b)/i, page);
  }
});
