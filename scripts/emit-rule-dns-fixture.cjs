// Synthetic bridge fixture: execute production ArkTS form helpers, emit v1 intent.
const fs = require('node:fs'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const path = require('node:path');
const host = { exports: {}, require: () => ({}) };
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,'../cexing/entry/src/main/ets/lib/RuleDnsForms.ets'),'utf8')).outputText,host);
const input=JSON.parse(fs.readFileSync(0,'utf8'));
const f=host.exports.RuleDnsForms;
process.stdout.write(JSON.stringify({schemaVersion:1,revision:'forms-fixture',sourceRevision:input.sourceRevision,
 operations:[f.moveRule('move',input.rule,input.before,input.match),f.recommendedDns(input.dns)]}));
