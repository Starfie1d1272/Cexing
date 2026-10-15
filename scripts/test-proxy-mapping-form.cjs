const { resourceContext } = require('./ci/mock-profile-resources.cjs');
// Transient mapping forms use synthetic credentials. No persistence or device claim.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const modelExports = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/ProxyMappingForm.ets', 'utf8')).outputText,
  { exports: modelExports });
const { ProxyMappingForm: Form } = modelExports;
const node = { item: { id: 'opaque-node', revision: 'opaque-revision', fields: {} },
  value: { name: 'synthetic', type: 'vless', server: 'example.invalid', port: 443, uuid: 'synthetic-private',
    'reality-opts': { 'public-key': 'synthetic-key' }, 'ws-opts': { headers: { Host: 'synthetic.invalid' } } } };
const original = JSON.stringify(node);
const form = new Form('proxies', node);
form.setText('name', 'renamed'); form.setNumber('port', '8443');
form.setNestedText(['ws-opts', 'path'], '/synthetic');
const result = form.finish();
assert.equal(result.value['ws-opts'].path, '/synthetic');
assert.equal(result.value.uuid, 'synthetic-private');
assert.deepEqual(JSON.parse(JSON.stringify(result.value['reality-opts'])), { 'public-key': 'synthetic-key' });
assert.equal(result.value['ws-opts'].headers.Host, 'synthetic.invalid');
assert.equal(JSON.stringify(node), original, 'form edits cannot mutate the source target');
form.setNumber('port', 'bad'); assert.throws(() => form.finish(), /数字/);
form.setNumber('port', '65536'); assert.throws(() => form.finish(), /端口/);
form.setNumber('port', '443'); form.setText('uuid', ''); assert.throws(() => form.finish(), /UUID/);
const unsafe = JSON.parse('{"name":"large","type":"direct","x-unknown":{"integer":9007199254740993}}');
assert.throws(() => new Form('proxies', { item: {}, value: unsafe }), /原始配置/);
const rejectedAdvanced = new Form('proxies');
assert.throws(() => rejectedAdvanced.replaceAdvanced('{"name":"large","type":"direct","x-unknown":9007199254740993}'), /原始配置/);
assert.equal(rejectedAdvanced.text('name'), '', 'unrepresentable numbers never replace the editable draft');
const unknownNested = new Form('proxies', { item: {}, value: JSON.parse('{"name":"safe","type":"vless","server":"127.0.0.1","port":443,"uuid":"synthetic","ws-opts":{"path":"/old","__proto__":{"keep":true},"constructor":{"keep":true}}}') });
unknownNested.setNestedText(['ws-opts', 'path'], '');
const unknownValue = unknownNested.finish().value['ws-opts'];
assert.ok(Object.prototype.hasOwnProperty.call(unknownValue, '__proto__')); assert.equal(unknownValue.__proto__.keep, true);
assert.equal(unknownValue.constructor.keep, true); assert.equal(unknownValue.path, undefined);
const advancedDirect = new Form('proxies', { item: {}, value: { name: 'advanced', type: 'direct', 'x-unknown': { keep: true } } });
advancedDirect.setText('name', 'renamed-direct');
assert.equal(advancedDirect.finish().value['x-unknown'].keep, true, 'advanced adapter names can be edited without fabricated server/port fields');
assert.equal(advancedDirect.finish().value.server, undefined);
const group = new Form('proxy-groups', { item: {}, value: {
  name: 'provider-only', type: 'smart', use: ['synthetic-provider'], 'custom-key': { keep: true }
} });
assert.equal(group.finish().value['custom-key'].keep, true, 'provider-only groups are valid form input');
group.setList('use', []); assert.throws(() => group.finish(), /添加节点/);
const provider = new Form('proxy-providers', { name: 'source', item: {}, value: {
  type: 'http', url: 'https://example.invalid/synthetic', 'health-check': { enable: true, interval: 60 }
} });
provider.setNumber('interval', '3600');
const providerResult = provider.finish();
assert.equal(providerResult.name, 'source'); assert.equal(providerResult.value.name, undefined);
assert.equal(providerResult.value['health-check'].interval, 60);
const namedProvider = new Form('proxy-providers', { name: 'mapping-key', item: {}, value: {
  name: 'unknown-advanced-name', type: 'file', path: './synthetic.yaml' } });
assert.equal(namedProvider.text('name'), 'mapping-key');
assert.equal(namedProvider.finish().value.name, 'unknown-advanced-name', 'provider mapping name cannot erase an unknown advanced name field');
assert.throws(() => form.replaceAdvanced('[]'), /对象/);
assert.throws(() => form.replaceAdvanced('{bad'), /格式/);
let pageSource = fs.readFileSync('cexing/entry/src/main/ets/pages/ProxyMappingFormPage.ets', 'utf8');
pageSource = pageSource.slice(0, pageSource.indexOf('  @Builder')) + '\n}';
pageSource = pageSource.split('\n').map(line => line.trimStart().startsWith('@') ?
  line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '') : line).join('\n').replace('export struct ', 'export class ');
const importBox = { exports: {}, require: () => ({ util: {
  Base64Helper: class { decodeSync(value) { return Uint8Array.from(Buffer.from(value, 'base64')); } },
  TextDecoder: { create: (_encoding, options) => ({ decodeToString: value => new TextDecoder('utf-8', options).decode(value) }) }
} }) };
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/ProxyNodeImport.ets', 'utf8')).outputText, importBox);
const textBox = { exports: {} };
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/ProxyEditorText.ets', 'utf8')).outputText, textBox);
const sandbox = { exports: {}, getContext: () => resourceContext(), require: name => name.includes('ProxyMappingForm') ? modelExports :
  name.includes('ProxyNodeImport') ? importBox.exports : name.includes('ProxyEditorText') ? textBox.exports : {} };
