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
const controller = { VpnStatus: { Disconnected: 0, Connected: 2 }, VpnController: { status: 2 } };
const core = { CoreApi: {
  isAlive: async () => true,
  applyConfigText: async () => { applies++; return pending ? await new Promise(resolve => { resolveApply = resolve; }) : response; }
} };
const versions = { EffectiveVersions: {
  read: () => state,
  smartConversion: () => smartCurrent,
  regionPlan: () => null,
  stage: async (_, name, original, overlay, metadata, expected) => {
    assert.equal(expected, state.Current?.ID ?? '');
    const version = { ID: `version-${++id}`, Path: `/versions/${id}`, ProfileID: name };
    staged.set(version.Path, { version, original, overlay, metadata });
    return { version, receipt: '' };
  },
  verify: async () => '',
  commit: async (_, version, expected, active) => {
    if (failCommit) throw Error('synthetic commit failure');
    assert.equal(expected, state.Current?.ID ?? '');
    const entry = staged.get(version.Path);
    originals[version.ProfileID] = entry.original;
    state.Profiles[version.ProfileID] = version;
    if (active) { state.Previous = state.Current; state.Current = version; }
    if (active) smartCurrent = smartAutoConvert;
    if (lostAck) throw Error('synthetic lost acknowledgement');
  },
  discard: async (_, version) => { staged.delete(version.Path); }
} };
const store = { ProfileStore: {
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
  controller.VpnController.status = 0;
  const beforeEnsure = state.Current.ID;
  await tx.ensureActiveSmartPolicy({});
  assert.equal(state.Current.ID, beforeEnsure, 'matching generated policy must not restage');
  smartCurrent = false; // version staged before the default-on feature
  await tx.ensureActiveSmartPolicy({});
  assert.notEqual(state.Current.ID, beforeEnsure, 'legacy generated version must migrate through transaction');
  assert.equal(smartCurrent, true);
  console.log('PASS: rejected, unknown, staged pointer, merge reapply and concurrent profile transactions');
})().catch(error => { console.error(error); process.exitCode = 1; });
