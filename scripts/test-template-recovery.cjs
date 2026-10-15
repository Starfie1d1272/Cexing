// Actual template pages/models -> shared confirmation -> actual ProfileRecovery.
// All controller/storage ports are synthetic; no system VPN or socket is used.
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const ts=require('./ci/transpile-arkts.cjs'),ui=require('./ci/ui-fixtures.cjs');
const {resourceContext}=require('./ci/mock-profile-resources.cjs');
const ctx=resourceContext(),flush=()=>new Promise(setImmediate);
let discardDialog;
let unknown,active,status,session,epoch,choice,dialog,dialogs,stopOK,startOK,pendingShare,events,toasts,stopHold;
const reset=()=>{unknown=true;active='one.yaml';status=2;session='initial';epoch=1;choice={pending:''};
 dialog=null;dialogs=0;stopOK=true;startOK=true;pendingShare=false;events=[];toasts=[];stopHold=null;};
reset();
const controller={get status(){return status},needsStop:()=>false,trafficSession:()=>session,configurationEpoch:()=>epoch,
 stop:async(_ctx,_keep,force)=>{events.push(force?'stop-confirmed':'stop');if(stopHold)await stopHold.promise;
  if(!stopOK)return false;status=0;session='own-stop';epoch++;return true},
 start:()=>{events.push('start');status=1;return startOK}};
const store={isApplyUncertain:()=>unknown,getActiveFile:()=>active};
const mods={
 './ProfileStore':{ProfileStore:store},'./VpnController':{VpnController:controller,VpnStatus:{Disconnected:0,Connected:2}},
 './EffectiveVersions':{EffectiveVersions:{read:()=>({Profiles:{'one.yaml':{ID:'saved-version'}}}),editIntent:()=>null,regionPlan:()=>null}},
 './ProfileRegionChoices':{ProfileRegionChoices:{selector:()=>'',read:()=>choice}},
 './ProfileTransactions':{ProfileTransactions:{isBusy:()=>false,ensureActiveSmartPolicy:async()=>{events.push('prepare-saved-version')}}},
 './Settings':{Settings:{idle:async()=>{},isLanPersistenceUncertain:()=>false}},
 './AppRuntime':{AppRuntime:{cancelRestore:()=>events.push('cancel-auto-restore')}},
 '@kit.ArkUI':{promptAction:{showDialog:options=>{dialogs++;assert.match(options.message,/中断/);return new Promise(resolve=>dialog=resolve)},showToast:x=>toasts.push(x.message)}}
};
function lib(name){const box={exports:{},...ui.globals,require:key=>mods[key]??{}};
 vm.runInNewContext(ts.transpileModule(fs.readFileSync(`cexing/entry/src/main/ets/lib/${name}.ets`,'utf8')).outputText,box);return box.exports;}
mods['./ProfileRecovery']=lib('ProfileRecovery');
const feedback=lib('ProfileApplyFeedback'),recovery=lib('ProfileApplyRecovery');
mods['./ProfileApplyFeedback']=feedback;
const wizardModel=lib('TemplateWizardModel'),updates=lib('TemplateUpdates');
const pageMods={...mods,'../lib/UiText':ui.module,'../lib/ProfileApplyFeedback':feedback,'../lib/ProfileApplyRecovery':recovery,
 '../lib/ProfileImportInput':{ProfileImportInput:{hasPending:()=>pendingShare}},
 '../lib/TemplateWizardModel':wizardModel,'../lib/TemplateUpdates':updates,
 '../lib/AiProbeBinding':{AiProbeBinding:class{revision(){return ''}}}};
function page(name){let source=fs.readFileSync(`cexing/entry/src/main/ets/pages/${name}.ets`,'utf8');
 const cut=source.includes('  @Builder')?source.indexOf('  @Builder'):source.indexOf('  build()');
 source=(source.slice(0,cut)+'\n}').split('\n').map(line=>line.trimStart().startsWith('@')?
 line.replace(/@\w+(?:\([^\n)]*\))?\s*/g,''):line).join('\n').replace('export struct ','export class ');
 const box={exports:{},...ui.globals,AlertDialog:{show: options => { discardDialog=options; }},getContext:()=>ctx,require:key=>pageMods[key]??{}};
 vm.runInNewContext(ts.transpileModule(source).outputText,box);return box.exports[name];}
const classes=[page('TemplateWizard'),page('TemplateUpdateReview')];
function make(Page){const p=new Page();p.profileId='one.yaml';p.tabJump=-1;p.closed=0;p.reads=0;p.applies=0;
 p.navStack={clear:()=>{p.closed++;},pushPath:x=>{p.route=x.name}};
 p.editor={};p.source={};p.updateSource={available:()=>false};
 p.host={label:()=>'',load:async()=>{p.reads++;return{groups:['Pick'],selectors:['Pick'],current:{templateId:'original',version:1}}},
 preview:async()=>{p.reads++;return{ready:true,candidate:{templateId:'ai',version:1,entries:[]},conflicts:[],
 validation:{revision:'r',digest:'d',summary:''}}},apply:async()=>{p.applies++;return'saved'}};
 p.aboutToAppear();return p;}
