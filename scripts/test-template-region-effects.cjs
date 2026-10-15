const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const box = {exports:{}};
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/TemplateRegionEffects.ets','utf8')).outputText,box);
const {prepareRegionChoice:prepare, committedRegionChoice:commit, resumeRegionChoice:resume}=box.exports;
const clone=x=>JSON.parse(JSON.stringify(x));
let state, groups, current, selections, fail;
const port={read:()=>clone(state),write:s=>{state=clone(s)},groups:async()=>clone(groups),current:()=>current,
 select:async(s,n)=>{selections.push([s,n]);if(fail)return false;groups[s].now=n;return true;}};
const reset=()=>{state={pending:''};groups={A:{now:'manual-a',all:['manual-a','manual-b','fallback','Cexing Smart A']},B:{now:'manual-b',all:['manual-b','Cexing Smart B']}};current=true;selections=[];fail=false;};
(async()=>{
 reset(); let tx=prepare('','A',state,groups); assert.equal(state.pending,'');
 assert.equal(await commit(tx,'A',port),'done'); assert.equal(state.previous.selector,'A');assert.equal(state.previous.name,'manual-a');
 assert.equal(groups.A.now,'Cexing Smart A');assert.equal(state.pending,'');
 // Same-selector subscription/template update preserves a later manual choice.
 groups.A.now='manual-b';tx=prepare('A','A',state,groups);await commit(tx,'A',port);assert.equal(selections.length,1);
 tx=prepare('A','',state,groups);await commit(tx,'',port);assert.equal(selections.length,1);assert.equal(state.previous,undefined);
 // Successful Smart -> AI/original captures only the immediate reload fallback.
 reset();await commit(prepare('','A',state,groups),'A',port);tx=prepare('A','',state,groups);
 groups.A.now='fallback';fail=true;assert.equal(await commit(tx,'',port),'pending');assert.equal(state.previous.observed,'fallback');
 const persisted=clone(state);state=JSON.parse(JSON.stringify(persisted));fail=false;
 assert.equal(await resume('',port),'done');assert.equal(groups.A.now,'manual-a');assert.equal(state.previous,undefined);
 // Selector switch restores A before selecting B; record survives JSON restart.
 reset();await commit(prepare('','A',state,groups),'A',port);tx=prepare('A','B',state,groups);groups.A.now='fallback';
 await commit(tx,'B',port);assert.deepEqual(selections.slice(-2),[['A','manual-a'],['B','Cexing Smart B']]);assert.equal(state.previous.selector,'B');
 // A user's choice after a failed restoration wins over queued B.
 reset();state={pending:'B',previous:{selector:'A',name:'manual-a',observed:'fallback'}};groups.A.now='manual-b';
 assert.equal(await resume('B',port),'manual');assert.equal(selections.length,0);assert.equal(state.pending,'');
 // A failed first selection must not overwrite a subsequent manual change.
 reset();fail=true;await commit(prepare('','A',state,groups),'A',port);groups.A.now='manual-b';fail=false;
 assert.equal(await resume('A',port),'manual');assert.equal(selections.length,1);
 // Missing/invalid previous choice rejects before publication; unknown offline
 // fallback stays pending rather than guessing which manual choice is ours.
 reset();groups.A.now='Cexing Smart A';assert.throws(()=>prepare('A','',state,groups),/PREVIOUS_UNAVAILABLE/);
 state={pending:'',previous:{selector:'A',name:'manual-a'}};groups.A.now='fallback';assert.equal(await resume('',port),'pending');
 current=false;assert.equal(await resume('',port),'stale');assert.equal(selections.length,0);
 reset();await commit(prepare('','A',state,groups),'A',port);
 tx=prepare('A','B',state,{});state=clone(tx.state);groups.A.now='fallback';
 assert.equal(state.previous.observed,undefined);const beforeCount=selections.length;
 assert.equal(await resume('B',port),'pending');assert.equal(selections.length,beforeCount);
 assert.equal(state.pending,'B');assert.equal(state.previous.selector,'A');
 // Exercise the production adapter with compiler-projected renamed groups.
 const plan={templateId:'region',version:1,region:{enable:true,selector:'Pick'},
   baseline:{entries:[{id:'region/entry',section:'proxy-groups',value:{name:'Cexing Smart Pick'}}]},
   mine:{entries:[{id:'region/entry',section:'proxy-groups',value:{name:'Renamed Smart'}}]}};
 const intent={operations:[{section:'proxy-groups',kind:'rename'}],template:plan};
 const version={ID:'version-saved-B'};let globalCurrent='version-active-A';let saved={pending:'Pick'},selected=[],projectionCalls=0;
 const live={'Renamed Pick':{now:'Renamed Node',all:['Renamed Node','Renamed Smart']},'Renamed Smart':{now:'Region',all:['Region']}};
 const mods={'./TemplateRegionEffects':box.exports,'./ConfigEditor':{ConfigEditor:{list:async(_c,_o,_l,expected)=>{
   assert.equal(expected,globalCurrent);projectionCalls++;return{sections:[{section:'proxy-groups',items:[{sourceName:'Pick',name:'Renamed Pick'}]},{section:'proxies',items:[{sourceName:'Direct',name:'Renamed Node'}]}]};}}},
 './EffectiveVersions':{EffectiveVersions:{read:()=>({Current:{ID:globalCurrent}}),editIntent:()=>intent,regionPlan:()=>null,regionChoice:()=>saved,
 original:()=>'',overlay:()=>'',globalMerge:()=>''}},
 './ProfileStore':{ProfileStore:{getActiveFile:()=> 'one.yaml',runtimeRegionChoice:()=>saved,saveRuntimeRegionChoice:(_c,_f,_v,s)=>saved=clone(s)}},
 './CoreApi':{CoreApi:{getProxies:async()=>live,selectProxy:async(g,n)=>{selected.push([g,n]);live[g].now=n;return true}}}};
 const scope={exports:{}};vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/EditOperationScope.ets','utf8')).outputText,scope);mods['./EditOperationScope']=scope.exports;
 const adapter={exports:{},require:k=>mods[k]??{}};
 vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/ProfileRegionChoices.ets','utf8')).outputText,adapter);
 assert.equal(await adapter.exports.ProfileRegionChoices.resume({},'one.yaml',version,()=>true,async()=>true),true);
 assert.deepEqual(selected,[['Renamed Pick','Renamed Smart']]);assert.equal(saved.pending,'');
 assert.equal(saved.previous.name,'Direct');assert.equal(saved.sourceNames,true);
 assert.equal(saved.previous.selector,'Pick');assert.equal(projectionCalls,1);
 await adapter.exports.ProfileRegionChoices.resume({},'one.yaml',version,()=>true,async()=>true);assert.equal(selected.length,1);
 const listProjection=mods['./ConfigEditor'].ConfigEditor.list;
 mods['./ConfigEditor'].ConfigEditor.list=async()=>({sections:[{section:'proxies',items:[
 {sourceName:'A',name:'B'},{sourceName:'B',name:'C'}]}]});
 saved={pending:'',previous:{selector:'Pick',name:'B',observed:'B'}};
 await assert.rejects(adapter.exports.ProfileRegionChoices.prepare({},'one.yaml',version,'',true),/选择可用节点/);
 live.Pick={now:'Renamed Smart',all:['Renamed Smart','B','C']};
 await assert.rejects(adapter.exports.ProfileRegionChoices.prepare({},'one.yaml',version,'',true),/选择可用节点/);
 live.Pick.now='C';
 const manualStop=await adapter.exports.ProfileRegionChoices.prepare({},'one.yaml',version,'',true);
 assert.equal(manualStop.state.previous.name,'B');assert.equal(manualStop.state.pending,'');
 assert.equal(manualStop.observeRemoved,'Pick');
 intent.disabled=true;live.Pick={now:'A',all:['A','B']};
 await adapter.exports.ProfileRegionChoices.committed({},'one.yaml',version,manualStop,'',()=>true,async()=>true);
 assert.deepEqual(selected.at(-1),['Pick','B']);assert.equal(live.Pick.now,'B');
 intent.disabled=false;

 delete live.Pick;
 mods['./ConfigEditor'].ConfigEditor.list=listProjection;
 // Legacy runtime-named previous choices migrate before personal edits turn off.
 saved={pending:'',previous:{selector:'Pick',name:'Renamed Node',observed:'Renamed Node'}};
 const stopping=await adapter.exports.ProfileRegionChoices.prepare({},'one.yaml',version,'',true);
 assert.equal(stopping.state.previous.name,'Direct');assert.equal(stopping.state.sourceNames,true);
 intent.disabled=true;delete live['Renamed Pick'];delete live['Renamed Smart'];
 live.Pick={now:'Fallback',all:['Direct','Fallback']};globalCurrent='version-disabled';
 await adapter.exports.ProfileRegionChoices.committed({},'one.yaml',version,stopping,'',()=>true,async()=>true);
 assert.deepEqual(selected.at(-1),['Pick','Direct']);assert.equal(saved.previous,undefined);
 saved={pending:'Pick'};selected=[];
 await adapter.exports.ProfileRegionChoices.resume({},'one.yaml',version,()=>false,async()=>true);assert.equal(selected.length,0);
 console.log('PASS: region transition/reconnect helper preserves manual choices, original selector and durable restore ordering');
})().catch(e=>{console.error(e);process.exitCode=1});
