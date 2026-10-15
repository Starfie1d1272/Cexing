// Actual global/local page methods + production result classifier and formatter.
const assert = require('node:assert/strict');
const fs = require('node:fs'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs'), ui = require('./ci/ui-fixtures.cjs');
const shared = require('./ci/semantic-fixture.cjs');
let attempts = 0, message = '配置已保存，地区选择待重连恢复', closeCalls = 0;
const toasts = [], storage = new Map();
let activeFile = 'synthetic.yaml', persistentPending = false;
const stateModules = {
  './ProfileStore': { ProfileStore: { getActiveFile: () => activeFile, isApplyUncertain: () => false } },
  './EffectiveVersions': { EffectiveVersions: { read: () => ({ Profiles: { 'synthetic.yaml': {} } }), editIntent: () => null, regionPlan: () => null } },
  './ProfileRegionChoices': { ProfileRegionChoices: { selector: () => 'Pick', read: () => ({ pending: persistentPending ? 'Pick' : '' }) } },
  './VpnController': { VpnStatus: { Connected: 2 }, VpnController: { status: 2 } }
};
const feedback = { exports: {}, require: key => stateModules[key] ?? {} };
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/ProfileApplyFeedback.ets', 'utf8')).outputText, feedback);
const modules = {
  '../lib/UiText': ui.module, '../lib/CoreValidator': shared, '../lib/ProfileApplyFeedback': feedback.exports,
  '../lib/GlobalMergeDraft': { GlobalMergeDraft: { save() {}, read: () => null } },
  '../lib/EffectiveVersions': { EffectiveVersions: { globalContent: () => 'rules: []' } },
  '../lib/ProfileStore': { ProfileStore: { getActiveFile: () => activeFile, getProfileContent: () => 'synthetic', getMergeDraft: () => '', readDraft: () => null } },
  '../lib/ProfileTransactions': { ProfileTransactions: {
    applyGlobalMerge: async () => { attempts++; throw Error(message); },
    applyMerge: async () => { attempts++; throw Error(message); }
  } },
  '@kit.ArkUI': { promptAction: { showToast: ({message}) => toasts.push(message) } }
};
function load(name) {
  let source = fs.readFileSync(`cexing/entry/src/main/ets/pages/${name}.ets`, 'utf8');
  const point = source.indexOf('  @Builder');
  source = (source.slice(0, point < 0 ? source.indexOf('  build()') : point) + '\n}')
    .split('\n').map(line => line.trimStart().startsWith('@') ? line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '') : line)
    .join('\n').replace('export struct ', 'export class ');
  const box = { exports: {}, ...ui.globals, getContext: () => ({}),
    AppStorage: { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) },
    require: key => modules[key] ?? {} };
  vm.runInNewContext(ts.transpileModule(source).outputText, box);
  const Page = box.exports[name]; Page.bus = box.exports.ProfileEditBus; return Page;
}
(async () => {
  const Global = load('GlobalMergeEditor'), Local = load('ProfileEditPage');
  persistentPending = true;
  const reopenedGlobal = new Global(), reopenedLocal = new Local();
  // Local page normally gets this identity from the registered navigation bus.
  modules['../lib/ProfileStore'].ProfileStore.getActiveFile = () => activeFile;
  reopenedGlobal.aboutToAppear();
  assert.equal(reopenedGlobal.committedPending, true, 'reopening reads committed recovery state');
  // Bus is exported in the same production module; test load retains exports below.
  Local.bus.current = 'synthetic.yaml'; reopenedLocal.aboutToAppear();
  assert.equal(reopenedLocal.mergeCommittedPending, true);
  activeFile = 'different.yaml'; const unrelated = new Local(); unrelated.aboutToAppear();
  assert.equal(unrelated.mergeCommittedPending, false, 'another subscription does not inherit the active recovery lock');
  activeFile = 'synthetic.yaml'; persistentPending = false;
  const global = new Global(), local = new Local();
  global.profileRevision = 0; global.editedText = 'rules: []'; global.onClose = () => closeCalls++;
  local.profileRevision = 0; local.file = 'synthetic.yaml'; local.mergeText = local.persistedMergeText = 'rules: []';
  await global.apply(); await local.applyMerge();
  assert.equal(attempts, 2); assert.equal(global.committedPending, true); assert.equal(local.mergeCommittedPending, true);
  for (const text of [global.summary, local.mergeSummary, toasts.at(-1)]) {
    assert.match(text, /配置已保存/); assert.match(text, /连接页.*断开.*重新连接/); assert.ok(!text.includes('重试'));
  }
  assert.equal(global.globalEnabled, true); assert.equal(global.profileRevision, 1); assert.equal(local.profileRevision, 1);
  await global.apply(); await local.applyMerge(); await global.preview(); await local.previewMerge();
  assert.equal(attempts, 2, 'a committed result cannot offer repeat publication or replace recovery with a new preview');
  global.busy = true; global.recoverCommitted(); assert.equal(storage.size, 0);
  global.busy = false; global.recoverCommitted(); assert.equal(closeCalls, 1); assert.equal(storage.get('connectionEntryRequest'), 1);
  local.recoverCommittedMerge(); assert.equal(storage.get('connectionEntryRequest'), 2, 'local recovery reaches the existing root connection entry');
  for (const [error, expected] of [['备份恢复未确认，请重新打开应用后重试', /重新打开应用/], ['private.invalid/?token=synthetic', /应用未完成/]]) {
    message = error; const fresh = new Global(); await fresh.apply(); assert.equal(fresh.committedPending, false);
    assert.match(fresh.summary, expected); assert.ok(!fresh.summary.includes('private.invalid'));
  }
  for (const [name, method] of [['GlobalMergeEditor', 'recoverCommitted()'], ['ProfileEditPage', 'recoverCommittedMerge()']]) {
    const source = fs.readFileSync(`cexing/entry/src/main/ets/pages/${name}.ets`, 'utf8');
    assert.ok(source.includes('app.string.merge_open_connection')); assert.ok(source.includes('.onClick(() => this.' + method + ')'));
  }
  console.log('PASS: committed Merge result preserves saved fact, blocks repeat apply, exposes existing connection entry and keeps reopen/private-error handling');
})().catch(error => { console.error(error); process.exitCode = 1; });
