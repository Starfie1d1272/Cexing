// Invoked by the Go integration test; actual production modules, real Go RPC.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),crypto=require('node:crypto'),readline=require('node:readline');
const ui=require('./ui-fixtures.cjs'),ts=require('./transpile-arkts.cjs'),home=process.argv[2],phase=process.argv[3],base=path.resolve(__dirname,'../../cexing/entry/src/main/ets/lib');
let loseCommitAck=false,failCommit=false,serial=0;const replies=new Map();
const lines=readline.createInterface({input:process.stdin});lines.on('line',line=>{const r=JSON.parse(line);const resolve=replies.get(r.id);replies.delete(r.id);resolve(r.reply)});
const action=input=>input.op==='commit'&&failCommit?Promise.resolve(JSON.stringify({error:'VERSION_COMMIT_FAILED'})):new Promise(resolve=>{const id=++serial;replies.set(id,resolve);process.stdout.write(JSON.stringify({id,input:JSON.stringify(input)})+'\n')});
let failWrite=false,writeHook=null;
const io={OpenMode:{READ_ONLY:0,READ_WRITE:2,CREATE:64,TRUNC:512},
 accessSync:p=>fs.existsSync(p),mkdirSync:(p)=>fs.mkdirSync(p,{recursive:true}),
 statSync:p=>{const s=fs.statSync(p);return {size:s.size,mtime:s.mtimeMs}},
 stat:async p=>{const s=typeof p==='number'?fs.fstatSync(p):await fs.promises.stat(p);return {size:s.size,mtime:s.mtimeMs}},
 openSync:(p,flags)=>({fd:fs.openSync(p,flags===0?'r':'w+')}),closeSync:f=>fs.closeSync(f.fd),writeSync:(fd,s)=>fs.writeSync(fd,s),
 readTextSync:(p,o)=>{if(p.endsWith('.intent.json')&&fs.statSync(p).size>2*1024*1024)assert.ok(o&&o.length<=2*1024*1024,'sync ticket must not read candidate body');const b=fs.readFileSync(p);return b.subarray(o?.offset??0,o?.length===undefined?b.length:(o?.offset??0)+o.length).toString('utf8')},
 listFileSync:p=>fs.readdirSync(p),moveFileSync:(a,b)=>fs.renameSync(a,b),unlinkSync:p=>fs.unlinkSync(p),
 open:async(p,flags)=>({fd:fs.openSync(p,flags===0?'r':'w+')}),close:async f=>fs.closeSync(f.fd),
 read:async(fd,b,o)=>fs.readSync(fd,new Uint8Array(b),0,b.byteLength,o?.offset??null),
 write:async(fd,b,o)=>{if(failWrite)throw Error('synthetic disk full');const n=fs.writeSync(fd,new Uint8Array(b),0,Math.min(b.byteLength,4096),o?.offset??null);if(writeHook){const hook=writeHook;writeHook=null;await hook()}return n},
 fsync:async fd=>fs.fsyncSync(fd),moveFile:async(a,b)=>fs.promises.rename(a,b),unlink:async p=>fs.promises.unlink(p)};