(async()=>{
 for(const Page of classes){
  reset();let p=make(Page);await flush();assert.equal(p.reads,0,'persistent unknown blocks even a cold template read/preview');
  assert.equal(p.needsRecovery(),true);assert.equal(p.model.needsRepair(),true);
  assert.match(p.failureMessage(),/未确认/);
  let wait=p.recoverApply();await p.recoverApply();assert.equal(dialogs,1,'single confirmation');dialog({index:0});await wait;
  assert.deepEqual(events,[]);assert.equal(unknown,true);assert.equal(p.model.needsRepair(),true);
  wait=p.recoverApply();p.aboutToDisappear();dialog({index:1});await wait;
  assert.deepEqual(events,[],'leaving invalidates an outstanding confirmation');
  reset();p=make(Page);await flush();wait=p.recoverApply();active='other.yaml';dialog({index:1});await wait;
  assert.deepEqual(events,[],'a confirmation for a previous active subscription cannot recover the new one');
  reset();p=make(Page);await flush();let release;stopHold={promise:new Promise(resolve=>release=resolve)};
  wait=p.recoverApply();dialog({index:1});await flush();assert.ok(events.includes('stop-confirmed'));
  p.aboutToDisappear();release();await wait;assert.ok(!events.includes('start'),'late stop completion cannot start from a departed page');
  reset();p=make(Page);await flush();stopOK=false;wait=p.recoverApply();dialog({index:1});await wait;
  assert.ok(!events.includes('start'));assert.match(p.recoveryMessage,/恢复未完成/);assert.equal(unknown,true);assert.equal(p.closed,0);
  stopOK=true;events=[];wait=p.recoverApply();dialog({index:1});await wait;
  assert.deepEqual(events,['cancel-auto-restore','stop-confirmed','prepare-saved-version','start']);
  assert.equal(p.closed,1);assert.equal(p.tabJump,0);assert.equal(p.applies,0);
  assert.equal(unknown,true,'a start acceptance/toast must not clear the persistent runtime fence');
  assert.equal(p.model.needsRepair(),true,'a start acceptance must not unlock template publication');
  assert.match(toasts.at(-1),/正在/);p.aboutToDisappear();
  // Only an independently observed runtime/Store change permits reopening.
  unknown=false;status=2;choice={pending:''};p=make(Page);await flush();assert.equal(p.needsRecovery(),false);assert.ok(p.reads>0);
  p.aboutToDisappear();
  reset();unknown=false;choice={pending:'Pick'};p=make(Page);await flush();assert.match(p.failureMessage(),/已保存/);
  wait=p.recoverApply();dialog({index:0});await wait;assert.equal(p.applies,0);assert.equal(choice.pending,'Pick');p.aboutToDisappear();
  reset();p=make(Page);await flush();pendingShare=true;wait=p.recoverApply();dialog({index:1});await wait;
  assert.equal(p.closed,1);assert.equal(p.tabJump,-1,'a queued external import keeps its navigation priority');p.aboutToDisappear();
  reset();unknown=false;p=make(Page);await flush();p.model.setApplyFailure('selection-required');p.repairSelection();
  assert.equal(p.route,'zashboard');assert.deepEqual(events,[]);p.aboutToDisappear();
 }
 // Actual comparison page: candidate-only drafts have zero personal edits.
 reset(); unknown=false; status=0;
 let discards=0, closed=0, rev='draft-zero';
 const p=make(classes[1]); await flush();
 p.activeHost.discardRevision=()=>rev;
 p.activeHost.discard=async expected=>{assert.equal(expected,rev);discards++;rev='';};
 p.onClose=()=>closed++;
 p.discardDraft(); const first=discardDialog; p.discardDraft(); assert.equal(discardDialog,first);
 first.primaryButton.action(); await first.secondaryButton.action(); assert.equal(discards,0);
 p.discardDraft(); const late=discardDialog; p.aboutToDisappear(); await late.secondaryButton.action(); assert.equal(discards,0);
 p.aboutToAppear(); await flush(); p.discardDraft(); const stale=discardDialog; rev='foreign';
 await stale.secondaryButton.action(); assert.equal(discards,0);
 stale.cancel(); p.discardDraft(); const confirmed=discardDialog;
 await confirmed.secondaryButton.action(); await confirmed.secondaryButton.action();
 assert.equal(discards,1); assert.equal(closed,1);
 for(const [Model,method] of [[wizardModel.TemplateWizardModel,'inspect'],[updates.TemplateUpdateModel,'refresh']]){
  let calls=0;const m=new Model({load:async()=>({groups:[],selectors:[],current:{templateId:'original',version:1}}),preview:async()=>{calls++;},apply:async()=>{calls++;},label:()=>''},()=>{});
  m.setApplyFailure('unconfirmed');await m[method]();await m.apply();assert.equal(calls,0);
  m.setApplyFailure('committed-pending');await m[method]();await m.apply();assert.equal(calls,0);
  for(const [message,kind] of [['应用未确认，请重连恢复','unconfirmed'],['配置已保存，地区选择待重连恢复','committed-pending'],
   ['请先在代理面板选择可用节点，再关闭或切换地区策略','selection-required'],['private: synthetic-token','failed']]){
   let previews=0,applies=0;const valid={revision:'r',digest:'d',summary:'',ready:true,conflicts:[],
    candidate:{templateId:'ai',version:1,entries:[]},validation:{revision:'r',digest:'d',summary:''}};
   const model=new Model({load:async()=>({groups:[],selectors:[],current:{templateId:'original',version:1}}),
    preview:async()=>{previews++;return valid},apply:async()=>{applies++;throw Error(message)},label:()=>''},()=>{});
   if(model.load)await model.load();await model[method]();await model.apply();
   assert.equal(model.applyFailure,kind);assert.equal(model.preview,null);assert.ok(!model.error.includes('synthetic-token'));
   if(kind!=='failed'){await model[method]();await model.apply();assert.equal(previews,1);assert.equal(applies,1)}
  }
 }
 console.log('PASS: both real template recovery buttons call shared confirmation/stop/rebuild, protect cancel/leave/profile/repeat/import ownership and never clear unknown on startup acceptance');
})().catch(e=>{console.error(e);process.exitCode=1});
