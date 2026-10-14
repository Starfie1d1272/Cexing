const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
function load(file) {
  const sandbox = { exports: {}, require: name => {
    if (name !== '@kit.ArkTS') throw Error('unexpected fixture dependency');
    return { util: { Base64Helper: class { decodeSync(value) { return Uint8Array.from(Buffer.from(value, 'base64')); } },
      TextDecoder: { create: (_encoding, options) => ({ decodeToString: value => new TextDecoder('utf-8', options).decode(value) }) } } };
  } };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8')).outputText, sandbox);
  return sandbox.exports;
}
const { ProxyMappingForm: Form } = load('cexing/entry/src/main/ets/lib/ProxyMappingForm.ets');
const { ProxyIntentEdits: edits } = load('cexing/entry/src/main/ets/lib/ProxyIntentEdits.ets');
let intent = { schemaVersion: 1, sourceRevision: input.sourceRevision, revision: 'synthetic-draft', operations: [] };
const node = new Form('proxies', input.node);
if (input.rename) node.setText('name', 'renamed-node');
node.setNumber('port', '8443'); node.setFlag('udp', true);
intent = edits.mapping(intent, input.node, node.finish(), 'node-change', input.missing);
const provider = new Form('proxy-providers', input.provider);
provider.setNumber('interval', '3600');
intent = edits.mapping(intent, input.provider, provider.finish(), 'provider-change', input.missing);
const group = new Form('proxy-groups');
group.setText('name', 'new-provider-only'); group.setText('type', 'select'); group.setList('use', ['source']);
intent = edits.mapping(intent, null, group.finish(), 'group-add', input.missing);
if (input.link) {
  const { ProxyNodeImport } = load('cexing/entry/src/main/ets/lib/ProxyNodeImport.ets');
  const imported = new Form('proxies'); imported.replaceAdvanced(JSON.stringify(ProxyNodeImport.parse(input.link)));
  intent = edits.mapping(intent, null, imported.finish(), 'link-import', input.missing);
}
process.stdout.write(JSON.stringify(intent));
