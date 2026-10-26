const assert=require('node:assert/strict');
const {create}=require('./ci/profile-import-runtime.cjs');
const yaml='proxies: [节点😀]\n',url='https://example.invalid/subscription';
const root='/files/profiles/',meta=root+'meta.json';
const modes=['sync','async','url'];
const invoke=(r,mode,name='new',current)=>mode==='sync'?Promise.resolve().then(()=>r.store.importContent(r.ctx,name,yaml)):mode==='url'?r.store.importFromUrl(r.ctx,url,current):r.store.importContentAsync(r.ctx,name,yaml,current);
const seeded=()=>{const r=create();r.store.importContent(r.ctx,'old',yaml);r.put(root+'active.txt','old.yaml');r.store.writeDraft(r.ctx,'old.yaml','old private draft');return r};
const snapshot=r=>[...r.data].map(([k,v])=>[k,v.toString()]).sort((a,b)=>a[0].localeCompare(b[0]));
const ownPayload=p=>p.includes('.yaml.import-');
(async()=>{
 // Inject once before every I/O stage, including all sidecar and metadata writes.
 for(const mode of modes){
  const baseline=seeded();baseline.events.length=0;await invoke(baseline,mode);
  const stages=baseline.events.filter(e=>['open','write','sync','close','rename'].includes(e.op));
  for(let index=0;index<stages.length;index++){
   const r=seeded(),before=snapshot(r);let seen=0,fired=false;
   r.fault=(op,p)=>{if(!['open','write','sync','close','rename'].includes(op))return;if(seen++===index){fired=true;throw Error('synthetic secret https://example.invalid/?token=private')}};
   await assert.rejects(invoke(r,mode),e=>e.kind==='storage');r.fault=null;
   assert.equal(fired,true,`${mode} ${index}`);assert.deepEqual(snapshot(r),before,`${mode} failure at ${JSON.stringify(stages[index])}`);
   assert.equal(r.fds.size,0,'all handles closed');assert.equal(r.store.list(r.ctx).length,1);
   const retry=await invoke(r,mode);assert.ok(retry);assert.equal(r.store.getMeta(r.ctx)[retry].origin,mode==='url'?url:'');
  }
 }
 // The final YAML rename sees every sidecar already prepared and no prior raw publication.
 const ordered=create();let published=0;
 ordered.hook=(op,p)=>{if(op==='rename'&&p.endsWith('.yaml')){const file=p.slice(root.length);const info=JSON.parse(ordered.text(meta))[file];assert.ok(info);assert.ok(ordered.text(p+'.update.json'));assert.equal(ordered.text(p),undefined);assert.equal(ordered.text(p+'.url'),info.origin);published++}};
 await invoke(ordered,'url');assert.equal(published,1);
 // Existing orphan records (including temps) all reserve their source name, never get deleted.
 for(const orphan of ['.url','.last-good','.merge.json','.region-select.json','.region-previous.json','.update.json','.intent.json','.unknown','.import-old','draft']){
  const r=create(),p=orphan==='draft'?root+'drafts/new.yaml.draft':root+'new.yaml'+orphan;r.put(p,'prior private material');
  // The real filesystem has the drafts directory whenever its file exists.
  if(orphan==='draft')r.io.mkdirSync(root+'drafts');
  assert.equal(await invoke(r,'async'),'new (2).yaml');assert.equal(r.text(p),'prior private material');
 }
 const metaOrphan=create();metaOrphan.put(meta,JSON.stringify({'new.yaml':{origin:'old',sub:{},updatedAt:1}}));assert.equal(await invoke(metaOrphan,'sync'),'new (2).yaml');assert.equal(JSON.parse(metaOrphan.text(meta))['new.yaml'].origin,'old');
 const immutable=create();immutable.state={Current:null,Profiles:{'new.yaml':{ID:'existing'}}};assert.equal(await invoke(immutable,'async'),'new (2).yaml');
 // Two overlapping imports reserve unique names; one failing never rewinds the other's metadata.
 const concurrent=seeded();let release;const oldSync=concurrent.io.fsync;
 concurrent.io.fsync=async fd=>{await oldSync(fd);if(concurrent.fds.get(fd).includes('/new.yaml.import-'))await new Promise(resolve=>{release=resolve})};
 const first=invoke(concurrent,'async');while(!release)await new Promise(setImmediate);
 const second=await invoke(concurrent,'async');assert.equal(second,'new (2).yaml');
 concurrent.fault=(op,p)=>{if(op==='rename'&&p===root+'new.yaml')throw Error('synthetic rename failure')};release();await assert.rejects(first,e=>e.kind==='storage');concurrent.fault=null;
 assert.equal(concurrent.text(root+second),yaml);assert.ok(JSON.parse(concurrent.text(meta))[second]);assert.equal(JSON.parse(concurrent.text(meta))['new.yaml'],undefined);
 // Cancellation during write/flush/close/sidecar preparation leaves no published source.
 for(const cancelAt of ['write','sync','close','sidecars']){
  const r=seeded(),before=snapshot(r);let current=true;
  r.hook=(op,p)=>{if(op===(cancelAt==='sidecars'?'rename':cancelAt)&&(cancelAt==='sidecars'?p.endsWith('.update.json'):ownPayload(p)))current=false};
  await assert.rejects(invoke(r,'async','new',()=>current),e=>e.kind==='cancelled');assert.deepEqual(snapshot(r),before);assert.equal(r.fds.size,0);
 }
 // There is no await between the final guard and sync rename. A leave at committed rename is success.
 const leaving=create();let current=true;leaving.hook=(op,p)=>{if(op==='rename'&&p===root+'new.yaml')current=false};assert.equal(await invoke(leaving,'async','new',()=>current),'new.yaml');assert.equal(current,false);assert.equal(leaving.text(root+'new.yaml'),yaml);
 const unicode=create(),text='proxies: ['+'x'.repeat(65525)+'😀节点]\n';const file=await unicode.store.importContentAsync(unicode.ctx,'unicode',text);assert.equal(unicode.text(root+file),text);
 // Cleanup failure is explicit and never deletes changed ownership or another source.
 const dirty=seeded();dirty.fault=(op,p)=>{if((op==='rename'&&p===root+'new.yaml')||(op==='unlink'&&p.endsWith('.update.json')))throw Error('synthetic failure')};await assert.rejects(invoke(dirty,'async'),e=>e.kind==='storage'&&e.stage==='rollback');assert.equal(dirty.text(root+'new.yaml'),undefined);assert.equal(dirty.text(root+'old.yaml'),yaml);
 const changed=seeded();changed.hook=(op,p)=>{if(op==='rename'&&p===root+'new.yaml'){changed.put(root+'new.yaml.update.json','someone else');throw Error('synthetic failure')}};await assert.rejects(invoke(changed,'async'),e=>e.stage==='rollback');assert.equal(changed.text(root+'new.yaml.update.json'),'someone else');
 const cancelledUrl=create();let urlCurrent=true;cancelledUrl.hook=(op,p)=>{if(op==='write'&&ownPayload(p))urlCurrent=false};await assert.rejects(invoke(cancelledUrl,'url','new',()=>urlCurrent),e=>e.kind==='cancelled');assert.equal(cancelledUrl.destroyed,1);assert.equal(cancelledUrl.store.list(cancelledUrl.ctx).length,0);
 const beforeRequest=create();await assert.rejects(invoke(beforeRequest,'url','new',()=>false),e=>e.kind==='cancelled');assert.equal(beforeRequest.options.length,0);
 const interrupted=seeded(),oldFiles=snapshot(interrupted);let writes=0;interrupted.fault=(op,p)=>{if(op==='write'&&ownPayload(p)&&++writes===3)throw Error('synthetic partial-write failure')};await assert.rejects(interrupted.store.importContentAsync(interrupted.ctx,'partial','proxies: ['+'合成😀'.repeat(20000)+']'),e=>e.kind==='storage');assert.deepEqual(snapshot(interrupted),oldFiles);
 const both=create();const names=await Promise.all([invoke(both,'async'),invoke(both,'async')]);assert.deepEqual(names,['new.yaml','new (2).yaml']);assert.equal(Object.keys(JSON.parse(both.text(meta))).length,2);
 for(const mode of ['sync','async'])for(const count of [0,100000000]){const r=seeded(),before=snapshot(r);if(mode==='sync')r.io.writeSync=()=>count;else r.io.write=async()=>count;await assert.rejects(invoke(r,mode),e=>e.kind==='storage');assert.deepEqual(snapshot(r),before)}
 const metaCleanup=seeded();let publishing=false;metaCleanup.fault=(op,p)=>{if(op==='rename'&&p===root+'new.yaml'){publishing=true;throw Error('synthetic publish failure')}if(publishing&&op==='rename'&&p===meta)throw Error('synthetic cleanup failure')};await assert.rejects(invoke(metaCleanup,'async'),e=>e.stage==='rollback');assert.equal(metaCleanup.text(root+'new.yaml'),undefined);assert.ok(JSON.parse(metaCleanup.text(meta))['old.yaml']);
 console.log('PASS: actual sync/async/URL import stages, exclusive publication, isolated rollback, orphans, concurrent names/metadata, cancellation/retry and Unicode chunks');
})().catch(e=>{console.error(e);process.exitCode=1});
