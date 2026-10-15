const uiFixture = require('./ci/ui-fixtures.cjs');
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
const failureModule = { exports: {}, ...uiFixture.globals, require: key => { assert.ok(key.endsWith('/UiText')); return uiFixture.module; } };
vm.runInNewContext(failureCode, failureModule);
const failures = failureModule.exports.ConnectionFailures;
const phaseModule = {exports:{}};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,'../cexing/entry/src/main/ets/lib/VpnPhases.ets'),'utf8')).outputText,phaseModule);
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
  }, setTimeout: fn => { timers.push(fn); }, clearTimeout() {}, Date: clock, Promise, Uint8Array, Object, JSON };
  vm.runInNewContext(output, context);
  return context.exports;
}
const realSettings = load('lib/Settings.ets', { './BackupJournal': {}, '@kit.ArkData': {}, './Logger': logger });
const {AppSettings,Settings} = realSettings;
const baseline = new AppSettings();
const equivalent = new AppSettings(); equivalent.accessMode='black'; equivalent.accessList=['test.bundle','test.bundle'];
assert.equal(Settings.restartKey(baseline,'test.bundle'),Settings.restartKey(equivalent,'test.bundle'), 'all and empty effective exclusions are equal');
equivalent.accessList=['other.app','sample.app','other.app','test.bundle'];
const reordered = Object.assign(new AppSettings(),{accessMode:'black',accessList:['sample.app','other.app']});
assert.equal(Settings.restartKey(equivalent,'test.bundle'),Settings.restartKey(reordered,'test.bundle'), 'order, duplicates and self do not change the effective system scope');
reordered.accessMode='white';assert.notEqual(Settings.restartKey(equivalent,'test.bundle'),Settings.restartKey(reordered,'test.bundle'));
async function testClient(mode, accessMode = 'all', accessList = [], ipv6 = false) {
  let cleared = 0;
  let callbacks;
  let session = '';
  let activeSession = '';
  let stopReceipt = '';
  let ready = false;
  let error = '';
  const timers = [];
  const settings = Object.assign(new realSettings.AppSettings(), { accessMode, accessList, ipv6, vpnWasConnected: false });
  const context = {
    filesDir: '/private', applicationInfo: { name: 'test.bundle' },
    connectServiceExtensionAbility: (want, value) => {
      const config = want.parameters.VPN_CONFIG;
      assert.equal(config.isIPv6Accepted,ipv6);
      assert.equal(config.addresses.length,ipv6 ? 2 : 1);
      assert.equal(config.routes.some(r=>r.destination.address.family===2),ipv6);
      if (ipv6) {
        assert.equal(config.addresses[1].address.address,'fdfe:dcba:9876::1');
        assert.equal(config.addresses[1].prefixLength,126);
        assert.ok(config.dnsAddresses.includes('fdfe:dcba:9876::2'));
      }
      assert.ok(!(config.trustedApplications && config.blockedApplications), 'SDK application fields must be exclusive');
      if (accessMode === 'white') assert.deepEqual(Array.from(config.trustedApplications), ['sample.app']);
      else assert.ok(config.blockedApplications.includes('test.bundle'), 'host remains excluded');
      callbacks = value; session = want.parameters.SESSION_ID; activeSession = session; return mode === 'zero' ? 0 : 1;
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
    './ConnectionFailure': failureModule.exports, './VpnPhases': phaseModule.exports,
    './CoreApi': { CoreApi: { bindContext() {} } }, './Settings': { Settings: { restartKey: realSettings.Settings.restartKey, isLanPersistenceUncertain: () => false, idle: async () => {}, load: () => settings, save() {} } },
    './ProfileStore': { ProfileStore: { clearApplyUncertain: () => { cleared++; } } },
    '@kit.IPCKit': { rpc: { MessageSequence: { create: () => ({values:[],writeString(value){this.values.push(value);},reclaim() {} }) }, MessageOption: class {} } }
  };
  let clockTick = 0;
  const clock = mode === 'stale-receipt' ? { now: () => (clockTick += 20000) } : Date;
  const { VpnController: controller, VpnStatus } = load('lib/VpnController.ets', modules, timers, clock);
  const remote = { sendMessageRequest: async (code, data) => {
    if (code === 2) return {errCode:0,reply:{readString:()=>mode === 'stale-receipt' ? 'old-request' : data.values[1],
      readBoolean:()=>mode !== 'cleanup-failed' && data.values[0] === session}};
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
    settings.logToFile = false; // saved after bind, before readiness
    ready = true;
    timers.shift()();
    await flush();
    assert.equal(controller.status, VpnStatus.Connected);
    assert.equal(controller.getKernelReadyReported(), true);
    assert.equal(settings.vpnWasConnected, true);
    assert.equal(controller.settingsNeedReconnect(context), true, 'readiness acknowledges the sent snapshot, not later saved preferences');
    settings.logToFile = true;
    assert.equal(controller.settingsNeedReconnect(context), false, 'reverting clears the actual difference');
    settings.keepAlive = false; settings.mode = 'global'; settings.autoRestore = false;
    assert.equal(controller.settingsNeedReconnect(context), false, 'immediate preferences do not create a restart prompt');
    settings.ipv6 = !ipv6;
    assert.equal(controller.settingsNeedReconnect(context), true);
    settings.ipv6 = ipv6;
    assert.equal(controller.settingsNeedReconnect(context), false);
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
async function testExtension(failStop = false, lateCreate = false, protection = 'ok') {
  let failNative = failStop;
  let completeCreate;
  let complete;
  let stopCount = 0;
  let destroyCount = 0;
  let prepared = 0;
  let brokenPointer = false;
  let modelPrepared = 0;
  let geoPrepared = 0;
  const files = new Map();
  const pending = new Promise(resolve => { complete = resolve; });
  const connection = { create: () => lateCreate ? new Promise(resolve => { completeCreate = resolve; }) : Promise.resolve(32), protectProcessNet: protection === 'missing' ? undefined : async () => { if (protection === 'failed') throw Error('synthetic protection failed'); },
    destroy: async () => { destroyCount++; } };
  const modules = {
    '@kit.BasicServicesKit': {deviceInfo:{sdkApiVersion:protection === 'old' ? 21 : 26}},
    '@kit.NetworkKit': { VpnExtensionAbility: class {}, vpnExtension: { createVpnConnection: () => connection } },
    '@kit.IPCKit': { rpc: { RemoteObject: class {} } },
    '@kit.CoreFileKit': { fileIo: { accessSync: () => false, openSync: path => ({ fd: path }),
      writeSync: (fd, value) => files.set(fd, value), closeSync() {},
      renameSync: (from, to) => files.set(to, files.get(from)), OpenMode: {} } },
    'libentry.so': { __esModule: true, default: { initCore: async () => { assert.ok(prepared > 0, 'Prepare static assets before Controller initialization'); assert.ok(modelPrepared > 0, 'Prepare verified model before core initialization'); assert.ok(geoPrepared > 0, 'Repair verified GeoData before core initialization'); return ''; }, startTun: () => pending,
      stopCore: async () => { stopCount++; if (failNative) throw Error('synthetic native stop failure'); } } },
    '../lib/CoreApi': { CoreApi: { bindContext() {} } },
    '../lib/ZashboardAssets': { ZashboardAssets: { prepare: async () => { prepared++; return { directory: '', error: 'synthetic missing panel' }; } } },
    '../lib/GeoDataAssets': { GeoDataAssets: { inspect: async () => 'invalid', restore: async (_, token, permit) => { assert.ok(!token.cancelled); geoPrepared++; } } },
    '../lib/SmartModelAssets': { SmartModelAssets: { prepare: async () => { modelPrepared++; return { state: 'missing', message: 'synthetic model absent' }; } } },
    '../lib/Logger': logger, '../lib/VpnPhases': phaseModule.exports, '../lib/ConnectionFailure': failureModule.exports,
    '../lib/ProfileStore': { ProfileStore: { getActiveContent: () => 'proxies: []' } },
    '../lib/EffectiveVersions': { EffectiveVersions: { read: () => {
      if (brokenPointer) throw Error('synthetic invalid effective pointer');
      return null;
    } } },
    '../lib/Settings': { Settings: { restartKey: realSettings.Settings.restartKey, isLanPersistenceUncertain: () => false, idle: async () => {}, load: () => ({}) } }, '@kit.ArkTS': { util: {} }
  };
  const Extension = load('vpnability/CexingVpnAbility.ets', modules).default;
  const extension = new Extension();
  extension.context = { filesDir: '/private', resourceManager: { getRawFileContent: async () => new Uint8Array(16) } };
  extension.onCreate();
  const observed = extension.onConnect({ parameters: { RECOVER_ONLY: true } });
  observed.onRemoteMessageRequest(1, {}, { writeBoolean: value => assert.equal(value, false), writeString() {} }, {});
  assert.equal(destroyCount, 0);
  assert.equal(prepared, 0, 'recovery bind never enters native initialization');
  let snapshotText;
  observed.onRemoteMessageRequest(3, {}, {writeString:value=>snapshotText=value}, {});
  assert.equal(JSON.parse(snapshotText).events.length,0);

  let emptyAck;
  const emptyData = ['', 'empty-stop'];
  await observed.onRemoteMessageRequest(2, {readString:()=>emptyData.shift()},
    {writeString:value=>assert.equal(value,'empty-stop'),writeBoolean:value=>emptyAck=value}, {});
  assert.equal(emptyAck,true,'read-only empty session confirms its actual no-resource cleanup through IPC');
  assert.equal(destroyCount,0);assert.equal(stopCount,0);

  const hostSettings = JSON.stringify({ mixedPort: 7890, logLevel: 'info', allowLan: false, mode: '', logToFile: true });
  const remote = extension.onConnect({ parameters: { HOST_SETTINGS: hostSettings, VPN_CONFIG: {}, SESSION_ID: 'fixture-1' } });
  assert.ok(remote && typeof remote.then !== 'function', 'onConnect must return synchronously');
  await flush();
  if (protection !== 'ok') {
    assert.equal(extension.coreStarted,false);assert.equal(prepared,0);assert.equal(modelPrepared,0);
    assert.equal(destroyCount,protection==='failed' ? 1 : 0,'created TUN is reclaimed after protection failure');
    assert.equal(stopCount,0,'no native core enters after unavailable/failed protection');
    assert.ok(extension.startupError.length>0);
    return;
  }
  let reportedReady;
  const reportedStrings = [];
  const reportedBooleans = [];
  remote.onRemoteMessageRequest(1, {}, { writeBoolean: value => { reportedReady = value; reportedBooleans.push(value); },
    writeString: value => reportedStrings.push(value) }, {});
  assert.equal(reportedBooleans[0], false);
  assert.equal(reportedBooleans[1], !lateCreate, 'TUN create is observed separately from core readiness');
  assert.equal(reportedStrings[1], 'fixture-1');
  remote.onRemoteMessageRequest(3, {}, {writeString:value=>snapshotText=value}, {});
  const snapshot=JSON.parse(snapshotText);
  assert.equal(snapshot.session,'fixture-1');
  if (!lateCreate) {
    assert.ok(snapshot.events.some(e=>e.stage==='protect'&&e.outcome==='success'));
    assert.ok(snapshot.events.some(e=>e.stage==='smart_model_prepare'&&e.outcome==='skipped'));
  }
  assert.ok(snapshot.events.every(e=>phaseModule.exports.VpnPhases.valid(e)));

  extension.onDisconnect();
  await flush();
  assert.equal(destroyCount, 1, 'Stop must remove system VPN while initialization is pending');
  if (lateCreate) { completeCreate(32); await flush(); }
  complete('');
  await flush();
  if (lateCreate) assert.equal(destroyCount,2,'late TUN creation is destroyed again after pending startup settles');
  assert.equal(stopCount, 1, 'Stop must clean up a late kernel startup');
  assert.equal(JSON.parse(files.get('/private/last_stop_result.json')).completed, !failStop,
    'Extension receipt must reflect the awaited native stop result');
  if (failStop) {
    assert.equal(extension.coreInitialized,true,'failed native stop retains the cleanup obligation');
    failNative=false;let ack;
    const retryData=['fixture-1','retry-stop'];
    await remote.onRemoteMessageRequest(2,{readString:()=>retryData.shift()},
      {writeString:v=>assert.equal(v,'retry-stop'),writeBoolean:v=>ack=v},{});
    assert.equal(ack,true);assert.equal(stopCount,2,'explicit retry awaits native cleanup instead of forgetting it');
    return;
  }
  let mismatchAck;
  const mismatchData=['wrong-session','wrong-stop'];
  await remote.onRemoteMessageRequest(2,{readString:()=>mismatchData.shift()},
    {writeString(){},writeBoolean:v=>mismatchAck=v},{});
  assert.equal(mismatchAck,false,'wrong process session cannot authorize cleanup');
  const restarted = extension.onConnect({ parameters: { HOST_SETTINGS: hostSettings, VPN_CONFIG: {} } });
  await flush();
  if (lateCreate) { completeCreate(32); await flush(); }
  restarted.onRemoteMessageRequest(1, {}, { writeBoolean: value => { reportedReady = value; }, writeString() {} }, {});
  assert.equal(reportedReady, true, 'The same extension must allow restart after cleanup despite unavailable panel resources');
  assert.equal(prepared, 2);
  brokenPointer = true;
  await assert.rejects(extension.buildCoreConfig(), /invalid effective pointer/,
    'broken effective pointer must not silently start the built-in fallback');
}
function testApplicationPolicy() {
  const modules = {
    '@kit.NetworkKit': {}, '@kit.CoreFileKit': {}, '@kit.IPCKit': {}, './Logger': logger,
    './ConnectionFailure': failureModule.exports, './VpnPhases': phaseModule.exports,
    './CoreApi': {}, './Settings': { Settings: {restartKey: realSettings.Settings.restartKey, isLanPersistenceUncertain: () => false, idle: async () => {}, load: () => ({accessMode:'white',accessList:[]})} }, './ProfileStore': {}
  };
  const policy = load('lib/VpnController.ets', modules);
  const self = 'test.bundle';
  assert.deepEqual(Array.from(policy.buildVpnApplicationPolicy('all', ['ignored'], self).blockedApplications), [self]);
  assert.deepEqual(Array.from(policy.buildVpnApplicationPolicy('white', [self,'sample.app','sample.app'], self).trustedApplications), ['sample.app']);
  assert.deepEqual(Array.from(policy.buildVpnApplicationPolicy('black', [self,'sample.app','sample.app'], self).blockedApplications), [self,'sample.app']);
  for (const list of [[], [self], ['bad'], ['foo..bar'], ['foo.bar;DROP'], ['foo.bar\n'], [null], ['x'.repeat(129)]]) {
    assert.throws(() => policy.buildVpnApplicationPolicy('white', list, self));
  }
  assert.throws(() => policy.buildVpnApplicationPolicy('invalid', [], self));
  const names = Array.from({length:64}, (_,i) => `sample.app${i}`);
  assert.equal(policy.buildVpnApplicationPolicy('white', names, self).trustedApplications.length,64);
  assert.throws(() => policy.buildVpnApplicationPolicy('white', [...names,'sample.extra'], self));
  assert.equal(policy.buildVpnApplicationPolicy('black', names.slice(0,63), self).blockedApplications.length,64);
  assert.throws(() => policy.buildVpnApplicationPolicy('black', names, self));
  assert.equal(policy.VpnController.start({applicationInfo:{name:self}}),false,'empty whitelist refuses before authorization');
  assert.equal(policy.VpnController.status,policy.VpnStatus.Disconnected);
  assert.match(policy.VpnController.lastStartError,/添加/);
}
(async () => {
  testApplicationPolicy();
  await testClient('ready');
  await testClient('ready','all',[],true);
  await testClient('ready', 'white', ['test.bundle','sample.app','sample.app']);
  await testClient('ready', 'black', ['sample.app','sample.app']);
  await testClient('error');
  await testClient('stale');
  await testClient('cancel');
  await testClient('zero');
  await testClient('stop-failed');
  await testClient('cleanup-failed');
  await testClient('stale-receipt');
  await testExtension();
  await testExtension(false,false,'old');
  await testExtension(false,false,'missing');
  await testExtension(false,false,'failed');
  await testExtension(true);
  await testExtension(false, true);
  console.log('PASS: readiness, error propagation, cancellation and extension lifecycle scenarios');
})().catch(error => { console.error(error); process.exitCode = 1; });
