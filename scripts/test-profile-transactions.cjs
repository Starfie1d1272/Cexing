// Synthetic method-level checks against the actual ArkTS transaction module.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const source = fs.readFileSync(path.join(__dirname, '../cexing/entry/src/main/ets/lib/ProfileTransactions.ets'), 'utf8');
const js = ts.transpileModule(source, { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
} }).outputText;
const originals = { 'old.yaml': 'proxies: [old]', 'new.yaml': 'proxies: [new]' };
const staged = new Map();
const regionPlans = new Map();
const state = { Current: { ID: 'version-old', Path: '/versions/old', ProfileID: 'old.yaml' },
  Previous: null, Profiles: {} };
state.Profiles['old.yaml'] = state.Current;
let id = 0;
let response = 'applied';
let resolveApply;
let pending = false;
let uncertain = false;
let applies = 0;
let failCommit = false;
let lostAck = false;
let smartAutoConvert = true;
let smartCurrent = false;
let pendingRegionSelector = '';
let previousRegionChoice = '';
let previousRegionObserved = '';
let currentProxyChoice = 'Original';
let selectAccepted = true;
let reloadFallbackChoice = '';
const controller = { VpnStatus: { Disconnected: 0, Connected: 2 }, VpnController: { status: 2 } };
const core = { CoreApi: {
  isAlive: async () => true,
  getProxies: async () => ({ Main: { now: currentProxyChoice,
    all: ['Original', 'Other', 'Manual', 'Cexing Smart Main'] } }),
  selectProxy: async (_, name) => { if (selectAccepted) currentProxyChoice = name; return selectAccepted; },
  applyConfigText: async () => {
    applies++;
    const result = pending ? await new Promise(resolve => { resolveApply = resolve; }) : response;
    if (result === 'applied' && reloadFallbackChoice !== '') { currentProxyChoice = reloadFallbackChoice; }
    return result;
  }
} };
const versions = { EffectiveVersions: {
  read: () => state,
  smartConversion: () => smartCurrent,
  globalContent: () => state.GlobalMerge ?? "",
  globalMerge: () => state.GlobalMerge ?? "",
  previewMerge: async (_, __, overlay) => {
    if (overlay.includes("secret:")) throw new Error("protected");
    return { digest: "synthetic", changes: [{ section: "hosts", before: 0, after: 1 }] };
  },
  regionPlan: (_, version) => regionPlans.get(version.ID) ?? null,
  stage: async (_, name, original, overlay, metadata, expected, regionPlan) => {
    assert.equal(expected, state.Current?.ID ?? '');
    const version = { ID: `version-${++id}`, Path: `/versions/${id}`, ProfileID: name };
    staged.set(version.Path, { version, original, overlay, metadata, regionPlan });
    return { version, receipt: '' };
  },
  verify: async () => '',
  commit: async (_, version, expected, active) => {
    if (failCommit) throw Error('synthetic commit failure');
    assert.equal(expected, state.Current?.ID ?? '');
    const entry = staged.get(version.Path);
    regionPlans.set(version.ID, entry.regionPlan);
    originals[version.ProfileID] = entry.original;
    state.Profiles[version.ProfileID] = version;
    if (active) { state.Previous = state.Current; state.Current = version; }
    if (active) smartCurrent = smartAutoConvert;
    if (lostAck) throw Error('synthetic lost acknowledgement');
  },
  discard: async (_, version) => { staged.delete(version.Path); }
} };
const store = { ProfileStore: {
  pendingRegionSelection: () => pendingRegionSelector,
  setPendingRegionSelection: (_, __, selector) => { pendingRegionSelector = selector; },
  clearPendingRegionSelection: () => { pendingRegionSelector = ''; },
  previousRegionSelection: () => previousRegionChoice,
  previousRegionObservation: () => previousRegionObserved,
  setPreviousRegionSelection: (_, __, name) => { previousRegionChoice = name; previousRegionObserved = ''; },
  setPreviousRegionObservation: (_, __, observed) => { previousRegionObserved = observed; },
  clearPreviousRegionSelection: () => { previousRegionChoice = ''; previousRegionObserved = ''; },
  isApplyUncertain: () => uncertain,
  markApplyUncertain: () => { uncertain = true; },
  getProfileContent: (_, name) => originals[name] ?? null,
  getActiveContent: () => originals[state.Current.ProfileID],
  getActiveFile: () => state.Current.ProfileID,
  getEnabledMerge: () => '',
  getMeta: () => ({}),
  prepareContent: content => { if (content.includes('bad')) throw new Error('parse'); return content; },
  downloadFromOrigin: async () => ({ content: 'proxies: [updated]', meta: { origin: 'synthetic', sub: {}, updatedAt: 1 } }),
  saveMergeDraft: (_, name, value) => { originals[name + '.merge'] = value; },
  setMergeEnabled: (_, name, value) => { originals[name + '.merge'] = value; }
} };
const settings = { Settings: {
  load: () => ({ smartAutoConvert }),
  setSmartAutoConvert: (_, enabled) => { smartAutoConvert = enabled; }
} };
const context = { exports: {}, require: name => {
  if (name === '@kit.CoreFileKit') return { fileIo: { readTextSync: name => {
    const entry = staged.get(name);
    return entry.original + entry.overlay;
  } } };
  if (name.endsWith('CoreApi')) return core;
  if (name.endsWith('ProfileStore')) return store;
  if (name.endsWith('Settings')) return settings;
  if (name.endsWith('EffectiveVersions')) return versions;
  if (name.endsWith('VpnController')) return controller;
  if (name.endsWith('CoreValidator')) return { CoreValidator: {
    prepareResources: async () => {},
    previewMerge: async (_, __, overlay) => {
      if (overlay.includes('secret:')) throw new Error('protected');
      return { digest: 'synthetic', changes: [{ section: 'hosts', before: 0, after: 1 }] };
    } } };
  return {};
} };
vm.runInNewContext(js, context);
const tx = context.exports.ProfileTransactions;
(async () => {
  response = 'rejected';
  await assert.rejects(tx.activate({}, 'new.yaml'), /拒绝/);
  assert.equal(state.Current.ProfileID, 'old.yaml');
  await assert.rejects(tx.edit({}, 'old.yaml', 'bad'), /parse/);
  assert.equal(originals['old.yaml'], 'proxies: [old]');
  response = 'unknown';
  await assert.rejects(tx.update({}, 'old.yaml'), /未知/);
  assert.equal(state.Current.ProfileID, 'old.yaml');
  await assert.rejects(tx.activate({}, 'new.yaml'), /断开 VPN/);
  controller.VpnController.status = 0;
  uncertain = false; // explicit confirmed stop clears the persistent marker
  assert.equal(await tx.activate({}, 'new.yaml'), 'saved');
  assert.equal(state.Current.ProfileID, 'new.yaml');
  controller.VpnController.status = 2;
  response = 'applied';
  pending = true;
  const first = tx.update({}, 'new.yaml');
  await new Promise(resolve => setTimeout(resolve, 0));
  await assert.rejects(tx.edit({}, 'new.yaml', 'proxies: [edit]'), /正在进行/);
  resolveApply('applied');
  assert.equal(await first, 'applied');
  assert.equal(originals['new.yaml'], 'proxies: [updated]');
  pending = false;
  const before = applies;
  assert.equal(await tx.activate({}, 'new.yaml'), 'applied');
  assert.equal(applies, before + 1, 'selecting the current file must confirm runtime application');
  const preview = await tx.saveMergeDraft({}, 'new.yaml', 'hosts: {synthetic.example: 192.0.2.1}');
  assert.equal(preview.changes[0].section, 'hosts');
  await assert.rejects(tx.saveMergeDraft({}, 'new.yaml', 'secret: forbidden'), /protected/);
  assert.equal(originals['new.yaml.merge'], 'hosts: {synthetic.example: 192.0.2.1}');
  assert.equal(await tx.applyMerge({}, 'new.yaml', 'hosts: {synthetic.example: 192.0.2.1}'), 'applied');
  assert.equal(originals['new.yaml.merge'], 'hosts: {synthetic.example: 192.0.2.1}');
  failCommit = true;
  const prior = state.Current.ID;
  await assert.rejects(tx.edit({}, 'new.yaml', 'proxies: [changed]'), /commit failure/);
  assert.equal(state.Current.ID, prior, 'failed pointer publish must retain previous version');
  assert.equal(originals['new.yaml'], 'proxies: [updated]');
  failCommit = false;
  lostAck = true;
  const beforeLostAck = applies;
  assert.equal(await tx.edit({}, 'new.yaml', 'proxies: [ack-lost]'), 'applied');
  assert.equal(applies, beforeLostAck + 1, 'committed version must not trigger a false rollback');
  lostAck = false;
  response = 'rejected';
  const beforeToggle = state.Current.ID;
  await assert.rejects(tx.setSmartAutoConvert({}, false), /拒绝/);
  assert.equal(smartAutoConvert, true, 'failed toggle must restore the saved preference');
  assert.equal(state.Current.ID, beforeToggle, 'failed toggle must preserve the effective version');
  response = 'applied';
  assert.equal(await tx.setSmartAutoConvert({}, false), 'applied');
  assert.equal(smartAutoConvert, false);
  assert.equal(await tx.setSmartAutoConvert({}, true), 'applied');
  assert.equal(smartAutoConvert, true);
  const region = { mode: 'region', selector: 'Main', enable: true, assignments: { unknown: '日本' } };
  assert.equal(await tx.setRegionPlan({}, 'new.yaml', region), 'applied');
  assert.equal(regionPlans.get(state.Current.ID).selector, 'Main');
  await tx.update({}, 'new.yaml');
  assert.equal(regionPlans.get(state.Current.ID).assignments.unknown, '日本',
    'subscription updates must reapply the saved region choice');
  currentProxyChoice = 'Cexing Smart Main';
  previousRegionChoice = 'Original';
  pendingRegionSelector = 'Main';
  selectAccepted = false;
  reloadFallbackChoice = 'Other';
  const beforePartialDisable = state.Current.ID;
  await assert.rejects(tx.setRegionPlan({}, 'new.yaml', { ...region, enable: false }),
    /地区策略已关闭，但原选项未恢复/);
  assert.notEqual(state.Current.ID, beforePartialDisable,
    'failed Controller restore must not hide a committed disable');
  assert.equal(regionPlans.get(state.Current.ID).enable, false);
  assert.equal(previousRegionChoice, 'Original', 'retain the original choice for reconnect retry');
  assert.equal(previousRegionObserved, 'Other', 'record the automatic post-reload fallback');
  assert.equal(pendingRegionSelector, '', 'discard the obsolete enable intent after disable');
  reloadFallbackChoice = '';
  selectAccepted = true;
  assert.equal(await tx.applyPendingRegionSelection({}), true,
    'reconnect retry must restore the original choice');
  assert.equal(currentProxyChoice, 'Original');
  assert.equal(previousRegionChoice, '');
  previousRegionChoice = 'Original';
  previousRegionObserved = 'Other';
  currentProxyChoice = 'Manual';
  assert.equal(await tx.applyPendingRegionSelection({}), false,
    'reconnect must not overwrite a later manual choice');
  assert.equal(currentProxyChoice, 'Manual');
  assert.equal(previousRegionChoice, 'Original', 'uncertain user intent must not erase restore evidence');
  currentProxyChoice = 'Other';
  assert.equal(await tx.applyPendingRegionSelection({}), true,
    'the recorded reload fallback can be retried later');
  assert.equal(previousRegionChoice, '');
  currentProxyChoice = 'Original';
  assert.equal(await tx.setRegionPlan({}, 'new.yaml', region), 'applied');
  response = 'rejected';
  const beforeRegionFailure = state.Current.ID;
  await assert.rejects(tx.setRegionPlan({}, 'new.yaml', null), /拒绝/);
  assert.equal(state.Current.ID, beforeRegionFailure, 'failed region toggle keeps the old version');
  response = 'applied';
  assert.equal(await tx.setRegionPlan({}, 'new.yaml', { ...region, enable: false }), 'applied');
  assert.equal(regionPlans.get(state.Current.ID).enable, false);
  controller.VpnController.status = 0;
  const beforeEnsure = state.Current.ID;
  await tx.ensureActiveSmartPolicy({});
  assert.equal(state.Current.ID, beforeEnsure, 'matching generated policy must not restage');
  smartCurrent = false; // version staged before the default-on feature
  await tx.ensureActiveSmartPolicy({});
  assert.notEqual(state.Current.ID, beforeEnsure, 'legacy generated version must migrate through transaction');
  assert.equal(smartCurrent, true);
  assert.equal(await tx.setRegionPlan({}, 'old.yaml', region, true), 'saved');
  assert.equal(state.Current.ProfileID, 'old.yaml', 'create and enable must select the imported profile');
  assert.equal(pendingRegionSelector, 'Main', 'offline selection intent must survive until Controller is ready');
  controller.VpnController.status = 2;
  selectAccepted = false;
  assert.equal(await tx.applyPendingRegionSelection({}), false);
  assert.equal(pendingRegionSelector, 'Main', 'failed Controller selection must remain pending');
  selectAccepted = true;
  assert.equal(await tx.applyPendingRegionSelection({}), true);
  assert.equal(pendingRegionSelector, '', 'one-time explicit selection must be consumed');
  controller.VpnController.status = 0;
  assert.equal(await tx.setRegionPlan({}, 'old.yaml', { ...region, enable: false, disabled: true }), 'saved');
  assert.equal(previousRegionChoice, 'Original', 'offline disable retains the manual choice for restore');
  controller.VpnController.status = 2;
  assert.equal(await tx.applyPendingRegionSelection({}), true);
  assert.equal(currentProxyChoice, 'Original');
  assert.equal(previousRegionChoice, '');
  console.log('PASS: rejected, unknown, staged pointer, merge reapply and concurrent profile transactions');
})().catch(error => { console.error(error); process.exitCode = 1; });
