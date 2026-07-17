import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';

const ACTIVE_HTML = [
  'round3.html',
  'drop2.html',
  'badge_counter.html',
  'plush_counter.html',
  'round4.html',
];

const projectUrl = new URL('../', import.meta.url);

function projectFile(path) {
  return new URL(path, projectUrl);
}

async function readProjectFile(path) {
  return readFile(projectFile(path), 'utf8');
}

function stripSourceComments(source) {
  return source
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/^\s*\/\/.*$/gm, '');
}

function stripSqlComments(source) {
  return source
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/--.*$/gm, '');
}

async function findMigration(suffix) {
  const migrationNames = await readdir(projectFile('supabase/migrations/'));
  const matches = migrationNames.filter((name) => name.endsWith(suffix));
  assert.equal(matches.length, 1, `expected exactly one migration ending in ${suffix}`);
  return readProjectFile(`supabase/migrations/${matches[0]}`);
}

async function collectTypeScriptSources(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const sources = [];

  for (const entry of entries) {
    const entryUrl = new URL(`${entry.name}${entry.isDirectory() ? '/' : ''}`, directory);
    if (entry.isDirectory()) {
      sources.push(...await collectTypeScriptSources(entryUrl));
    } else if (entry.name.endsWith('.ts') && !entry.name.endsWith('_test.ts')) {
      sources.push({ path: entryUrl.pathname, source: await readFile(entryUrl, 'utf8') });
    }
  }

  return sources;
}

