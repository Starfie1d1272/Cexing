const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs'), { resourceContext } = require('./ci/mock-profile-resources.cjs');
let unknown = false, active = 'one.yaml', choice = { pending: '' }, selector = 'Pick', connected = 2, session = 's1', epoch = 1, accepted = 0;
let answer, dialogs = 0, show = () => new Promise(resolve => { answer = resolve; });
const controller = { get status() { return connected; }, needsStop: () => false, trafficSession: () => session, configurationEpoch: () => epoch };
const mods = {
 './ProfileStore': { ProfileStore: { isApplyUncertain: () => unknown, getActiveFile: () => active } },
 './EffectiveVersions': { EffectiveVersions: { read: () => ({ Profiles: { 'one.yaml': { ID: 'version' } } }), editIntent: () => null, regionPlan: () => null } },
 './ProfileRegionChoices': { ProfileRegionChoices: { selector: () => selector, read: () => choice } },
 './VpnController': { VpnController: controller, VpnStatus: { Disconnected: 0, Connected: 2 } },
 '@kit.ArkUI': { promptAction: { showDialog: options => { dialogs++; assert.match(options.message, /中断/); return show(); } } },
 './ProfileRecovery': { ProfileRecovery: { reconnect: async (_ctx, current) => { assert.equal(current(), true); session = 'own-stop'; connected = 0; assert.equal(current(), true, 'own stop does not invalidate the approved UI scope'); accepted++; return true; } } }
};
function load(name) { const box = { exports: {}, $r: () => '', require: key => mods[key] || {} };
 vm.runInNewContext(ts.transpileModule(fs.readFileSync(`cexing/entry/src/main/ets/lib/${name}.ets`, 'utf8')).outputText, box); return box.exports; }
const feedback = load('ProfileApplyFeedback').ProfileApplyFeedback, recovery = load('ProfileApplyRecovery').ProfileApplyRecovery;
(async () => {
 for (const [text, kind] of [['应用未确认，请重连恢复', 'unconfirmed'], ['配置已保存，地区选择待重连恢复', 'committed-pending'],
  ['请先在代理面板选择可用节点，再关闭或切换地区策略', 'selection-required'], ['private: synthetic-token', 'failed'], ['应用未确认，请重连恢复 private:synthetic-token', 'failed']]) {
  assert.equal(feedback.classify(text), kind); assert.ok(!feedback.key(kind).includes('synthetic-token'));
 }
 assert.equal(feedback.recovery({}), ''); unknown = true; assert.equal(feedback.recovery({}), 'unconfirmed'); unknown = false;
 choice = { pending: 'Pick' }; assert.equal(feedback.recovery({}), 'committed-pending'); connected = 0; assert.equal(feedback.recovery({}), '', 'normal offline pending selection is not an apply failure'); connected = 2;
 choice = { pending: '', previous: { selector: 'Pick', name: 'manual' } }; assert.equal(feedback.recovery({}), '', 'the retained active selector is not unfinished recovery'); selector = ''; assert.equal(feedback.recovery({}), 'committed-pending');
 const ctx = resourceContext(); let current = true;
 const cancelled = recovery.reconnect(ctx, () => current); answer({ index: 0 }); assert.equal(await cancelled, null); assert.equal(accepted, 0);
 const hidden = recovery.reconnect(ctx, () => current); current = false; answer({ index: 1 }); assert.equal(await hidden, null); current = true;
 for (const mutate of [() => active = 'other.yaml', () => session = 'foreign', () => epoch++]) {
  active = 'one.yaml'; session = 's1'; epoch = 1; const stale = recovery.reconnect(ctx, () => true); mutate(); answer({ index: 1 }); assert.equal(await stale, null);
 }
 assert.equal(accepted, 0); active = 'one.yaml'; session = 's1'; epoch = 1;
 const confirmed = recovery.reconnect(ctx, () => true); answer({ index: 1 }); assert.equal(await confirmed, true); assert.equal(accepted, 1);
 const before = dialogs; assert.equal(await recovery.reconnect(ctx, () => true), true); assert.equal(dialogs, before, 'disconnected known state starts without interruption confirmation');
 connected = 2; show = async () => { throw Error('synthetic UI cancellation'); }; assert.equal(await recovery.reconnect(ctx, () => true), null); assert.equal(accepted, 2);
 assert.equal(await recovery.reconnect(ctx, () => false), null);
 console.log('PASS: bounded apply categories, persistent unknown/committed choice, offline distinction and confirmed reconnect cancellation/scope/session/epoch fences');
})().catch(error => { console.error(error); process.exitCode = 1; });
