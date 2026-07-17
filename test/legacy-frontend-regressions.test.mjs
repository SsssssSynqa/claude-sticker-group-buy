import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const pageSource = async page => readFile(new URL(`../${page}`, import.meta.url), 'utf8');

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

function extractJsonObject(source, name) {
  const match = source.match(new RegExp(`const ${name} = (\\{[^\\n]+\\});`));
  assert.ok(match, `missing ${name}`);
  return JSON.parse(match[1]);
}

test('Round3/Drop2 地址请求只能回填当前弹窗且不覆盖新输入', async () => {
  for (const page of ['round3.html', 'drop2.html']) {
    const source = await pageSource(page);
    const guard = extractFunction(source, 'addressLoadCanApply');
    const load = extractFunction(source, 'loadAddressFor');
    assert.match(source, /field\.addEventListener\('input', \(\) => \{ addressInputRevision \+= 1; \}\)/);
    assert.match(guard, /requestRevision === addressLoadRevision/);
    assert.match(guard, /inputRevisionAtStart === addressInputRevision/);
    assert.match(load, /if \(!addressLoadCanApply\(name, requestRevision, inputRevisionAtStart\)\) return/);
    assert.match(load, /writeAddressForm\(/);
  }

  const round3 = await pageSource('round3.html');
  assert.match(extractFunction(round3, 'addressLoadCanApply'), /name === currentAddressFormTarget\(\)/);
});

test('Round3 二次地址请求失败时保留已有缓存', async () => {
  const source = await pageSource('round3.html');
  const load = extractFunction(source, 'loadAllAddressesCache');
  const failureReturn = load.indexOf('return false;');
  const addressCommit = load.indexOf('allAddressesCache = nextAddresses;');
  const summaryCommit = load.indexOf('allShippingSummary = nextShippingSummary;');
  assert.match(load, /const nextAddresses = \{\}/);
  assert.match(load, /const nextShippingSummary = \{\}/);
  assert.ok(failureReturn > -1);
  assert.ok(addressCommit > failureReturn, '地址缓存必须在请求成功后再原子替换');
  assert.ok(summaryCommit > failureReturn, '运费摘要必须在请求成功后再原子替换');
  assert.doesNotMatch(load.slice(0, failureReturn), /allAddressesCache = \{\}/);
  assert.doesNotMatch(load.slice(0, failureReturn), /allShippingSummary = \{\}/);
});

test('快递单号只在服务端保存成功后推进 lastSaved 和绿色状态', async () => {
  for (const [page, saveName] of [['round3.html', 'saveTracking'], ['drop2.html', 'saveDropTracking']]) {
    const source = await pageSource(page);
    const save = extractFunction(source, saveName);
    assert.match(save, /return true;/);
    assert.match(save, /catch[\s\S]*return false;/);
    assert.match(source, new RegExp(`const saved = await ${saveName}\\(name, v\\);[\\s\\S]*if \\(!saved\\) \\{[\\s\\S]*return;[\\s\\S]*lastSaved = v;`));
  }
});

test('管理员实付、退款和团长确认失败时回滚乐观状态', async () => {
  const round3 = await pageSource('round3.html');
  const drop2 = await pageSource('drop2.html');

  for (const fn of [
    extractFunction(round3, 'leaderConfirmPayment'),
    extractFunction(round3, 'leaderConfirmShipFee'),
    extractFunction(drop2, 'leaderConfirm'),
  ]) {
    assert.match(fn, /const previousLeader = !!/);
    assert.match(fn, /const previousSelf = !!/);
    assert.match(fn, /if \(previousLeader\)[\s\S]*else delete/);
    assert.match(fn, /if \(previousSelf\)[\s\S]*else delete/);
    assert.match(fn, /renderTable\(\); recalculate\(\); saveOffline\(\);/);
  }

  for (const fn of [
    extractFunction(round3, 'saveActualPaid'),
    extractFunction(round3, 'saveRefunded'),
    extractFunction(drop2, 'saveActualPaid'),
  ]) {
    assert.match(fn, /const hadPrevious = Object\.prototype\.hasOwnProperty\.call/);
    assert.match(fn, /if \(hadPrevious\)[\s\S]*else delete/);
    assert.match(fn, /renderTable\(\); recalculate\(\); saveOffline\(\);/);
  }
});

test('Drop2 锁单后不恢复 stale local draft', async () => {
  const source = await pageSource('drop2.html');
  const restore = extractFunction(source, 'restorePendingDraft');
  assert.match(restore, /^function restorePendingDraft\(\) \{\s*if \(iAmLocked\(\)\)/);
  assert.match(restore, /pendingChanges = \{\};\s*clearPendingDraft\(\);\s*return false;/);
  assert.match(source, /if \(iAmLocked\(\)\) \{\s*pendingChanges = \{\};\s*clearPendingDraft\(\);\s*\} else \{\s*restorePendingDraft\(\);/);
});

test('Round3/Drop2 保存与清空共用串行队列', async () => {
  for (const page of ['round3.html', 'drop2.html']) {
    const source = await pageSource(page);
    assert.match(source, /let orderMutationQueue = Promise\.resolve\(\)/);
    assert.match(extractFunction(source, 'enqueueOrderMutation'), /orderMutationQueue\.then\(operation\)/);
    assert.match(extractFunction(source, 'submitCart'), /return enqueueOrderMutation\(submitCartNow\)/);
    const clear = extractFunction(source, 'clearMyOrders');
    assert.match(clear, /clearMutationPending = true/);
    assert.match(clear, /enqueueOrderMutation\(clearMyOrdersNow\)/);
    assert.match(extractFunction(source, 'clearMyOrdersNow'), /pendingChanges = \{\}[\s\S]*action: 'submit_orders'/);
    assert.match(extractFunction(source, 'flushPendingOnExit'), /if \(clearMutationPending\)/);
  }
});

test('320x568 所用的登录、付款、地址和公告弹窗可纵向滚动', async () => {
  for (const page of ['round3.html', 'drop2.html']) {
    const source = await pageSource(page);
    assert.match(source, /\.nick-overlay\{[^}]*overflow-y:auto/);
    assert.match(source, /\.nick-popup\{[^}]*max-height:calc\(100dvh - 32px\)[^}]*overflow-y:auto/);
    assert.match(source, /\.pay-qr-overlay\{[^}]*overflow-y:auto/);
    assert.match(source, /\.pay-qr-popup\{[^}]*max-height:calc\(100dvh - 32px\)[^}]*overflow-y:auto/);
    assert.match(source, /#reminderOverlay>div\{[^}]*max-height:calc\(100dvh - 32px\)[^}]*overflow-y:auto/);
  }
});

test('Round3 六团汇总和顶部实付总计沿用行汇总口径', async () => {
  const source = await pageSource('round3.html');
  assert.match(source, /六团汇总/);
  assert.doesNotMatch(source, /五团汇总/);
  assert.match(source, /personActual = r2\(actualBase \+ actualFee \+ personTax \+ personShipfee \+ personPackfee\)/);
  assert.match(source, /const grandActualCNY = gtActual > 0 \? r2\(gtActual\) : 0;/);
  assert.doesNotMatch(source, /const grandActualCNY = r2\(actualUSD \* rate/);
});

test('Round3 导出掉落订单使用 Drop2 自己的折扣单价和汇率', async () => {
  const round3 = await pageSource('round3.html');
  const drop2 = await pageSource('drop2.html');
  assert.deepEqual(extractJsonObject(round3, 'DROP_EXPORT_R3_TOTALS'), extractJsonObject(drop2, 'R3_TOTALS'));
  assert.match(round3, /const DROP_EXPORT_ACTUAL_USD = 2004\.5;/);
  assert.match(drop2, /const DROP_ACTUAL_USD = 2004\.5;/);
  assert.match(round3, /dropExportGrandUSD \+= r2\(unitPrice\(s, qty\) \* qty\)/);
  assert.match(round3, /DROP_EXPORT_UNIT_PRICES\[s\.id\] = unitPrice\(s, DROP_EXPORT_R3_TOTALS\[s\.id\] \|\| 0\) \* DROP_EXPORT_DISCOUNT_RATIO/);
  assert.match(round3, /if \(setting\.key === 'drop_r3_rate'\) dropRate = parseFloat\(setting\.value\)/);
  assert.match(round3, /const up = DROP_EXPORT_UNIT_PRICES\[s\.id\] \|\| 0;/);
  assert.match(round3, /dropUSD \* dropRate/);
  assert.match(round3, /dropQty \* dropUnitPrice/);
  assert.match(round3, /dropTotalUSD \* dropRate/);
});

test('jsArg XSS 编码和 snapshotRevision 优化仍保留', async () => {
  for (const page of ['round3.html', 'drop2.html']) {
    const source = await pageSource(page);
    assert.match(source, /function jsArg\(value\)/);
    assert.match(source, /let snapshotRevision = null/);
    assert.match(source, /known_revision: snapshotRevision/);
  }
});

test('输错旧密码不会误删仍有效的登录 token', async () => {
  for (const page of ['round3.html', 'drop2.html']) {
    const source = await pageSource(page);
    assert.match(source, /const credentialFailure = fn === 'auth' && \['login', 'change_pin'\]\.includes\(body && body\.action\)/);
    assert.match(source, /if \(r\.status === 401 && !credentialFailure\) efClearToken\(\)/);
    assert.doesNotMatch(source, /if \(r\.status === 401\) efClearToken\(\)/);
  }
});
