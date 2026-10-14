const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),ts=require('./ci/transpile-arkts.cjs');
let draft={revision:'',intent:null},version='v1',settings={ipv6:false},provider='cache1',id=0,writes=0,applies=0,delay,resolve;
const ticket=()=>({file:'one.yaml',profileIdentity:'source',profileVersion:version,activeVersion:version,activeFile:'one.yaml',draftRevision:draft.revision});
const versions={read:()=>({Profiles:{'one.yaml':{ID:version}}}),globalContent:()=>'',regionPlan:()=>null,editIntent:()=>null};
const tx={editTicket:ticket,saveEditDraft:async(_,t,i,guard)=>{if(delay)await new Promise(r=>resolve=r);if(guard)await guard();assert.equal(t.draftRevision,draft.revision);draft={revision:`draft${++id}`,intent:i?{...i,revision:`draft${id}`}:null};writes++},previewEditDraft:async()=>({digest:'digest',changes:[]}),applyEditDraft:async(_,t,d,guard)=>{assert.equal(d,'digest');await guard(false);version='v2';await guard(true);applies++;return 'saved'}};
const modules={'@kit.ArkTS':{util:{generateRandomUUID:()=>`token${++id}`}},'libentry.so':{versionAction:async(_,json)=>{let a=JSON.parse(json);if(a.expected!==version)return JSON.stringify({error:'stale'});return JSON.stringify({identity:JSON.stringify([a.original,a.overlay,a.globalMerge,a.editIntent,a.overrides,provider])})}},'./ConfigEditor':{ConfigEditor:{list:async()=>({sourceRevision:'source',missingFieldRevision:'missing',sections:[]}),target:async()=>({value:{},item:{id:'target'}})}},'./Settings':{Settings:{load:()=>settings,idle:async()=>{}}},'./EffectiveVersions':{EffectiveVersions:versions},'./ProfileStore':{ProfileStore:{getProfileContent:()=> 'original',getEnabledMerge:()=>'',readEditDraft:()=>draft}},'./ProfileTransactions':{ProfileTransactions:tx}};
const sandbox={exports:{},require:n=>modules[n]??{}};vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/EditorDraftHosts.ets','utf8')).outputText,sandbox);
(async()=>{
 const host=sandbox.exports.EditorDraftHosts.create({filesDir:'/synthetic'},'one.yaml');let s=await host.load();assert.equal(s.profileId,'one.yaml');assert.equal(s.snapshot.missingFieldRevision,'missing');
 provider='cache2';await assert.rejects(host.save({operations:[]},s.revision),/变化/);assert.equal(writes,0);
 s=await host.load();settings={ipv6:true};await assert.rejects(host.target('hosts','target',s.revision),/变化/);
 s=await host.load();delay=true;let pending=host.save({schemaVersion:1,operations:[]},s.revision);await new Promise(r=>setImmediate(r));provider='cache3';resolve();await assert.rejects(pending,/变化/);assert.equal(writes,0);delay=false;
 s=await host.load();s=await host.save({schemaVersion:1,revision:'draft',operations:[]},s.revision);assert.equal(writes,1);const shown=await host.preview(s.revision);
 await assert.rejects(host.apply({...shown,digest:'forged'}),/预览/);assert.equal(applies,0);
 assert.equal(await host.apply(shown),'saved');assert.equal(applies,1);await assert.rejects(host.apply(shown),/预览/);
 s=await host.load();const old=s.revision;s=await host.undo(old);assert.equal(s.intent,null);assert.notEqual(s.revision,old);
 console.log('PASS: production editor host binds profile/draft/settings/provider, delayed save CAS, preview digest, own commit and undo');
})().catch(e=>{console.error(e);process.exitCode=1});
