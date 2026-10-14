const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const read = name => fs.readFileSync(`cexing/entry/src/main/ets/${name}`, 'utf8');
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
let pending, calls = 0;
const statuses = [{ id: 'model', label: 'Smart 模型', state: 'ready' }];
const recovery = {
  inspect: async () => statuses,
  restore: async (_, id, token, permit) => { calls++; assert.ok(permit()); if (pending) await pending.promise; }
};
const controller = { status: 0, needsStop: () => false };
let source = read('pages/ResourceRecoveryPage.ets');
source = (source.slice(0, source.indexOf('  build()')) + '\n}').split('\n')
  .map(line => line.trimStart().startsWith('@') ? line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '') : line)
  .join('\n').replace('export struct ', 'export class ');
const modules = { '../lib/ResourceRecovery': { ResourceRecovery: recovery }, '../lib/VpnController': { VpnController: controller, VpnStatus: { Disconnected: 0 } }, './NativeTheme': {} };
const sandbox = { exports: {}, getContext: () => ({}), require: n => modules[n] };
vm.runInNewContext(ts.transpileModule(source).outputText, sandbox);
(async () => {
  const page = new sandbox.exports.ResourceRecoveryPage();
  page.aboutToAppear(); await page.refresh();
  pending = deferred();
  const operation = page.restore('model');
  await page.restore('model'); assert.equal(calls, 1, 'repeat click ignored');
  const token = page.cancellation;
  page.aboutToDisappear(); assert.equal(token.cancelled, true);
  page.aboutToAppear(); await page.refresh();
  page.message = '新页面'; pending.resolve(); await operation;
  assert.equal(page.message, '新页面', 'old completion cannot update reopened page');
  pending = deferred();
  const hidden = page.restore('panel');
  page.visible = false; page.visibilityChanged();
  assert.equal(page.cancellation.cancelled, true);
  page.visible = true; page.visibilityChanged(); await page.refresh();
  page.message = '返回前台'; pending.resolve(); await hidden;
  assert.equal(page.message, '返回前台', 'cached navigation hide invalidates old completion');
  pending = null;
  await page.restore('model'); assert.equal(page.message, '已恢复');

  // Exercise the real service: queued cancellation, stop gate and last-good failure.
  let finish = deferred(), restores = 0;
  const assets = {
    './GeoDataAssets': { GeoDataAssets: { inspect: async () => 'ready', restore: async () => { restores++; await finish.promise; } } },
    './SmartModelAssets': { SmartModelAssets: { inspect: async () => ({ state: 'missing' }), prepare: async () => ({ state: 'invalid' }) } },
    './ZashboardAssets': { ZashboardAssets: { inspect: async () => 'ready', prepare: async () => ({ directory: '/private/ui', fallback: true }) } }
  };
  const host = { exports: {}, require: n => assets[n] };
  vm.runInNewContext(ts.transpileModule(read('lib/ResourceRecovery.ets')).outputText, host);
  const service = host.exports.ResourceRecovery;
  assert.equal((await service.inspect({})).length, 3);
  const active = service.restore({}, 'geodata', { cancelled: false }, () => true);
  const cancelled = { cancelled: false };
  const queued = service.restore({}, 'geodata', cancelled, () => true);
  cancelled.cancelled = true; finish.resolve(); await active;
  await assert.rejects(queued, /已取消/); assert.equal(restores, 1);
  await assert.rejects(service.restore({}, 'geodata', { cancelled: false }, () => false), /先断开/);
  await assert.rejects(service.restore({}, 'model', { cancelled: false }, () => true), /恢复失败/);
  await assert.rejects(service.restore({}, 'panel', { cancelled: false }, () => true), /保留可用版本/);
  console.log('PASS: recovery stop gate, queued cancellation, last-good failures, repeat click, return/reopen and stale result');
})().catch(e => { console.error(e); process.exitCode = 1; });
