const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const source = fs.readFileSync('cexing/entry/src/main/ets/lib/Settings.ets','utf8');
function fixture({journal = null, disk = new Map()} = {}) {
 let cache = new Map(disk), fail = 0, flushes = 0, cleaned = 0;
 const pref = { getSync: (k,v) => cache.has(k)?cache.get(k):v, putSync: (k,v) => cache.set(k,v),
  async flush() { flushes++; if(flushes===fail) throw Error('disk full'); disk.clear();for(const [k,v]of cache)disk.set(k,v); } };
 const bridge = { exists: () => journal !== null, call: async (_,input) => { const a=JSON.parse(input);
   if(a.op==='backup-clean'){cleaned++;return {}};if(!journal)throw Error('missing');return journal; },
   acknowledge: async () => {journal=null;} };
 const sandbox={exports:{},require:n=>n==='@kit.ArkData'?{preferences:{getPreferencesSync:()=>pref}}:
   n==='./BackupJournal'?{BackupJournal:bridge}:n==='./Logger'?{Logger:{error(){}}}:{}};
 vm.runInNewContext(ts.transpileModule(source).outputText,sandbox);
 return {s:sandbox.exports.Settings,disk,fail(n){fail=n;flushes=0},get journal(){return journal},get cleaned(){return cleaned}};
}
(async()=>{
 let f=fixture(),ctx={};let base=f.s.load(ctx),next=f.s.portable(base);next.ipv6=true;next.smartAutoConvert=false;next.mixedPort=9090;
 assert.equal(next.allowLan,undefined);assert.equal(next.vpnWasConnected,undefined);
 let armed=0,committed=0,finished=0;
 await f.s.restoreBackup(ctx,next,async old=>{armed++;assert.equal(old.mixedPort,7890)},async()=>{committed++;return 'committed'},async()=> 'prior',async()=>{finished++});
 assert.equal(f.s.load(ctx).mixedPort,9090);assert.equal(f.s.load(ctx).smartAutoConvert,false);assert.equal(armed,1);assert.equal(committed,1);assert.equal(finished,1);
 f=fixture();f.s.load(ctx);f.fail(1);
 await assert.rejects(f.s.restoreBackup(ctx,next,async()=>{},async()=>{throw Error('must not commit')},async()=> 'prior',async()=>{}),/原资料已保留/);
 assert.equal(f.s.load(ctx).mixedPort,7890);assert.equal(f.disk.get('mixedPort'),7890);
 f=fixture();f.s.load(ctx);
 await f.s.restoreBackup(ctx,next,async()=>{},async()=>{throw Error('response lost')},async()=> 'committed',async()=>{});
 assert.equal(f.disk.get('mixedPort'),9090,'lost response follows real published pointer');
 f=fixture();f.s.load(ctx);
 await assert.rejects(f.s.restoreBackup(ctx,next,async()=>{},async()=>{throw Error('lost')},async()=> 'unknown',async()=>{}),/未确认/);
 await assert.rejects(f.s.idle(),/未确认/);
 // A new process repairs preferences before ordinary writers and startup can pass idle.
 f=fixture({journal:{token:'restore-test',outcome:'prior',preferences:next}});
 f.s.load({filesDir:'/synthetic'});await f.s.idle();assert.equal(f.disk.get('mixedPort'),9090);assert.equal(f.journal,null);
 f=fixture({journal:{token:'restore-test',outcome:'committed',preferences:next}});f.fail(1);f.s.load({filesDir:'/synthetic'});
 await assert.rejects(f.s.idle(),/未确认/);assert.ok(f.journal,'failed repair must retain journal');
 // Real component callbacks: one risk prompt, stale navigation and duplicate confirmation.
 let src=fs.readFileSync('cexing/entry/src/main/ets/pages/LocalBackupActions.ets','utf8');src=(src.slice(0,src.indexOf('  build()'))+'\n}').split('\n').map(l=>l.trimStart().startsWith('@')?l.replace(/@\w+(?:\([^\n)]*\))?\s*/g,''):l).join('\n').replace('export struct ','export class ');
 let dialog,restores=0,cancels=0,epoch=1,resolveRestore,paths=[];
 const modules={'../lib/LocalBackup':{LocalBackup:{restore:async()=>{restores++;await new Promise(r=>resolveRestore=r)},cancel:async()=>{cancels++}}},'../lib/VpnController':{VpnStatus:{Disconnected:0},VpnController:{status:0,needsStop:()=>false,configurationEpoch:()=>epoch}},'@kit.ArkUI':{promptAction:{showToast(){}}}};
 const sandbox={exports:{},require:n=>modules[n]??{},getContext:()=>({}),AlertDialog:{show:d=>dialog=d}};vm.runInNewContext(ts.transpileModule(src).outputText,sandbox);
 const p=new sandbox.exports.LocalBackupActions();p.navStack={getAllPathName:()=>paths};p.aboutToAppear();p.exportConfirm();assert.match(dialog.message,/凭据/);dialog.primaryButton.action();assert.equal(p.working,false);
 const preview={profiles:1,names:[{from:'one.yaml',to:'one (2).yaml'}],globalChanged:true};p.confirmRestore({},preview,p.generation);const stale=dialog;epoch++;await stale.secondaryButton.action();assert.equal(restores,0);
 p.confirmRestore({},preview,p.generation);const first=dialog.secondaryButton.action();await dialog.secondaryButton.action();assert.equal(restores,1);p.aboutToDisappear();resolveRestore();await first;assert.equal(p.working,false);
 console.log('PASS: backup settings commit/rollback/lost response/cold repair/failure journal, sensitive export consent, stale and duplicate restore UI');
})().catch(e=>{console.error(e);process.exitCode=1});
