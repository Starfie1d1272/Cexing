const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const code = ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/Settings.ets', 'utf8')).outputText;
function fixture(disk = new Map()) {
  const cache = new Map(disk);
  let puts = 0, flushes = 0, policy = {}, delayed = null;
  const p = {
    getSync: (key, fallback) => cache.has(key) ? cache.get(key) : fallback,
    putSync(key, value) {
      puts++;
      if (puts === policy.put || (policy.persistentPut && puts >= policy.put)) throw Error('put failure');
      cache.set(key, value);
    },
    flushSync() {
      flushes++;
      if (flushes === policy.flush || (policy.persistentFlush && flushes >= policy.flush)) throw Error('flush failure');
      disk.clear(); for (const [key, value] of cache) disk.set(key,value);
    },
    async flush() { if (delayed) { const gate = delayed; delayed = null; await gate; } this.flushSync(); }
  };
  const sandbox = {exports: {}, require: key => key === '@kit.ArkData' ?
    {preferences: {getPreferencesSync: () => p}} : key === './Logger' ? {Logger: {error() {}}} : {}};
  vm.runInNewContext(code, sandbox);
  return { hold() { let release; delayed = new Promise(resolve => { release = resolve; }); return release; }, settings: sandbox.exports.Settings, cache, disk,
    fail(value) { puts = 0; flushes = 0; policy = value; },
    cold() { return fixture(disk).settings.load({}).allowLan; }};
}
(async () => {
let f = fixture();
assert.equal(f.settings.load({}).allowLan,false);
f.cache.set('allowLan',true);
assert.equal(f.settings.load({}).allowLan,false,'legacy true is not consent');
await f.settings.save({},f.settings.load({}), ['ipv6']);
assert.equal(f.cold(),false);
await f.settings.setAllowLan({},true);
assert.equal(f.cold(),true);
await f.settings.save({},f.settings.load({}), ['ipv6']);
assert.equal(f.cold(),true);
// Every enable write and flush stage, with one-shot and continuing failure.
for (const kind of ['put','flush']) for (const stage of kind === 'put' ? [1,14,15,16,17] : [1,2,3]) for (const persistent of [false,true]) {
  f = fixture();
  f.fail({[kind]:stage, [kind === 'put' ? 'persistentPut' : 'persistentFlush']:persistent});
  await assert.rejects(() => f.settings.setAllowLan({},true));
  assert.equal(f.settings.load({}).allowLan,false, `enable ${kind}/${stage}/${persistent}`);
  assert.equal(f.cold(),false,'failed enable cannot invent a durable grant in this precommit failure fixture');
  f.fail({}); await f.settings.setAllowLan({},true);
  assert.equal(f.settings.load({}).allowLan,true);
  assert.equal(f.cold(),true);
}
// Durable previous consent must remain visibly possible after failed revocation.
// A new VM represents the app or VPN Extension with a distinct Preferences cache.
for (const kind of ['put','flush']) for (const stage of kind === 'put' ? [1,14,15,16] : [1]) for (const persistent of [false,true]) {
  f = fixture(); await f.settings.setAllowLan({},true);
  f.fail({[kind]:stage, [kind === 'put' ? 'persistentPut' : 'persistentFlush']:persistent});
  await assert.rejects(() => f.settings.setAllowLan({},false));
  assert.equal(f.settings.load({}).allowLan,true, `failed revoke ${kind}/${stage}/${persistent} must show prior consent`);
  assert.equal(f.cold(),true,'extension/new process still sees old durable consent');
  f.fail({}); await f.settings.setAllowLan({},false);
  assert.equal(f.settings.load({}).allowLan,false);
  assert.equal(f.cold(),false,'successful retry revokes across processes');
}
console.log('PASS: separate cache/disk and process VMs; every enable/revoke put/flush stage, continuing failure, prior-consent warning and durable retry');

// Ordinary batches must report every failure, restore cached reads and survive a fresh process.
for (const kind of ['put', 'flush']) for (const stage of kind === 'put' ? [1, 5, 14, 15, 20, 27] : [1]) {
  f = fixture();
  const s = f.settings.load({}); s.ipv6 = true; s.mixedPort = 9090;
  f.fail({ [kind]: stage });
  await assert.rejects(() => f.settings.save({}, s, ['ipv6', 'mixedPort']), /保存失败/);
  assert.equal(f.settings.load({}).ipv6, false);
  assert.equal(f.settings.load({}).mixedPort, 7890);
  assert.equal(fixture(f.disk).settings.load({}).ipv6, false);
  f.fail({}); await f.settings.save({}, s, ['ipv6', 'mixedPort']);
  assert.equal(fixture(f.disk).settings.load({}).mixedPort, 9090);
}
f = fixture();
const ipv6Edit = f.settings.load({}), portEdit = f.settings.load({});
ipv6Edit.ipv6 = true; portEdit.mixedPort = 9090;
const release = f.hold(); let done = false;
const first = f.settings.save({}, ipv6Edit, ['ipv6']).then(() => { done = true; });
await new Promise(resolve => setImmediate(resolve));
assert.equal(done, false); assert.equal(f.settings.load({}).ipv6, false, 'pending cache is not durable state');
const second = f.settings.save({}, portEdit, ['mixedPort']);
release(); await Promise.all([first, second]);
let cold = fixture(f.disk).settings.load({});
assert.equal(cold.ipv6, true); assert.equal(cold.mixedPort, 9090, 'queued scoped saves preserve unrelated fields');
const on = f.settings.load({}), off = f.settings.load({}); on.ipv6 = true; off.ipv6 = false;
await Promise.all([f.settings.save({}, on, ['ipv6']), f.settings.save({}, off, ['ipv6'])]);
assert.equal(fixture(f.disk).settings.load({}).ipv6, false, 'latest same-field intent wins');
const releaseLan = f.hold(); const ordinary = f.settings.save({}, f.settings.load({}), ['ipv6']);
await new Promise(resolve => setImmediate(resolve)); const grant = f.settings.setAllowLan({}, true);
assert.equal(f.cold(), false); releaseLan(); await Promise.all([ordinary, grant]); assert.equal(f.cold(), true);
await f.settings.setAllowLan({}, false); assert.equal(f.cold(), false);
console.log('PASS: ordinary put/flush failure, rollback, durable readback and retry');

// Persisted application scope recovery uses the production CAS writer and validator.
const vpnCode = ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/VpnController.ets', 'utf8')).outputText;
function scopeAPI(f) {
  const box = {exports:{}, require:key=>key==='./Settings'?{Settings:f.settings}:{}};
  vm.runInNewContext(vpnCode,box); return box.exports;
}
const ctx = {applicationInfo:{name:'test.bundle'}};
for (const mode of ['white','black']) {
  f=fixture(new Map([['accessMode',mode],['accessList',['sample.one','sample.two']]]));
  let api=scopeAPI(f);
  const revision=f.settings.applicationAccessRevision(ctx);
  await api.setVpnApplicationAccessSuspended(ctx,true,revision,()=>true);
  let restarted=fixture(f.disk); api=scopeAPI(restarted);
  let state=restarted.settings.load(ctx);
  assert.equal(state.accessMode,'all'); assert.equal(state.accessRestoreMode,mode);
  assert.deepEqual(Array.from(state.accessRestoreList),['sample.one','sample.two']);
  const edit=restarted.settings.load(ctx);edit.ipv6=true;
  await restarted.settings.save(ctx,edit,['ipv6']);
  await api.setVpnApplicationAccessSuspended(ctx,false,restarted.settings.applicationAccessRevision(ctx),()=>true);
  state=fixture(restarted.disk).settings.load(ctx);
  assert.equal(state.accessMode,mode);assert.deepEqual(Array.from(state.accessList),['sample.one','sample.two']);
  assert.equal(state.ipv6,true);
}
for (const kind of ['put','flush']) {
  f=fixture(new Map([['accessMode','white'],['accessList',['sample.one']]]));
  f.fail({[kind]:kind==='put'?20:1});
  await assert.rejects(scopeAPI(f).setVpnApplicationAccessSuspended(ctx,true,f.settings.applicationAccessRevision(ctx),()=>true));
  const state=fixture(f.disk).settings.load(ctx);assert.equal(state.accessMode,'white');assert.equal(state.accessRestoreMode,'');
}
f=fixture(new Map([['accessMode','all'],['accessList',['sample.one']],['accessRestoreMode','black'],['accessRestoreList',['sample.one']]]));
f.fail({flush:1});
await assert.rejects(scopeAPI(f).setVpnApplicationAccessSuspended(ctx,false,f.settings.applicationAccessRevision(ctx),()=>true));
assert.equal(fixture(f.disk).settings.load(ctx).accessMode,'all');
assert.equal(fixture(f.disk).settings.load(ctx).accessRestoreMode,'black','failed restore preserves recoverable snapshot');
f=fixture(new Map([['accessMode','black'],['accessList',['sample.one']]]));
let api=scopeAPI(f), rev=f.settings.applicationAccessRevision(ctx);
const repeated=await Promise.allSettled([api.setVpnApplicationAccessSuspended(ctx,true,rev,()=>true),api.setVpnApplicationAccessSuspended(ctx,true,rev,()=>true)]);
assert.deepEqual(repeated.map(x=>x.status),['fulfilled','rejected']);
const stale=f.settings.applicationAccessRevision(ctx);
await f.settings.editApplicationAccess(ctx,s=>{s.accessList=['sample.changed'];});
await assert.rejects(api.setVpnApplicationAccessSuspended(ctx,false,stale,()=>true),/已更改/);
assert.equal(f.settings.load(ctx).accessMode,'all');
f=fixture(new Map([['accessMode','all'],['accessRestoreMode','white'],['accessRestoreList',['test.bundle']]]));
await assert.rejects(scopeAPI(f).setVpnApplicationAccessSuspended(ctx,false,f.settings.applicationAccessRevision(ctx),()=>true));
assert.equal(f.settings.load(ctx).accessMode,'all','invalid or self-only saved whitelist must not activate');

// Legacy all+list records carry no trustworthy old mode; only explicit choice restores them.
for (const mode of ['white','black']) {
  f=fixture(new Map([['accessMode','all'],['accessList',['sample.legacy']]]));
  const api=scopeAPI(f), revision=f.settings.applicationAccessRevision(ctx);
  await assert.rejects(api.setVpnApplicationAccessSuspended(ctx,false,revision,()=>true));
  assert.equal(f.settings.load(ctx).accessMode,'all','legacy mode must never be inferred');
  await api.setVpnApplicationAccessSuspended(ctx,false,revision,()=>true,mode);
  const state=fixture(f.disk).settings.load(ctx);
  assert.equal(state.accessMode,mode);assert.equal(state.accessRestoreMode,mode);
  assert.deepEqual(Array.from(state.accessList),['sample.legacy']);
}

// Local recovery snapshots do not carry across a portable backup replacement.
f=fixture(new Map([['accessMode','all'],['accessRestoreMode','black'],['accessRestoreList',['sample.old']]]));
const backup=f.settings.portable(f.settings.load(ctx));backup.accessList=['sample.new'];
await f.settings.restoreBackup(ctx,backup,async()=>{},async()=>'committed',async()=>'prior',async()=>{});
cold=fixture(f.disk).settings.load(ctx);
assert.equal(cold.accessRestoreMode,'');assert.deepEqual(Array.from(cold.accessRestoreList),[]);
assert.deepEqual(Array.from(cold.accessList),['sample.new']);
// Corrupted optional snapshots are discarded on load without breaking ordinary writes.
for (const [mode,list] of [['unknown',[]],['white','broken'],['black',[42]],['white',Array(65).fill('sample.one')],['white',['a'.repeat(129)]]]) {
  f=fixture(new Map([['accessMode','all'],['accessRestoreMode',mode],['accessRestoreList',list]]));
  const state=f.settings.load(ctx);assert.equal(state.accessRestoreMode,'');
  state.ipv6=true;await f.settings.save(ctx,state,['ipv6']);
  assert.equal(fixture(f.disk).settings.load(ctx).ipv6,true);
  await assert.rejects(f.settings.editApplicationAccess(ctx,s=>{s.accessRestoreMode=mode;s.accessRestoreList=list;}),/设置值无效/);
}

// The real page fences confirmations and queued writes after cancellation/navigation.
const uiFixture=require('./ci/ui-fixtures.cjs');
let pageSource=fs.readFileSync('cexing/entry/src/main/ets/pages/NetworkSettingsPage.ets','utf8');
pageSource=pageSource.slice(0,pageSource.indexOf('  @Builder'))+'\n}';
pageSource=pageSource.split('\n').map(line=>line.trimStart().startsWith('@')?line.replace(/@\w+(?:\([^\n)]*\))?\s*/g,''):line).join('\n').replace('export struct ','export class ');
const pageCode=ts.transpileModule(pageSource).outputText;
f=fixture(new Map([['accessMode','black'],['accessList',['sample.one']]]));api=scopeAPI(f);
let dialog, routes=['network'];
const box={exports:{},getContext:()=>ctx,AlertDialog:{show:d=>{dialog=d;}},require:key=>
  key==='../lib/Settings'?{Settings:f.settings}:key==='../lib/VpnController'?api:key==='../lib/UiText'?uiFixture.module:key==='@kit.ArkUI'?{promptAction:{showToast(){}}}:{}};
Object.assign(box,uiFixture.globals);vm.runInNewContext(pageCode,box);
const page=new box.exports.NetworkSettingsPage();page.navStack={getAllPathName:()=>routes,pushPath:r=>routes.push(r.name)};
page.aboutToAppear();await new Promise(setImmediate);
page.restoreAll();dialog.primaryButton.action();dialog.secondaryButton.action();await f.settings.idle();
assert.equal(f.settings.load(ctx).accessMode,'black','cancelled callback cannot grant all');
page.restoreAll();routes=['network','traffic'];dialog.secondaryButton.action();await f.settings.idle();
assert.equal(f.settings.load(ctx).accessMode,'black','hidden page cannot grant all');routes=['network'];
page.restoreAll();dialog.secondaryButton.action();dialog.secondaryButton.action();await f.settings.idle();await new Promise(setImmediate);
assert.equal(f.settings.load(ctx).accessMode,'all');assert.equal(page.hasPrevious(),true);
page.restorePrevious();dialog.secondaryButton.action();await f.settings.idle();await new Promise(setImmediate);
assert.equal(f.settings.load(ctx).accessMode,'black');
const releaseScope=f.hold();const queued=f.settings.save(ctx,f.settings.load(ctx),['ipv6']);await new Promise(setImmediate);
page.restoreAll();dialog.secondaryButton.action();page.aboutToDisappear();releaseScope();await queued;await f.settings.idle();await new Promise(setImmediate);
assert.equal(f.settings.load(ctx).accessMode,'black','page exit before queued writer starts cancels grant');
for (const mode of ['white','black']) {
  f=fixture(new Map([['accessMode','all'],['accessList',['sample.legacy']]]));api=scopeAPI(f);
  routes=['network'];
  const legacyBox={...box,exports:{}};vm.runInNewContext(pageCode,legacyBox);
  const legacy=new legacyBox.exports.NetworkSettingsPage();legacy.navStack=page.navStack;
  legacy.aboutToAppear();await new Promise(setImmediate);
  legacy.chooseSavedScope();
  const cancelledSelector=dialog;
  cancelledSelector.cancel();
  cancelledSelector.primaryButton.action();cancelledSelector.secondaryButton.action();await f.settings.idle();
  assert.equal(f.settings.load(ctx).accessMode,'all','cancelled legacy selector retains all');
  legacy.chooseSavedScope();
  dialog[mode==='white'?'primaryButton':'secondaryButton'].action();
  const cancelledConfirmation=dialog;
  cancelledConfirmation.primaryButton.action();cancelledConfirmation.secondaryButton.action();await f.settings.idle();
  assert.equal(f.settings.load(ctx).accessMode,'all','cancelled direction confirmation cannot later activate');
  legacy.chooseSavedScope();
  dialog[mode==='white'?'primaryButton':'secondaryButton'].action();
  dialog.secondaryButton.action();await f.settings.idle();await new Promise(setImmediate);
  const restored=fixture(f.disk).settings.load(ctx);
  assert.equal(restored.accessMode,mode);
  assert.deepEqual(Array.from(restored.accessList),['sample.legacy']);
}
console.log('PASS: persisted white/black and explicit legacy recovery, cold restart, rollback, CAS, invalid lists and cancelled/hidden/queued confirmations');

})().catch(error => { console.error(error); process.exitCode = 1; });
