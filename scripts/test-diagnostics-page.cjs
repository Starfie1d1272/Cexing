const uiFixture = require('./ci/ui-fixtures.cjs');
// Actual page + snapshot store methods; no physical picker/share claim.
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const ts=require('./ci/transpile-arkts.cjs');
function load(file,modules={},extra={}){const c={exports:{},require:k=>{if(k.endsWith('/UiText'))return uiFixture.module;assert.ok(k in modules,k);return modules[k];},...extra};Object.assign(c,uiFixture.globals);vm.runInNewContext(ts.transpileModule(fs.readFileSync(file,'utf8')).outputText,c);return c.exports;}
const failures=load('cexing/entry/src/main/ets/lib/ConnectionFailure.ets');
const view=load('cexing/entry/src/main/ets/lib/DiagnosticsBundleView.ets');
function packet(marker,count=1){return JSON.stringify({schema:'cexing-support-bundle/1',sources:[{name:'host-current',status:'available',journal:{events:Array(count).fill({}),dropped:3,writeFailures:2,logSuppressed:1},exportOmitted:4,unpersistedEvents:1},{name:'host-previous',status:'available',journal:{events:[{},{}]}},{name:'kernel-previous',status:'invalid'}],exportContextCollected:false,selectedVersion:{effectiveVersion:'unknown'},checkCoverage:{controller:[{}]},marker,padding:'x'.repeat(250000)});}
const facts=view.DiagnosticsBundleView.facts(packet('A'));
assert.ok(facts.some(s=>s.includes('上一会话：2')));assert.ok(facts.some(s=>s.includes('记录丢弃 3')));assert.ok(facts.some(s=>s.includes('文件损坏')));assert.ok(facts.some(s=>s.includes('不能据此判断')));
let clock=1760000000000,uuid=0,nextFD=0,copyFail=false,shortWrite=false;
const files=new Map(),modified=new Map(),directories=new Set(),descriptors=new Map(),closed=[],copies=[];
const fileIo={OpenMode:{READ_WRITE:1,CREATE:2,TRUNC:4,WRITE_ONLY:8,NOFOLLOW:16},
 accessSync:p=>files.has(p)||directories.has(p),mkdirSync:p=>directories.add(p),
 listFileSync:dir=>Array.from(files.keys()).filter(p=>p.startsWith(dir+'/')).map(p=>p.slice(dir.length+1)),
 unlinkSync:p=>{modified.delete(p);return files.delete(p);},statSync:p=>({mtime:(modified.get(p)??clock)/1000}),utimes:(p,time)=>modified.set(p,time),
 openSync:(path,mode)=>{const fd=++nextFD;if(!files.has(path)||(mode&4))files.set(path,Buffer.alloc(0));descriptors.set(fd,{path,position:0});return {fd};},
 writeSync:(fd,buffer)=>{const d=descriptors.get(fd),all=Buffer.from(buffer),bytes=all.subarray(0,shortWrite?Math.min(7,all.length):all.length);files.set(d.path,Buffer.concat([files.get(d.path),bytes]));modified.set(d.path,clock);d.position+=bytes.length;return bytes.length;},
 fsyncSync(){},closeSync:file=>{const fd=typeof file==='number'?file:file.fd;closed.push(descriptors.get(fd).path);descriptors.delete(fd);},
 copyFileSync:(src,to)=>{if(copyFail)throw Error('disk');const dest=typeof to==='number'?descriptors.get(to).path:to;const bytes=Buffer.from(files.get(src));copies.push({src,dest,bytes});files.set(dest,bytes);}
};
const snapshots=load('cexing/entry/src/main/ets/lib/DiagnosticExportSnapshots.ets',{'@kit.CoreFileKit':{fileIo},'@kit.ArkTS':{util:{TextEncoder:class{encodeInto(s){return new TextEncoder().encode(s);}},generateRandomUUID:()=>`00000000-0000-0000-0000-${String(++uuid).padStart(12,'0')}`}}},{Date:{now:()=>clock}});
let outcome='success',stage='controller_version',listener,currentJson=packet('A'),exportsMade=0,checks=0,holdPicker=false,holdShare=false,holdCheck=false,holdProxy=false,holdExport=false,dest=['file://chosen'],opened,copied;
const pickerWaits=[],shareCalls=[],messages=[],checkWaits=[],proxyWaits=[],exportWaits=[];
const deviceInfo={osFullName:'HarmonyOS 7.0.0.109'};
const context={filesDir:'/private',cacheDir:'/cache',startAbility:async w=>{opened=w.uri;}};
const service={record:async()=>true,check:(_ctx,kind)=>{checks++;const result={kind,stage,outcome,at:'2026-10-13T00:00:00Z',durationMs:1};return holdCheck?new Promise(resolve=>checkWaits.push(()=>resolve(result))):Promise.resolve(result);},exportBundle:()=>{exportsMade++;const json=currentJson;files.set('/cache/cexing-support.json',Buffer.from(json));const result={json,path:'/cache/cexing-support.json',fileName:'cexing-support.json'};return holdExport?new Promise(resolve=>exportWaits.push(()=>resolve(result))):Promise.resolve(result);}};
const modules={'../lib/CoreApi':{CoreApi:{getProxies:()=>holdProxy?new Promise(resolve=>proxyWaits.push(()=>resolve({UserChoice:{}}))):Promise.resolve({UserChoice:{}})}},'./NativeTheme':{},
 '../lib/VpnController':{VpnController:{status:2,onChanged:fn=>{listener=fn;},offChanged(){},getLastStartFailure:()=>null,getTunCreateObserved:()=>true,getKernelReadyReported:()=>true},VpnStatus:{Connected:2,Connecting:1,Disconnecting:3}},
 '../lib/ConnectionFailure':failures,'../lib/DiagnosticsBundleView':view,'../lib/DiagnosticExportSnapshots':snapshots,'../lib/DiagnosticsService':{DiagnosticsService:service},
 '@kit.BasicServicesKit':{deviceInfo,pasteboard:{MIMETYPE_TEXT_PLAIN:'text/plain',createData:(_m,s)=>s,getSystemPasteboard:()=>({setData:async s=>{copied=s;}})}},
 '@kit.AbilityKit':{bundleManager:{BundleFlag:{GET_BUNDLE_INFO_DEFAULT:0},getBundleInfoForSelf:async()=>({versionName:'1.0.0',versionCode:1})}},'@kit.ArkUI':{promptAction:{showToast:v=>messages.push(v.message)}},
 '@kit.CoreFileKit':{fileIo,fileUri:{getUriFromPath:p=>'file://'+p},picker:{DocumentViewPicker:class{save(){return holdPicker?new Promise(resolve=>pickerWaits.push(resolve)):Promise.resolve(dest);}}}},
 '@kit.ArkData':{uniformTypeDescriptor:{UniformDataType:{FILE:'general.file'}}},
 '@kit.ShareKit':{systemShare:{SharedData:class{constructor(record){this.record=record;}},ShareController:class{constructor(data){this.record=data.record;this.listeners=new Map();}on(k,fn){this.listeners.set(k,fn);}off(k){this.listeners.delete(k);}show(){shareCalls.push(this);return holdShare?new Promise(resolve=>{this.resolve=resolve;}):Promise.resolve();}dismiss(){this.listeners.get('dismiss')?.();}}}}
};
const src=fs.readFileSync('cexing/entry/src/main/ets/pages/DiagnosticsPage.ets','utf8');
const methods=(src.slice(0,src.indexOf('  build()'))+'\n}').split('\n').map(l=>l.trimStart().startsWith('@')?l.replace(/@\w+(?:\([^\n)]*\))?\s*/g,''):l).join('\n').replace('export struct ','export class ');
const c={exports:{},require:k=>{if(k.endsWith('/UiText'))return uiFixture.module;assert.ok(k in modules,k);return modules[k];},getContext:()=>context,Date,Promise,setTimeout:()=>1,clearTimeout(){}};
Object.assign(c,uiFixture.globals);vm.runInNewContext(ts.transpileModule(methods).outputText,c);
const flush=async()=>{for(let i=0;i<12;i++)await Promise.resolve();};
const readURI=uri=>files.get(uri.slice('file://'.length)).toString();
(async()=>{
 const page=new c.exports.DiagnosticsPage();page.aboutToAppear();await page.check();assert.equal(page.control,'本机服务可达');listener(2);assert.equal(page.control,'本机服务可达');
 await page.exportSupport(false); assert.equal(files.get('file://chosen').toString(),currentJson);assert.equal(checks,1,'export never probes');assert.ok(closed.includes('file://chosen'));assert.match(page.exportMessage,/诊断支持包已保存/);
 dest=[];await page.exportSupport(false);assert.match(page.exportMessage,/取消/);
 copyFail=true;dest=['file://fail'];await page.exportSupport(false);assert.ok(closed.includes('file://fail'));assert.match(page.exportMessage,/未完成/);copyFail=false;
 // P2: picker waits while another caller replaces the mutable service cache.
 currentJson=packet('picker-A',2);holdPicker=true;const saveA=page.exportSupport(false);await flush();assert.equal(pickerWaits.length,1);const previewA=page.bundleFacts.slice();
 currentJson=packet('cache-B',4);await service.exportBundle();pickerWaits.shift()(['file://saved-A']);await saveA;
 assert.equal(JSON.parse(files.get('file://saved-A')).marker,'picker-A');assert.ok(previewA.some(x=>x.includes('当前会话：2')));assert.ok(page.bundleFacts.some(x=>x.includes('当前会话：2')));
 // P1: VPN notification unblocks B while share A is still waiting.
 holdPicker=false;holdShare=true;currentJson=packet('share-A',2);const shareA=page.exportSupport(true);await flush();const a=shareCalls.at(-1);assert.equal(a.record.content,undefined);assert.equal(a.record.utd,'general.file');
 listener(0);currentJson=packet('share-B',4);const shareB=page.exportSupport(true);await flush();const b=shareCalls.at(-1);assert.notEqual(a.record.uri,b.record.uri);assert.equal(JSON.parse(readURI(a.record.uri)).marker,'share-A');assert.equal(JSON.parse(readURI(b.record.uri)).marker,'share-B');
 a.resolve();await shareA;assert.equal(page.busy,true,'late A completion cannot clear B busy state');b.resolve();await shareB;
 const aPath=a.record.uri.slice(7),bPath=b.record.uri.slice(7);clock+=25*60*60*1000;
 // Active shares survive cleanup and page reentry even after the grace period.
 const lease=snapshots.DiagnosticExportSnapshots.create(context,packet('cleanup'),false);assert.ok(files.has(aPath)&&files.has(bPath));snapshots.DiagnosticExportSnapshots.release(lease,false);
 page.aboutToDisappear();page.aboutToAppear();a.dismiss();a.dismiss();assert.ok(files.has(bPath),'late/idempotent A dismiss does not release B');
 const lease2=snapshots.DiagnosticExportSnapshots.create(context,packet('cleanup2'),false);assert.ok(files.has(aPath)&&files.has(bPath),'dismiss refreshes retained mtime after a long activity');snapshots.DiagnosticExportSnapshots.release(lease2,false);b.dismiss();
 // All operation owners: old save success/cancel/share completion cannot
 // clear a newer DNS check or proxy-list load after a VPN notification.
 holdShare=false;holdPicker=true;holdCheck=true;
 for(const choice of [[],['file://old-save']]) {
  const old=page.exportSupport(false);await flush();listener(page.status===0?2:0);
  const newer=page.check('dns');await flush();pickerWaits.shift()(choice);await old;
  assert.equal(page.busy,true,'old export completion/cancel cannot clear newer check');checkWaits.shift()();await newer;assert.equal(page.busy,false);
 }
 holdPicker=false;holdShare=true;const oldShare=page.exportSupport(true);await flush();const oldController=shareCalls.at(-1);listener(page.status===0?2:0);holdProxy=true;
 const newProxy=page.chooseProxy();await flush();oldController.resolve();await oldShare;assert.equal(page.busy,true,'old share cannot clear proxy operation');proxyWaits.shift()();await newProxy;oldController.dismiss();holdShare=false;holdProxy=false;
 const oldCheck=page.check('dns');await flush();listener(page.status===0?2:0);holdPicker=true;const newSave=page.exportSupport(false);await flush();checkWaits.shift()();await oldCheck;assert.equal(page.busy,true,'old check cannot clear newer export');pickerWaits.shift()([]);await newSave;holdCheck=false;
 holdExport=true;holdPicker=true;holdCheck=true;const preparing=page.exportSupport(false);await flush();listener(page.status===0?2:0);const currentCheck=page.check('dns');await flush();const pickerCount=pickerWaits.length;exportWaits.shift()();await preparing;assert.equal(pickerWaits.length,pickerCount,'stale preparation does not launch a new dialog over another operation');assert.equal(page.busy,true);checkWaits.shift()();await currentCheck;holdExport=false;holdCheck=false;
 // Picker completion after leaving/reentering cannot write a user file.
 holdShare=false;holdPicker=true;currentJson=packet('old-page');const late=page.exportSupport(false);await flush();page.aboutToDisappear();page.aboutToAppear();pickerWaits.shift()(['file://late']);await late;assert.ok(!files.has('file://late'));
 // Fresh exports remain accurate and partial native writes are completed.
 holdPicker=false;shortWrite=true;const small=snapshots.DiagnosticExportSnapshots.create(context,'{"中文":"完整"}',false);assert.equal(files.get(small.path).toString(),'{"中文":"完整"}');snapshots.DiagnosticExportSnapshots.release(small,false);shortWrite=false;
 const quotaContext={cacheDir:'/quota'};const retained=[];for(let i=0;i<16;i++){const item=snapshots.DiagnosticExportSnapshots.create(quotaContext,'{}',true);retained.push(item);snapshots.DiagnosticExportSnapshots.release(item,true);}
 assert.throws(()=>snapshots.DiagnosticExportSnapshots.create(quotaContext,'{}',true),/snapshot_capacity/);const reservedSave=snapshots.DiagnosticExportSnapshots.create(quotaContext,'{}',false);snapshots.DiagnosticExportSnapshots.release(reservedSave,false);
 assert.throws(()=>snapshots.DiagnosticExportSnapshots.create(context,'x'.repeat(1024*1024+1),false),/snapshot_size/);
 await page.chooseProxy();assert.deepEqual(Array.from(page.proxyNames),['UserChoice']);assert.equal(page.proxyName,'');await page.copySummary();assert.match(copied,/controller_checked_at=/);deviceInfo.osFullName='https://private.invalid/?token=secret';await page.copySummary();assert.match(copied,/system_version=unknown/);assert.ok(!copied.includes('secret'));await page.openFeedback();assert.ok(opened.includes('template=diagnostics.yml'));
 assert.match(src,/Text\(this\.control\)/);assert.ok(!src.includes('this.Fact('));
 console.log('PASS: immutable per-export JSON, VPN-concurrent A/B sharing, mutable-cache picker race, preview consistency, active/grace cleanup, cancellation/failure/FD close, reentry/late callbacks, full UTF8 writes and no implicit checks/upload');
})().catch(e=>{console.error(e);process.exitCode=1;});
