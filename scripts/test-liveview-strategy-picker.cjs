// Execute the actual display-only preference editor, never a real Controller/device.
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
function compile(source, modules) {
  const c = { exports: {}, require: key => { assert.ok(key in modules, key); return modules[key]; }, getContext: () => ({}) };
  vm.runInNewContext(ts.transpileModule(source).outputText, c); return c.exports;
}
const strategy = compile(fs.readFileSync('cexing/entry/src/main/ets/lib/LiveViewStrategy.ets', 'utf8'), {});
let proxies = { first: { type: 'Selector', now: 'leaf' }, 自动: { type: 'Smart' }, DIRECT: { type: 'Direct' }, REJECT: { type: 'Reject' } };
let saved = { mainGroup: 'first' }, writes = 0, reads = 0, refreshes = 0, failSave = false, held = false;
const waits = [];
const api = { getProxies: () => { reads++; return held ? new Promise(resolve => waits.push(resolve)) : Promise.resolve(proxies); },
  selectProxy: () => { throw Error('Display selection must never change real policy'); }, patchMode: () => { throw Error('Display selection must never change mode'); } };
const source = fs.readFileSync('cexing/entry/src/main/ets/pages/LiveViewStrategyPicker.ets', 'utf8');
const methods = (source.slice(0, source.indexOf('  build()')) + '\n}').split('\n').map(line => line.trimStart().startsWith('@') ?
  line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '') : line).join('\n').replace('export struct ', 'export class ');
const { LiveViewStrategyPicker } = compile(methods, { '@kit.AbilityKit': {}, './NativeTheme': {},
  '../lib/VpnController': { VpnStatus: { Connected: 2, Disconnected: 0 } }, '../lib/CoreApi': { CoreApi: api },
  '../lib/LiveViewStrategy': strategy, '../lib/LiveViewKeeper': { LiveViewKeeper: { refreshDisplayGroup: async () => { refreshes++; } } },
  '../lib/Settings': { Settings: { load: () => ({ ...saved }), save: (_ctx, value) => { if (failSave) throw Error('disk'); writes++; saved = value; } } } });
(async () => {
  const page = new LiveViewStrategyPicker(); page.status = 2; page.aboutToAppear();
  await page.open(); page.draft = '自动'; assert.equal(page.selectedIndex(), 2, 'Literal group named 自动 is distinct from default sentinel');
  page.cancel(); assert.equal(writes, 0, 'Choosing and cancelling never changes a preference'); assert.equal(refreshes, 0);
  held = true; const old = page.open(); await page.open(); assert.equal(waits.length, 1, 'Repeated open has one request');
  page.cancel(); waits.shift()(proxies); await old; assert.equal(page.editing, false); assert.equal(writes, 0);
  const stale = page.open(); page.aboutToDisappear(); page.aboutToAppear(); waits.shift()(proxies); await stale;
  assert.equal(page.editing, false, 'Returned page cannot accept an old read'); held = false;
  await page.open(); page.draft = '自动'; failSave = true; await page.apply(); assert.equal(writes, 0); assert.match(page.message, /保存失败/);
  failSave = false; held = true; const pending = page.apply(); await page.apply(); assert.equal(waits.length, 1, 'Repeated apply has one write intent');
  waits.shift()(proxies); await pending; assert.equal(saved.mainGroup, '自动'); assert.equal(writes, 1); assert.equal(refreshes, 1);
  held = false; await page.open(); page.draft = 'first'; held = true; const changed = page.apply();
  waits.shift()({ 自动: { type: 'Smart' } }); await changed; assert.equal(writes, 1); assert.match(page.message, /策略已变化/);
  page.cancel(); held = false; await page.open(); page.draft = 'first'; held = true; const late = page.apply();
  page.status = 0; page.cancel(); waits.shift()(proxies); await late; assert.equal(writes, 1, 'Late validation after disconnect cannot persist');
  console.log('PASS: display-only policy, staged cancel, repeated clicks, page/status fences, preference failure and changed group validation');
})().catch(error => { console.error(error); process.exitCode = 1; });
