const uiFixture = require('./ci/ui-fixtures.cjs');
// Read-only generated result lifecycle with synthetic content; no device/UI claim.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const root = 'cexing/entry/src/main/ets/pages/';
const detail = fs.readFileSync(root + 'ProfilePage.ets', 'utf8');
assert.match(detail, /DetailAction\('本订阅覆写'[\s\S]*?name: 'profileMerge'/);
assert.match(detail, /DetailAction\('生成配置'[\s\S]*?name: 'profileGenerated'/);
assert.ok(!detail.includes("DetailAction('内核参数覆写'"));
let source = fs.readFileSync(root + 'ProfileGeneratedPage.ets', 'utf8');
source = source.slice(0, source.indexOf('  build()')) + '\n}';
source = source.split('\n').map(line => line.trimStart().startsWith('@') ?
  line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '') : line).join('\n').replace('export struct ', 'export class ');
let state = { Profiles: {} }, fail = false, resolveRead, reads = 0;
const bus = { current: 'first.yaml' };
const modules = {
  '@kit.CoreFileKit': { fileIo: { readText: async path => {
    reads++; assert.equal(path, '/synthetic/generated.yaml');
    return await new Promise(resolve => { resolveRead = resolve; });
  } } },
  '../lib/EffectiveVersions': { EffectiveVersions: { read: () => {
    if (fail) throw Error('corrupt state'); return state;
  } } },
  './ProfileEditPage': { ProfileEditBus: bus }
};
const sandbox = { exports: {}, getContext: () => ({}), require: name => modules[name] ?? {} };
Object.assign(sandbox, uiFixture.globals); modules['../lib/UiText'] = uiFixture.module;
vm.runInNewContext(ts.transpileModule(source).outputText, sandbox);
(async () => {
  const page = new sandbox.exports.ProfileGeneratedPage();
  await page.load(); assert.equal(page.error, '尚无生成配置，请先启用订阅'); assert.equal(reads, 0);
  fail = true; await page.load(); assert.equal(page.error, '生成配置读取失败，请重试');
  fail = false; state.Profiles['first.yaml'] = { Path: '/synthetic/generated.yaml' };
  const loading = page.load(); assert.equal(page.loading, true);
  resolveRead('proxies: []\n'); await loading; assert.equal(page.content, 'proxies: []\n');
  const stale = page.load(); page.aboutToDisappear(); resolveRead('stale secret'); await stale;
  assert.equal(page.content, '', 'a hidden page cannot receive a late result');
  console.log('PASS: direct scoped entries, read-only published inspection, missing/corrupt state and stale async result');
})().catch(error => { console.error(error); process.exitCode = 1; });
