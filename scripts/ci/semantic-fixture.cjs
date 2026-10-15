// Execute the shipped presentation helper; no replacement semantic algorithm.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require('./transpile-arkts.cjs'), ui = require('./ui-fixtures.cjs');
const feedback = { exports: {}, require: () => ({}) };
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname, '../../cexing/entry/src/main/ets/lib/ProfileApplyFeedback.ets'), 'utf8')).outputText, feedback);
const c = { exports: {}, ...ui.globals, require: key => key.endsWith('/UiText') ? ui.module : key.endsWith('/ProfileApplyFeedback') ? feedback.exports : {} };
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
  '../../cexing/entry/src/main/ets/lib/CoreValidator.ets'), 'utf8')).outputText, c);
module.exports = { ...c.exports, ...feedback.exports };
