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
 console.log('PASS: region transition/reconnect helper preserves manual choices, original selector and durable restore ordering');
})().catch(e=>{console.error(e);process.exitCode=1});
