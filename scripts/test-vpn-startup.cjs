// 用法：source scripts/env.sh && node scripts/test-vpn-startup.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(path.join(process.env.OHOS_SDK_HOME, 'ets/build-tools/ets-loader/node_modules/typescript'));
const flush = () => new Promise(resolve => setImmediate(resolve));
const logger = { Logger: { info() {}, warn() {}, error() {} } };
function load(relative, modules, timers = []) {
  const source = fs.readFileSync(path.join(__dirname, '../clash-openharmony/entry/src/main/ets', relative), 'utf8');
  const output = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
  const context = { exports: {}, require: name => {
    assert.ok(name in modules, `Missing mock: ${name}`);
    return modules[name];
  }, setTimeout: fn => { timers.push(fn); }, Date, Promise, Uint8Array, Object, JSON };
  vm.runInNewContext(output, context);
  return context.exports;
}
async function testClient(mode) {
  let callbacks;
  let ready = false;
  let error = '';
  const timers = [];
  const settings = { accessMode: 'all', accessList: [], ipv6: false, vpnWasConnected: false };
  const context = {
    filesDir: '/private', applicationInfo: { name: 'test.bundle' },
    connectServiceExtensionAbility: (want, value) => { callbacks = value; return 1; },
    disconnectServiceExtensionAbility: async () => {}
  };
  const modules = {
    '@kit.NetworkKit': { vpnExtension: { startVpnExtensionAbility: async () => {}, stopVpnExtensionAbility() {} } },
    '@kit.CoreFileKit': { fileIo: {} }, './Logger': logger,
    './CoreApi': { CoreApi: {} }, './Settings': { Settings: { load: () => settings, save() {} } },
    '@kit.IPCKit': { rpc: { MessageSequence: { create: () => ({ reclaim() {} }) }, MessageOption: class {} } }
  };
  const { VpnController: controller, VpnStatus } = load('lib/VpnController.ets', modules, timers);
  const remote = { sendMessageRequest: async () => ({ errCode: 0, reply: {
    readBoolean: () => ready, readString: () => error
  } }) };
  let notifications = 0;
  const pageListener = () => { notifications++; };
  controller.onChanged(pageListener);
  controller.onChanged(pageListener);
  controller.start(context);
  assert.equal(notifications, 1, 'Page observer registration must be idempotent');
  controller.offChanged(pageListener);
  await flush();
  callbacks.onConnect({}, remote);
  await flush();
  assert.equal(controller.status, VpnStatus.Connecting, 'Service connection must not claim kernel readiness');
  assert.equal(settings.vpnWasConnected, false);
  if (mode === 'ready') {
    ready = true;
    timers.shift()();
    await flush();
    assert.equal(controller.status, VpnStatus.Connected);
    assert.equal(settings.vpnWasConnected, true);
  } else if (mode === 'error') {
    error = 'GeoIP unavailable';
    timers.shift()();
    await flush();
    assert.equal(controller.status, VpnStatus.Disconnected);
    assert.equal(controller.lastStartError, error);
  } else {
    controller.stop(context);
    await flush();
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
  const pending = new Promise(resolve => { complete = resolve; });
  const connection = { create: async () => 32, protectProcessNet: async () => {},
    destroy: async () => { destroyCount++; } };
  const modules = {
    '@kit.NetworkKit': { VpnExtensionAbility: class {}, vpnExtension: { createVpnConnection: () => connection } },
    '@kit.IPCKit': { rpc: { RemoteObject: class {} } },
    '@kit.CoreFileKit': { fileIo: { accessSync: () => false, openSync: () => ({ fd: 1 }),
      writeSync() {}, closeSync() {}, renameSync() {}, OpenMode: {} } },
    'libentry.so': { default: { initCore: async () => '', startTun: () => pending,
      stopCore: async () => { stopCount++; } } },
    '../lib/Logger': logger,
    '../lib/ProfileStore': { ProfileStore: { getActiveContent: () => 'proxies: []' } },
    '../lib/Settings': { Settings: { load: () => ({}) } }, '@kit.ArkTS': { util: {} }
  };
  const Extension = load('vpnability/ClashVpnAbility.ets', modules).default;
  const extension = new Extension();
  extension.context = { filesDir: '/private', resourceManager: { getRawFileContent: async () => new Uint8Array(16) } };
  extension.onCreate();
  const remote = extension.onConnect({ parameters: { VPN_CONFIG: {} } });
  assert.ok(remote && typeof remote.then !== 'function', 'onConnect must return synchronously');
  await flush();
  let reportedReady;
  remote.onRemoteMessageRequest(1, {}, { writeBoolean: value => { reportedReady = value; }, writeString() {} }, {});
  assert.equal(reportedReady, false);
  extension.onDisconnect();
  await flush();
  assert.equal(destroyCount, 1, 'Stop must remove system VPN while initialization is pending');
  complete('');
  await flush();
  assert.equal(stopCount, 1, 'Stop must clean up a late kernel startup');
  const restarted = extension.onConnect({ parameters: { VPN_CONFIG: {} } });
  await flush();
  restarted.onRemoteMessageRequest(1, {}, { writeBoolean: value => { reportedReady = value; }, writeString() {} }, {});
  assert.equal(reportedReady, true, 'The same extension must allow restart after cleanup');
}
(async () => {
  await testClient('ready');
  await testClient('error');
  await testClient('cancel');
  await testExtension();
  console.log('PASS: readiness, error propagation, cancellation and extension lifecycle scenarios');
})().catch(error => { console.error(error); process.exitCode = 1; });
