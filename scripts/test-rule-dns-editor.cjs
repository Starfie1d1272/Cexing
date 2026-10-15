const uiFixture=require('./ci/ui-fixtures.cjs');
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const ts=require('./ci/transpile-arkts.cjs');
const read=name=>fs.readFileSync(`cexing/entry/src/main/ets/${name}`,'utf8');
function load(source,modules,extra={}){const box={exports:{},...uiFixture.globals,require:n=>{if(n.endsWith('/EditOperationScope'))return require('./ci/edit-operation-scope.cjs');if(n.endsWith('/UiText'))return uiFixture.module;assert.ok(n in modules,n);return modules[n];},...extra};vm.runInNewContext(ts.transpileModule(source).outputText,box);return box.exports;}
const feedback=load(read('lib/ProfileApplyFeedback.ets'),{'./ProfileStore':{},'./EffectiveVersions':{},'./ProfileRegionChoices':{},'./VpnController':{}});
const text=load(read('lib/RuleDnsText.ets'),{'./ProfileApplyFeedback':feedback});
const forms=load(read('lib/RuleDnsForms.ets'),{}),drafts=load(read('lib/RuleDnsDraft.ets'),{});
const gate=()=>{let resolve;const promise=new Promise(r=>{resolve=r;});return {promise,resolve};};
const snapshot={sourceRevision:'source',missingFieldRevision:'missing-revision',sections:[{section:'rules',items:[{id:'rule',revision:'rev',type:'DOMAIN',name:'规则 1'},{id:'match',revision:'end',type:'MATCH',name:'规则 2'}]},{section:'dns',items:[{id:'dns',revision:'dns-rev',name:'DNS'}]},{section:'proxy-groups',items:[{id:'group',revision:'g',name:'Synthetic group'}]}]};
let revision='session-0',loads=0,saves=0,applies=0,previews=0,pending=null,fail=false,applyFailure=false;
let intent={schemaVersion:1,revision:'draft-0',sourceRevision:'source',operations:[]};
const clone=value=>JSON.parse(JSON.stringify(value));
const host={load:async()=>{loads++;return {profileId:'synthetic.yaml',revision,intent:clone(intent),snapshot:clone(snapshot)};},
 target:async(section,id,expected)=>{assert.equal(expected,revision);return {missingFieldRevision:'missing-revision',item:{id,revision:'rev',fields:{}},value:section==='rules'?'DOMAIN,public.test,DIRECT':{},name:'synthetic'};},
 save:async(value,expected)=>{assert.equal(expected,revision);saves++;if(pending)await pending.promise;intent=clone(value);revision='session-'+saves;return host.load();},
 preview:async expected=>{previews++;assert.equal(expected,revision);if(fail)throw Error('conflict');return {revision,digest:'validated',changes:{digest:'validated',changes:[{section:'rules',before:2,after:2}]}};},
 apply:async preview=>{assert.equal(preview.revision,revision);assert.equal(preview.digest,'validated');applies++;if(applyFailure)throw Error('应用未确认，请重连恢复');if(pending)await pending.promise;return 'applied';},
 undo:async expected=>{assert.equal(expected,revision);intent.operations=[];revision='undo';return host.load();}};
const modules={'../lib/RuleDnsText':text,'../lib/CoreValidator':{CoreValidator:{describeMergePreview:value=>{assert.equal(value.digest,'validated');return '规则：顺序已调整';}}},'../lib/EditorDraftHosts':{EditorDraftHosts:{create:(_,file)=>{assert.equal(file,'synthetic.yaml');return host;}}},
 '../lib/ProfileTransactions':{ProfileTransactions:{isBusy:()=>false,editTicket:()=>({file:'synthetic.yaml',activeFile:'synthetic.yaml',activeVersion:'active',draftRevision:'draft'})}},
 '../lib/ProfileStore':{ProfileStore:{}},'../lib/EffectiveVersions':{EffectiveVersions:{read:()=>({Profiles:{}})}},'../lib/VpnController':{VpnController:{status:0},VpnStatus:{Connected:2}},
 '../lib/RuleDnsForms':forms,'../lib/RuleDnsDraft':drafts,'../lib/RuleProviderStatus':{RuleProviderStatus:{}},'@kit.ArkTS':{util:{generateRandomUUID:()=> 'synthetic-operation'}},'./RuleDnsEditForm':{},'./NativeTheme':{}};
