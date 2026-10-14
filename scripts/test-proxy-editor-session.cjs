// UI session against published worker/transaction signatures; all inputs synthetic.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
let ticket = { file: 'synthetic.yaml', profileIdentity: 'identity', profileVersion: 'profile-v1',
  activeVersion: 'active-v1', activeFile: 'synthetic.yaml', draftRevision: '' };
let publishedIntent = null;
let draft = { intent: null }, saveCalls = 0, applyCalls = 0, revision = 0;
let read = async () => ({ sourceRevision: 'source-v1', sections: [] });
let target = async () => ({ item: { id: 'target' }, value: { password: 'synthetic-private' } });
let save = async (_context, expected, intent) => {
  assert.equal(expected.draftRevision, ticket.draftRevision);
  ticket = { ...ticket, draftRevision: `draft-${++revision}` }; draft = { intent };
  return ticket.draftRevision;
};
let preview = async () => ({ digest: 'synthetic-digest', changes: [] });
let apply = async () => 'saved';
const editsBox = { exports: {} };
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/ProxyIntentEdits.ets', 'utf8')).outputText, editsBox);
const modules = {
  './ProxyIntentEdits': editsBox.exports,
  './ConfigEditor': { ConfigEditor: { list: (...args) => read(...args), target: (...args) => target(...args) } },
  './ProfileStore': { ProfileStore: { getProfileContent: () => 'proxies: []', getEnabledMerge: () => '', readEditDraft: () => draft } },
  './ProfileTransactions': { ProfileTransactions: { editTicket: () => ({ ...ticket }),
    saveEditDraft: (...args) => { saveCalls++; return save(...args); },
    previewEditDraft: (...args) => preview(...args), applyEditDraft: (...args) => { applyCalls++; return apply(...args); } } },
  './EffectiveVersions': { EffectiveVersions: { read: () => ({ Profiles: { 'synthetic.yaml': {} } }), regionPlan: () => null, editIntent: () => publishedIntent } }
};
const sandbox = { exports: {}, require: name => { assert.ok(name in modules, name); return modules[name]; } };
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/ProfileProxyEditorModel.ets', 'utf8')).outputText, sandbox);
const Model = sandbox.exports.ProfileProxyEditorModel;
(async () => {
  let finishRead;
  read = () => new Promise(resolve => { finishRead = resolve; });
  const stale = new Model({}, ticket.file); const reading = stale.load();
  ticket.activeVersion = 'active-v2'; finishRead({ sourceRevision: 'old-source', sections: [] });
  await assert.rejects(reading, /变化/); assert.equal(stale.snapshot, null);
  read = async () => ({ sourceRevision: 'source-v2', missingFieldRevision: 'absent-hash', sections: [] });
  const model = new Model({}, ticket.file); await model.load();
  assert.equal(model.snapshot.missingFieldRevision, 'absent-hash');
  assert.equal(await model.apply(), null, 'application requires a confirmed preview');
  publishedIntent = { operations: [{ section: 'proxy-providers', target: 'source-id', kind: 'rename', name: 'applied-name' }] };
  assert.equal(model.publishedProviderName({ item: { id: 'source-id' }, name: 'original-name' }), 'applied-name');
  model.intent = { operations: [{ section: 'proxy-providers', target: 'source-id', kind: 'rename', name: 'unapplied-name' }] };
  assert.equal(model.publishedProviderName({ item: { id: 'source-id' }, name: 'original-name' }), 'applied-name', 'runtime provider lookup follows published provenance, never an unapplied rename');
  model.intent = null; publishedIntent = null;
  let finishTarget;
  target = () => new Promise(resolve => { finishTarget = resolve; });
  const editing = model.target('proxies', 'target'); model.cancel();
  finishTarget({ item: { id: 'target' }, value: { password: 'synthetic-private' } });
  assert.equal(await editing, null, 'late target values cannot enter a hidden UI');
  await model.load();
  const intent = model.workingIntent(); intent.operations.push({ id: 'add-1', kind: 'add', section: 'proxies', value: {} });
  let finishSave;
  const actualSave = save;
  save = (...args) => new Promise(resolve => { finishSave = async () => resolve(await actualSave(...args)); });
  const saving = model.save(intent); await new Promise(setImmediate); assert.equal(await model.save(intent), false); assert.equal(saveCalls, 1);
  await finishSave(); assert.equal(await saving, true); assert.ok(model.preview);
  assert.equal(model.intent.revision, ticket.draftRevision);
  ticket.draftRevision = 'other-editor';
  await assert.rejects(model.apply(), /变化/); assert.equal(applyCalls, 0, 'a new draft cannot be disguised by recapturing its ticket');
  save = actualSave; await model.load();
  preview = async () => { throw Error('invalid reference'); };
  await assert.rejects(model.save(intent), /reference/);
  assert.equal(model.preview, null); assert.equal(model.intent.operations.length, 1, 'failed preview retains the inert repairable draft');
  preview = async () => ({ digest: 'fixed', changes: [] }); await model.previewSaved();
  let finishApply; apply = () => new Promise(resolve => { finishApply = resolve; });
  const applying = model.apply(); model.cancel(); finishApply('saved');
  assert.equal(await applying, null, 'late transaction completion cannot navigate or claim success');
  console.log('PASS: captured read/draft tickets, private-target cancellation, single-flight saving, stale apply rejection, inert failed preview and late completion');
})().catch(error => { console.error(error); process.exitCode = 1; });
