// Synthetic untrusted inputs only; this does not exercise system URI grants or camera UI.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const source = fs.readFileSync('cexing/entry/src/main/ets/lib/ProfileImportInput.ets', 'utf8');
let changes = 0;
let resolveShare;
const sandbox = { exports: {}, require: name => {
  if (name === '@kit.ArkUI') return { promptAction: { showToast() {} } };
  assert.equal(name, '@kit.ShareKit');
  return { systemShare: { getSharedData: () => new Promise(resolve => { resolveShare = resolve; }) } };
}, AppStorage: { setOrCreate: key => {
  assert.equal(key, 'profileImportRequest'); changes++;
} } };
vm.runInNewContext(ts.transpileModule(source).outputText, sandbox);
const input = sandbox.exports.ProfileImportInput;
const link = 'https://example.invalid/profile.yaml?token=synthetic';
assert.equal(input.parseText(link).value, link);
assert.equal(input.parseText('clash://install-config?url=' + encodeURIComponent(link)).value, link);
assert.equal(input.parseText('cexing://import?url=' + encodeURIComponent(link)).value, link);
for (const bad of ['http://example.invalid/config', 'https://u:p@example.invalid/', 'javascript:alert(1)',
  'file:///data/storage/private.yaml', 'https://example.invalid/%0a', 'https://example.invalid/%zz',
  'https://example.invalid/#secret', 'https://example.invalid/\n', 'x'.repeat(8193),
  'clash://install-config?url=' + encodeURIComponent(link) + '&url=' + encodeURIComponent(link),
  'cexing://import?url=' + encodeURIComponent('file:///private.yaml')]) {
  assert.equal(input.parseText(bad), null, bad.slice(0, 50));
}
const view = uri => ({ action: 'ohos.want.action.viewData', uri });
const document = 'file://docs/storage/Users/currentUser/Download/synthetic.yaml';
assert.equal(input.fromWant(view(document)), null, 'no read grant');
assert.equal(input.fromWant({ ...view(document), flags: 1 }).kind, 'file');
for (const uri of ['file:///data/storage/private.yaml', 'file://other/private.yaml', 'file://com.starfie1d.cexing/x/private.yaml',
  'file://docs/x/../private.yaml', 'file://docs/x/%2e%2e/private.yaml', 'file://docs/x/a.yaml%00',
  'file://docs/x/a.txt']) {
  assert.equal(input.fromWant({ ...view(uri), flags: 1 }), null);
}
assert.equal(input.fromWant({ action: 'unrelated', uri: link }), null);
assert.equal(input.fromWant({ action: 'ohos.want.action.sendData', flags: 1,
  parameters: { 'ability.params.stream': [document, document] } }), null);
const external = { action: 'ohos.want.action.sendData', parameters: {
  'ohos.extra.param.key.TEXT': link, cexingConnectionAction: 'connect' } };
input.receive(external); assert.equal(changes, 1);
input.receive(external); assert.equal(changes, 1, 'duplicate intent must not reopen confirmation');
const firstLease = input.take();
assert.equal(firstLease.value, link); assert.equal(input.take(), null);
input.receive(external); assert.equal(changes, 1, 'visible confirmation also deduplicates repeated delivery');
input.release(firstLease); input.receive(external);
assert.equal(changes, 2, 'cancelled input can be shared again');
const retriedLease = input.take(); assert.equal(retriedLease.value, link);
input.receive(view('https://other.invalid/sub')); assert.equal(changes, 3);
const newerLease = input.take(); assert.equal(newerLease.value, 'https://other.invalid/sub');
input.release(retriedLease); input.receive(view('https://other.invalid/sub'));
assert.equal(changes, 3, 'old completion cannot release a newer confirmation');
input.release(newerLease);
const entry = fs.readFileSync('cexing/entry/src/main/ets/entryability/EntryAbility.ets', 'utf8');
assert.equal((entry.match(/else \{ ConnectionEntry.receive\(want\); \}/g) || []).length, 2,
  'cold/hot external input must be isolated from connection shortcuts');
(async () => {
  input.receive({ action: 'ohos.want.action.sendData' });
  resolveShare({ getRecords: () => [{ content: 'https://shared.invalid/sub' }] });
  await Promise.resolve(); assert.equal(input.take().value, 'https://shared.invalid/sub');
  input.receive({ action: 'ohos.want.action.sendData' });
  const oldShare = resolveShare;
  input.receive(view('https://newer.invalid/sub'));
  oldShare({ getRecords: () => [{ content: 'https://stale.invalid/sub' }] });
  await Promise.resolve(); assert.equal(input.take().value, 'https://newer.invalid/sub');
  input.receive({ action: 'ohos.want.action.sendData' });
  resolveShare({ getRecords: () => [{ uri: 'file://com.sender.test/shared/synthetic.yaml' }] });
  await Promise.resolve(); assert.equal(input.take().kind, 'file');
  console.log('PASS: bounded link/encoding validation, URI grants/private-path restrictions, cold/hot duplicates, Share Kit records, stale share results and connection isolation');
})().catch(error => { console.error(error); process.exitCode = 1; });
