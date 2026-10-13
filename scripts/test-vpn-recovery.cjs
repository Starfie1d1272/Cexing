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
  const cleanupRequests = [];
  const nativeRequests = [];
  const remote = { sendMessageRequest: async (code, data) => {
    if (failRead) throw Error('synthetic service loss');
    if (code === 3) {
      if (options.delayedNative) return new Promise(resolve=>nativeRequests.push({session,resolve}));
      return {errCode:0,reply:{readString:()=>JSON.stringify(options.nativeSnapshot ?? {session,events:[],dropped:0})}};
    }
    if (code === 2) {
      const request = data.values[1];
      if (options.delayedCleanup) return new Promise(resolve => cleanupRequests.push({ request, resolve }));
      return { errCode: 0, reply: { readString: () => options.staleReceipt ? 'old-request' : request,
        readBoolean: () => !options.cleanupFailed && data.values[0] === session } };
    }
    let strings = 0, booleans = 0;
    return { errCode: 0, reply: { readBoolean: () => ++booleans === 1 ? ready : tun,
      readString: () => ++strings === 1 ? '' : session } };
  } };
  const phaseModule = {exports:{}};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,'../cexing/entry/src/main/ets/lib/VpnPhases.ets'),'utf8')).outputText,phaseModule);
  const modules = {
    './VpnPhases': phaseModule.exports,
    '@kit.NetworkKit': { vpnExtension: { startVpnExtensionAbility: () => { calls.start++; if (options.throwStart) throw (typeof options.throwStart === 'object' ? options.throwStart : Error('synthetic authorization failure')); return auth; },
      stopVpnExtensionAbility: async () => { calls.stop++; if (options.receiptOnSystemStop) receipt = JSON.stringify({session,completed:true}); if (options.failFirstStop && calls.stop === 1) throw Error('synthetic early stop failure'); } } },
    '@kit.CoreFileKit': { fileIo: { accessSync: () => receipt.length > 0, readTextSync: () => receipt } },
    './Logger': { Logger: { info() {}, warn() {}, error() {} } },
    './CoreApi': { CoreApi: { bindContext() {}, isAlive: () => new Promise(resolve => probes.push(resolve)) } },
    './Settings': { Settings: { load: () => settings, save() {} } },
    '@kit.IPCKit': { rpc: { MessageSequence: { create: () => ({values:[], writeString(value){this.values.push(value);}, reclaim() {} }) }, MessageOption: class {} } },
    './ConnectionFailure': { ConnectionFailures: { classify: () => ({phase:'service'}), label: () => '连接服务不可用，请重试' } },
    './ProfileStore': { ProfileStore: { clearApplyUncertain() {} } }
  };
  const context = { filesDir: '/synthetic', applicationInfo: { name: 'test.bundle' },
    connectServiceExtensionAbility: (want, value) => {
      calls.bind++; if (options.throwBind) throw Error('synthetic binding failure'); callbacks = value;
      if (want.parameters.RECOVER_ONLY) {
        assert.equal(want.parameters.VPN_CONFIG, undefined);
        if (options.autoBind) Promise.resolve().then(()=>value.onConnect({},remote));
      }
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
  return { ...host.exports, context, probes, calls, timers, resolveAuth, cleanupRequests, nativeRequests, options,
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
module.exports = { load, recover };
if (require.main === module) {
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
    assert.equal(invalid.VpnController.needsStop(),true);
    assert.equal(invalid.VpnController.start(invalid.context),false);
    assert.equal(invalid.calls.start,0,'unconfirmed recovered binding never authorizes a new session');
    assert.equal(await invalid.VpnController.stop(invalid.context),true,'partial/empty recovered identity stops via current IPC ACK');
    assert.equal(invalid.VpnController.needsStop(),false);
    invalid.VpnController.start(invalid.context);await flush();
    assert.equal(invalid.calls.start,1,'only confirmed cleanup permits a new explicit start');
  }
  const lateAck = load({delayedCleanup:true});await recover(lateAck);
  const stopping = lateAck.VpnController.stop(lateAck.context);await flush();
  assert.equal(lateAck.VpnController.stop(lateAck.context),stopping,'stop reentry shares the request');
  lateAck.timers.at(-1)();assert.equal(await stopping,false);
  lateAck.cleanupRequests[0].resolve({errCode:0,reply:{readString:()=>lateAck.cleanupRequests[0].request,readBoolean:()=>true}});
  await flush();assert.equal(lateAck.VpnController.needsStop(),true,'late ACK does not clear an already unknown stop');
  assert.equal(lateAck.VpnController.start(lateAck.context),false);
  lateAck.options.autoBind=true;
  const retried = lateAck.VpnController.stop(lateAck.context);await flush();
  assert.notEqual(lateAck.cleanupRequests[0].request,lateAck.cleanupRequests[1].request);
  lateAck.cleanupRequests[1].resolve({errCode:0,reply:{readString:()=>lateAck.cleanupRequests[1].request,readBoolean:()=>true}});
  assert.equal(await retried,true,'fresh explicit stop can confirm a previously late cleanup');
  const retryOptions = {throwBind:true}, retry = load(retryOptions);
  let firstResult;
  retry.VpnController.recover(v=>firstResult=v,retry.context);retry.probes.shift()(true);await flush();
  assert.equal(firstResult,false);
  retryOptions.throwBind=false;assert.equal(await recover(retry),true,'failed binding may retry without retaining a rejected attempt');
  assert.equal(retry.calls.bind,2);
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
  const earlyFailure=load({delayedAuth:true,failFirstStop:true});earlyFailure.VpnController.start(earlyFailure.context);
  const reclaim=earlyFailure.VpnController.stop(earlyFailure.context);await flush();
  assert.equal(earlyFailure.VpnController.status,earlyFailure.VpnStatus.Disconnecting);
  earlyFailure.resolveAuth();assert.equal(await reclaim,true);assert.equal(earlyFailure.calls.stop,2);
  const syncFailure=load({throwStart:true});syncFailure.VpnController.start(syncFailure.context);
  assert.equal(syncFailure.VpnController.status,syncFailure.VpnStatus.Disconnected,'synchronous authorization failure can retry');
  const lost=load({receiptOnSystemStop:true});await recover(lost);lost.options.autoBind=true;
  lost.lost();assert.equal(lost.VpnController.status,lost.VpnStatus.Disconnected);
  assert.equal(lost.VpnController.getLastStopCompleted(),false,'service loss is not a confirmed stop');
  assert.equal(lost.VpnController.start(lost.context),false);assert.equal(lost.calls.start,0);
  assert.equal(await lost.VpnController.stop(lost.context),true,'explicit disconnect retries system stop after binding loss and awaits the retained identity');
  const mismatch=load();await recover(mismatch);mismatch.set({session:'different-process'});
  const checking=mismatch.VpnController.verify(mismatch.context);await flush();await checking;
  assert.equal(mismatch.VpnController.status,mismatch.VpnStatus.Disconnected,'health rejects a new process session');
  console.log('PASS: cold binding, legal ID zero, session identity, repeated recovery, cancellation, stale receipts and runtime loss');
})().catch(e=>{console.error(e);process.exitCode=1;});

}
