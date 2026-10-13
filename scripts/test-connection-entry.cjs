// Production entry intents execute without a second confirmation. Device authorization is separate.
const assert=require('node:assert/strict'), fs=require('node:fs'), path=require('node:path'), vm=require('node:vm');
const ts=require('./ci/transpile-arkts.cjs');
const source=fs.readFileSync(path.join(__dirname,'../cexing/entry/src/main/ets/lib/ConnectionEntry.ets'),'utf8');
const code=ts.transpileModule(source).outputText;
const status={Disconnected:0,Connecting:1,Connected:2,Disconnecting:3};
const flush=()=>new Promise(r=>setImmediate(r));
function fixture(persistedUnknown=false) {
 const ctx={},listeners=[],calls={start:0,stop:0,cancel:0,prepare:0,reports:[],toasts:[]};
 let stopResult=null,busy=false,uncertain=false,profile='synthetic.yaml',observed=false;
 let prepare=async()=>{};
 const controller={status:0,onChanged:cb=>listeners.push(cb),getLastStopCompleted:()=>stopResult,
 getLastStartFailure:()=>null,getTunCreateObserved:()=>observed,getKernelReadyReported:()=>observed,
 start:()=>{calls.start++;stopResult=null;emit(status.Connecting);},
 stop:async()=>{calls.stop++;emit(status.Disconnecting);stopResult=true;emit(status.Disconnected);return true;}};
 function emit(s){controller.status=s;listeners.forEach(cb=>cb(s));}
 const modules={
 '@kit.ArkUI':{promptAction:{showToast:({message})=>calls.toasts.push(message)}},
 './VpnController':{VpnController:controller,VpnStatus:status},
 './ProfileStore':{ProfileStore:{isApplyUncertain:()=>uncertain,getActiveFile:()=>profile}},
 './ProfileTransactions':{ProfileTransactions:{isBusy:()=>busy,ensureActiveSmartPolicy:async context=>{calls.prepare++;return prepare(context);}}},
 './AppRuntime':{AppRuntime:{cancelRestore:()=>calls.cancel++}},
 './ConnectionCards':{ConnectionCards:{read:()=>({stopUnknown:persistedUnknown}),publish:(_,label,unknown)=>calls.reports.push({label,unknown})}}};
 const host={exports:{},require:name=>{assert.ok(name in modules,name);return modules[name];},AppStorage:{setOrCreate(){}}};
 vm.runInNewContext(code,host);const entry=host.exports.ConnectionEntry;entry.bind(ctx);
 return {entry,ctx,controller,calls,emit,want:action=>({parameters:{cexingConnectionAction:action}}),
 set:values=>{if('busy'in values)busy=values.busy;if('uncertain'in values)uncertain=values.uncertain;
 if('profile'in values)profile=values.profile;if('observed'in values)observed=values.observed;
 if('prepare'in values)prepare=values.prepare;if('stopResult'in values)stopResult=values.stopResult;}};
}
async function tests(){
 const f=fixture();f.entry.receive(f.want('toggle'));assert.equal(f.entry.request,0);
 f.entry.receive({parameters:{params:'{bad'}});assert.equal(f.entry.request,0);
 f.entry.receive({parameters:{params:JSON.stringify({cexingConnectionAction:'connect'})}});
 assert.equal(f.calls.start,0,'cold intent waits for runtime verification');
 f.entry.recovered(f.ctx);await flush();assert.equal(f.calls.start,1,'one Want starts without confirmation');
 f.entry.receive(f.want('connect'));await flush();assert.equal(f.calls.start,1,'connect keeps a pending connection');
 f.entry.receive(f.want('disconnect'));await flush();assert.equal(f.calls.stop,1,'one Want cancels a pending start');
 f.entry.receive(f.want('disconnect'));await flush();assert.equal(f.calls.stop,1,'disconnect stays disconnected');
 assert.equal(f.entry.label(),'未连接');f.emit(status.Connected);assert.equal(f.entry.label(),'已连接');
 for(const block of [{busy:true},{uncertain:true},{profile:''},{stopResult:false}]){
  const blocked=fixture();blocked.set(block);blocked.entry.receive(blocked.want('connect'));blocked.entry.recovered(blocked.ctx);await flush();
  assert.equal(blocked.calls.start,0,'configuration/stop safety blocks startup');assert.equal(blocked.calls.toasts.length,1);
 }
 const cold=fixture(true);cold.entry.receive(cold.want('connect'));cold.entry.recovered(cold.ctx);await flush();assert.equal(cold.calls.start,0);
 for(const supersede of ['want','ability','status','profile']){
  const g=fixture();let finish;g.set({prepare:()=>new Promise(r=>finish=r)});
  g.entry.receive(g.want('connect'));g.entry.recovered(g.ctx);assert.equal(g.calls.prepare,1);
  if(supersede==='want')g.entry.receive(g.want('disconnect'));
  if(supersede==='ability')g.entry.destroyed(g.ctx);
  if(supersede==='status')g.emit(status.Connected);
  if(supersede==='profile')g.set({profile:'other.yaml'});
  finish();await flush();assert.equal(g.calls.start,0,`${supersede} invalidates prepared start`);
 }
 const retry=fixture();retry.set({prepare:async()=>{throw Error('synthetic');}});
 retry.entry.receive(retry.want('connect'));retry.entry.recovered(retry.ctx);await flush();assert.equal(retry.calls.start,0);
 retry.set({prepare:async()=>{}});retry.entry.receive(retry.want('connect'));await flush();assert.equal(retry.calls.start,1);
 const queued=fixture();queued.entry.recovered(queued.ctx);queued.emit(status.Connected);let finish;
 queued.controller.stop=()=>{queued.calls.stop++;queued.emit(status.Disconnecting);return new Promise(r=>finish=r);};
 queued.entry.receive(queued.want('disconnect'));queued.entry.receive(queued.want('connect'));
 queued.set({stopResult:true});queued.emit(status.Disconnected);finish(true);await flush();
 assert.equal(queued.calls.start,1,'latest connect runs after prior stop completion');
 const rebound=fixture();rebound.entry.receive(rebound.want('connect'));const next={};rebound.entry.bind(next);rebound.entry.recovered(next);
 rebound.entry.destroyed(rebound.ctx);await flush();assert.equal(rebound.entry.ready,true);assert.equal(rebound.calls.start,0);
  // Persistence belongs to the card adapter, not to an alternate VPN controller.
  const files = new Map(), updates = [];
  const io = { OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
    openSync: p => ({ fd: p }), writeSync: (p, data) => files.set(p, data), closeSync() {},
    renameSync: (a, b) => { files.set(b, files.get(a)); files.delete(a); },
    readTextSync: p => { if (!files.has(p)) throw Error('missing'); return files.get(p); } };
  const cardModules = { '@kit.CoreFileKit': { fileIo: io }, '@kit.FormKit': {
    formBindingData: { createFormBindingData: data => data },
    formProvider: { updateForm: async (id, data) => updates.push({ id, data }) }
  }, './Logger': { Logger: { warn() {} } } };
  const host = { exports: {}, require: name => { assert.ok(name in cardModules, name); return cardModules[name]; } };
  const cardsCode = ts.transpileModule(fs.readFileSync(path.join(__dirname,
    '../cexing/entry/src/main/ets/lib/ConnectionCards.ets'), 'utf8')).outputText;
  vm.runInNewContext(cardsCode, host);
  const cards = host.exports.ConnectionCards, cardCtx = { filesDir: '/synthetic' };
  assert.equal(cards.read(cardCtx).label, '状态待核对');
  const id = '9007199254740993';
  cards.add(cardCtx, id); cards.add(cardCtx, id);
  cards.publish(cardCtx, '停止结果未知', true);
  assert.equal(updates.length, 1, 'Multiple callbacks must retain one exact string form identity');
  assert.equal(updates[0].id, id);
  assert.equal(cards.read(cardCtx).stopUnknown, true);
  assert.equal(cards.read(cardCtx).label, '状态待核对', 'cached connected labels never claim current runtime state');
  assert.equal(updates[0].data.label, '停止结果未知', 'live publish uses the current observation');
  assert.ok(cards.read(cardCtx).reportedAt.length > 0, 'Historical reports must include their observation time');
  cards.remove(cardCtx, id); cards.publish(cardCtx, '已确认断开', false);
  assert.equal(updates.length, 1, 'Removed forms must not receive later lifecycle reports');
  assert.equal(cards.read(cardCtx).stopUnknown, false);
  // Execute the card's freshness logic; SDK compilation checks the form-supported TextClock.
  let cardSource = fs.readFileSync(path.join(__dirname,
    '../cexing/entry/src/main/ets/connectionform/ConnectionCard.ets'), 'utf8');
  cardSource = cardSource.slice(cardSource.indexOf('@Component'), cardSource.indexOf('  build()')) + '\n}';
  cardSource = cardSource.split('\n').filter(line => line.trim() !== '@Component')
    .map(line => line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '')).join('\n')
    .replace('struct ConnectionCard', 'class ConnectionCard');
  cardSource += '\nexports.Card = ConnectionCard;';
  let time = 100000;
  const cardHost = { exports: {}, Date: { now: () => time }, postCardAction() {} };
  vm.runInNewContext(ts.transpileModule(cardSource).outputText, cardHost);
  const widget = new cardHost.exports.Card();
  widget.aboutToAppear(); assert.equal(widget.fresh, false);
  widget.verifiedAt = time; widget.refreshFreshness(); assert.equal(widget.fresh, true);
  time += 60001; widget.refreshFreshness(); assert.equal(widget.fresh, false, 'stopped runtime heartbeat expires');
  widget.verifiedAt = time + 1; widget.refreshFreshness(); assert.equal(widget.fresh, false, 'future timestamp cannot claim current status');
  console.log('PASS: one-tap intents, cold recovery, stale/repeated preparation, profile gate and historical card protection');
}
tests().catch(e => { console.error(e); process.exitCode = 1; });
