// UI session against published worker/transaction signatures; all inputs synthetic.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
let ticket = { file: 'synthetic.yaml', profileIdentity: 'identity', profileVersion: 'profile-v1',
  activeVersion: 'active-v1', activeFile: 'synthetic.yaml', draftRevision: '' };
let publishedIntent = null, smartIntent;
let draft = { intent: null }, saveCalls = 0, applyCalls = 0, revision = 0;
let read = async () => ({ sourceRevision: 'source-v1', sections: [] });
let target = async () => ({ item: { id: 'target' }, value: { password: 'synthetic-private' } });
let save = async (_context, expected, intent) => {
  assert.equal(expected.draftRevision, ticket.draftRevision);
  ticket = { ...ticket, draftRevision: `draft-${++revision}` }; draft = { intent: intent === null ? null : { ...intent, revision: ticket.draftRevision } };
  return ticket.draftRevision;
};
let preview = async () => ({ digest: 'synthetic-digest', changes: [] });
let apply = async () => 'saved';
const modules = {
  './EditorDraftHosts': { EditorDraftHosts: { create: () => {
    let captured;
    return { load: async () => { captured = {...ticket}; return { revision: 'host-private-revision' }; },
      preview: async revision => { assert.equal(revision, 'host-private-revision');
        const changes = await preview({}, captured); return { revision, digest: changes.digest, changes }; },
      apply: async receipt => { assert.equal(receipt.revision, 'host-private-revision'); assert.ok(receipt.digest);
        applyCalls++; return await apply({}, captured); } };
  } } },
  './Settings': { Settings: { load: () => ({ smartAutoConvert: true }) } },
  './ConfigEditor': { ConfigEditor: { list: (...args) => read(...args), target: (...args) => target(...args), smartPreview: async (_ctx, _raw, _merge, expected, enabled, intent) => {
    assert.equal(expected, ticket.activeVersion); assert.equal(enabled, true);
    smartIntent = intent;
    return [{ id: 'renamed-group', choiceId: 'original-group', before: 'url-test', after: 'url-test', override: true }];
  } } },
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
  assert.equal(model.canUndo(), false, 'unchanged successful configuration has nothing to undo');
  assert.equal(await model.apply(), null, 'application requires a confirmed preview');
  publishedIntent = { operations: [{ section: 'proxy-providers', target: 'source-id', kind: 'rename', name: 'applied-name' }] };
  assert.equal(model.publishedProviderName({ item: { id: 'source-id' }, name: 'original-name' }), 'applied-name');
  model.intent = { operations: [{ section: 'proxy-providers', target: 'source-id', kind: 'rename', name: 'unapplied-name' }] };
  assert.equal(model.publishedProviderName({ item: { id: 'source-id' }, name: 'original-name' }), 'applied-name', 'runtime provider lookup follows published provenance, never an unapplied rename');
  model.intent = { schemaVersion: 1, sourceRevision: 'source-v2', revision: 'draft', operations: [], smartGroups: { 'original-group': false } };
  const choices = await model.smartChoices();
  assert.equal(smartIntent.smartGroups['original-group'], false, 'read uses the current stable Smart override');
  assert.equal(choices[0].choiceId, 'original-group', 'Smart control follows stable pre-rename identity');
  model.intent = { schemaVersion: 1, sourceRevision: 'source-v2', revision: 'draft', operations: [
    { id: 'rename-node', kind: 'rename', section: 'proxies', target: 'old-node-id', name: 'new-node' } ] };
  read = async (_context, _raw, _merge, _expected, _global, intent) => {
    assert.equal(intent.operations[0].kind, 'rename');
    return { sourceRevision: 'projected', missingFieldRevision: 'absent-hash', sections: [
      { section: 'proxy-groups', items: [{ id: 'group-id', name: 'group' }] } ] };
  };
  target = async (_context, _raw, _merge, _expected, section, id, _global, intent) => {
    assert.equal(id, 'group-id'); assert.equal(intent.operations[0].name, 'new-node');
    return { item: { id, revision: 'projected-group' }, name: 'group', value: { proxies: ['new-node'] } };
  };
  const baseline = { item: { id: 'group-id', revision: 'original-group' }, name: 'group', value: { proxies: ['old-node'] } };
  const projected = await model.presentTarget('proxy-groups', baseline);
  assert.deepEqual(Array.from(projected.value.proxies), ['new-node']);
  assert.deepEqual(baseline.value.proxies, ['old-node'], 'compiler presentation must not replace authoring preconditions');
  read = async () => ({ sourceRevision: 'source-v2', missingFieldRevision: 'absent-hash', sections: [] });
  model.intent = { operations: [{ kind: 'add', id: 'added-source', section: 'proxy-providers', name: 'draft-name' }] };
  publishedIntent = null;
  assert.equal(model.publishedProviderName({ item: { id: 'added-source' }, name: 'draft-name' }, true), '', 'draft additions cannot query a published provider');
  publishedIntent = { operations: [{ kind: 'add', id: 'added-source', section: 'proxy-providers', name: 'published-name' }] };
  assert.equal(model.publishedProviderName({ item: { id: 'added-source' }, name: 'draft-name' }, true), 'published-name');
  model.intent = { schemaVersion: 1, sourceRevision: 'source-v2', revision: 'draft', operations: [
    { id: 'caller-add-id', kind: 'add', section: 'proxies', name: 'added-node', value: { name: 'added-node', type: 'ss' } },
    { id: 'pause', kind: 'disable', section: 'proxies', target: 'compiler-node' },
    { id: 'rename', kind: 'rename', section: 'proxies', target: 'other-node', name: 'other-renamed' } ] };
  read = async (_ctx, _raw, _merge, _expected, _global, intent) => {
    assert.equal(intent.operations.length, 1, 'disable target is read at the real compiler insertion point');
    return { sections: [{ section: 'proxies', items: [{ id: 'compiler-node', name: 'added-node' }] }] };
  };
  target = async (_ctx, _raw, _merge, _expected, section, id, _global, intent) => {
    assert.equal(section, 'proxies'); assert.equal(id, 'compiler-node'); assert.equal(intent.operations.length, 1);
    return { item: { id, revision: 'compiler-new-revision' }, value: { password: 'synthetic' } };
  };
  assert.equal((await model.nodeTarget('caller-add-id', true)).item.revision, 'compiler-new-revision');
  model.intent.operations[0].name = undefined;
  assert.equal((await model.nodeTarget('caller-add-id', true)).item.id, 'compiler-node', 'standard add value name remains compiler-resolved');
  await assert.rejects(model.nodeTarget('missing-add', true), /NODE_OPERATION_CHANGED/);
  let finishAddedList; read = () => new Promise(resolve => { finishAddedList = resolve; });
  const lateAdded = model.nodeTarget('caller-add-id', true); model.cancel(); finishAddedList({ sections: [] });
  assert.equal(await lateAdded, null);
  read = async () => ({ sourceRevision: 'source-v2', missingFieldRevision: 'absent-hash', sections: [] });
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
  assert.equal(model.smartChanges[0].before, 'url-test'); assert.equal(model.smartChanges[0].after, 'url-test');
  assert.equal(smartIntent.revision, ticket.draftRevision, 'Smart display and receipt use the same saved draft ticket');
  assert.equal(model.intent.revision, ticket.draftRevision);
  assert.equal(model.canUndo(), true); assert.equal(model.undoNeedsConfirmation(), false, 'current-session edits keep step undo');
  save = actualSave;
  const reopened = new Model({}, ticket.file); await reopened.load();
  assert.equal(reopened.undoNeedsConfirmation(), true, 'reopened private drafts need explicit whole-draft restoration');
  await reopened.reset(); assert.equal(reopened.intent, null); assert.equal(draft.intent, null);
  assert.equal(applyCalls, 0, 'restoring the draft never applies a running configuration');
  await reopened.undo(); assert.equal(reopened.intent.operations[0].id, 'add-1', 'local undo can recover the discarded draft');

  ticket.draftRevision = 'other-editor';
  await assert.rejects(model.apply(), /变化/); assert.equal(applyCalls, 0, 'a new draft cannot be disguised by recapturing its ticket');
  save = actualSave; await model.load();
  assert.equal(model.undoNeedsConfirmation(), true, 'an external ticket change clears unrelated session history');
  preview = async () => { throw Error('invalid reference'); };
  await assert.rejects(model.save(intent), /reference/);
  assert.equal(model.preview, null); assert.equal(model.smartChanges.length, 0, 'failed preview clears old type evidence'); assert.equal(model.intent.operations.length, 1, 'failed preview retains the inert repairable draft');
  preview = async () => ({ digest: 'fixed', changes: [] }); await model.previewSaved();
  let finishApply; apply = () => new Promise(resolve => { finishApply = resolve; });
  const applying = model.apply(); model.cancel(); finishApply('saved');
  assert.equal(await applying, null, 'late transaction completion cannot navigate or claim success');
  console.log('PASS: captured read/draft tickets, private-target cancellation, single-flight saving, stale apply rejection, inert failed preview and late completion');
})().catch(error => { console.error(error); process.exitCode = 1; });
