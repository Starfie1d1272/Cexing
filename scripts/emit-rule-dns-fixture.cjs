// Synthetic bridge fixture: execute production ArkTS form helpers, emit v1 intent.
const fs = require('node:fs'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const path = require('node:path');
const host = { exports: {}, require: () => ({}) };
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,'../cexing/entry/src/main/ets/lib/RuleDnsForms.ets'),'utf8')).outputText,host);
const input=JSON.parse(fs.readFileSync(0,'utf8'));
const f=host.exports.RuleDnsForms;
const draftHost={exports:{},require:()=>({})};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,'../cexing/entry/src/main/ets/lib/RuleDnsDraft.ets'),'utf8')).outputText,draftHost);
let intent={schemaVersion:1,revision:'forms-fixture',sourceRevision:input.sourceRevision,
 operations:[f.moveRule('move',input.rule,input.before,input.match),f.recommendedDns(input.dns)]};
if (input.variant==='added' || input.variant==='added-moved') {
 intent.operations=[f.addRule('added-direct',{type:'DOMAIN',condition:'public.test',target:'DIRECT',noResolve:false},input.before),
 f.addRule('added-reject',{type:'DOMAIN',condition:'public.test',target:'REJECT',noResolve:false},input.before)];
 if(input.variant==='added-moved') intent=draftHost.exports.RuleDnsDraft.moveAdded(intent,'rules',1,0);
}
process.stdout.write(JSON.stringify(intent));
