// Actual bounded import failure classifier and shipped resource copy for host runtimes.
const fs = require('node:fs'), vm = require('node:vm'), path = require('node:path');
const ts = require('./transpile-arkts.cjs'), ui = require('./ui-fixtures.cjs');
exports.load = (logger = { warn() {} }) => {
  const box = { exports: {}, ...ui.globals, require: name => {
    if (name === './Logger') return { Logger: logger };
    if (name === './UiText') return ui.module;
    throw Error('Unexpected import failure dependency ' + name);
  } };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
    '../../cexing/entry/src/main/ets/lib/ImportFailure.ets'), 'utf8')).outputText, box);
  return box.exports;
};
