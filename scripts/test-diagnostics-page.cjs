// Actual page methods and full-file export; no picker/share/device claim.
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const ts=require('./ci/transpile-arkts.cjs');
function module(source,require=()=>({})){const c={exports:{},require};vm.runInNewContext(ts.transpileModule(source).outputText,c);return c.exports;}
const failures=module(fs.readFileSync('cexing/entry/src/main/ets/lib/ConnectionFailure.ets','utf8'));
const view=module(fs.readFileSync('cexing/entry/src/main/ets/lib/DiagnosticsBundleView.ets','utf8'));
const sources=[{name:'host-current',status:'available',journal:{events:[{}],dropped:3,writeFailures:2,logSuppressed:1},exportOmitted:4,unpersistedEvents:1},
 {name:'host-previous',status:'available',journal:{events:[{},{}]}},{name:'kernel-previous',status:'invalid'}];
const json=JSON.stringify({schema:'cexing-support-bundle/1',sources,exportContextCollected:false,selectedVersion:{effectiveVersion:'unknown'},checkCoverage:{controller:[{}]}, padding:'x'.repeat(250000)});
const facts=view.DiagnosticsBundleView.facts(json);
assert.ok(facts.some(s=>s.includes('上一会话：2')));assert.ok(facts.some(s=>s.includes('记录丢弃 3')));
assert.ok(facts.some(s=>s.includes('文件损坏')));assert.ok(facts.some(s=>s.includes('不能据此判断')));
assert.throws(()=>view.DiagnosticsBundleView.facts('{"schema":"wrong","sources":[]}'));
let outcome='success',kind='controller',stage='controller_version',listener,copied,opened,shares=[],dest=['file://chosen'],closed=0,files=[],throwsCopy=false,exportCount=0,checks=0;
const messages=[];
const context={filesDir:'/private',cacheDir:'/cache',startAbility:async w=>{opened=w.uri;}};
const modules={
 '../lib/CoreApi':{CoreApi:{getProxies:async()=>({UserChoice:{}})}},'./NativeTheme':{},
 '../lib/VpnController':{VpnController:{status:2,onChanged:fn=>{listener=fn;},offChanged(){},getLastStartFailure:()=>null,getTunCreateObserved:()=>true,getKernelReadyReported:()=>true},VpnStatus:{Connected:2,Connecting:1,Disconnecting:3}},
 '../lib/ConnectionFailure':failures,'../lib/DiagnosticsBundleView':view,
 '../lib/DiagnosticsService':{DiagnosticsService:{record:async()=>true,check:async(_ctx,k)=>{checks++;return {kind:k,stage,outcome,at:'2026-10-13T00:00:00Z',durationMs:1};},exportBundle:async()=>{exportCount++;return {json,path:'/cache/cexing-support.json',fileName:'cexing-support.json'};}}},
 '@kit.BasicServicesKit':{deviceInfo:{osFullName:'HarmonyOS 7.0.0.109'},pasteboard:{MIMETYPE_TEXT_PLAIN:'text/plain',createData:(_m,text)=>text,getSystemPasteboard:()=>({setData:async text=>{copied=text;}})}},
 '@kit.AbilityKit':{bundleManager:{BundleFlag:{GET_BUNDLE_INFO_DEFAULT:0},getBundleInfoForSelf:async()=>({versionName:'1.0.0',versionCode:1})}},
 '@kit.ArkUI':{promptAction:{showToast:v=>messages.push(v.message)}},
 '@kit.CoreFileKit':{fileUri:{getUriFromPath:p=>'file://'+p},picker:{DocumentViewPicker:class{async save(){return dest;}}},fileIo:{OpenMode:{READ_WRITE:1,CREATE:2,TRUNC:4},openSync:()=>({fd:9}),copyFileSync:(src,to)=>{if(throwsCopy)throw Error('disk');files.push({src,to});},closeSync:()=>closed++}},
 '@kit.ArkData':{uniformTypeDescriptor:{UniformDataType:{FILE:'general.file'}}},
 '@kit.ShareKit':{systemShare:{SharedData:class{constructor(r){this.record=r;}},ShareController:class{constructor(data){this.data=data;}async show(){shares.push(this.data.record);}}}}
};
const src=fs.readFileSync('cexing/entry/src/main/ets/pages/DiagnosticsPage.ets','utf8');
const methods=(src.slice(0,src.indexOf('  build()'))+'\n}').split('\n').map(l=>l.trimStart().startsWith('@')?l.replace(/@\w+(?:\([^\n)]*\))?\s*/g,''):l).join('\n').replace('export struct ','export class ');
const c={exports:{},require:k=>{assert.ok(k in modules,k);return modules[k];},getContext:()=>context,Date,Promise,setTimeout:()=>1,clearTimeout(){}};
vm.runInNewContext(ts.transpileModule(methods).outputText,c);
(async()=>{
 const page=new c.exports.DiagnosticsPage();page.aboutToAppear();await page.check();assert.equal(page.control,'本机服务可达');listener(2);assert.equal(page.control,'本机服务可达');
 stage='controller_authorization';outcome='failed';await page.check();assert.match(page.control,/认证失败/);
 await page.exportSupport(false);assert.equal(exportCount,1);assert.equal(checks,2,'export never probes');assert.equal(files[0].to,9);assert.equal(closed,1);assert.match(page.exportMessage,/诊断支持包已保存/);
 dest=[];await page.exportSupport(false);assert.equal(closed,1);assert.match(page.exportMessage,/取消/);
 throwsCopy=true;dest=['file://chosen'];await page.exportSupport(false);assert.equal(closed,2,'failed copy closes destination');assert.match(page.exportMessage,/未完成/);
 throwsCopy=false;await page.exportSupport(true);assert.equal(shares.length,1);assert.equal(shares[0].utd,'general.file');assert.equal(shares[0].uri,'file:///cache/cexing-support-share.json');assert.equal(shares[0].content,undefined,'1 MiB JSON is not text IPC');
 assert.ok(files.some(f=>f.to==='/cache/cexing-support-share.json'));
 await page.chooseProxy();assert.deepEqual(Array.from(page.proxyNames),['UserChoice']);assert.equal(page.proxyName,'','read never silently selects a proxy');
 await page.copySummary();assert.match(copied,/controller_checked_at=/);await page.openFeedback();assert.ok(opened.includes('template=diagnostics.yml'));assert.ok(!opened.includes('json='));
 page.aboutToDisappear();const before=files.length;await page.exportSupport(false);assert.equal(files.length,before,'hidden generation cannot save');
 assert.match(src,/Text\(this\.control\)/);assert.ok(!src.includes('this.Fact('));
 console.log('PASS: service result updates, bundle coverage/truncation/missing, complete file save/cancel/failure/close, URI share, no implicit probe/proxy/upload and hidden cleanup');
})().catch(e=>{console.error(e);process.exitCode=1;});
