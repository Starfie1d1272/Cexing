// Synthetic bridge fixture: execute production ArkTS form helpers, emit v1 intent.
const fs = require('node:fs'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const path = require('node:path');
const host = { exports: {}, require: () => ({}) };
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,'../cexing/entry/src/main/ets/lib/RuleDnsForms.ets'),'utf8')).outputText,host);
const input=JSON.parse(fs.readFileSync(0,'utf8'));
const f=host.exports.RuleDnsForms;
const draftHost={exports:{},require:()=>require('./ci/edit-operation-scope.cjs')};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,'../cexing/entry/src/main/ets/lib/RuleDnsDraft.ets'),'utf8')).outputText,draftHost);
let intent={schemaVersion:1,revision:'forms-fixture',sourceRevision:input.sourceRevision,
 operations:input.variant==='hosts' || input.variant==='match' ? [] : [f.moveRule('move',input.rule,input.before,input.match),f.recommendedDns(input.dns)]};
if(input.variant==='match') intent.operations=[f.addRule('added-match',{type:'MATCH',condition:'',target:'manual',noResolve:false},'')];
if (input.variant==='added' || input.variant==='added-moved') {
 intent.operations=[f.addRule('added-direct',{type:'DOMAIN',condition:'public.test',target:'DIRECT',noResolve:false},input.before),
 f.addRule('added-reject',{type:'DOMAIN',condition:'public.test',target:'REJECT',noResolve:false},input.before)];
 if(input.variant==='added-moved') intent=draftHost.exports.RuleDnsDraft.moveAdded(intent,'rules',1,0);
}
if (input.variant==='hosts') {
 intent.operations=[];
 intent=draftHost.exports.RuleDnsDraft.put(intent,{id:'first',kind:'update',section:'hosts',target:input.host.item.id,expected:input.host.item.revision,value:'192.0.2.2'});
 intent=draftHost.exports.RuleDnsDraft.put(intent,{id:'second',kind:'update',section:'hosts',target:input.host.item.id,expected:'intermediate-projected-revision',value:'192.0.2.3'});
}
process.stdout.write(JSON.stringify(intent));
