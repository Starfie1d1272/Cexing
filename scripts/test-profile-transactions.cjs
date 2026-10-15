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
const regionPlans = new Map(), regionChoices = new Map(), runtimeChoices = new Map(), intents = new Map();
let editDraft={revision:"",intent:null};
const state = { Current: { ID: 'version-old', Path: '/versions/old', ProfileID: 'old.yaml' },
  Previous: null, Profiles: {} };
state.Profiles['old.yaml'] = state.Current;
let id = 0;
let response = 'applied';
let responses = [];
let commitHook = null, afterCommitHook = null, clearUnknownMarker = false, switchRestoreAt = -1;
const smartVersionOverrides = new Map();
let session = 'synthetic-session';
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
const controller = { VpnStatus: { Disconnected: 0, Connected: 2 }, VpnController: { status: 2, holdConfiguration: () => () => {}, configurationEpoch: () => 0 } };
const core = { CoreApi: {
  isAlive: async () => true,
  getControllerSession: async () => session,
  getProxies: async () => ({ Main: { now: currentProxyChoice,
    all: ['Original', 'Other', 'Manual', 'Cexing Smart Main'] } }),
  selectProxy: async (_, name) => { if (selectAccepted) currentProxyChoice = name; return selectAccepted; },
  applyConfigText: async () => {
    applies++;
    if (applies === switchRestoreAt) session = 'third-session';
    const result = pending ? await new Promise(resolve => { resolveApply = resolve; }) : (responses.shift() ?? response);
    if (result === 'applied' && reloadFallbackChoice !== '') { currentProxyChoice = reloadFallbackChoice; }
    return result;
  }
} };
const versions = { EffectiveVersions: {
  read: () => state,
  editIntent: (_,v) => intents.get(v.ID) ?? null,
  regionChoice: (_,v) => regionChoices.get(v.ID) ?? null,
  smartConversion: (_, version) => smartVersionOverrides.has(version.ID) ? smartVersionOverrides.get(version.ID) : smartCurrent,
  original: (_, version) => originals[version.ProfileID],
  overlay: () => '',

  globalContent: () => state.GlobalMerge ?? "",
  globalMerge: () => state.GlobalMerge ?? "",
  previewMerge: async (_, __, overlay) => {
    if (overlay.includes("secret:")) throw new Error("protected");
    return { digest: "synthetic", changes: [{ section: "hosts", before: 0, after: 1 }] };
  },
  regionPlan: (_, version) => regionPlans.get(version.ID) ?? null,
  stage: async (_, name, original, overlay, metadata, expected, regionPlan, global, intent, regionChoice) => {
    assert.equal(expected, state.Current?.ID ?? '');
    const version = { ID: `version-${++id}`, Path: `/versions/${id}`, ProfileID: name };
    staged.set(version.Path, { version, original, overlay, metadata, regionPlan, intent, regionChoice, smartPolicy:smartAutoConvert });
    return { version, receipt: '' };
  },
  verify: async () => '',
  commit: async (_, version, expected, active) => {
    if (commitHook) await commitHook();
    if (failCommit) throw Error('synthetic commit failure');
    assert.equal(expected, state.Current?.ID ?? '');
    const entry = staged.get(version.Path);
    regionPlans.set(version.ID, entry.regionPlan);
    regionChoices.set(version.ID, entry.regionChoice); intents.set(version.ID,entry.intent);
    originals[version.ProfileID] = entry.original;
    state.Profiles[version.ProfileID] = version;
    if (active) { state.Previous = state.Current; state.Current = version; }
    if (active) smartCurrent = entry.smartPolicy;
    if (afterCommitHook) await afterCommitHook();
    if (lostAck) throw Error('synthetic lost acknowledgement');
  },
  discard: async (_, version) => { staged.delete(version.Path); }
} };
const store = { ProfileStore: {
  updateState: (_, file) => ({id:file}), readEditDraft: () => editDraft,
  runtimeRegionChoice: (_,file,id) => runtimeChoices.get(id) ?? null,
  saveRuntimeRegionChoice: (_,file,id,state) => { runtimeChoices.set(id,structuredClone(state)); pendingRegionSelector=state.pending;previousRegionChoice=state.previous?.name??'';previousRegionObserved=state.previous?.observed??''; },
  pendingRegionSelection: () => pendingRegionSelector,
  setPendingRegionSelection: (_, __, selector) => { pendingRegionSelector = selector; },
  clearPendingRegionSelection: () => { pendingRegionSelector = ''; },
  previousRegionSelection: () => previousRegionChoice,
  previousRegionObservation: () => previousRegionObserved,
  setPreviousRegionSelection: (_, __, name) => { previousRegionChoice = name; previousRegionObserved = ''; },
  setPreviousRegionObservation: (_, __, observed) => { previousRegionObserved = observed; },
  clearPreviousRegionSelection: () => { previousRegionChoice = ''; previousRegionObserved = ''; },
  isApplyUncertain: () => uncertain,
  markApplyUncertain: () => { uncertain = !clearUnknownMarker; },
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
  idle: async () => {},
  setSmartAutoConvert: (_, enabled) => { smartAutoConvert = enabled; }
} };
let regionModule;
const context = { exports: {}, require: name => {
  if (name === '@kit.CoreFileKit') return { fileIo: { readTextSync: name => {
    if (name.endsWith('/source.json')) return JSON.stringify({ Metadata: JSON.stringify({ origin: '', sub: {}, updatedAt: 1 }) });
    const entry = staged.get(name);
    return entry.original + entry.overlay;
  } } };
  if (name.endsWith('ProfileRegionChoices')) return regionModule;
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
const effectContext={exports:{}};
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/TemplateRegionEffects.ets','utf8')).outputText,effectContext);
const regionContext={exports:{},require:name=>name.endsWith('TemplateRegionEffects')?effectContext.exports:context.require(name)};
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/ProfileRegionChoices.ets','utf8')).outputText,regionContext);
regionModule=regionContext.exports;
vm.runInNewContext(js, context);
const tx = context.exports.ProfileTransactions;
(async () => {
  response = 'rejected';
  await assert.rejects(tx.activate({}, 'new.yaml'), /拒绝/);
  assert.equal(state.Current.ProfileID, 'old.yaml');
  await assert.rejects(tx.edit({}, 'old.yaml', 'bad'), /parse/);
  assert.equal(originals['old.yaml'], 'proxies: [old]');
  response = 'unknown';
  await assert.rejects(tx.update({}, 'old.yaml'), /应用未确认/);
  assert.equal(state.Current.ProfileID, 'old.yaml');
  await assert.rejects(tx.activate({}, 'new.yaml'), /重连恢复/);
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
    /地区选择待重连恢复/);
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
  runtimeChoices.set(state.Current.ID,{pending:'',previous:{selector:'Main',name:'Original',observed:'Other'}});
  previousRegionChoice = 'Original'; previousRegionObserved = 'Other';
  currentProxyChoice = 'Manual';
  assert.equal(await tx.applyPendingRegionSelection({}), true,
    'manual outcome consumes the automatic request without overwriting the user');
  assert.equal(currentProxyChoice, 'Manual');
  assert.equal(previousRegionChoice, '', 'confirmed manual choice cancels old automatic restoration');
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
  assert.equal(regionChoices.get(state.Current.ID).pending, 'Main', 'offline selection intent must survive until Controller is ready');
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
  controller.VpnController.status = 0;
  const previewRestore = tx.previewPrevious({});
  await assert.rejects(tx.restorePrevious({}, 'stale', previewRestore.previousId), /重新预览/);
  const beforeRestore = state.Current.ID;
  assert.equal(await tx.restorePrevious({}, previewRestore.currentId, previewRestore.previousId), 'saved');
  assert.notEqual(state.Current.ID, beforeRestore, 'restore must stage a new immutable version');
  assert.equal(state.Previous.ID, beforeRestore, 'the pre-restore version remains available');
  controller.VpnController.status = 2;
  const rejectedRestore = tx.previewPrevious({});
  const beforeRejectedPreference=smartAutoConvert;
  smartVersionOverrides.set(state.Previous.ID,!smartAutoConvert);
  response = 'rejected';
  const rejectId = state.Current.ID;
  await assert.rejects(tx.restorePrevious({}, rejectedRestore.currentId, rejectedRestore.previousId), /拒绝/);
  assert.equal(state.Current.ID, rejectId, 'rejected restore preserves the current pointer');
  assert.equal(smartAutoConvert,beforeRejectedPreference,'confirmed rejection restores the prior Smart preference');
  response = 'applied';
  responses = ['applied', 'unknown']; failCommit = true;
  const beforeRollbackFailure = state.Current.ID;
  await assert.rejects(tx.update({}, 'old.yaml'), /应用未确认/);
  assert.equal(state.Current.ID, beforeRollbackFailure);
  await assert.rejects(tx.activate({}, 'new.yaml'), /重连恢复/);
  failCommit = false; controller.VpnController.status = 0; uncertain = false;
  await tx.activate({}, 'old.yaml');
  controller.VpnController.status = 2;
  const beforeUnknownApply = smartAutoConvert, beforeUnknownPointer = state.Current.ID;
  response='unknown';
  await assert.rejects(tx.setSmartAutoConvert({},!beforeUnknownApply),/应用未确认/);
  assert.equal(state.Current.ID,beforeUnknownPointer);
  assert.equal(smartAutoConvert,beforeUnknownApply,'no commit was attempted: keep the known pointer and preference paired');
  response='applied';uncertain=false;controller.VpnController.status=0;
  await tx.activate({},'old.yaml');controller.VpnController.status=2;
  const beforeFailedCommit = smartAutoConvert, knownPointer = state.Current.ID;
  failCommit=true;switchRestoreAt=applies+2;
  await assert.rejects(tx.setSmartAutoConvert({},!beforeFailedCommit),/应用未确认/);
  assert.equal(state.Current.ID,knownPointer);
  assert.equal(smartAutoConvert,beforeFailedCommit,'confirmed unpublished pointer retains its old preference even if runtime rollback is unknown');
  failCommit=false;switchRestoreAt=-1;uncertain=false;controller.VpnController.status=0;
  await tx.activate({},'old.yaml');controller.VpnController.status=2;
  // A commit can publish and only then lose session confirmation. Never revert
  // the preference alone while retaining the newly published candidate.
  for (const operation of ['toggle','previous']) {
    const beforePreference=smartAutoConvert, beforePublished=state.Current.ID;
    const restored=tx.previewPrevious({});
    if(operation==='previous')smartVersionOverrides.set(state.Previous.ID,!beforePreference);
    clearUnknownMarker=operation==='previous';
    afterCommitHook=async()=>{session=`post-commit-${operation}`};
    await assert.rejects(operation==='toggle'?tx.setSmartAutoConvert({},!beforePreference):tx.restorePrevious({},restored.currentId,restored.previousId),/应用未确认/);
    assert.notEqual(state.Current.ID,beforePublished,'published candidate must remain the truthful pointer');
    assert.equal(smartAutoConvert,!beforePreference,'unknown cannot roll back just the preference');
    assert.equal(smartAutoConvert,staged.get(state.Current.Path).smartPolicy,'retained preference matches the actual staged policy');
    assert.equal(uncertain,!clearUnknownMarker);
    await assert.rejects(tx.activate({},'new.yaml'),/重连恢复/,'in-memory unknown fence survives a cleared persistent marker');
    afterCommitHook=null;clearUnknownMarker=false;uncertain=false;controller.VpnController.status=0;
    await tx.activate({},'old.yaml');controller.VpnController.status=2;
  }
  let valid = true; pending = true;
  const cancelledVersion = state.Current.ID;
  const cancelled = tx.update({}, 'old.yaml', () => valid);
  await new Promise(resolve => setTimeout(resolve, 0));
  valid = false; pending = false; resolveApply('applied');
  await assert.rejects(cancelled, /取消/);
  assert.equal(state.Current.ID, cancelledVersion); assert.equal(uncertain, false, 'same-session cancellation confirms rollback');
  commitHook = async () => { session = 'commit-new-session'; };
  const beforeCommitSwitch = state.Current.ID;
  await assert.rejects(tx.update({}, 'old.yaml'), /应用未确认/);
  assert.notEqual(state.Current.ID, beforeCommitSwitch, 'published pointer truth is retained after a late session change');
  assert.equal(uncertain, true); commitHook = null;
  controller.VpnController.status = 0; uncertain = false; await tx.activate({}, 'old.yaml'); controller.VpnController.status = 2;
  failCommit = true; switchRestoreAt = applies + 2;
  const beforeRestoreSwitch = state.Current.ID;
  await assert.rejects(tx.update({}, 'old.yaml'), /应用未确认/);
  assert.equal(state.Current.ID, beforeRestoreSwitch); assert.equal(uncertain, true);
  failCommit = false; switchRestoreAt = -1;
  controller.VpnController.status = 0; uncertain = false; await tx.activate({}, 'old.yaml'); controller.VpnController.status = 2;
  pending = true;
  const priorSessionVersion = state.Current.ID;
  const oldResult = tx.update({}, 'old.yaml');
  await new Promise(resolve => setTimeout(resolve, 0));
  session = 'new-session';
  resolveApply('applied');
  await assert.rejects(oldResult, /应用未确认/);
  assert.equal(state.Current.ID, priorSessionVersion, 'old runtime result cannot publish into a new session');
  await assert.rejects(tx.activate({}, 'new.yaml'), /重连恢复/);
  // Candidate Original is inert until the existing publisher commits the same
  // Original, metadata, intent and initial region choice in one version.
  controller.VpnController.status=0; uncertain=false; pending=false;
  await tx.activate({},'old.yaml');
  const candidate={original:'proxies: [candidate]',metadata:{origin:'synthetic',sub:{},updatedAt:7}};
  editDraft={revision:'candidate-draft',intent:{schemaVersion:1,revision:'candidate-draft',sourceRevision:'s',operations:[],template:{templateId:'region',version:1,region}}};
  const originalBefore=originals['old.yaml'];
  const ticket=tx.editTicket({},'old.yaml');
  await tx.previewEditDraft({},ticket,candidate);assert.equal(originals['old.yaml'],originalBefore);
  failCommit=true;await assert.rejects(tx.applyEditDraft({},ticket,undefined,undefined,candidate),/commit failure/);
  assert.equal(originals['old.yaml'],originalBefore);failCommit=false;
  await tx.applyEditDraft({},ticket,undefined,undefined,candidate);
  assert.equal(originals['old.yaml'],candidate.original);
  const success=staged.get(state.Current.Path);assert.equal(JSON.parse(success.metadata).updatedAt,7);
  assert.equal(success.intent.template.templateId,'region');assert.equal(success.regionChoice.pending,'Main');
  controller.VpnController.status=2;currentProxyChoice='Original';
  await tx.applyPendingRegionSelection({});assert.equal(currentProxyChoice,'Cexing Smart Main');
  // Same-selector rebase preserves a later manual choice and consumed pending.
  const beforeMissingChoice=state.Current.ID;
  runtimeChoices.set(beforeMissingChoice,{pending:'',previous:undefined});
  editDraft={revision:'missing-choice',intent:{schemaVersion:1,revision:'missing-choice',sourceRevision:'s',operations:[],template:{templateId:'original',version:1}}};
  await assert.rejects(tx.applyEditDraft({},tx.editTicket({},'old.yaml')),/请先在代理面板选择可用节点/);
  assert.equal(state.Current.ID,beforeMissingChoice,'unrestorable manual choice is refused before publication');
  runtimeChoices.set(beforeMissingChoice,{pending:'',previous:{selector:'Main',name:'Original',observed:'Original'}});
  currentProxyChoice='Manual';await tx.update({},'old.yaml');assert.equal(currentProxyChoice,'Manual');
  assert.equal(regionChoices.get(state.Current.ID).pending,'');
  // Removing a template uses the same restoration path as a legacy region plan.
  editDraft={revision:'remove-template',intent:{schemaVersion:1,revision:'remove-template',sourceRevision:'s',operations:[],template:{templateId:'original',version:1}}};
  await tx.applyEditDraft({},tx.editTicket({},'old.yaml'));
  assert.equal(currentProxyChoice,'Manual');assert.equal(regionChoices.get(state.Current.ID).previous,undefined);
  console.log('PASS: rejected, unknown, staged pointer, merge reapply and concurrent profile transactions');
})().catch(error => { console.error(error); process.exitCode = 1; });
