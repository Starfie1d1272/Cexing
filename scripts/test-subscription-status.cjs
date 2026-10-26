// Synthetic protocol and actual Store/transaction/page lifecycle regression. No real origin.
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),ts=require('./ci/transpile-arkts.cjs'),ui=require('./ci/ui-fixtures.cjs');
const {SubscriptionInfo:info}=require('./ci/subscription-fixture.cjs'),{create}=require('./ci/profile-import-runtime.cjs');
const NOW=1800000000,GiB=1024**3;
const full=`upload=${GiB}; download=${GiB}; total=${888*GiB}; expire=${NOW+10*86400}`;
const parse=raw=>info.parse({'Subscription-UserInfo':raw},NOW);
const view=sub=>info.view(sub,true,NOW);
const fields=['upload','download','total','expire'];
const complete=parse(full);assert.equal(complete.validity.fetchedAt,NOW);assert.ok(fields.every(k=>complete.validity[k]));assert.match(view(complete).summary,/886.0 GiB/);assert.ok(!view(complete).summary.includes('GB'));
assert.match(view(parse('total=100')).summary,/总量.*剩余未提供/);assert.match(view(parse('expire='+(NOW+1))).summary,/1 天后到期/);assert.match(view(parse('expire='+(NOW-1))).expiry,/已过期/);assert.ok(!view(parse('expire='+NOW)).summary.includes('0 天'));
for(const raw of ['upload=Infinity; download=-1; total=NaN; expire=NaN','upload=; download= ; total=1e3; expire=0x10','upload=9007199254740992; download=1.5; total=-0; expire=8640000000001']){
 const x=parse(raw);assert.ok(fields.every(k=>!x.validity[k]));assert.equal(x.validity.header,'invalid');assert.equal(x.validity.fetchedAt,0);assert.match(view(x).updated,/未提供/);
}
assert.equal(info.parse({},NOW).validity.header,'missing');assert.equal(parse('').validity.header,'invalid');assert.equal(info.parse({'subscription-userinfo':123},NOW).validity.header,'invalid');
assert.equal(parse('total=1; total=2; total=1').validity.total,false);assert.equal(parse('total=1; total=Infinity; total=1').validity.total,false);assert.equal(parse('total=1; TOTAL=1').validity.total,true);
assert.equal(info.parse({'Subscription-UserInfo':'total=1','subscription-userinfo':'total=2'},NOW).validity.total,false);
const zero=parse('upload=0; download=0; total=0; expire=0');assert.ok(fields.every(k=>zero.validity[k]));assert.match(view(zero).summary,/已用尽/);assert.match(view(zero).expiry,/未提供/);assert.ok(!JSON.stringify(view(zero)).includes('永久'));
assert.match(view(parse('upload=20; download=0; total=10')).summary,/已超额/);assert.match(view(parse('upload=9007199254740991; download=9007199254740991; total=9007199254740991')).summary,/已超额/);
const legacy={upload:0,download:1,total:888*GiB,expire:NOW-1};assert.match(view(legacy).remaining,/未提供/);assert.match(view(legacy).summary,/已过期/);assert.match(view(legacy).updated,/未提供/);
assert.match(view({...legacy,upload:1}).remaining,/GiB/);assert.equal(info.known({...legacy,total:Infinity},'total'),false);assert.equal(info.view(complete,false,NOW).summary,'');
for(const limit of [Number.MAX_SAFE_INTEGER,0])assert.equal(parse(`total=${limit}`).validity.total,true);
const pageSource=fs.readFileSync('cexing/entry/src/main/ets/pages/ProfilePage.ets','utf8');
const row=pageSource.slice(pageSource.indexOf('  ProfileRow('),pageSource.indexOf('  DetailAction('));
const detail=pageSource.slice(pageSource.indexOf('  ProfileDetail('),pageSource.indexOf('  ImportEntry('));
assert.match(row,/Text\(this\.subscription\(p\)\.summary\)/,'the list must actually render the shared summary');
for(const field of ['usage','remaining','expiry'])assert.match(detail,new RegExp('Text\\(this\\.subscription\\(p\\)\\.'+field+'\\)'));
assert.match(detail,/Text\(this\.lastUpdated\(p.file\)\)/);assert.match(row,/accessibilityText\(this.rowAccessibility\(p\)\)/);
assert.ok(!/summary\)[^\n]*(?:maxLines|textOverflow|\.height\()/.test(row),'quota summary wraps at large font sizes');assert.match(row,/layoutWeight\(1\)/);assert.ok(!/\.height\(/.test(row),'long name and scaled text must not be clipped by fixed row height');
let clock=NOW*1000;
function loadPage(r,tx){
 let source=(pageSource.slice(0,pageSource.indexOf('  @Builder'))+'\n}').split('\n').map(l=>l.trimStart().startsWith('@')?l.replace(/@\w+(?:\([^\n)]*\))?\s*/g,''):l).join('\n').replace('export struct ','export class ');
 const mods={'../lib/UiText':ui.module,'../lib/SubscriptionInfo':{SubscriptionInfo:info},'../lib/ProfileStore':{ProfileStore:r.store},'../lib/ProfileTransactions':{ProfileTransactions:tx},'../lib/EffectiveVersions':r.modules['./EffectiveVersions'],
 '../lib/ProfileApplyFeedback':{ProfileApplyFeedback:{recovery:()=>'',classify:()=> 'failed'}},'../lib/ProfileImportInput':{ProfileImportInput:{take:()=>null,release(){},hasPending:()=>false}},'@kit.ArkUI':{promptAction:{showToast(){}}}};
 const box={exports:{},...ui.globals,setTimeout,clearTimeout,Date:class extends Date{static now(){return clock}},getContext:()=>r.ctx,require:n=>mods[n]??{}};
 vm.runInNewContext(ts.transpileModule(source).outputText,box);const p=new box.exports.ProfilePage();p.rootVisible=true;p.currentVisibleTab=1;p.profileRevision=0;p.navStack={getAllPathName:()=>[],pop(){}};return p;
}
function wireTransaction(r){
 const versions=r.modules['./EffectiveVersions'].EffectiveVersions;let id=0;
 versions.overlay=()=>'';versions.regionPlan=()=>null;versions.stage=async(_,file,original,overlay,metadata)=>{const version={ID:`quota-${++id}`,Path:`/files/profile-versions/quota-${id}/config.yaml`,ProfileID:file};r.put(version.Path,original);r.put(`/files/profile-versions/${version.ID}/original.yaml`,original);r.put(`/files/profile-versions/${version.ID}/source.json`,JSON.stringify({Metadata:metadata}));return{version,receipt:''}};
 versions.commit=async(_,v,expected,active)=>{r.state={Current:active?v:r.state?.Current??null,Profiles:{...r.state?.Profiles,[v.ProfileID]:v}};r.put('/files/profile-versions/state.json',JSON.stringify(r.state))};versions.collect=async()=>{};
 Object.assign(r.modules,{'./ProfileStore':{ProfileStore:r.store},'./Settings':{Settings:{load:()=>({autoUpdate:true,autoUpdateIntervalHours:24}),idle:async()=>{}}},'./CoreValidator':{CoreValidator:{prepareResources:async()=>{}}},'./CoreApi':{CoreApi:{isAlive:async()=>true}},'./VpnController':{VpnStatus:{Disconnected:0},VpnController:{status:0,holdConfiguration:()=>()=>{},configurationEpoch:()=>0}},'./ProfileRegionChoices':{ProfileRegionChoices:{selector:()=>'',prepare:async()=>({state:null})}}});
 return r.load('./ProfileTransactions').ProfileTransactions;
}
(async()=>{
 const r=create();r.clock=()=>clock;
 const scenarios=[['sUBSCRIPTION-uSERiNFO',full,'present'],['Subscription-Userinfo','total=123','present'],['SUBSCRIPTION-USERINFO',`expire=${NOW-1}`,'present'],['subscription-userinfo','upload=0; download=0; total=0; expire=0','present'],['subscription-userinfo','total=Infinity','invalid'],[null,null,'missing']];
 for(let i=0;i<scenarios.length;i++){const [key,value,state]=scenarios[i];r.headers=key?{[key]:value}:{};const file=await r.store.importFromUrl(r.ctx,`https://example.invalid/case-${i}.yaml`);const stored=r.store.getMeta(r.ctx)[file];assert.equal(stored.sub.validity.header,state);assert.equal(stored.sub.validity.fetchedAt,state==='present'?NOW:0);assert.ok(JSON.parse(r.text('/files/profiles/meta.json'))[file].sub.validity);}
 r.headers={'Subscription-UserInfo':full};const file=await r.store.importFromUrl(r.ctx,'https://example.invalid/primary.yaml');
 const tx=wireTransaction(r);const p=loadPage(r,tx);p.aboutToAppear();const item=p.profiles.find(x=>x.file===file);assert.match(p.subscription(item).summary,/886.0 GiB/);
 // Execute the actual text expressions present in each builder with real persisted metadata.
 const rowExpression=row.match(/Text\((this\.subscription\(p\)\.summary)\)/)[1];assert.match(Function('p','return '+rowExpression).call(p,item),/886.0 GiB/);
 for(const field of ['usage','remaining','expiry'])assert.ok(Function('p','return this.subscription(p).'+field).call(p,item).length>0);
 const unicode={...item,name:'超长订阅😀'.repeat(50)};assert.ok(p.rowAccessibility(unicode).startsWith(unicode.name));assert.ok(p.rowAccessibility(unicode).includes(p.subscription(item).summary));
 const initialStamp=r.store.getMeta(r.ctx)[file].sub.validity.fetchedAt;const beforeKey=p.detailKey(item);
 clock+=12*86400*1000;
 // Actual EntryAbility foreground notification, not an artificial new metadata time.
 const abilitySource=fs.readFileSync('cexing/entry/src/main/ets/entryability/EntryAbility.ets','utf8');const box={exports:{},Date:class extends Date{static now(){return clock}},AppStorage:{setOrCreate:(key,value)=>{assert.equal(key,'subscriptionStatusEpoch');p.subscriptionStatusEpoch=value;p.onSubscriptionForeground()}},require:n=>n==='@kit.AbilityKit'?{UIAbility:class{}}:n==='../lib/AppRuntime'?{AppRuntime:{foreground(){}}}:{}};vm.runInNewContext(ts.transpileModule(abilitySource).outputText,box);new box.exports.default().onForeground();assert.match(p.subscription(item).summary,/已过期/);assert.notEqual(p.detailKey(item),beforeKey);assert.equal(r.store.getMeta(r.ctx)[file].sub.validity.fetchedAt,initialStamp);
 r.headers={'SUBSCRIPTION-USERINFO':`upload=0; download=${3*GiB}; total=${888*GiB}; expire=${Math.floor(clock/1000)+86400}`};await p.updateProfile(item);assert.match(p.subscription(item).summary,/885.0 GiB/);const success=r.store.getMeta(r.ctx)[file];assert.equal(success.sub.validity.fetchedAt,clock/1000);
 clock+=60000;await tx.edit(r.ctx,file,'proxies: [synthetic edited]');p.refresh();assert.equal(r.store.getMeta(r.ctx)[file].sub.validity.fetchedAt,success.sub.validity.fetchedAt,'local edits cannot refresh service information time');
 const persisted=JSON.stringify(r.store.getMeta(r.ctx)[file]);r.code=503;clock+=3600*1000;await assert.rejects(tx.update(r.ctx,file),/HTTP 503/);assert.equal(JSON.stringify(r.store.getMeta(r.ctx)[file]),persisted);
 // Automatic update uses that same real transaction and retains old source info/time on failure.
 r.put('/files/profiles/active.txt',file);r.state.Current=r.state.Profiles[file];r.put('/files/profile-versions/state.json',JSON.stringify(r.state));const auto=r.load('./AutoUpdater').AutoUpdater;await auto.checkAndRun(r.ctx,true);assert.equal(JSON.stringify(r.store.getMeta(r.ctx)[file]),persisted);assert.ok(r.store.updateState(r.ctx,file).failedAt>0);
 r.code=200;r.headers={};await tx.update(r.ctx,file);p.refresh();const absent=r.store.getMeta(r.ctx)[file];assert.equal(absent.sub.validity.header,'missing');assert.equal(absent.sub.validity.fetchedAt,0);assert.match(p.subscription(item).remaining,/未提供/);assert.match(p.lastUpdated(file),/未提供/);assert.ok(absent.updatedAt>success.updatedAt,'configuration update time remains separate from quota observation');
 // Cold module/page reads retain the same receipt and unknown state, without touching raw input.
 r.state=JSON.parse(r.text('/files/profile-versions/state.json'));delete r.modules['./ProfileStore'];r.store=r.load('./ProfileStore').ProfileStore;const reopened=loadPage(r,tx);reopened.aboutToAppear();assert.match(reopened.subscription(item).summary,/未提供/);assert.equal(r.store.getMeta(r.ctx)[file].sub.validity.fetchedAt,0);
 const local=r.store.importContent(r.ctx,'local','proxies: [synthetic]');reopened.refresh();assert.equal(reopened.subscription(reopened.profiles.find(x=>x.file===local)).summary,'');
 // Legacy source metadata is read conservatively in-place; no migration clears files.
 const legacyFile=await r.store.importFromUrl(r.ctx,'https://example.invalid/legacy.yaml');const all=JSON.parse(r.text('/files/profiles/meta.json'));all[legacyFile].sub=legacy;r.put('/files/profiles/meta.json',JSON.stringify(all));reopened.refresh();const legacyItem=reopened.profiles.find(x=>x.file===legacyFile);assert.match(reopened.subscription(legacyItem).remaining,/未提供/);assert.match(reopened.lastUpdated(legacyFile),/未提供/);r.headers={'subscription-userinfo':full};await tx.update(r.ctx,legacyFile);reopened.refresh();assert.equal(r.store.getMeta(r.ctx)[legacyFile].sub.validity.upload,true);
 p.aboutToDisappear();reopened.aboutToDisappear();
 console.log('PASS: actual case-insensitive subscription import/update/persistence/foreground/cold reentry, finite fields and zero/unknown, quota/expiry list/detail wiring, safe metadata age and automatic failure retention; synthetic clock/origin only');
})().catch(e=>{console.error(e);process.exitCode=1});
