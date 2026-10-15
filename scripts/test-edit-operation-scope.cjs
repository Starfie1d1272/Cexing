// Pure production editor operations, with synthetic inactive template edits.
const assert = require('node:assert/strict');
const fs = require('node:fs'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const scope = require('./ci/edit-operation-scope.cjs');
function load(name) {
  const host = { exports: {}, require: () => scope };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(`cexing/entry/src/main/ets/lib/${name}.ets`, 'utf8')).outputText, host);
  return host.exports[name];
}
const edits = load('ProxyIntentEdits'), rules = load('RuleDnsDraft');
const clone = value => JSON.parse(JSON.stringify(value));
const dormant = [
  { id: 'sleep-rename', kind: 'rename', section: 'proxies', target: 'node', name: 'sleep-name' },
  { id: 'sleep-update', kind: 'update', section: 'proxies', target: 'node', patch: { port: 9 } },
  { id: 'sleep-delete', kind: 'delete', section: 'proxies', target: 'node' },
  { id: 'sleep-disable', kind: 'disable', section: 'proxies', target: 'node' },
  { id: 'sleep-move', kind: 'move', section: 'proxies', target: 'node', before: '' },
  { id: 'added', kind: 'add', section: 'proxies', name: 'sleep-add', value: { name: 'sleep-add' } },
  { id: 'added:disable', kind: 'disable', section: 'proxies', target: 'added-node' }
].map(op => ({ ...op, templateId: 'region' }));
const intent = { schemaVersion: 1, revision: 'r', sourceRevision: 's', template: { templateId: 'original' }, operations: clone(dormant) };
const target = { item: { id: 'node', revision: 'rev', fields: { port: 'port-rev' } }, name: 'node', value: { name: 'node', port: 1 } };
const draft = { section: 'proxies', name: 'new-name', value: { name: 'new-name', port: 2 } };
const sleeping = value => clone(value.operations.filter(op => !scope.isEditOperationActive(value, op)));
for (const value of [edits.mapping(intent, target, draft, 'edit', 'missing'), edits.remove(intent, 'proxies', target, 'delete'),
  edits.restore(intent, 'proxies', 'node'), edits.enableNode(intent, 'node'), edits.enableNode(intent, 'added', true),
  edits.disableNode(intent, target, 'new-disable'), edits.removeAddition(intent, 'added'), edits.move(intent, 'proxies', 'node', '', 'move')]) {
  assert.deepEqual(sleeping(value), dormant, 'inactive operations survive unchanged and in order');
}
assert.throws(() => edits.disableNode(intent, target, 'sleep-disable'), /NODE_OPERATION_CHANGED/);
assert.throws(() => edits.mapping(intent, null, draft, 'added', 'missing'), /重新打开/);
assert.equal(edits.nodeDisabled(intent, 'node'), false);
assert.equal(edits.nodeDisabled(intent, 'added', true), false);
assert.deepEqual(intent.operations, dormant, 'input remains untouched');
const active = clone(intent); active.template.templateId = 'region';
const modified = edits.mapping(active, null, draft, 'added', 'missing');
assert.equal(modified.operations.find(op => op.id === 'added').templateId, 'region');
assert.equal(scope.isEditOperationActive({ operations: [] }, { templateId: 'region' }), false);
assert.equal(scope.isEditOperationActive(intent, {}), true);
assert.equal(scope.isEditOperationActive(active, { templateId: 'region' }), true);
const dns = { id: 'dns', kind: 'update', section: 'dns', target: 'dns', patch: { nameserver: ['old'] }, preconditions: { nameserver: 'guard' }, templateId: 'region' };
const dnsIntent = { ...clone(intent), operations: [dns] };
const dnsOp = { id: 'dns', kind: 'update', section: 'dns', target: 'dns', patch: { nameserver: ['new'] }, preconditions: { nameserver: 'guard' } };
assert.throws(() => rules.put(dnsIntent, dnsOp), /重新打开/);
assert.deepEqual(sleeping(rules.put(dnsIntent, { ...dnsOp, id: 'new-dns' })), [dns]);
dnsIntent.template.templateId = 'region';
assert.equal(rules.put(dnsIntent, dnsOp).operations[0].templateId, 'region');
const scalar = { ...clone(dnsIntent), operations: [{ id: 'scalar', kind: 'update', section: 'hosts', target: 'host', value: '192.0.2.1', expected: 'original', templateId: 'region' }] };
const replaced = rules.put(scalar, { id: 'scalar', kind: 'update', section: 'hosts', target: 'host', expected: 'projected', value: '192.0.2.2' });
assert.equal(replaced.operations[0].templateId, 'region'); assert.equal(replaced.operations[0].expected, 'original');
const additions = { ...clone(intent), operations: [
  { id: 'a', kind: 'add', section: 'rules', value: 'DOMAIN,a.test,DIRECT' },
  { id: 'sleep-rule', kind: 'add', section: 'rules', value: 'MATCH,DIRECT', templateId: 'region' },
  { id: 'b', kind: 'add', section: 'rules', value: 'DOMAIN,b.test,DIRECT' }
] };
const moved = rules.moveAdded(additions, 'rules', 1, 0);
assert.deepEqual(clone(moved.operations.map(op => op.id)), ['b', 'sleep-rule', 'a']);
assert.deepEqual(sleeping(moved), sleeping(additions));
console.log('PASS: dormant edits survive proxy mutations/DNS merges/reordering; active replacements retain template ownership');
