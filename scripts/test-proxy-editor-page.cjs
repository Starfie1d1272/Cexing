const { resourceContext } = require('./ci/mock-profile-resources.cjs');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
let code = fs.readFileSync('cexing/entry/src/main/ets/pages/ProfileProxyEditorPage.ets', 'utf8');
code = code.slice(0, code.indexOf('  build()')) + '\n}';
code = code.split('\n').map(line => line.trimStart().startsWith('@') ?
  line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '') : line).join('\n').replace('export struct ', 'export class ');
let finishObservation, observations = 0, restores = 0, undoSteps = 0;
let finishLoad, finishTarget, finishSave, targetCalls = 0, saveCalls = 0, dialog;
const intent = { schemaVersion: 1, sourceRevision: 'source', revision: 'draft', operations: [] };
class Model {
  snapshot = null; preview = null;
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
const editBus = { current: '' };
const sandbox = { exports: {}, getContext: () => resourceContext(), AlertDialog: { show: value => { dialog = value; } },
  require: name => name.includes('ProfileProxyEditorModel') ? { ProfileProxyEditorModel: Model } :
    name.includes('ProfileEditPage') ? { ProfileEditBus: editBus } : name.includes('ProxyEditorText') ? textBox.exports : name.includes('ConfigEditor') ? editorExports.exports : name.includes('ProxyProviderStatus') ?
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
  console.log('PASS: real native proxy editor load/target/save lifecycle, repeat actions, hidden private values and stale delete confirmation');
})().catch(error => { console.error(error); process.exitCode = 1; });
