// Execute the shipped presentation helper; no replacement semantic algorithm.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require('./transpile-arkts.cjs'), ui = require('./ui-fixtures.cjs');
const c = { exports: {}, ...ui.globals, require: key => key.endsWith('/UiText') ? ui.module : {} };
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
  '../../cexing/entry/src/main/ets/lib/CoreValidator.ets'), 'utf8')).outputText, c);
module.exports = c.exports;
