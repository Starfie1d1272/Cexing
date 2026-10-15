// Synthetic bridge used by the real worker publication regression.
const fs = require('node:fs'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const sandbox = { exports: {} };
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/ProxyIntentEdits.ets', 'utf8')).outputText, sandbox);
const edits = sandbox.exports.ProxyIntentEdits;
let next = edits.disableNode(input.intent, input.target, `${input.addition}:disable`);
if (input.restore) next = edits.enableNode(next, input.addition, true);
process.stdout.write(JSON.stringify(next));
