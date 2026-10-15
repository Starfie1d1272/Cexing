const { resourceContext } = require('./ci/mock-profile-resources.cjs');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
let code = fs.readFileSync('cexing/entry/src/main/ets/pages/ProfileProxyEditorPage.ets', 'utf8');
code = code.slice(0, code.indexOf('  build()')) + '\n}';
code = code.split('\n').map(line => line.trimStart().startsWith('@') ?
  line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '') : line).join('\n').replace('export struct ', 'export class ');
let actionIds = 0, smartAnswer, smartDialog, smartDialogCount = 0;
let finishObservation, observations = 0, restores = 0, undoSteps = 0;
let finishLoad, finishTarget, finishSave, targetCalls = 0, saveCalls = 0, dialog;
const intent = { schemaVersion: 1, sourceRevision: 'source', revision: 'draft', operations: [] };
class Model {
  snapshot = null; preview = null; smartChanges = [];
  cancel() {}
  canUndo() { return true; }
  undoNeedsConfirmation() { return true; }
  async reset() { restores++; return true; }
  async undo() { undoSteps++; return true; }
  profileVersion() { return 'v1'; }
  publishedProviderName(target) { return target.name; }
  load() { return new Promise(resolve => { finishLoad = () => { this.snapshot = { missingFieldRevision: 'absent-hash', sections: [
    { section: 'proxies', items: [{ id: 'node', type: 'ss', name: 'known-node' }] }
  ] }; resolve(true); }; }); }
  async presentTarget() { return { item: { id: 'projected-node' }, name: 'projected', value: { port: 8443 } }; }
  workingIntent() { return JSON.parse(JSON.stringify(intent)); }
  target() { targetCalls++; return new Promise(resolve => { finishTarget = resolve; }); }
  save() { saveCalls++; return new Promise(resolve => { finishSave = () => { this.preview = { changes: [] }; resolve(true); }; }); }
}
const editorExports = { exports: {}, require: () => ({}) };
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/ConfigEditor.ets', 'utf8')).outputText, editorExports);
const textBox = { exports: {} };
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/ProxyEditorText.ets', 'utf8')).outputText, textBox);
let unknownApply = false, recoveryResult = null, recoveryCalls = 0, sharePending = false;
const feedbackBox = { exports: {}, require: name => name === './ProfileStore' ? { ProfileStore: { isApplyUncertain: () => unknownApply, getActiveFile: () => 'one.yaml' } } :
  name === './EffectiveVersions' ? { EffectiveVersions: { read: () => null } } : {} };
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/ProfileApplyFeedback.ets', 'utf8')).outputText, feedbackBox);
const editBus = { current: '' };
const editExports = { exports: {} };
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/ProxyIntentEdits.ets', 'utf8')).outputText, editExports);
const sandbox = { exports: {}, $r: id => ({ id }), getContext: () => resourceContext(), AlertDialog: { show: value => { dialog = value; } },
  require: name => name === '../lib/CoreValidator' ? require('./ci/semantic-fixture.cjs') : name.includes('ProfileApplyFeedback') ? feedbackBox.exports :
    name.includes('ProfileApplyRecovery') ? { ProfileApplyRecovery: { reconnect: async (_ctx, current) => { recoveryCalls++; assert.equal(current(), true); return recoveryResult; } } } :
    name.includes('ProfileImportInput') ? { ProfileImportInput: { hasPending: () => sharePending } } : name.includes('ProfileProxyEditorModel') ? { ProfileProxyEditorModel: Model } :
    name === '@kit.ArkUI' ? { promptAction: { showToast() {}, showDialog(value) { smartDialog = value; smartDialogCount++; return new Promise(resolve => { smartAnswer = resolve; }); } } } : name === '@kit.ArkTS' ? { util: { generateRandomUUID: () => `add-action-${++actionIds}` } } : name.includes('ProxyIntentEdits') ? editExports.exports : name.includes('ProfileEditPage') ? { ProfileEditBus: editBus } : name.includes('ProxyEditorText') ? textBox.exports : name.includes('ConfigEditor') ? editorExports.exports : name.includes('ProxyProviderStatus') ?
      { ProxyProviderStatus: { observe: () => { observations++; return new Promise(resolve => { finishObservation = resolve; }); } } } : {} };
