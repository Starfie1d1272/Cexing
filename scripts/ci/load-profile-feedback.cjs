// The actual closed classifier, with unused platform/persistence ports inert.
const fs = require('node:fs'), vm = require('node:vm'), path = require('node:path');
const ts = require('./transpile-arkts.cjs');
const box = { exports: {}, require: () => ({}) };
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
  '../../cexing/entry/src/main/ets/lib/ProfileApplyFeedback.ets'), 'utf8')).outputText, box);
module.exports = box.exports;
