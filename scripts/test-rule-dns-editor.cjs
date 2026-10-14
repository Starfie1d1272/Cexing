const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const ts=require('./ci/transpile-arkts.cjs');
const read=name=>fs.readFileSync(`cexing/entry/src/main/ets/${name}`,'utf8');
function load(source,modules,extra={}){const box={exports:{},require:n=>{assert.ok(n in modules,n);return modules[n];},...extra};vm.runInNewContext(ts.transpileModule(source).outputText,box);return box.exports;}
const forms=load(read('lib/RuleDnsForms.ets'),{});
const drafts=load(read('lib/RuleDnsDraft.ets'),{});
const gate=()=>{let resolve;const promise=new Promise(r=>{resolve=r;});return {promise,resolve};};
const snapshot={sourceRevision:'source',missingFieldRevision:'missing-revision',sections:[{section:'rules',items:[{id:'rule',revision:'rev',type:'DOMAIN'},{id:'match',revision:'end',type:'MATCH'}]},{section:'dns',items:[{id:'dns',revision:'dns-rev'}]}]};
let revision='v0',reads=0,saves=0,applies=0,pending=null,fail=false,applyFailure=false;
let published=null;const providerCalls=[];const controller={status:2};
let intent={schemaVersion:1,revision:'v0',sourceRevision:'source',operations:[]};
const transactions={isBusy:()=>false,editTicket:()=>{reads++;return {file:'synthetic.yaml',draftRevision:revision,activeVersion:'active',activeFile:'synthetic.yaml'};},
 saveEditDraft:async(_,ticket,value)=>{saves++;assert.equal(ticket.draftRevision,revision);if(pending)await pending.promise;revision='v'+saves;intent=value;return revision;},
 previewEditDraft:async(_,ticket)=>{assert.equal(ticket.draftRevision,revision);if(fail)throw Error('conflict');return {changes:[{section:'rules',before:2,after:2}]};},
 applyEditDraft:async(_,ticket)=>{applies++;if(applyFailure)throw Error('应用未确认，请重连恢复');assert.equal(ticket.draftRevision,revision);if(pending)await pending.promise;return 'applied';}};
const modules={'../lib/ConfigEditor':{ConfigEditor:{list:async()=>snapshot,read:async()=>snapshot,target:async(_,o,l,e,section,id)=>({missingFieldRevision:'missing-revision',item:{id,revision:'rev',fields:{}},value:section==='rules'?'DOMAIN,public.test,DIRECT':{},name:'synthetic'})}},
 '../lib/ProfileTransactions':{ProfileTransactions:transactions},'../lib/ProfileStore':{ProfileStore:{getProfileContent:()=>'',getEnabledMerge:()=>'',readEditDraft:()=>({revision,intent})}},
 '../lib/VpnController':{VpnController:controller,VpnStatus:{Connected:2}}, '../lib/EffectiveVersions':{EffectiveVersions:{read:()=>({Profiles:{'synthetic.yaml':{ID:'active'}}}),editIntent:()=>published,regionPlan:()=>null}},'../lib/RuleDnsForms':forms,'../lib/RuleDnsDraft':drafts,'../lib/RuleProviderStatus':{RuleProviderStatus:{read:async name=>{providerCalls.push(['read',name]);return {available:true,count:5,references:2,error:''};},refresh:async name=>{providerCalls.push(['refresh',name]);return {available:true,count:5,references:2,error:''};}}},'@kit.ArkTS':{util:{generateRandomUUID:()=> 'synthetic-operation'}}, './RuleDnsEditForm':{},'./NativeTheme':{}};
let source=read('pages/RuleDnsEditorPage.ets');source=(source.slice(0,source.indexOf('  build()'))+'\n}').split('\n').map(line=>line.trimStart().startsWith('@')?line.replace(/@\w+(?:\([^\n)]*\))?\s*/g,''):line).join('\n').replace('export struct ','export class ');
const {RuleDnsEditorPage:Page,RuleDnsEditorBus:Bus}=load(source,modules,{getContext:()=>({})});
(async()=>{
 Bus.file='synthetic.yaml';const page=new Page();page.aboutToAppear();await page.load();
 await page.open(snapshot.sections[0].items[0]);assert.equal(page.selected.value,'DOMAIN,public.test,DIRECT');
 const op={id:'edit',kind:'update',section:'rules',target:'rule',expected:'rev',value:'DOMAIN,public.test,REJECT'};
 pending=gate();const saving=page.preview(drafts.RuleDnsDraft.put(intent,op));await page.preview(intent);assert.equal(saves,1,'repeat click rejected');
 const before=reads;page.visible=false;page.visibilityChanged();pending.resolve();await saving;assert.equal(reads,before,'hidden completion cannot capture new ticket');assert.equal(page.previewReady,false);
 pending=null;page.visible=true;page.visibilityChanged();await page.load();await page.preview(intent);assert.equal(page.previewReady,true);
 fail=true;await page.preview(intent);assert.equal(page.previewReady,false,'failed preview cannot enable apply');assert.equal(applies,0);fail=false;
 await page.preview(intent);applyFailure=true;await page.apply();assert.equal(page.previewReady,false);assert.equal(page.message,'应用未确认，请重连恢复');applyFailure=false;applies=0;
 await page.preview(intent);pending=gate();const apply=page.apply();await page.apply();assert.equal(applies,1,'apply serialized');page.aboutToDisappear();page.message='new view';pending.resolve();await apply;assert.equal(page.message,'new view');
 published={schemaVersion:1,revision:'published',sourceRevision:'source',operations:[{id:'rename',kind:'rename',section:'rule-providers',target:'provider',expected:'rev',name:'running-feed'}]};
 pending=null;page.visible=true;page.aboutToAppear();await page.load();page.section='rule-providers';
 await page.open({id:'provider',revision:'rev'});await page.provider(false);assert.equal(providerCalls.length,0,'unapplied changes cannot claim runtime state');
 await page.provider(true);assert.equal(providerCalls.length,0,'unapplied changes cannot refresh a different source');
 page.intent=published;page.liveProviderName='running-feed';await page.provider(true);assert.equal(providerCalls[0][1],'running-feed');
 const target={missingFieldRevision:'missing-revision',item:{id:'dns',revision:'dns-rev',fields:{}},value:{}};
 let composed=drafts.RuleDnsDraft.put({schemaVersion:1,revision:'r',sourceRevision:'s',operations:[]},forms.RuleDnsForms.patch('custom','dns',target,{'x-advanced':{keep:true}}));
 composed=drafts.RuleDnsDraft.put(composed,forms.RuleDnsForms.recommendedDns(target));
 composed=drafts.RuleDnsDraft.put(composed,forms.RuleDnsForms.patch('custom-again','dns',target,{enable:true}));
 assert.equal(composed.operations.length,1);assert.ok(composed.operations[0].patch['x-advanced']);assert.ok(composed.operations[0].patch.nameserver,'custom edit retains preset resolvers until explicitly changed');
 console.log('PASS: real editor page read/save/preview/apply wiring, repeat/hide/reopen/stale result and lossless DNS composition');
})().catch(e=>{console.error(e);process.exitCode=1;});