vm.runInNewContext(ts.transpileModule(code).outputText, sandbox);
const Page = sandbox.exports.ProfileProxyEditorPage; sandbox.exports.ProfileProxyEditorBus.file = 'one.yaml';
(async () => {
  const page = new Page(); page.visible = true; page.aboutToAppear();
  page.visible = false; page.visibilityChanged(); finishLoad(); await new Promise(setImmediate);
  assert.equal(page.rows.length, 0, 'late load cannot repopulate a hidden page');
  page.visible = true; page.visibilityChanged(); finishLoad(); await new Promise(setImmediate);
  assert.equal(page.rows.length, 1, page.error);
  const row = page.rows[0];
  assert.equal(row.label, 'known-node', 'names appear before opening private targets');
  assert.equal(page.missingRevision, 'absent-hash');
  const opening = page.open(row); await page.open(row); assert.equal(targetCalls, 1);
  page.visible = false; page.visibilityChanged();
  finishTarget({ item: { id: 'node' }, name: 'synthetic', value: { password: 'synthetic-private' } });
  await opening; assert.equal(page.formOpen, false, 'late private target stays out of hidden UI');
  page.visible = true; page.visibilityChanged(); finishLoad(); await new Promise(setImmediate);
  page.remove(row); const oldDialog = dialog; page.aboutToDisappear();
  await oldDialog.secondaryButton.action(); assert.equal(targetCalls, 1, 'old delete confirmation cannot read or modify a target');
  page.visible = true; page.aboutToAppear(); finishLoad(); await new Promise(setImmediate);
  const openingCurrent = page.open(page.rows[0]);
  finishTarget({ item: { id: 'node', revision: 'authoring' }, name: 'known-node', value: { port: 443 } });
  await openingCurrent;
  assert.equal(page.originalTarget.item.revision, 'authoring');
  assert.equal(page.formTarget.value.port, 8443, 'form uses actual compiler projection');
  const saving = page.save(intent); await page.save(intent); assert.equal(saveCalls, 1);
  page.visible = false; page.visibilityChanged(); finishSave(); await saving;
  assert.equal(page.previewReady, false, 'late preview cannot enable application');
  intent.disabled = true; intent.operations = [{ id: 'new-node', section: 'proxies', kind: 'add', name: 'added while paused', value: { name: 'added while paused', type: 'ss' } }];
  page.labels = { node: 'known-node', provider: 'known-source' };
  page.model.snapshot.sections.push({ section: 'proxy-providers', items: [{ id: 'provider', type: 'inline' }] });
  page.sync();
  assert.ok(page.rows.some(row => row.label === 'added while paused'), 'paused edits remain visible and editable');
  assert.ok(page.names.includes('known-node')); assert.ok(!page.names.includes('known-source'));
  assert.ok(page.providers.includes('known-source'), 'provider choices cannot be confused with node/group choices');
  page.sourceKey = 'raw'; assert.equal(page.moveHandler(), undefined); assert.ok(page.shownRows().every(row => !row.added));
  page.sourceKey = 'custom'; assert.equal(page.shownRows()[0].label, 'added while paused');
  page.model.snapshot.sections.push({ section: 'proxy-groups', items: [{ id: 'group-id', name: 'group', type: 'select' }] });
  page.section = 'proxy-groups'; page.sync(); assert.equal(page.shownRows()[0].label, 'group', 'a hidden node-source filter cannot hide groups');
  page.visibleCount = 100; page.moreRows(); assert.equal(page.visibleCount, 100, 'short/empty lists cannot cause repeated pagination state changes');
  page.section = 'proxies'; page.sync();
  page.sourceKey = 'all'; page.query = ''; page.section = 'proxies'; page.busy = false; assert.equal(typeof page.moveHandler(), 'function'); page.query = 'known'; assert.equal(page.moveHandler(), undefined); const beforeMove = saveCalls;
  await page.moveRow(0, 1); assert.equal(saveCalls, beforeMove, 'filtered indexes cannot reorder a different full-list item');
  page.query = '';
  intent.operations = []; intent.disabled = false;
  const onlyProviders = new Page(); onlyProviders.visible = true; onlyProviders.aboutToAppear(); finishLoad();
  onlyProviders.model.snapshot = { sections: [{ section: 'proxies', items: [] }, { section: 'proxy-providers', items: [{ id: 'source', type: 'inline' }] }] };
  await new Promise(setImmediate);
  assert.equal(onlyProviders.section, 'proxy-providers', 'provider-only subscriptions start at their source list');
  assert.equal(onlyProviders.rows.length, 1);
  const sourcePage = new Page(); sourcePage.visible = true; sourcePage.aboutToAppear(); finishLoad(); await new Promise(setImmediate);
  sourcePage.model.snapshot.sections.push({ section: 'proxy-providers', items: [{ id: 'pool-id', name: 'pool', type: 'http' }] }); sourcePage.sync();
  const sourceIndex = sourcePage.sourceChoices.findIndex(choice => choice.value === 'pool');
  const oldObservation = sourcePage.chooseSource(sourceIndex); await sourcePage.chooseSource(sourceIndex);
  assert.equal(observations, 1, 'source reads are single-flight');
  sourcePage.visible = false; sourcePage.visibilityChanged();
  finishObservation({ nodes: [{ name: 'private-old-node', type: 'ss' }], count: 1, available: true, error: '' }); await oldObservation;
  assert.equal(sourcePage.sourceNodes.length, 0, 'late source names cannot repopulate a hidden page');
  sourcePage.visible = true; sourcePage.visibilityChanged(); finishLoad(); await new Promise(setImmediate);
  assert.equal(sourcePage.sourceKey, 'all', 'return reloads current source identity and clears observations');
  sourcePage.model.snapshot.sections.push({ section: 'proxy-providers', items: [{ id: 'pool-id', name: 'pool', type: 'http' }] }); sourcePage.sync();
  const reading = sourcePage.chooseSource(sourcePage.sourceChoices.findIndex(choice => choice.value === 'pool'));
  finishObservation({ nodes: [{ name: 'loaded-node', type: 'ss' }], count: 1, available: true, error: '' }); await reading;
  assert.equal(sourcePage.sourceNodes[0].name, 'loaded-node'); assert.equal(sourcePage.sourceReady, true);
  const editingSource = sourcePage.editSelectedSource();
  finishTarget({ item: { id: 'pool-id', revision: 'source-revision' }, name: 'pool', value: { type: 'http', url: 'https://example.invalid/private' } });
  await editingSource; assert.equal(sourcePage.section, 'proxy-providers'); assert.equal(sourcePage.originalTarget.item.id, 'pool-id');
  const Failure = editorExports.exports.EditIntentFailure;
  assert.match(sourcePage.previewFailure({ operations: [] }, new Failure('conflict', 0)), /冲突/);
  assert.match(sourcePage.previewFailure({ operations: [{ section: 'proxy-groups' }] }, Error('private backend data')), /组成员和来源/);

  const undoPage = new Page(); undoPage.visible = true; undoPage.aboutToAppear(); finishLoad(); await new Promise(setImmediate);
  await undoPage.undo(); const cancelledUndo = dialog; cancelledUndo.primaryButton.action(); await cancelledUndo.secondaryButton.action();
  assert.equal(restores, 0, 'cancelled draft restoration is not replayable');
  await undoPage.undo(); const oldUndo = dialog; undoPage.aboutToDisappear(); await oldUndo.secondaryButton.action();
  assert.equal(restores, 0, 'old confirmation cannot restore a hidden session');
  undoPage.visible = true; undoPage.aboutToAppear(); finishLoad(); await new Promise(setImmediate);
  await undoPage.undo(); const acceptedUndo = dialog; await acceptedUndo.secondaryButton.action(); await acceptedUndo.secondaryButton.action();
  assert.equal(restores, 1, 'explicit restore is single use');
  undoPage.model.undoNeedsConfirmation = () => false; await undoPage.undo(); assert.equal(undoSteps, 1);

  const rawPaths = []; undoPage.navStack = { getAllPathName: () => rawPaths.slice(), pushPath: value => rawPaths.push(value.name) };
  undoPage.openOriginal(); undoPage.openOriginal();
  assert.equal(rawPaths.join(','), 'profileEdit'); assert.equal(editBus.current, 'one.yaml'); assert.equal(undoPage.formOpen, false);

  intent.operations = []; const retryAdd = new Page(); retryAdd.visible = true; retryAdd.aboutToAppear(); finishLoad(); await new Promise(setImmediate);
  retryAdd.section = 'proxy-groups'; retryAdd.add(); let attempts = 0;
  retryAdd.model.save = async next => { intent.operations = JSON.parse(JSON.stringify(next.operations));
    if (++attempts === 1) { throw Error('invalid reference'); }
    retryAdd.model.preview = { changes: [] }; return true; };
  const createGroup = { section: 'proxy-groups', name: 'repairable', value: { name: 'repairable', type: 'select', use: ['missing'] } };
  await retryAdd.saveForm(createGroup); assert.equal(retryAdd.formOpen, true); assert.equal(intent.operations.length, 1);
  const firstId = intent.operations[0].id; createGroup.value.use = ['known-source'];
  await retryAdd.saveForm(createGroup); assert.equal(intent.operations.length, 1, 'failed new-item preview must be repairable without a duplicate add');
  assert.equal(intent.operations[0].id, firstId); assert.equal(intent.operations[0].value.use[0], 'known-source'); assert.equal(retryAdd.formOpen, false);
  intent.operations = []; const statePage = new Page(); statePage.visible = true; statePage.aboutToAppear(); finishLoad(); await new Promise(setImmediate);
  let reads = 0, states = 0, finishNode;
  statePage.model.nodeTarget = () => { reads++; return new Promise(resolve => { finishNode = resolve; }); };
  statePage.model.save = async next => { states++; intent.operations = JSON.parse(JSON.stringify(next.operations)); return true; };
  const stateRow = statePage.rows[0];
  await statePage.toggleNode(stateRow); assert.ok(dialog.title.includes(stateRow.label), 'pause confirmation identifies the affected node'); const cancelledState = dialog; cancelledState.primaryButton.action(); await cancelledState.secondaryButton.action();
  assert.equal(reads, 0, 'cancelled pause confirmation cannot be replayed');
  await statePage.toggleNode(stateRow); const staleState = dialog; statePage.section = 'proxy-groups'; await staleState.secondaryButton.action();
  assert.equal(reads, 0, 'switching section invalidates a node confirmation'); statePage.section = 'proxies';
  await statePage.toggleNode(stateRow); const lateState = dialog; const lateRead = lateState.secondaryButton.action();
  await lateState.secondaryButton.action(); assert.equal(reads, 1, 'pause confirmation is single-use');
  statePage.visible = false; statePage.visibilityChanged();
  finishNode({ item: { id: stateRow.id, revision: 'baseline' } }); await lateRead;
  assert.equal(states, 0, 'late private target cannot save into a hidden node page');
  statePage.visible = true; statePage.visibilityChanged(); finishLoad(); await new Promise(setImmediate);
  await statePage.toggleNode(stateRow); const confirmedState = dialog; const pausing = confirmedState.secondaryButton.action();
  finishNode({ item: { id: stateRow.id, revision: 'baseline' } }); await pausing;
  assert.equal(states, 1); assert.equal(intent.operations[0].kind, 'disable'); assert.equal(intent.operations[0].expected, 'baseline');
  const pausedRow = statePage.rows.find(row => row.id === stateRow.id); assert.equal(pausedRow.disabled, true);
  const beforeDisabledOpen = targetCalls; await statePage.open(pausedRow); assert.equal(targetCalls, beforeDisabledOpen, 'rejected runtime shape cannot replace the original credential form');
  await statePage.toggleNode(pausedRow); assert.equal(states, 2); assert.equal(intent.operations.length, 0);
  assert.equal(statePage.rows.find(row => row.id === stateRow.id).disabled, false);
  for (const [message, kind] of [['应用未确认，请重连恢复', 'unconfirmed'], ['配置已保存，地区选择待重连恢复', 'committed-pending'], ['private: synthetic-token', 'failed']]) {
    const failed = new Page(); failed.visible = true; failed.aboutToAppear(); finishLoad(); await new Promise(setImmediate);
    let applyAttempts = 0; failed.model.apply = async () => { applyAttempts++; throw Error(message); };
    failed.previewReady = true; await failed.apply(); assert.equal(failed.applyFailure, kind); assert.equal(failed.previewReady, false);
    assert.ok(!failed.error.includes('synthetic-token')); assert.ok(!failed.error.includes('private:'));
    if (kind !== 'failed') {
      assert.match(failed.error, /重连恢复/); await failed.apply(); await failed.inspect(); assert.equal(applyAttempts, 1, 'unconfirmed/committed results cannot offer ordinary repeated apply');
      let clears = 0; failed.navStack = { clear: () => clears++ }; failed.tabJump = -1;
      recoveryResult = null; await failed.recoverApply(); assert.equal(clears, 0); assert.equal(failed.applyFailure, kind);
      recoveryResult = true; await failed.recoverApply(); assert.equal(clears, 1); assert.equal(failed.tabJump, 0);
    }
  }
  unknownApply = true; const reopenedFailure = new Page(); reopenedFailure.visible = true; reopenedFailure.aboutToAppear(); finishLoad(); await new Promise(setImmediate);
  assert.equal(reopenedFailure.applyFailure, 'unconfirmed', 'reopening cannot hide the persistent unknown fence'); unknownApply = false;
  const smartPage = new Page(); smartPage.visible = true; smartPage.aboutToAppear(); finishLoad(); await new Promise(setImmediate);
  for (const [changes, expected] of [
    [[{ section: 'proxies', before: 1, after: 1, modified: 1, kind: 'modified', contentChanged: true }], /节点：修改 1 项/],
    [[{ section: 'proxy-groups', before: 2, after: 2, membersChanged: 1 }], /策略组：成员已调整/],
    [[{ section: 'proxy-groups', before: 2, after: 2, typesChanged: 1 }], /策略组：类型已调整/],
    [[{ section: 'private.invalid/?token=synthetic', before: 1, after: 1, fields: [{ field: 'password', before: 1, after: 1 }], contentChanged: true }], /其他配置：内容已调整/]
  ]) {
    smartPage.model.preview = { changes, platformChanges: [{ section: 'tun', before: 1, after: 1, kind: 'protected' }] };
    smartPage.sync(); assert.match(smartPage.previewText, expected); assert.match(smartPage.previewText, /1 项使用设备约束/);
    assert.ok(!smartPage.previewText.includes('1 → 1')); assert.ok(!smartPage.previewText.includes('private.invalid'));
    assert.ok(!smartPage.previewText.includes('password')); assert.ok(!smartPage.previewText.includes('synthetic'));
  }
  smartPage.model.preview = null; smartPage.sync(); assert.equal(smartPage.previewText, '', 'a missing receipt clears old semantic evidence');
  const group = { id: 'group', label: 'Synthetic group', type: 'url-test', section: 'proxy-groups' };
  let smartIntent = { schemaVersion: 1, operations: [], smartGroups: {} }, smartSaves = 0;
  smartPage.model.workingIntent = () => structuredClone(smartIntent);
  smartPage.model.smartChoices = async () => [{ id: 'group', choiceId: 'group', before: 'url-test', after: smartIntent.smartGroups.group === false ? 'url-test' : 'smart', override: smartIntent.smartGroups.group !== undefined }];
  smartPage.model.save = async next => { smartSaves++; smartIntent = structuredClone(next); smartPage.model.smartChanges = await smartPage.model.smartChoices(); smartPage.model.preview = { changes: [{ section: 'proxy-groups', before: 2, after: 2 }] }; return true; };
  const enabling = smartPage.smart(group); await new Promise(setImmediate);
  assert.equal(smartDialog.message, 'Smart：url-test → smart'); await smartPage.smart(group); assert.equal(smartDialogCount, 1, 'repeated Smart action stays single-flight');
  smartAnswer({ index: 1 }); await enabling; assert.match(smartPage.previewText, /url-test → smart/); assert.equal(smartSaves, 1);
  const keeping = smartPage.smart(group); await new Promise(setImmediate); smartAnswer({ index: 2 }); await keeping;
  assert.match(smartPage.previewText, /url-test → url-test/, 'explicit original type choice displays actual compiler before/after');
  const staleSmart = smartPage.smart(group); await new Promise(setImmediate); smartPage.visible = false; smartPage.visibilityChanged(); smartAnswer({ index: 1 }); await staleSmart;
  assert.equal(smartSaves, 2, 'late Smart dialog does not persist into a hidden page');
  console.log('PASS: real native proxy editor load/target/save lifecycle, repeat actions, hidden private values and stale delete confirmation');
})().catch(error => { console.error(error); process.exitCode = 1; });
