// Shared fs/IPC/runtime; actual Source/Host/Tx/Store and real Go worker only.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const fixture=require('./candidate-draft-lifecycle.cjs');
const {ctx,file,home,phase,hooks}=fixture;
const draftPath=path.join(home,'profiles',file+'.intent.json'),statePath=path.join(home,'profile-versions','state.json');
const gate=()=>{let resolve;const promise=new Promise(r=>resolve=r);return{promise,resolve}};
function pageRuntime(){return fixture.runtime({
 globals:{getContext:()=>ctx},
 modules:{'@kit.ArkUI':{promptAction:{}},'./ProfileApplyRecovery':{ProfileApplyRecovery:{}},
  './ProfileImportInput':{ProfileImportInput:{hasPending:()=>false}}},
 transform:(key,source)=>{
  if(!key.endsWith('/TemplateUpdateReview'))return source;
  return (source.slice(0,source.indexOf('  build()'))+'\n}').split('\n').map(line=>
   line.trimStart().startsWith('@')?line.replace(/@\w+(?:\([^\n)]*\))?\s*/g,''):line).join('\n').replace('export struct ','export class ');
 }
})}
async function run(){
 if(!phase.startsWith('paired-source-')){await fixture.runPhase(phase);return}
 let r=fixture.runtime(),reads=0;
 const original=r.store.getProfileContent(ctx,file),beforeDraft=fs.readFileSync(draftPath),beforeState=fs.readFileSync(statePath);
 assert.ok(!original.includes('US-two'));assert.ok(r.store.readEditDraft(ctx,file).source);
 const sharedRead=r.tx.readEditSource;
 r.tx.readEditSource=async(...args)=>{reads++;return await sharedRead(...args)};
 if(phase==='paired-source-read'){
  const host=r.hosts.create(ctx,file),session=await host.load();
  const source=r.updateSource(ctx,file),request=await source.read(session);
  assert.equal(reads,1,'the production template Source must use the shared readEditSource API');
  assert.ok(request.next.entries.find(e=>e.id==='region/us').value.proxies.includes('US-two'));
  assert.deepEqual(Array.from(request.mine.entries.find(e=>e.id==='region/us').value.proxies),['DIRECT']);
  assert.deepEqual(fs.readFileSync(draftPath),beforeDraft);assert.deepEqual(fs.readFileSync(statePath),beforeState);
  // Wrong authoring revisions fail before the worker; no alternate old Original.
  await assert.rejects(source.read({...session,intent:{...session.intent,revision:'foreign'}}),/SESSION/);
  assert.equal(reads,1);
  // The API also detects byte-only changes that do not advance a version ID.
  const version=r.versions.read(ctx).Profiles[file],raw=path.join(home,'profile-versions',version.ID,'original.yaml'),bytes=fs.readFileSync(raw);
  hooks.read=()=>fs.writeFileSync(raw,Buffer.concat([bytes,Buffer.from('# external change\n')]));
  await assert.rejects(source.read(session),/来源已变化/);fs.writeFileSync(raw,bytes);
  assert.deepEqual(fs.readFileSync(draftPath),beforeDraft);assert.deepEqual(fs.readFileSync(statePath),beforeState);
 }else if(phase==='paired-source-cancel'){
  const reached=gate(),release=gate();
  r=pageRuntime();const actualRead=r.tx.readEditSource;let reading;
  r.tx.readEditSource=(...args)=>{reads++;hooks.read=async()=>{reached.resolve();await release.promise};
   reading=actualRead(...args);return reading};
  const Page=r.load('pages/TemplateUpdateReview').TemplateUpdateReview,p=new Page();p.profileId=file;
  p.aboutToAppear();await reached.promise;const rejected=assert.rejects(reading,/取消|SESSION/);
  p.aboutToDisappear();release.resolve();await rejected;
  await new Promise(setImmediate);assert.equal(p.ready,false);
  assert.equal(reads,1);assert.deepEqual(fs.readFileSync(draftPath),beforeDraft);assert.deepEqual(fs.readFileSync(statePath),beforeState);
  // A new module graph has no in-memory candidate or sourceOverride.
  r=fixture.runtime();const fresh=r.updateHost(ctx,file,undefined,r.updateSource(ctx,file));
  const preview=await fresh.preview({});assert.equal(preview.ready,true);assert.ok(preview.validation.digest);
  fresh.reset();assert.ok(r.store.readEditDraft(ctx,file).source);assert.equal(r.store.getProfileContent(ctx,file),original);
 }else if(phase.startsWith('paired-source-page-')){
  r=pageRuntime();const actualRead=r.tx.readEditSource;
  r.tx.readEditSource=async(...args)=>{reads++;return await actualRead(...args)};
  const Page=r.load('pages/TemplateUpdateReview').TemplateUpdateReview,p=new Page();
  p.profileId=file;p.navStack={clear(){throw Error('offline draft preview must not reconnect')},pushPath(){}};
  p.aboutToAppear();const deadline=Date.now()+15000;
  while(p.model.busy&&Date.now()<deadline)await new Promise(resolve=>setTimeout(resolve,5));
  assert.equal(p.model.busy,false);assert.equal(p.ready,true,p.message);assert.equal(reads,1);
  const preview=p.model.preview;assert.ok(preview.validation.digest);
  assert.equal(r.store.getProfileContent(ctx,file),original);
  if(phase==='paired-source-page-reopen'){
   p.aboutToDisappear();assert.ok(r.store.readEditDraft(ctx,file).source);
   assert.equal(r.store.getProfileContent(ctx,file),original);assert.deepEqual(fs.readFileSync(statePath),beforeState);return;
  }
  await p.model.apply();assert.match(p.model.result,/已保存/);assert.ok(r.store.getProfileContent(ctx,file).includes('US-two'));
  const version=r.versions.read(ctx).Profiles[file],intent=r.versions.editIntent(ctx,version);
  assert.deepEqual(Array.from(intent.template.mine.entries.find(e=>e.id==='region/us').value.proxies),['DIRECT']);
  assert.equal(r.store.readEditDraft(ctx,file).source,undefined);
  await assert.rejects(p.activeHost.apply(preview),/STALE/);p.aboutToDisappear();
 }
}
run().then(()=>{fixture.close();process.exit(0)},e=>{console.error(e);fixture.close();process.exit(1)});
