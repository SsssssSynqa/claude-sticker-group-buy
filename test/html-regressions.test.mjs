import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFile } from 'node:fs/promises';

function extractFunction(source, name) {
  const start = source.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, `missing ${name}`);
  const bodyStart = source.indexOf('{', start);
  let depth = 0;
  for (let index = bodyStart; index < source.length; index += 1) {
    if (source[index] === '{') depth += 1;
    if (source[index] === '}') depth -= 1;
    if (depth === 0) return source.slice(start, index + 1);
  }
  throw new Error(`unterminated ${name}`);
}

for (const page of ['round3.html', 'drop2.html']) {
  test(`${page} 低于 MOQ 的页面价格函数不再产生 NaN`, async () => {
    const source = await readFile(new URL(`../${page}`, import.meta.url), 'utf8');
    const context = vm.createContext({});
    vm.runInContext(`${extractFunction(source, 'unitPrice')}; globalThis.unitPrice = unitPrice;`, context);
    const sticker = { t: [[10, 17], [50, 63]] };
    for (const quantity of [1, 5, 9]) {
      assert.equal(context.unitPrice(sticker, quantity), 1.7);
    }
  });
}

test('Drop2 应补应退使用商品加运费的统一口径', async () => {
  const source = await readFile(new URL('../drop2.html', import.meta.url), 'utf8');
  assert.match(source, /const diff = r2\(tot \+ shipInfo\.amount - paid\)/);
  assert.match(source, /const teamDiff = r2\(tCNY \+ tShippingKnown - tActualPaid\)/);
  assert.doesNotMatch(source, /const diff = r2\(tot - paid\)/);
});

test('Drop2 依据真实 Round3 商品订单合并发货', async () => {
  const source = await readFile(new URL('../drop2.html', import.meta.url), 'utf8');
  assert.match(source, /let r3OrderNames = new Set\(\)/);
  assert.match(source, /function hasR3Order\(name = myName\) \{ return r3OrderNames\.has\(name\); \}/);
  assert.match(source, /if \(hasR3Order\(name\)\) return \{text: '随R3'/);
  assert.doesNotMatch(source, /if \(r3PaidNames\.has\(name\)\) return \{text: '随R3'/);
});

test('保存成功只清除本次请求快照，保留请求期间的新编辑', async () => {
  for (const page of ['round3.html', 'drop2.html']) {
    const source = await readFile(new URL(`../${page}`, import.meta.url), 'utf8');
    assert.match(source, /if \(pendingChanges\[sid\] === qty\) delete pendingChanges\[sid\]/);
    assert.doesNotMatch(extractFunction(source, 'submitCart'), /pendingChanges = \{\}/);
  }
});

test('用户昵称进入内联事件前经过 JavaScript 参数编码', async () => {
  for (const page of ['round3.html', 'drop2.html']) {
    const source = await readFile(new URL(`../${page}`, import.meta.url), 'utf8');
    const context = vm.createContext({});
    vm.runInContext(`${extractFunction(source, 'jsArg')}; globalThis.jsArg = jsArg;`, context);
    const encoded = context.jsArg(`&quot;');alert(1)//<script>\u2028`);
    assert.match(encoded, /^&quot;/);
    assert.match(encoded, /&amp;quot;/);
    assert.match(encoded, /&lt;script&gt;/);
    assert.doesNotMatch(encoded, /<script>/);
    assert.doesNotMatch(encoded, /\u2028/);
    assert.match(encoded, /\\u2028/);
    assert.doesNotMatch(source, /esc\(name\)\.replace\(\/'\/g/);
    assert.doesNotMatch(source, /JSON\.stringify\(name\)\.replace\(\/"\/g/);
  }
});

test('旧入口是真正的惰性跳转页，不再携带旧数据库代码', async () => {
  for (const page of ['index.html', 'claude_sticker_group_buy.html', 'round2.html']) {
    const source = await readFile(new URL(`../${page}`, import.meta.url), 'utf8');
    assert.match(source, /http-equiv="refresh" content="0; url=round3\.html"/);
    assert.doesNotMatch(source, /SUPA_|createClient|\.from\(|upsert|delete\(\)|_pin/);
    assert.doesNotMatch(source, /<script/i);
  }
  const dropSource = await readFile(new URL('../drop.html', import.meta.url), 'utf8');
  assert.match(dropSource, /http-equiv="refresh" content="0; url=drop2\.html"/);
  assert.doesNotMatch(dropSource, /SUPA_|createClient|\.from\(|upsert|delete\(\)|_pin/);
  assert.doesNotMatch(dropSource, /<script/i);
});