test('active HTML 不再携带浏览器直连 Supabase 或明文 PIN 标记', async (t) => {
  const forbiddenPatterns = [
    [/(?:@supabase\/supabase-js|\bsupabase-js\b|\bcreateClient\s*\(|\bwindow\s*\.\s*supabase\b)/i, 'Supabase JS SDK'],
    [/\.\s*from\s*\(/i, 'direct table .from()'],
    [/\bpostgres_changes\b/i, 'postgres_changes realtime channel'],
    [/__pin\b/i, 'legacy plaintext PIN marker'],
  ];

  for (const page of ACTIVE_HTML) {
    await t.test(page, async () => {
      const source = await readProjectFile(page);
      for (const [pattern, label] of forbiddenPatterns) {
        assert.doesNotMatch(source, pattern, `${page} must not contain ${label}`);
      }
    });
  }
});

test('Round4 只通过动态 catalog/bootstrap 和版本化 RPC 工作', async () => {
  const source = stripSourceComments(await readProjectFile('round4.html'));
  assert.match(source, /action\s*:\s*['"]catalog['"]\s*,\s*round_id\s*:\s*ROUND_ID/);
  assert.match(source, /action\s*:\s*['"]bootstrap['"]\s*,\s*round_id\s*:\s*ROUND_ID/);
  assert.match(source, /action\s*,\s*round_id\s*:\s*ROUND_ID[\s\S]{0,240}expected_version\s*:/);
  assert.match(source, /action\s*:\s*['"]save_address['"]/);
  assert.match(source, /action\s*:\s*['"]confirm_payment['"]/);
  assert.match(source, /!state\.busyAction[\s\S]{0,180}\(!order \|\| order\.status === ['"]draft['"]\)/);
  assert.doesNotMatch(source, /const\s+(?:PRODUCTS|STICKERS|CATALOG)\s*=\s*\[/i);
});

test('Round3 和 Drop2 通过 auth session 恢复账号并通过 my-data 读取快照', async (t) => {
  for (const page of ['round3.html', 'drop2.html']) {
    await t.test(page, async () => {
      const source = stripSourceComments(await readProjectFile(page));
      assert.match(
        source,
        /callEF\s*\(\s*['"]auth['"]\s*,\s*\{\s*action\s*:\s*['"]session['"][^}]*\}\s*\)/,
        `${page} must validate the saved account token through auth session`,
      );
      assert.match(
        source,
        /callEF\s*\(\s*['"]my-data['"]\s*,\s*\{\s*action\s*:\s*['"]get_legacy_snapshot['"][^}]*\}\s*\)/,
        `${page} must load legacy data through my-data get_legacy_snapshot`,
      );
    });
  }
});

test('Badge 和 Plush 通过 counter Edge Function 并校验 session', async (t) => {
  for (const page of ['badge_counter.html', 'plush_counter.html']) {
    await t.test(page, async () => {
      const source = stripSourceComments(await readProjectFile(page));
      assert.match(
        source,
        /fetch\s*\(\s*EF_BASE\s*\+\s*['"]\/counter['"]/,
        `${page} must send counter requests to /counter`,
      );
      assert.match(
        source,
        /callCounter\s*\(\s*\{\s*action\s*:\s*['"]session['"][^}]*\}\s*\)/,
        `${page} must validate the saved counter token with session`,
      );
    });
  }
});

test('Edge Functions 不得用 service role key 回退签发 JWT，也不得开放通配 CORS', async () => {
  const sourceFiles = await collectTypeScriptSources(projectFile('supabase/functions/'));
  const source = stripSourceComments(
    sourceFiles.map(({ path, source: fileSource }) => `\n/* ${path} */\n${fileSource}`).join('\n'),
  );

  const jwtFallbackPatterns = [
    /Deno\.env\.get\(\s*['"]CUSTOM_JWT_SECRET['"]\s*\)\s*(?:\|\||\?\?)\s*Deno\.env\.get\(\s*['"]SUPABASE_SERVICE_ROLE_KEY['"]\s*\)/,
    /Deno\.env\.get\(\s*['"]SUPABASE_SERVICE_ROLE_KEY['"]\s*\)\s*(?:\|\||\?\?)\s*Deno\.env\.get\(\s*['"]CUSTOM_JWT_SECRET['"]\s*\)/,
    /\bcustomJwtSecret\b\s*(?:\|\||\?\?)\s*\bserviceRoleKey\b/,
    /\bserviceRoleKey\b\s*(?:\|\||\?\?)\s*\bcustomJwtSecret\b/,
    /\bcustomJwtSecret\b\s*\?\s*\bcustomJwtSecret\b\s*:\s*\bserviceRoleKey\b/,
    /\bserviceRoleKey\b\s*\?\s*\bserviceRoleKey\b\s*:\s*\bcustomJwtSecret\b/,
    /TextEncoder\s*\(\s*\)\s*\.\s*encode\s*\(\s*(?:serviceRoleKey|Deno\.env\.get\(\s*['"]SUPABASE_SERVICE_ROLE_KEY['"]\s*\))/,
    /(?:signAccountToken|verifyAccountToken|jwtVerify)\s*\([^)]*\bserviceRoleKey\b/,
  ];

  for (const pattern of jwtFallbackPatterns) {
    assert.doesNotMatch(source, pattern, 'service role key must never be a JWT secret fallback');
  }

  assert.doesNotMatch(
    source,
    /(?:['"]Access-Control-Allow-Origin['"]\s*:\s*|\.set\(\s*['"]Access-Control-Allow-Origin['"]\s*,\s*)['"]\*['"]/i,
    'Edge Functions must not use wildcard CORS',
  );

  const edgeAuth = stripSourceComments(await readProjectFile('supabase/functions/_shared/edge-auth.ts'));
  assert.match(edgeAuth, /allowedOrigins\.has\(origin\)/, 'CORS origin must be checked against an allowlist');
  assert.match(
    edgeAuth,
    /['"]Access-Control-Allow-Origin['"]\s*:\s*allowedOrigin/,
    'CORS response must return the selected allowlisted origin',
  );
});

test('最终权限迁移撤销所有 legacy tables 的 anon 与 authenticated 权限', async () => {
  const source = stripSqlComments(await findMigration('_private_legacy_tables.sql'));

  for (const table of ['orders', 'addresses', 'settings', 'accounts', 'user_pins']) {
    const revokePattern = new RegExp(
      `\\bREVOKE\\s+ALL(?:\\s+PRIVILEGES)?\\s+ON\\s+(?:TABLE\\s+)?public\\.${table}\\s+FROM\\s+` +
      `(?=[^;]*\\banon\\b)(?=[^;]*\\bauthenticated\\b)[^;]+;`,
      'i',
    );
    assert.match(source, revokePattern, `legacy table ${table} must be private from browser roles`);
  }
});

test('Round4 地址按 shipping_group_id 共享且每账号在每个发货组唯一', async () => {
  const source = stripSqlComments(await findMigration('_round4_normalized_schema.sql'))
    .replace(/\s+/g, ' ');

  assert.match(
    source,
    /CREATE TABLE public\.group_buy_rounds\s*\([^;]*\bshipping_group_id\s+text\s+NOT NULL[^;]*\);/i,
    'each round must declare its shipping group',
  );
  assert.match(
    source,
    /CREATE TABLE public\.account_addresses\s*\([^;]*\baccount_id\s+uuid\s+NOT NULL[^;]*\bshipping_group_id\s+text\s+NOT NULL[^;]*UNIQUE\s*\(\s*account_id\s*,\s*shipping_group_id\s*\)[^;]*\);/i,
    'addresses must be unique by account and shipping group',
  );
  assert.match(
    source,
    /SELECT\s+shipping_group_id\s+INTO\s+v_shipping_group_id\s+FROM\s+public\.group_buy_rounds\s+WHERE\s+id\s*=\s*p_round_id/i,
    'address writes must resolve the shared shipping group from the round',
  );
  assert.match(
    source,
    /INSERT INTO public\.account_addresses\s*\(\s*account_id\s*,\s*shipping_group_id[^;]*ON CONFLICT\s*\(\s*account_id\s*,\s*shipping_group_id\s*\)\s+DO UPDATE/i,
    'address upserts must share one row per account and shipping group',
  );
});
