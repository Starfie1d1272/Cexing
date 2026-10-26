// All four actual page callbacks, actual Store/reader/classifier, synthetic I/O only.
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),ts=require('./ci/transpile-arkts.cjs'),ui=require('./ci/ui-fixtures.cjs');
const {create}=require('./ci/profile-import-runtime.cjs');
const secret='https://private.invalid/sub?token=fake-secret';
const source=fs.readFileSync('cexing/entry/src/main/ets/pages/ProfilePage.ets','utf8');
const paste=source.slice(source.indexOf('  private async importPaste()'),source.indexOf('  @Builder\n  PasteSheet()'));
const body=(source.slice(0,source.indexOf('  @Builder'))+paste+'\n}').split('\n').map(l=>l.trimStart().startsWith('@')?l.replace(/@\w+(?:\([^\n)]*\))?\s*/g,''):l).join('\n').replace('export struct ','export class ');
function fixture(){
 const r=create(),toasts=[],box={exports:{},...ui.globals,getContext:()=>r.ctx};let clipboard='proxies: [synthetic]',clipboardError=null;
 const mods={'../lib/ImportFailure':r.failures,'../lib/ProfileStore':{ProfileStore:r.store},'../lib/BoundedFileReader':{BoundedFileReader:r.reader},
  '../lib/UiText':ui.module,'../lib/Logger':{Logger:{warn:(...x)=>r.logs.push(x.join(' '))}},'../lib/ProfileTransactions':{ProfileTransactions:{isBusy:()=>false}},
  '../lib/ProfileImportInput':{ProfileImportInput:{take:()=>null,release(){}}},'@kit.ArkUI':{promptAction:{showToast:x=>toasts.push(x.message)}},
  '@kit.CoreFileKit':{picker:{DocumentViewPicker:class{async select(){return ['file://picked.yaml']}},DocumentSelectMode:{FILE:0}}},
  '@kit.BasicServicesKit':{pasteboard:{getSystemPasteboard:()=>({getData:async()=>{if(clipboardError)throw clipboardError;return{getPrimaryText:()=>clipboard}}})}}};
 box.require=n=>mods[n]??{};vm.runInNewContext(ts.transpileModule(body).outputText,box);
 const p=new box.exports.ProfilePage();p.pageVisible=true;p.rootVisible=true;p.currentVisibleTab=1;p.pageGeneration=1;p.navStack={getAllPathName:()=>[]};
 p.inputUrl='https://example.invalid/synthetic';p.inputPaste=clipboard;p.showSheet=true;
 r.put('file://picked.yaml',clipboard);
 return {r,p,toasts,setClipboard:v=>clipboard=v,setClipboardError:e=>clipboardError=e};
}
const label=(r,key,...args)=>ui.module.UiText.get({id:'app.string.'+key},...args);
(async()=>{
 for(const route of ['importUrl','importFile','importClipboard','importPaste']){
  for(const kind of ['http','timeout','network','format','size','storage','cancelled']){
   const f=fixture(),{r,p,toasts}=f;let expected='';
   // URL variants exercise request failures even when entering via clipboard/paste.
   if(['http','timeout','network'].includes(kind)){
    if(route==='importFile'){
     // File callbacks share the same bounded classifier for typed transport failures.
     const err=kind==='http'?r.failures.ImportFailures.http(403):new r.failures.ImportFailure(kind,'request');r.fault=(op,target)=>{if(op==='open'&&target.startsWith('file://'))throw err};
    }else{f.setClipboard(p.inputUrl);p.inputPaste=p.inputUrl;if(kind==='http')r.code=403;else r.networkError=Object.assign(Error(secret),{code:kind==='timeout'?2300028:2300007})}
    expected=label(r,'import_error_'+kind,...(kind==='http'?[403]:[]));
   }else if(kind==='format'){
    r.body='c3M6Ly9zeW50aGV0aWM=';r.put('file://picked.yaml','not a supported configuration');f.setClipboard('bad input');p.inputPaste='bad input';expected=label(r,'import_error_format');
    // Clipboard treats non-YAML input as a URL, then receives the unsupported body.
   }else if(kind==='size'){
    const tooLarge='proxies: ['+'x'.repeat(15*1024*1024)+']';r.body=tooLarge;r.put('file://picked.yaml',tooLarge);f.setClipboard(tooLarge);p.inputPaste=tooLarge;expected=label(r,'import_error_size');
   }else if(kind==='storage'){
    r.fault=(op,target)=>{if(op==='open'&&!target.startsWith('file://'))throw Error(secret)};expected=label(r,'import_error_storage');
   }else{
    r.fault=()=>{throw new r.failures.ImportFailure('cancelled','prepare')};r.networkError=new r.failures.ImportFailure('cancelled','request');
   }
   await p[route]();const shown=route==='importFile'?(toasts.at(-1)??''):p.importError;
   assert.equal(shown,expected,`${route} ${kind}`);assert.equal(p.importing,false);
   assert.ok(!JSON.stringify([shown,r.logs,toasts]).includes(secret),'raw secrets cannot enter hints/logs');
   assert.ok(r.logs.every(line=>!line.includes('private.invalid')&&!line.includes('fake-secret')));
  }
 }
 // Numeric request codes only; arbitrary raw error text cannot inject a category/status or logs.
 const f=fixture();f.r.networkError=Error(secret+' HTTP 401 timeout');await f.p.importUrl();assert.equal(f.p.importError,label(f.r,'import_error_network'));assert.ok(!JSON.stringify(f.r.logs).includes(secret));
 for(const status of [401,403,503]){const r=create();assert.equal(r.failures.ImportFailures.http(status).status,status)}
 assert.equal(create().failures.ImportFailures.http(999999).kind,'network');
 const unknownStatus=fixture();unknownStatus.r.code=555;await unknownStatus.p.importUrl();assert.equal(unknownStatus.p.importError,label(unknownStatus.r,'import_error_http_generic'));assert.ok(unknownStatus.r.logs.every(line=>!line.includes('555')));
 const oversized=fixture();oversized.r.networkError=Object.assign(Error(secret),{code:2300063});await oversized.p.importUrl();assert.equal(oversized.p.importError,label(oversized.r,'import_error_size'));
 const encoding=fixture();encoding.r.put('file://picked.yaml',Buffer.from([0xff,0xff]));await encoding.p.importFile();assert.equal(encoding.toasts.at(-1),label(encoding.r,'import_error_format'));
 const cancelledClipboard=fixture();cancelledClipboard.p.showSheet=false;cancelledClipboard.r.fault=()=>{throw new cancelledClipboard.r.failures.ImportFailure('cancelled','prepare')};await cancelledClipboard.p.importClipboard();assert.equal(cancelledClipboard.p.showSheet,false);
 const tampered=fixture();const forged=new tampered.r.failures.ImportFailure('storage','prepare');forged.stage=secret;forged.kind=secret;forged.status=999999;tampered.r.networkError=forged;await tampered.p.importUrl();assert.ok(!JSON.stringify([tampered.r.logs,tampered.p.importError]).includes(secret));
 const fallback=fixture();fallback.setClipboardError(Error(secret));await fallback.p.importClipboard();assert.equal(fallback.p.showSheet,true);assert.equal(fallback.p.sheetMode,5);assert.ok(fallback.toasts.at(-1).includes('粘贴'));assert.ok(!JSON.stringify(fallback.r.logs).includes(secret));
 const stale=fixture();let release;stale.r.io.open=async()=>await new Promise(resolve=>release=resolve);const read=stale.p.importFile();while(!release)await new Promise(setImmediate);stale.p.pageVisible=false;release({fd:-1});await read;assert.equal(stale.toasts.length,0);assert.equal(stale.p.importError,'');
 console.log('PASS: four actual import entrypoints share bounded HTTP/network/timeout/format/size/storage/cancel hints, safe logs, late results and manual-paste fallback');
})().catch(e=>{console.error(e);process.exitCode=1});
