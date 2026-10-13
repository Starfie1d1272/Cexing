// Execute the production controller with synthetic service/IPC replies. No device claim.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const flush = () => new Promise(resolve => setImmediate(resolve));
function load(options = {}) {
  const probes = [], timers = [], calls = { bind: 0, start: 0, stop: 0, disconnect: [] };
  let callbacks, receipt = '', ready = true, tun = true, session = 'running-session', failRead = false;
  let resolveAuth;
  const auth = options.delayedAuth ? new Promise(r => { resolveAuth = r; }) : Promise.resolve();
  const settings = { accessMode: 'all', accessList: [], ipv6: false };
  const remote = { sendMessageRequest: async () => {
    if (failRead) throw Error('synthetic service loss');
    let strings = 0, booleans = 0;
    return { errCode: 0, reply: { readBoolean: () => ++booleans === 1 ? ready : tun,
      readString: () => ++strings === 1 ? '' : session } };
  } };
  const modules = {
    '@kit.NetworkKit': { vpnExtension: { startVpnExtensionAbility: () => { calls.start++; return auth; },
      stopVpnExtensionAbility: async () => { calls.stop++; } } },
    '@kit.CoreFileKit': { fileIo: { accessSync: () => receipt.length > 0, readTextSync: () => receipt } },
    './Logger': { Logger: { info() {}, warn() {}, error() {} } },
    './CoreApi': { CoreApi: { bindContext() {}, isAlive: () => new Promise(resolve => probes.push(resolve)) } },
    './Settings': { Settings: { load: () => settings, save() {} } },
    '@kit.IPCKit': { rpc: { MessageSequence: { create: () => ({ reclaim() {} }) }, MessageOption: class {} } },
    './ConnectionFailure': { ConnectionFailures: { classify: () => ({phase:'service'}), label: () => '连接服务不可用，请重试' } },
    './ProfileStore': { ProfileStore: { clearApplyUncertain() {} } }
  };
  const context = { filesDir: '/synthetic', applicationInfo: { name: 'test.bundle' },
    connectServiceExtensionAbility: (want, value) => {
      calls.bind++; callbacks = value;
      if (want.parameters.RECOVER_ONLY) assert.equal(want.parameters.VPN_CONFIG, undefined);
      else session = want.parameters.SESSION_ID;
      return options.id ?? 0;
    },
    disconnectServiceExtensionAbility: async id => {
      calls.disconnect.push(id);
      receipt = JSON.stringify({session: options.staleReceipt ? 'old-session' : session, completed: true});
    } };
  const host = { exports: {}, require: name => { assert.ok(name in modules, name); return modules[name]; },
    setTimeout: fn => { timers.push(fn); return timers.length; }, clearTimeout() {},
    Date: options.staleReceipt ? { now: () => 20000 * ++host.tick } : Date, tick:0 };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
    '../cexing/entry/src/main/ets/lib/VpnController.ets'),'utf8')).outputText, host);
  return { ...host.exports, context, probes, calls, timers, resolveAuth,
    connected: () => callbacks.onConnect({}, remote),
    lost: () => callbacks.onDisconnect(),
    set: v => { if ('ready' in v) ready=v.ready; if ('tun' in v) tun=v.tun;
      if ('session' in v) session=v.session; if ('failRead' in v) failRead=v.failRead; } };
}
async function recover(f) {
  let result;
  f.VpnController.recover(alive => {result=alive;}, f.context);
  f.probes.shift()(true); await flush(); f.connected(); await flush();
  return result;
}
(async () => {
  const f=load();
  assert.equal(await recover(f), true);
  assert.equal(f.VpnController.status,f.VpnStatus.Connected);
  assert.equal(f.VpnController.getTunCreateObserved(),true);
  assert.equal(f.calls.start,0,'cold recovery never authorizes or starts another TUN');
  assert.equal(await f.VpnController.stop(f.context),true,'recovered session supplies the matching cleanup identity');
  assert.deepEqual(f.calls.disconnect,[0],'zero is a legal binding identity');
  const repeated=load(); let old=0,newest;
  repeated.VpnController.recover(()=>old++,repeated.context);
  repeated.VpnController.recover(v=>newest=v,repeated.context);
  repeated.probes[0](true); repeated.probes[1](true); await flush(); repeated.connected(); await flush();
  assert.equal(old,0); assert.equal(newest,true); assert.equal(repeated.calls.bind,1);
  for (const fields of [{ready:false},{tun:false},{session:''}]) {
    const invalid=load();invalid.set(fields);assert.equal(await recover(invalid),false);
    assert.equal(invalid.VpnController.status,invalid.VpnStatus.Disconnected);
    assert.equal(invalid.VpnController.getLastStopCompleted(),false);
  }
  const stale=load({staleReceipt:true});await recover(stale);
  assert.equal(await stale.VpnController.stop(stale.context),false,'an old receipt cannot confirm this session');
  const late=load();let completed=0;
  late.VpnController.recover(()=>completed++,late.context);
  late.VpnController.cancelRecovery();late.probes[0](true);await flush();
  assert.equal(late.calls.bind,0);assert.equal(completed,0);
  const cancel=load({delayedAuth:true});cancel.VpnController.start(cancel.context);
  const stop=cancel.VpnController.stop(cancel.context);await flush();
  assert.equal(cancel.calls.stop,1,'cancel removes the system session immediately');
  assert.equal(cancel.VpnController.status,cancel.VpnStatus.Disconnecting);
  assert.equal(cancel.VpnController.stop(cancel.context),stop,'repeated stop shares completion');
  cancel.resolveAuth();assert.equal(await stop,true);
  assert.equal(cancel.calls.bind,0);assert.equal(cancel.calls.stop,2,'late authorization is reclaimed before reconnect');
  const lost=load();await recover(lost);
  lost.lost();assert.equal(lost.VpnController.status,lost.VpnStatus.Disconnected);
  assert.equal(lost.VpnController.getLastStopCompleted(),false,'service loss is not a confirmed stop');
  const mismatch=load();await recover(mismatch);mismatch.set({session:'different-process'});
  const checking=mismatch.VpnController.verify(mismatch.context);await flush();await checking;
  assert.equal(mismatch.VpnController.status,mismatch.VpnStatus.Disconnected,'health rejects a new process session');
  console.log('PASS: cold binding, legal ID zero, session identity, repeated recovery, cancellation, stale receipts and runtime loss');
})().catch(e=>{console.error(e);process.exitCode=1;});