let source=read('pages/RuleDnsEditorPage.ets');source=(source.slice(0,source.indexOf('  build()'))+'\n}').split('\n').map(line=>line.trimStart().startsWith('@')?line.replace(/@\w+(?:\([^\n)]*\))?\s*/g,''):line).join('\n').replace('export struct ','export class ');
const {RuleDnsEditorPage:Page,RuleDnsEditorBus:Bus}=load(source,modules,{getContext:()=>({}),AlertDialog:{show:options=>{dialog=options;dialogs++;}}});
let dialog=null,dialogs=0;
(async()=>{
 Bus.file='synthetic.yaml';const page=new Page();page.aboutToAppear();await page.load();assert.ok(page.targets.includes('Synthetic group'));
 await page.open(snapshot.sections[0].items[0]);assert.equal(page.selected.value,'DOMAIN,public.test,DIRECT');
 const op={id:'edit',kind:'update',section:'rules',target:'rule',expected:'rev',value:'DOMAIN,public.test,REJECT'};
 pending=gate();const saving=page.preview(drafts.RuleDnsDraft.put(intent,op));await page.preview(intent);assert.equal(saves,1,'repeat click rejected');
 const before=previews;page.visible=false;page.visibilityChanged();pending.resolve();await saving;assert.equal(previews,before,'hidden save completion cannot preview or rebind');assert.equal(page.previewReady,false);
 pending=null;page.visible=true;page.visibilityChanged();await page.load();await page.preview(intent);assert.equal(page.previewReady,true);assert.equal(page.message,'规则：顺序已调整');
 fail=true;await page.preview(intent);assert.equal(page.previewReady,false,'failed preview cannot apply');assert.equal(applies,0);fail=false;
 await page.preview(intent);applyFailure=true;await page.apply();assert.equal(page.previewReady,false);assert.equal(page.message,'应用未确认，请重连恢复');applyFailure=false;applies=0;
 await page.preview(intent);pending=gate();const apply=page.apply();await page.apply();assert.equal(applies,1);page.aboutToDisappear();page.message='new view';pending.resolve();await apply;assert.equal(page.message,'new view');
 pending=null;page.visible=true;page.aboutToAppear();await page.load();page.discardDraft();const firstDialog=dialog;const count=dialogs;page.discardDraft();assert.equal(dialogs,count);const beforeCancel=JSON.stringify(intent);firstDialog.primaryButton.action();assert.equal(JSON.stringify(intent),beforeCancel);await firstDialog.secondaryButton.action();assert.equal(JSON.stringify(intent),beforeCancel,'cancel cannot later confirm');page.discardDraft();const stale=dialog;page.aboutToDisappear();await stale.secondaryButton.action();assert.equal(JSON.stringify(intent),beforeCancel,'late confirmation after leaving is inert');page.visible=true;page.aboutToAppear();await page.load();page.discardDraft();await dialog.secondaryButton.action();assert.equal(intent.operations.length,0);await dialog.secondaryButton.action();
 page.items=[{id:'first',revision:'a',type:'DOMAIN'},{id:'second',revision:'b',type:'DOMAIN-SUFFIX'},{id:'final',revision:'c',type:'MATCH'}];
 page.move(1,0);for(let i=0;i<20;i++)await Promise.resolve();
 assert.equal(intent.operations.at(-1).kind,'move');assert.equal(intent.operations.at(-1).target,'second');assert.equal(intent.operations.at(-1).before,'first');
 let protectedSaves=saves;page.move(2,0);page.move(0,2);assert.equal(saves,protectedSaves,'MATCH cannot be moved or crossed');
 page.edit({id:'duplicate-match',kind:'add',section:'rules',value:'MATCH,DIRECT'});assert.equal(saves,protectedSaves,'existing MATCH blocks duplicate');
 page.items=[{id:'first',revision:'a',type:'DOMAIN'}];page.edit({id:'new-match',kind:'add',section:'rules',value:'MATCH,DIRECT',before:''});for(let i=0;i<20;i++)await Promise.resolve();
 assert.equal(intent.operations.at(-1).id,'new-match');assert.equal(intent.operations.at(-1).before,'','new MATCH reaches production host save/preview when none exists');
 const savesBeforeUnknown=saves;
 page.items=[{id:'unknown',revision:'u'},{id:'other',revision:'o'}];page.move(0,1);
 assert.equal(saves,savesBeforeUnknown,'missing rule type cannot bypass MATCH order protection');
 assert.equal(page.items[0].id,'unknown');assert.equal(page.message,'无法读取最终规则，请重试');
 const target={missingFieldRevision:'missing-revision',item:{id:'dns',revision:'dns-rev',fields:{}},value:{}};
 let composed=drafts.RuleDnsDraft.put({schemaVersion:1,revision:'r',sourceRevision:'s',operations:[]},forms.RuleDnsForms.patch('custom','dns',target,{'x-advanced':{keep:true}}));
 composed=drafts.RuleDnsDraft.put(composed,forms.RuleDnsForms.recommendedDns(target));
 const projected=clone(target);projected.item.fields={nameserver:'projected-ns'};
 composed=drafts.RuleDnsDraft.put(composed,forms.RuleDnsForms.patch('custom-again','dns',projected,{nameserver:['https://new.test/dns-query']}));
 assert.equal(composed.operations.length,1);assert.ok(composed.operations[0].patch['x-advanced']);assert.equal(composed.operations[0].preconditions.nameserver,'missing-revision','coalesced update retains initial field revision');
 let hosts=drafts.RuleDnsDraft.put({schemaVersion:1,revision:'r',sourceRevision:'s',operations:[]},{id:'host-first',kind:'update',section:'hosts',target:'host-id',expected:'original-host',value:'192.0.2.1'});
 hosts=drafts.RuleDnsDraft.put(hosts,{id:'host-second',kind:'update',section:'hosts',target:'host-id',expected:'projected-host',value:'192.0.2.2'});
 assert.equal(hosts.operations.length,1);assert.equal(hosts.operations[0].expected,'original-host');assert.equal(hosts.operations[0].value,'192.0.2.2');
 page.busy=false; page.active=true; page.selected={item:{id:'dns'},value:{}};
 const sleepingDns={id:'sleep-dns',kind:'update',section:'dns',templateId:'region',patch:{nameserver:['sleep']},preconditions:{nameserver:'guard'}};
 page.intent={schemaVersion:1,revision:'r',sourceRevision:'s',template:{templateId:'original'},operations:[sleepingDns,{id:'live-dns',kind:'update',section:'dns',patch:{nameserver:['live']},preconditions:{nameserver:'guard'}}]};
 let restoredDns; page.preview=async next=>{restoredDns=clone(next);}; page.preset(false);
 assert.deepEqual(restoredDns.operations,[sleepingDns],'DNS restore leaves inactive template edits intact');
 console.log('PASS: unified EditorDraftHost load/target/save/preview/digest-bound apply/undo, names, repeats, stale view and retained source preconditions');
})().catch(e=>{console.error(e);process.exitCode=1;});
