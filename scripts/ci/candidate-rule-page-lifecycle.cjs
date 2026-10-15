// Shared lifecycle runner supplies production modules and real Go RPC.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require('./transpile-arkts.cjs');
function page(r,ctx,file){
 const presentation={exports:{},require:n=>n==='./Settings'?r.load('Settings'): {}};
 vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.resolve(__dirname,'../../cexing/entry/src/main/ets/lib/CoreValidator.ets'),'utf8')).outputText,presentation);
 const source=fs.readFileSync(path.resolve(__dirname,'../../cexing/entry/src/main/ets/pages/RuleDnsEditorPage.ets'),'utf8');
 const body=(source.slice(0,source.indexOf('  build()'))+'\n}').split('\n').map(line=>line.trimStart().startsWith('@')?line.replace(/@\w+(?:\([^\n)]*\))?\s*/g,''):line).join('\n').replace('export struct ','export class ');
 const box={exports:{},getContext:()=>ctx,require:n=>{
  if(n==='./NativeTheme'||n==='./RuleDnsEditForm')return {};
  if(n==='../lib/CoreValidator')return presentation.exports;
  if(n.startsWith('../lib/'))return r.load(n.slice('../lib/'.length));
  if(n==='@kit.AbilityKit')return {};
  if(n==='@kit.ArkTS')return {util:{generateRandomUUID:()=>require('node:crypto').randomUUID()}};
  throw Error('Unexpected page dependency '+n);
 }};
 vm.runInNewContext(ts.transpileModule(body).outputText,box,{filename:'RuleDnsEditorPage'});
 const p=new box.exports.RuleDnsEditorPage();p.file=file;p.section='dns';p.active=true;return p;
}
async function idle(p){const until=Date.now()+10000;while(p.busy){assert.ok(Date.now()<until,'actual page operation timed out');await new Promise(resolve=>setImmediate(resolve));}}
async function opened(runtime,ctx,file){const r=runtime(),p=page(r,ctx,file);await p.load();assert.ok(p.snapshot,p.message);assert.equal(p.message,'');await p.open(p.items[0]);assert.ok(p.selected,p.message);return {r,p};}
exports.run=async({runtime,action,ctx,file,phase})=>{
 file='rules-page.yaml';
 const original='proxies: [{name: synthetic, type: direct}]\ndns: {enable: true, nameserver: [192.0.2.1]}\nrules: ["MATCH,DIRECT"]\n';
 const candidate=original.replace('192.0.2.1','192.0.2.2'),metadata={origin:'https://example.invalid/synthetic',sub:{upload:0,download:0,total:0,expire:0},updatedAt:2};
 if(phase==='rules-save'){
  fs.mkdirSync(path.join(ctx.filesDir,'profiles'),{recursive:true});fs.writeFileSync(path.join(ctx.filesDir,'profiles',file),original);fs.writeFileSync(path.join(ctx.filesDir,'profiles','active.txt'),file);
  const expected=runtime().versions.read(ctx)?.Current?.ID??'';
  const stage=JSON.parse(await action({op:'stage',profileId:file,original,metadata:JSON.stringify(metadata),expected}));assert.ok(stage.version,JSON.stringify(stage));
  const commit=JSON.parse(await action({op:'commit',versionId:stage.version.ID,expected,active:true}));assert.ok(commit.state);
  const r=runtime(),h=r.hosts.create(ctx,file,{original:candidate,metadata});let s=await h.load();
  const view=await r.editor.list(ctx,candidate,'',stage.version.ID),dns=view.sections.find(v=>v.section==='dns');
  const target=await r.editor.target(ctx,candidate,'',stage.version.ID,'dns',dns.items[0].id);
  const intent={schemaVersion:1,revision:'rules-pair',sourceRevision:view.sourceRevision,operations:[r.load('RuleDnsForms').RuleDnsForms.patch('candidate-dns','dns',target,{nameserver:['192.0.2.3']})]};
  s=await h.save(intent,s.revision);await h.preview(s.revision);
  await assert.rejects(r.editor.list(ctx,original,'',stage.version.ID,'',s.intent),/EDIT_INTENT_FAILED/,'fixture must expose old-source pairing bug');
  assert.equal(r.store.getProfileContent(ctx,file),original);
 }
 let {r,p}=await opened(runtime,ctx,file);
 if(phase==='rules-save'||phase==='rules-reopen'){
  assert.equal(p.selected.value.nameserver[0],'192.0.2.3','cold actual page must use paired candidate');
  const before=fs.readFileSync(path.join(ctx.filesDir,'profiles',file+'.intent.json'));p.aboutToDisappear();
  assert.deepEqual(fs.readFileSync(path.join(ctx.filesDir,'profiles',file+'.intent.json')),before,'leaving must retain complete pair');
 }else if(phase==='rules-modify'){
  assert.equal(p.selected.value.nameserver[0],'192.0.2.3');
  const f=r.load('RuleDnsForms').RuleDnsForms;
  p.edit(f.patch('page-change','dns',p.selected,{nameserver:['192.0.2.4']}));await idle(p);assert.ok(p.previewReady,p.message);
  await p.open(p.items[0]);assert.equal(p.selected.value.nameserver[0],'192.0.2.4');
  await p.preview(p.undo);await p.open(p.items[0]);assert.equal(p.selected.value.nameserver[0],'192.0.2.3','one-step undo keeps candidate source');
  p.edit(f.patch('page-change-again','dns',p.selected,{nameserver:['192.0.2.4']}));await idle(p);assert.ok(p.previewReady,p.message);
  const savedIntent=JSON.parse(JSON.stringify(p.intent)),paired=await r.store.readEditDraftSource(ctx,file,r.store.readEditDraft(ctx,file).revision);
  await p.discardDraft();assert.equal(r.store.readEditDraft(ctx,file).source,undefined);await p.open(p.items[0]);assert.equal(p.selected.value.nameserver[0],'192.0.2.1','explicit draft undo restores successful source');
  const h=r.hosts.create(ctx,file,paired),s=await h.load();await h.save(savedIntent,s.revision);
  assert.equal(r.store.getProfileContent(ctx,file),original);
 }else if(phase==='rules-apply'){
  assert.equal(p.selected.value.nameserver[0],'192.0.2.4');await p.preview(p.intent);assert.ok(p.previewReady,p.message);
  // A second real host saves after this page preview: the old receipt must fail.
  const other=r.hosts.create(ctx,file),otherSession=await other.load();await other.save(otherSession.intent,otherSession.revision);
  await p.apply();assert.equal(p.previewReady,false);assert.match(p.message,/变化/);
  assert.equal(r.store.getProfileContent(ctx,file),original);assert.ok(r.store.readEditDraft(ctx,file).source);
  ({r,p}=await opened(runtime,ctx,file));await p.preview(p.intent);assert.ok(p.previewReady,p.message);
  const shown=JSON.parse(JSON.stringify(p.shown));assert.equal(shown.digest,p.shown.digest);await p.apply();assert.equal(p.message,'已保存');
  assert.equal(r.store.getProfileContent(ctx,file),candidate);assert.equal(r.store.readEditDraft(ctx,file).source,undefined);
  const version=r.versions.read(ctx).Profiles[file];assert.match(fs.readFileSync(version.Path,'utf8'),/192\.0\.2\.4/);
  assert.equal(p.previewReady,false);await p.apply();assert.equal(p.previewReady,false,'consumed receipt cannot be applied twice');
 }else throw Error('Unknown rules phase '+phase);
};
