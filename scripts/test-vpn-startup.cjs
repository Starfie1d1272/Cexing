// 用法：source scripts/env.sh && node scripts/test-vpn-startup.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const flush = () => new Promise(resolve => setImmediate(resolve));
const logger = { Logger: { info() {}, warn() {}, error() {} } };
const failureSource = fs.readFileSync(path.join(__dirname, '../cexing/entry/src/main/ets/lib/ConnectionFailure.ets'), 'utf8');
const failureCode = ts.transpileModule(failureSource, { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
} }).outputText;
const failureModule = { exports: {} };
vm.runInNewContext(failureCode, failureModule);
const failures = failureModule.exports.ConnectionFailures;
const secret = 'https://private.example/token?secret=abc';
const bounded = failures.classify('core-start', `dial ${secret}: errno=111`);
const summary = failures.summary('disconnected', 'failed', bounded, '0.1.0+1', true, false);
assert.equal(bounded.category, 'network');
assert.equal(bounded.code, 0, 'Numeric fields from raw text must never be exported as system status');
assert.equal(failures.systemCode('service', 111).code, 111);
assert.ok(!summary.includes('private.example') && !summary.includes('secret=abc'));
assert.ok(summary.includes('request_forwarding=unverified'));
assert.ok(summary.includes('app_version=0.1.0+1'));
assert.ok(summary.includes('system_session=tun-create-resolved'));
assert.ok(summary.includes('kernel_readiness=not-reported'));
const missing = failures.summary('connected', 'not-run', null);
assert.ok(missing.includes('system_session=not-observed'));
assert.ok(missing.includes('kernel_readiness=not-reported'), 'Connected must not infer core readiness');
assert.equal(failures.decode(JSON.stringify({ phase: 'core-start', category: secret, code: 3 })), null);
function load(relative, modules, timers = [], clock = Date) {
  const source = fs.readFileSync(path.join(__dirname, '../cexing/entry/src/main/ets', relative), 'utf8');
  const output = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
  const context = { exports: {}, require: name => {
    assert.ok(name in modules, `Missing mock: ${name}`);
    return modules[name];
  }, setTimeout: fn => { timers.push(fn); }, Date: clock, Promise, Uint8Array, Object, JSON };
  vm.runInNewContext(output, context);
  return context.exports;
}
async function testClient(mode) {
  let cleared = 0;
  let callbacks;
  let session = '';
  let activeSession = '';
  let stopReceipt = '';
  let ready = false;
  let error = '';
  const timers = [];
  const settings = { accessMode: 'all', accessList: [], ipv6: false, vpnWasConnected: false };
  const context = {
    filesDir: '/private', applicationInfo: { name: 'test.bundle' },
    connectServiceExtensionAbility: (want, value) => {
      callbacks = value; session = want.parameters.SESSION_ID; activeSession = session; return 1;
    },
    disconnectServiceExtensionAbility: async () => {
      stopReceipt = JSON.stringify({ session: mode === 'stale-receipt' ? 'old-session' : activeSession,
        completed: mode !== 'cleanup-failed' });
    }
  };
  const modules = {
    '@kit.NetworkKit': { vpnExtension: { startVpnExtensionAbility: async () => {},
      stopVpnExtensionAbility: async () => { if (mode === 'stop-failed') throw Error('synthetic stop failure'); } } },
    '@kit.CoreFileKit': { fileIo: { accessSync: () => stopReceipt.length > 0,
      readTextSync: () => stopReceipt } }, './Logger': logger,
    './ConnectionFailure': failureModule.exports,
    './CoreApi': { CoreApi: { bindContext() {} } }, './Settings': { Settings: { load: () => settings, save() {} } },
    './ProfileStore': { ProfileStore: { clearApplyUncertain: () => { cleared++; } } },
    '@kit.IPCKit': { rpc: { MessageSequence: { create: () => ({ reclaim() {} }) }, MessageOption: class {} } }
  };
  let clockTick = 0;
  const clock = mode === 'stale-receipt' ? { now: () => (clockTick += 20000) } : Date;
  const { VpnController: controller, VpnStatus } = load('lib/VpnController.ets', modules, timers, clock);
  const remote = { sendMessageRequest: async () => {
    let strings = 0;
    let booleans = 0;
    return { errCode: 0, reply: {
      readBoolean: () => ++booleans === 1 ? ready : true,
      readString: () => ++strings === 1 ? error : session
    } };
  } };
  let notifications = 0;
  let failureAtDisconnect = '';
  const pageListener = () => { notifications++; };
  controller.onChanged(status => {
    if (status === VpnStatus.Disconnected) failureAtDisconnect = controller.lastStartError;
  });
  controller.onChanged(pageListener);
  controller.onChanged(pageListener);
  controller.start(context);
  assert.equal(notifications, 1, 'Page observer registration must be idempotent');
  controller.offChanged(pageListener);
  await flush();
  callbacks.onConnect({}, remote);
  await flush();
  assert.equal(controller.status, VpnStatus.Connecting, 'Service connection must not claim kernel readiness');
  assert.equal(controller.getTunCreateObserved(), true);
  assert.equal(controller.getKernelReadyReported(), false);
  assert.equal(settings.vpnWasConnected, false);
  if (mode === 'ready') {
    ready = true;
    timers.shift()();
    await flush();
    assert.equal(controller.status, VpnStatus.Connected);
    assert.equal(controller.getKernelReadyReported(), true);
    assert.equal(settings.vpnWasConnected, true);
  } else if (mode === 'error') {
    error = failures.encode(session, failures.classify('core-start', 'synthetic config error: secret.example'));
    timers.shift()();
    await flush();
    assert.equal(controller.status, VpnStatus.Disconnected);
    assert.equal(controller.lastStartFailure.category, 'configuration');
    assert.ok(!controller.lastStartError.includes('secret.example'));
    assert.equal(failureAtDisconnect, controller.lastStartError, 'Failure must be stored before disconnect notification');
  } else if (mode === 'stale') {
    session = 'old-session';
    ready = true;
    timers.shift()();
    await flush();
    assert.equal(controller.status, VpnStatus.Disconnected, 'A ready response from another session must be rejected');
    assert.equal(controller.lastStartFailure.phase, 'readiness');
  } else {
    const stopped = await controller.stop(context);
    assert.equal(stopped, mode !== 'stop-failed' && mode !== 'cleanup-failed' && mode !== 'stale-receipt',
      'Stop result must require matching extension cleanup and system stop completion');
    assert.equal(cleared, stopped ? 1 : 0, 'only a confirmed stop may clear the uncertain config marker');
    ready = true;
    timers.shift()();
    await flush();
    assert.equal(controller.status, VpnStatus.Disconnected, 'Late readiness must not reconnect after stop');
    assert.equal(settings.vpnWasConnected, false);
  }
  assert.equal(notifications, 1, 'Detached page must not receive late status changes');
}
async function testExtension() {
  let complete;
  let stopCount = 0;
  let destroyCount = 0;
  let prepared = 0;
  let brokenPointer = false;
  const files = new Map();
  const pending = new Promise(resolve => { complete = resolve; });
  const connection = { create: async () => 32, protectProcessNet: async () => {},
    destroy: async () => { destroyCount++; } };
  const modules = {
    '@kit.NetworkKit': { VpnExtensionAbility: class {}, vpnExtension: { createVpnConnection: () => connection } },
    '@kit.IPCKit': { rpc: { RemoteObject: class {} } },
    '@kit.CoreFileKit': { fileIo: { accessSync: () => false, openSync: path => ({ fd: path }),
      writeSync: (fd, value) => files.set(fd, value), closeSync() {},
      renameSync: (from, to) => files.set(to, files.get(from)), OpenMode: {} } },
    'libentry.so': { __esModule: true, default: { initCore: async () => { assert.ok(prepared > 0, 'Prepare static assets before Controller initialization'); return ''; }, startTun: () => pending,
      stopCore: async () => { stopCount++; } } },
    '../lib/CoreApi': { CoreApi: { bindContext() {} } },
    '../lib/ZashboardAssets': { ZashboardAssets: { prepare: async () => { prepared++; return { directory: '', error: 'synthetic missing panel' }; } } },
    '../lib/Logger': logger, '../lib/ConnectionFailure': failureModule.exports,
    '../lib/ProfileStore': { ProfileStore: { getActiveContent: () => 'proxies: []' } },
    '../lib/EffectiveVersions': { EffectiveVersions: { read: () => {
      if (brokenPointer) throw Error('synthetic invalid effective pointer');
      return null;
    } } },
    '../lib/Settings': { Settings: { load: () => ({}) } }, '@kit.ArkTS': { util: {} }
  };
  const Extension = load('vpnability/CexingVpnAbility.ets', modules).default;
  const extension = new Extension();
  extension.context = { filesDir: '/private', resourceManager: { getRawFileContent: async () => new Uint8Array(16) } };
  extension.onCreate();
  const remote = extension.onConnect({ parameters: { VPN_CONFIG: {}, SESSION_ID: 'fixture-1' } });
  assert.ok(remote && typeof remote.then !== 'function', 'onConnect must return synchronously');
  await flush();
  let reportedReady;
  const reportedStrings = [];
  const reportedBooleans = [];
  remote.onRemoteMessageRequest(1, {}, { writeBoolean: value => { reportedReady = value; reportedBooleans.push(value); },
    writeString: value => reportedStrings.push(value) }, {});
  assert.equal(reportedBooleans[0], false);
  assert.equal(reportedBooleans[1], true, 'TUN create is observed separately from core readiness');
  assert.equal(reportedStrings[1], 'fixture-1');
  extension.onDisconnect();
  await flush();
  assert.equal(destroyCount, 1, 'Stop must remove system VPN while initialization is pending');
  complete('');
  await flush();
  assert.equal(stopCount, 1, 'Stop must clean up a late kernel startup');
  assert.equal(JSON.parse(files.get('/private/last_stop_result.json')).completed, true,
    'Extension receipt must follow the awaited native stop');
  const restarted = extension.onConnect({ parameters: { VPN_CONFIG: {} } });
  await flush();
  restarted.onRemoteMessageRequest(1, {}, { writeBoolean: value => { reportedReady = value; }, writeString() {} }, {});
  assert.equal(reportedReady, true, 'The same extension must allow restart after cleanup despite unavailable panel resources');
  assert.equal(prepared, 2);
  brokenPointer = true;
  await assert.rejects(extension.buildCoreConfig(), /invalid effective pointer/,
    'broken effective pointer must not silently start the built-in fallback');
}
(async () => {
  await testClient('ready');
  await testClient('error');
  await testClient('stale');
  await testClient('cancel');
  await testClient('stop-failed');
  await testClient('cleanup-failed');
  await testClient('stale-receipt');
  await testExtension();
  console.log('PASS: readiness, error propagation, cancellation and extension lifecycle scenarios');
})().catch(error => { console.error(error); process.exitCode = 1; });
