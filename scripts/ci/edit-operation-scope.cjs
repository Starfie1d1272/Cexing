// Load the actual pure scope predicate for ArkTS editor host fixtures.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./transpile-arkts.cjs');
const host = { exports: {} };
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
  '../../cexing/entry/src/main/ets/lib/EditOperationScope.ets'), 'utf8')).outputText, host);
module.exports = host.exports;
