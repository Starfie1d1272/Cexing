const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
let code = fs.readFileSync('cexing/entry/src/main/ets/pages/ProfileProxyEditorPage.ets', 'utf8');
code = code.slice(0, code.indexOf('  build()')) + '\n}';
code = code.split('\n').map(line => line.trimStart().startsWith('@') ?
  line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '') : line).join('\n').replace('export struct ', 'export class ');
let finishLoad, finishTarget, finishSave, targetCalls = 0, saveCalls = 0, dialog;
const intent = { schemaVersion: 1, sourceRevision: 'source', revision: 'draft', operations: [] };
class Model {
  snapshot = null; preview = null;
  cancel() {}
  load() { return new Promise(resolve => { finishLoad = () => { this.snapshot = { missingFieldRevision: 'absent-hash', sections: [
    { section: 'proxies', items: [{ id: 'node', type: 'ss', name: 'known-node' }] }
  ] }; resolve(true); }; }); }
  async presentTarget() { return { item: { id: 'projected-node' }, name: 'projected', value: { port: 8443 } }; }
  workingIntent() { return JSON.parse(JSON.stringify(intent)); }
  target() { targetCalls++; return new Promise(resolve => { finishTarget = resolve; }); }
  save() { saveCalls++; return new Promise(resolve => { finishSave = () => { this.preview = { changes: [] }; resolve(true); }; }); }
}
const sandbox = { exports: {}, getContext: () => ({}), AlertDialog: { show: value => { dialog = value; } },
  require: name => name.includes('ProfileProxyEditorModel') ? { ProfileProxyEditorModel: Model } : {} };
vm.runInNewContext(ts.transpileModule(code).outputText, sandbox);
const Page = sandbox.exports.ProfileProxyEditorPage;
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
  intent.operations = []; intent.disabled = false;
  const onlyProviders = new Page(); onlyProviders.visible = true; onlyProviders.aboutToAppear(); finishLoad();
  onlyProviders.model.snapshot = { sections: [{ section: 'proxies', items: [] }, { section: 'proxy-providers', items: [{ id: 'source', type: 'inline' }] }] };
  await new Promise(setImmediate);
  assert.equal(onlyProviders.section, 'proxy-providers', 'provider-only subscriptions start at their source list');
  assert.equal(onlyProviders.rows.length, 1);
  console.log('PASS: real native proxy editor load/target/save lifecycle, repeat actions, hidden private values and stale delete confirmation');
})().catch(error => { console.error(error); process.exitCode = 1; });