vm.runInNewContext(ts.transpileModule(pageSource).outputText, sandbox);
(async () => {
  const rawOnly = new sandbox.exports.ProxyMappingFormPage(); rawOnly.target = { item: {}, value: unsafe };
  let rawWrites = 0; rawOnly.onDraft = async () => rawWrites++; rawOnly.aboutToAppear();
  assert.equal(rawOnly.loadFailed, true); assert.match(rawOnly.error, /原始配置/); await rawOnly.submit(); assert.equal(rawWrites, 0);
  const imported = new sandbox.exports.ProxyMappingFormPage(); imported.aboutToAppear();
  let importedWrites = 0;
  imported.onDraft = async draft => { importedWrites++; assert.equal(draft.value.password, 'synthetic'); };
  imported.nodeLink = 'trojan://synthetic@127.0.0.1:443?security=tls#Imported'; imported.linkOpen = true;
  imported.importLink(); assert.equal(importedWrites, 0, 'decoding only fills the transient form');
  assert.equal(imported.type, 'trojan'); assert.equal(imported.nodeLink, ''); assert.equal(imported.linkOpen, false);
  await imported.submit(); assert.equal(importedWrites, 1, 'explicit preview sends the normal draft callback');
  imported.nodeLink = 'trojan://private@127.0.0.1:443?unknown=private'; imported.importLink();
  assert.ok(!imported.error.includes('private')); assert.equal(importedWrites, 1);
  const transport = new sandbox.exports.ProxyMappingFormPage(); transport.transport = 'h2';
  assert.equal(transport.transportTypes()[0], 'h2', 'an existing advanced transport is retained');
  transport.transport = ''; assert.deepEqual(Array.from(transport.transportTypes()), ['tcp', 'ws', 'grpc']);
  const page = new sandbox.exports.ProxyMappingFormPage(); page.target = node; page.aboutToAppear();
  let calls = 0, rejectPreview;
  page.onDraft = () => { calls++; return new Promise((_, reject) => { rejectPreview = reject; }); };
  page.busy = true; await page.submit(); assert.equal(calls, 0, 'provider status activity blocks overlapping form submission'); page.busy = false;
  const first = page.submit(); await page.submit(); assert.equal(calls, 1);
  page.aboutToDisappear(); rejectPreview(Error('late error')); await first;
  assert.equal(page.error, '', 'late preview cannot change a hidden form');
  page.members = ['A', 'B', 'C']; page.moveMember(1, -1);
  assert.equal(page.members.join(','), 'B,A,C');
  console.log('PASS: node/provider/group mapping round-trip, unknown nested fields and secrets retained, provider-only, field validation, member order, single-flight and late preview');
})().catch(error => { console.error(error); process.exitCode = 1; });
const editExports = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/ProxyIntentEdits.ets', 'utf8')).outputText,
  { exports: editExports });
const edits = editExports.ProxyIntentEdits;
const intent = { schemaVersion: 1, revision: 'draft-1', sourceRevision: 'source-1', operations: [] };
node.item.fields = { port: 'original-port', uuid: 'original-uuid' };
const changed = new Form('proxies', node); changed.setNumber('port', '8443'); changed.setText('name', 'renamed');
let candidate = edits.mapping(intent, node, changed.finish(), 'action-1', 'missing-from-compiler');
assert.equal(candidate.operations[0].patch.port, 8443);
assert.equal(candidate.operations[0].preconditions.port, 'original-port');
assert.equal(candidate.operations[1].kind, 'rename');
assert.equal(candidate.operations[1].expected, 'opaque-revision');
const back = new Form('proxies', { ...node, name: 'renamed', value: changed.finish().value }); back.setNumber('port', '443'); back.setText('name', 'synthetic');
candidate = edits.mapping(candidate, node, back.finish(), 'action-2', 'missing-from-compiler');
assert.equal(candidate.operations.length, 0, 'editing back to original removes previous field/rename intent');
candidate = edits.remove(intent, 'proxies', node, 'delete-1');
assert.equal(candidate.operations[0].kind, 'delete');
assert.equal(edits.restore(candidate, 'proxies', node.item.id).operations.length, 0);
console.log('PASS: minimal field preconditions, explicit rename/references operation, coalescing and reversible delete intents');

const paused = edits.disableNode(edits.mapping(intent, node, changed.finish(), 'edit-for-pause', 'missing-from-compiler'), node, 'pause');
assert.equal(paused.operations.map(op => op.kind).join(','), 'update,disable,rename');
assert.equal(paused.operations[1].expected, node.item.revision);
assert.equal(edits.nodeDisabled(paused, node.item.id), true);
const resumed = edits.enableNode(paused, node.item.id);
assert.equal(resumed.operations.map(op => op.kind).join(','), 'update,rename');
assert.equal(intent.operations.length, 0, 'pause helpers cannot mutate the captured intent');
const addedPause = edits.disableNode({ ...intent, operations: [{ id: 'addition', kind: 'add', section: 'proxies', name: 'added', value: {} }] },
  { item: { id: 'actual-compiler-id', revision: 'actual-compiler-revision' } }, 'addition:disable');
assert.equal(edits.nodeDisabled(addedPause, 'addition', true), true);
assert.equal(edits.removeAddition(addedPause, 'addition').operations.length, 0, 'deleting an added node removes its bound pause');
assert.equal(edits.enableNode(addedPause, 'addition', true).operations.length, 1, 'resuming keeps the original addition');
console.log('PASS: node disable preserves field/rename operations, opaque target revision, addition identity and enable/delete restoration');
