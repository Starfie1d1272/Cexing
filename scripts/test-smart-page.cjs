const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const source = fs.readFileSync('cexing/entry/src/main/ets/pages/SmartPage.ets', 'utf8');
const methods = (source.slice(0, source.indexOf('  build()')) + '\n}').split('\n')
  .map(line => line.trimStart().startsWith('@') ? line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '') : line)
  .join('\n').replace('export struct ', 'export class ');
let response = null;
let listener;
const controller = { status: 2, onChanged(fn) { listener = fn; }, offChanged() { listener = undefined; } };

const modules = { '@kit.AbilityKit': {}, '@kit.CoreFileKit': {}, './NativeTheme': {}, '../lib/SmartModelRestart': {},
  '../lib/Settings': { Settings: { load: () => ({ smartAutoConvert: true }) } }, '../lib/ProfileTransactions': {},
  '../lib/VpnController': { VpnController: controller, VpnStatus: { Connected: 2 } },
  '../lib/CoreApi': { CoreApi: { getSmartStatus: async () => response } } };
const sandbox = { exports: {}, require: key => modules[key], getContext: () => ({}), setTimeout: () => 1, clearTimeout() {} };
vm.runInNewContext(ts.transpileModule(methods).outputText, sandbox);
(async () => {
  const page = new sandbox.exports.SmartPage(); page.visible = true; page.aboutToAppear();
  await page.refresh(page.generation); assert.equal(page.ready, false); assert.ok(!page.predictions.includes('0 次'));
  response = { groups: {}, model: { state: 'not-requested', predictions: 0, restartRequired: false }, message: 'unused' };
  await page.refresh(page.generation); assert.equal(page.usage, '当前配置未使用智能选择'); assert.match(page.nextStep, /订阅详情/);
  response.groups = { Synthetic: { useLightGBM: true } }; response.model.state = 'loaded';
  await page.refresh(page.generation); assert.equal(page.modelSummary, '模型已加载'); assert.match(page.predictions, /0 次/);
  assert.match(page.predictionNote, /尚未记录/); assert.equal(page.usage, '智能选择已启用');
  response.model.predictions = 2; response.message = '固定错误的次数为零解释';
  await page.refresh(page.generation); assert.match(page.predictions, /2 次/); assert.match(page.predictionNote, /已记录/);
  assert.ok(!page.predictionNote.includes('尚未')); assert.ok(!page.message.includes('为零'));
  page.message = '已应用到当前运行配置'; await page.refresh(page.generation); assert.equal(page.message, '已应用到当前运行配置');
  response.model.state = 'missing'; response.model.restartRequired = true;
  await page.refresh(page.generation); assert.match(page.modelSummary, /统计策略/); assert.equal(page.restartRequired, true);
  response.groups = {}; await page.refresh(page.generation); assert.equal(page.usage, '当前配置未使用智能选择', 'Switching to a Selector-only profile removes the old enabled status');
  controller.status = 0; await page.refresh(page.generation); assert.equal(page.usage, '连接后查看智能选择'); assert.equal(page.ready, false);
  controller.status = 2; response = null; await page.refresh(page.generation); assert.equal(page.usage, '暂时无法读取状态'); assert.equal(page.groupSummary, '等待读取运行配置');
  const build = source.slice(source.indexOf('  build()'));
  const defaults = build.slice(0, build.indexOf('        if (this.detailsOpen)'));
  for (const detail of ['this.groupSummary', 'this.nextStep', 'this.predictions', 'this.predictionNote', 'this.modelSummary']) assert.ok(!defaults.includes(detail), detail + ' must be on demand');
  assert.ok(build.includes('Text(this.groupSummary)')); assert.ok(build.includes('Text(this.predictions)'));
  let resolve; modules['../lib/CoreApi'].CoreApi.getSmartStatus = () => new Promise(done => resolve = done);
  const stale = page.refresh(page.generation); controller.status = 0; listener(0);
  await Promise.resolve(); resolve({ groups: { old: { useLightGBM: true } }, model: { state: 'loaded', predictions: 999 } }); await stale;
  assert.equal(page.usage, '连接后查看智能选择', 'Old Controller response cannot restore status after disconnect');
  page.aboutToDisappear(); assert.equal(page.active, false);
  console.log('PASS: Smart unavailable/empty/groups, loaded versus zero/nonzero prediction, operation feedback and model recovery');
})().catch(error => { console.error(error); process.exitCode = 1; });
