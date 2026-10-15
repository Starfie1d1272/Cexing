// Reuses the public fixture exactly as page/model tests do; no compiler stubs.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const fixture=require('./candidate-draft-lifecycle.cjs');
async function run(){
 if(fixture.phase==='seed'){await fixture.runPhase('save');return}
 const seen=[];const r=fixture.runtime({transform:(key,source)=>{seen.push(key);return source}});
 assert.equal(typeof r.load('lib/ProfileProxyEditorModel').ProfileProxyEditorModel,'function');
 assert.equal(r.load('../lib/ProfileTransactions').ProfileTransactions,r.tx,'all reader paths share one real transaction module');
 assert.ok(seen.includes('./ProfileProxyEditorModel'));
 const {ctx,file,home,hooks}=fixture,ticket=r.tx.editTicket(ctx,file);
 const draftPath=path.join(home,'profiles',file+'.intent.json'),statePath=path.join(home,'profile-versions','state.json');
 const draftBefore=fs.readFileSync(draftPath),stateBefore=fs.readFileSync(statePath);
 const source=await r.tx.readEditSource(ctx,ticket);
 assert.ok(source.original.includes('192.0.2.2'));assert.equal(source.metadata.updatedAt,2);assert.equal(r.tx.isBusy(),false);
 // Recovered source actually compiles with the saved intent through the Go worker.
 await r.editor.list(ctx,source.original,'',ticket.activeVersion,'',r.store.readEditDraft(ctx,file).intent);
 for(const field of ['profileIdentity','profileVersion','activeVersion','activeFile','draftRevision']){
  await assert.rejects(r.tx.readEditSource(ctx,{...ticket,[field]:'stale'}),/变化/);
 }
 let rpc=0;hooks.beforeAction=()=>{rpc++};await assert.rejects(r.tx.readEditSource(ctx,ticket,()=>false),/取消/);assert.equal(rpc,0);hooks.beforeAction=null;
 let current=true;hooks.read=()=>{current=false};await assert.rejects(r.tx.readEditSource(ctx,ticket,()=>current),/取消/);
 const version=r.versions.read(ctx).Profiles[file],rawPath=path.join(home,'profile-versions',version.ID,'original.yaml'),original=fs.readFileSync(rawPath);
 hooks.read=()=>fs.writeFileSync(rawPath,Buffer.concat([original,Buffer.from('# changed during read\n')]));
 await assert.rejects(r.tx.readEditSource(ctx,ticket),/来源已变化/);fs.writeFileSync(rawPath,original);
 assert.deepEqual(fs.readFileSync(draftPath),draftBefore);assert.deepEqual(fs.readFileSync(statePath),stateBefore,'read and cancellation never publish');
}
run().then(()=>{fixture.close();process.exit(0)},e=>{console.error(e);process.exit(1)});
