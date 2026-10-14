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
assert.throws(() => form.replaceAdvanced('[]'), /对象/);
assert.throws(() => form.replaceAdvanced('{bad'), /格式/);
let pageSource = fs.readFileSync('cexing/entry/src/main/ets/pages/ProxyMappingFormPage.ets', 'utf8');
pageSource = pageSource.slice(0, pageSource.indexOf('  @Builder')) + '\n}';
pageSource = pageSource.split('\n').map(line => line.trimStart().startsWith('@') ?
  line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '') : line).join('\n').replace('export struct ', 'export class ');
const sandbox = { exports: {}, require: name => name.includes('ProxyMappingForm') ? modelExports : {} };
vm.runInNewContext(ts.transpileModule(pageSource).outputText, sandbox);
(async () => {
  const page = new sandbox.exports.ProxyMappingFormPage(); page.target = node; page.aboutToAppear();
  let calls = 0, rejectPreview;
  page.onDraft = () => { calls++; return new Promise((_, reject) => { rejectPreview = reject; }); };
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
const shown = edits.shownTarget(node, candidate, 'proxies'); assert.equal(shown.value.name, 'renamed');
const back = new Form('proxies', shown); back.setNumber('port', '443'); back.setText('name', 'synthetic');
candidate = edits.mapping(candidate, node, back.finish(), 'action-2', 'missing-from-compiler');
assert.equal(candidate.operations.length, 0, 'editing back to original removes previous field/rename intent');
candidate = edits.remove(intent, 'proxies', node, 'delete-1');
assert.equal(candidate.operations[0].kind, 'delete');
assert.equal(edits.restore(candidate, 'proxies', node.item.id).operations.length, 0);
console.log('PASS: minimal field preconditions, explicit rename/references operation, coalescing and reversible delete intents');