const settings={smartAutoConvert:false,mixedPort:7890,logLevel:'info',allowLan:false,ipv6:false,mode:'rule',logToFile:false};
function runtime(){
 const modules={'@kit.ArkTS':{util:{generateRandomUUID:()=>crypto.randomUUID(),TextEncoder:{create:()=>({encodeInto:s=>new TextEncoder().encode(s)})},TextDecoder:{create:(_,o)=>{const d=new TextDecoder('utf-8',o);return {decodeToString:(b,opt)=>d.decode(b,opt)}}}}},
 '@kit.CoreFileKit':{fileIo:io},'@kit.NetworkKit':{http:{}},'libentry.so':{versionAction:async(_,s)=>{const input=JSON.parse(s),reply=await action(input);if(input.op==='commit'&&loseCommitAck){failWrite=true;throw Error('synthetic lost commit reply')}return reply}},
 './UiText':ui.module,'./Settings':{Settings:{load:()=>settings,idle:async()=>{},setSmartAutoConvert:async(_,v)=>{settings.smartAutoConvert=v}}},'./Logger':{Logger:{info(){},warn(){},error(){}}},
 './CoreValidator':{CoreValidator:{prepareResources:async()=>{}}},'./VpnController':{VpnStatus:{Disconnected:0,Connected:2},VpnController:{status:0,holdConfiguration:()=>()=>{},configurationEpoch:()=>0}},'./CoreApi':{CoreApi:{}}};
 function load(name){const key='./'+name;if(modules[key])return modules[key];const box={exports:{},setTimeout,...ui.globals,require:n=>{if(n.startsWith('./'))return load(n.slice(2));assert.ok(n in modules,n);return modules[n]}};modules[key]=box.exports;vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(base,name+'.ets'),'utf8')).outputText,box,{filename:name});modules[key]=box.exports;return box.exports}
 return {store:load('ProfileStore').ProfileStore,versions:load('EffectiveVersions').EffectiveVersions,hosts:load('EditorDraftHosts').EditorDraftHosts,editor:load('ConfigEditor').ConfigEditor,tx:load('ProfileTransactions').ProfileTransactions,updateSource:load('TemplateUpdateSource').createTemplateUpdateSource,updateHost:load('TemplateUpdateHost').createTemplateUpdateHost};
}
const ctx={filesDir:home},file='one.yaml',original='proxies: [{name: synthetic, type: direct}]\ndns: {enable: true, nameserver: [192.0.2.1]}\nrules: ["MATCH,DIRECT"]\n',candidate=original.replace('192.0.2.1','192.0.2.2'),metadata={origin:'https://example.invalid/synthetic',sub:{upload:0,download:0,total:0,expire:0},updatedAt:2};
async function run(){
 let r=runtime();
 if(phase.startsWith('template-')){
  const regionOriginal='proxies: [{name: US-one, type: direct}, {name: HK-one, type: direct}]\nproxy-groups: [{name: Pick, type: select, proxies: [US-one, HK-one]}]\nrules: ["MATCH,Pick"]\n';
  const regionNext=regionOriginal.replace('{name: HK-one','{name: US-two, type: direct}, {name: HK-one').replace('[US-one, HK-one]','[US-one, US-two, HK-one]');
  if(phase==='template-save'){
   const expected=r.versions.read(ctx).Current.ID;
   const intent={schemaVersion:1,revision:'template-base',sourceRevision:'template-source',operations:[],template:{templateId:'region',version:1,region:{mode:'region',selector:'Pick',enable:true,assignments:{}}}};
   const id=crypto.createHash('sha256').update('cexing-template\0region\0region/us').digest('hex');
   const target=await r.editor.target(ctx,regionOriginal,'',expected,'proxy-groups',id,'',intent);
   intent.operations=[{id:'keep-personal',kind:'update',section:'proxy-groups',target:id,preconditions:{proxies:target.item.fields.proxies},patch:{proxies:['DIRECT']}}];
   const stage=JSON.parse(await action({op:'stage',profileId:file,original:regionOriginal,metadata:JSON.stringify(metadata),expected,editIntent:intent}));assert.ok(stage.version,JSON.stringify(stage));
   assert.ok(JSON.parse(await action({op:'commit',versionId:stage.version.ID,expected,active:true})).state);
   const candidate={original:regionNext,metadata};
   const update=r.updateHost(ctx,file,r.hosts.create(ctx,file,candidate),r.updateSource(ctx,file,candidate));
   const first=await update.preview({});assert.equal(first.ready,false);assert.ok(first.conflicts.length,'new region membership must genuinely conflict with the old personal patch');
   const decisions=Object.fromEntries(first.conflicts.map(c=>[c.id,'mine']));const resolved=await update.preview(decisions);assert.equal(resolved.ready,true);
   assert.equal(r.store.getProfileContent(ctx,file),regionOriginal);assert.ok(r.store.readEditDraft(ctx,file).source);update.reset();
  }else{
   // Neither source nor host receives an override, and there is no download API.
   const update=r.updateHost(ctx,file,undefined,r.updateSource(ctx,file));
   const resolved=await update.preview({});assert.equal(resolved.ready,true);assert.equal(resolved.conflicts.length,0);
   assert.equal(r.store.getProfileContent(ctx,file),regionOriginal);
   if(phase==='template-apply'){
    assert.match(await update.apply(resolved),/已保存/);assert.equal(r.store.getProfileContent(ctx,file),regionNext);
    const intent=r.versions.editIntent(ctx,r.versions.read(ctx).Profiles[file]);assert.deepEqual(Array.from(intent.template.mine.entries.find(e=>e.id==='region/us').value.proxies),['DIRECT']);
    assert.equal(r.store.readEditDraft(ctx,file).source,undefined);
   }else{update.reset();assert.ok(r.store.readEditDraft(ctx,file).source)}
  }
 }else if(phase==='save'){
  fs.mkdirSync(path.join(home,'profiles'),{recursive:true});fs.writeFileSync(path.join(home,'profiles',file),original);fs.writeFileSync(path.join(home,'profiles','active.txt'),file);
  const staged=JSON.parse(await action({op:'stage',profileId:file,original,metadata:JSON.stringify(metadata),expected:''}));assert.ok(staged.version,JSON.stringify(staged));
  const committed=JSON.parse(await action({op:'commit',versionId:staged.version.ID,expected:'',active:true}));assert.ok(committed.state);
  // Keep a pre-existing unpublished personal edit when a review is cancelled.
  const ordinary=r.hosts.create(ctx,file);let prior=await ordinary.load();
  const oldView=await r.editor.list(ctx,original,'',staged.version.ID);const oldDNS=oldView.sections.find(s=>s.section==='dns');
  const oldTarget=await ordinary.target('dns',oldDNS.items[0].id,prior.revision);
  const personal={schemaVersion:1,revision:'prior',sourceRevision:oldView.sourceRevision,operations:[{id:'prior-personal',kind:'update',section:'dns',target:oldTarget.item.id,preconditions:{enable:oldTarget.item.fields.enable},patch:{enable:false}}]};
  prior=await ordinary.save(personal,prior.revision);
  const privateBefore=fs.readFileSync(path.join(home,'profiles',file+'.intent.json'));
  const host=r.hosts.create(ctx,file,{original:candidate,metadata});let s=await host.load();
  assert.deepEqual(fs.readFileSync(path.join(home,'profiles',file+'.intent.json')),privateBefore,'open/cancel must not undo a previous private draft');
  const view=await r.editor.list(ctx,candidate,'',staged.version.ID);const dns=view.sections.find(s=>s.section==='dns');assert.ok(dns?.items.length,JSON.stringify(view));
  const target=await r.editor.target(ctx,candidate,'',staged.version.ID,'dns',dns.items[0].id);
  const intent={schemaVersion:1,revision:'resolved',sourceRevision:view.sourceRevision,operations:[...personal.operations,{id:'dns-personal',kind:'update',section:'dns',target:target.item.id,preconditions:{nameserver:target.item.fields.nameserver},patch:{nameserver:['192.0.2.3']}}]};
  s=await host.save(intent,s.revision);await host.preview(s.revision);
  await assert.rejects(r.editor.list(ctx,original,'',staged.version.ID,'',s.intent),/EDIT_INTENT_FAILED/,'resolved intent must truly conflict with the old Original');assert.equal(r.store.getProfileContent(ctx,file),original);
  // A closed page is a fresh module graph with no sourceOverride.
  r=runtime();const reopened=r.hosts.create(ctx,file);const again=await reopened.load();await reopened.preview(again.revision);
  assert.equal(again.intent.operations[0].id,'prior-personal');assert.equal(again.intent.operations[1].id,'dns-personal');
  // Disk failure and a late save preserve the entire old pair.
  const old=fs.readFileSync(path.join(home,'profiles',file+'.intent.json'));
  failWrite=true;await assert.rejects(reopened.save(again.intent,again.revision),/disk full/);failWrite=false;assert.deepEqual(fs.readFileSync(path.join(home,'profiles',file+'.intent.json')),old);
  const delayed=r.hosts.create(ctx,file);const ds=await delayed.load();
  writeHook=async()=>{settings.ipv6=true};await assert.rejects(delayed.save(ds.intent,ds.revision),/变化/);settings.ipv6=false;assert.deepEqual(fs.readFileSync(path.join(home,'profiles',file+'.intent.json')),old);
  const mismatch=r.hosts.create(ctx,file,{original:candidate+'# different\n',metadata});await assert.rejects(mismatch.load(),/已有的更新草稿/);assert.deepEqual(fs.readFileSync(path.join(home,'profiles',file+'.intent.json')),old);
  // The durable base digest also protects a legacy/raw source changing without a new pointer.
  const published=r.versions.read(ctx).Profiles[file],rawPath=path.join(home,'profile-versions',published.ID,'original.yaml');
  fs.writeFileSync(rawPath,original+'# externally changed\n');await assert.rejects(r.hosts.create(ctx,file).load(),/草稿来源已变化/);fs.writeFileSync(rawPath,original);
  // Only an explicit undo consumes the candidate; closing above never called it.
  const undoHost=r.hosts.create(ctx,file);const us=await undoHost.load();const undone=await undoHost.undo(us.revision);assert.equal(undone.intent,null);assert.equal(r.store.readEditDraft(ctx,file).source,undefined);
  const renewed=r.hosts.create(ctx,file,{original:candidate,metadata});const ns=await renewed.load();await renewed.save(again.intent,ns.revision);

 }else if(phase==='cold-reopen'){
  const host=r.hosts.create(ctx,file);let s=await host.load();const shown=await host.preview(s.revision);assert.ok(shown.digest);assert.equal(r.store.getProfileContent(ctx,file),original);
  s=await host.save(s.intent,s.revision);await host.preview(s.revision);assert.ok(r.store.readEditDraft(ctx,file).source,'ordinary save must retain the pair');
  // Read and write a large body without synchronous body I/O.
  const draft=r.store.readEditDraft(ctx,file),saved=fs.readFileSync(path.join(home,'profiles',file+'.intent.json'));
  const large=candidate+'#'+'x'.repeat(8*1024*1024)+'\n';await r.store.saveEditDraftAtomic(ctx,file,draft,draft.revision,async()=>{},large);
  assert.equal((await r.store.readEditDraftSource(ctx,file,draft.revision)).original,large);fs.writeFileSync(path.join(home,'profiles',file+'.intent.json'),saved);
 }else if(phase==='cold-apply'){
  const host=r.hosts.create(ctx,file),s=await host.load(),shown=await host.preview(s.revision);failCommit=true;const privateBefore=fs.readFileSync(path.join(home,'profiles',file+'.intent.json'));await assert.rejects(host.apply(shown),/VERSION_COMMIT_FAILED/);failCommit=false;assert.equal(r.store.getProfileContent(ctx,file),original);assert.deepEqual(fs.readFileSync(path.join(home,'profiles',file+'.intent.json')),privateBefore);
  const retried=await host.preview(s.revision);loseCommitAck=true;assert.equal(await host.apply(retried),'saved');loseCommitAck=false;assert.equal(r.store.getProfileContent(ctx,file),candidate);
  assert.equal(r.store.readEditDraft(ctx,file).source,undefined,'published revision consumes the private source');assert.equal(fs.readFileSync(path.join(home,'profiles',file+'.intent.json')).subarray(0,4).toString(),'CED2','failed compaction keeps the recoverable pair for the next cold publication');
  await assert.rejects(host.apply(shown),/预览/);
 }else if(phase==='consumed'){
  const host=r.hosts.create(ctx,file),s=await host.load();await host.preview(s.revision);assert.equal(r.store.getProfileContent(ctx,file),candidate);assert.equal(r.store.readEditDraft(ctx,file).source,undefined);
  const previous=r.tx.previewPrevious(ctx);await r.tx.restorePrevious(ctx,previous.currentId,previous.previousId);
  const restored=await r.hosts.create(ctx,file).load();assert.equal(restored.intent,null,'consumed candidate must not resurrect after restoring another version');assert.equal(r.store.readEditDraft(ctx,file).source,undefined);
 }
}
run().then(()=>{lines.close();process.exit(0)},e=>{console.error(e);process.exit(1)});
