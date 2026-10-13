const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const source = fs.readFileSync('cexing/entry/src/main/ets/pages/SmartPage.ets', 'utf8');
const methods = (source.slice(0, source.indexOf('  build()')) + '\n}').split('\n')
  .map(line => line.trimStart().startsWith('@') ? line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '') : line)
  .join('\n').replace('export struct ', 'export class ');
let response = null;
const controller = { status: 2 };
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
  await page.refresh(page.generation); assert.match(page.usage, /没有 Smart/); assert.match(page.nextStep, /URL Test/);
  response.groups = { Synthetic: { useLightGBM: true } }; response.model.state = 'loaded';
  await page.refresh(page.generation); assert.equal(page.modelSummary, '模型已加载'); assert.match(page.predictions, /0 次/);
  assert.match(page.predictionNote, /尚未记录/);
  response.model.predictions = 2; response.message = '固定错误的次数为零解释';
  await page.refresh(page.generation); assert.match(page.predictions, /2 次/); assert.match(page.predictionNote, /已记录/);
  assert.ok(!page.predictionNote.includes('尚未')); assert.ok(!page.message.includes('为零'));
  page.message = '已应用到当前运行配置'; await page.refresh(page.generation); assert.equal(page.message, '已应用到当前运行配置');
  response.model.state = 'missing'; response.model.restartRequired = true;
  await page.refresh(page.generation); assert.match(page.modelSummary, /统计策略/); assert.equal(page.restartRequired, true);
  page.aboutToDisappear(); assert.equal(page.active, false);
  console.log('PASS: Smart unavailable/empty/groups, loaded versus zero/nonzero prediction, operation feedback and model recovery');
})().catch(error => { console.error(error); process.exitCode = 1; });
