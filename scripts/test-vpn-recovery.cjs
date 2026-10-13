// Usage: source scripts/env.sh && node scripts/test-vpn-recovery.cjs
// VPN_CONTROLLER_SOURCE may point at an exported baseline for reproduction.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(path.join(process.env.OHOS_SDK_HOME, 'ets/build-tools/ets-loader/node_modules/typescript'));
const flush = () => new Promise(resolve => setImmediate(resolve));
const failureSource = fs.readFileSync(path.join(__dirname, '../cexing/entry/src/main/ets/lib/ConnectionFailure.ets'), 'utf8');
const failureCode = ts.transpileModule(failureSource, { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
} }).outputText;
const failureModule = { exports: {} };
vm.runInNewContext(failureCode, failureModule);
function load() {
  const probes = [];
  const source = fs.readFileSync(process.env.VPN_CONTROLLER_SOURCE || path.join(__dirname, '../cexing/entry/src/main/ets/lib/VpnController.ets'), 'utf8');
  const output = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
  const settings = { accessMode: 'all', accessList: [], ipv6: false, vpnWasConnected: false };
  const modules = {
    '@kit.NetworkKit': { vpnExtension: { startVpnExtensionAbility: async () => {}, stopVpnExtensionAbility() {} } },
    '@kit.CoreFileKit': { fileIo: {} }, './Logger': { Logger: { info() {}, warn() {}, error() {} } },
    './CoreApi': { CoreApi: { bindContext() {}, isAlive: () => new Promise(resolve => probes.push(resolve)) } },
    './Settings': { Settings: { load: () => settings, save() {} } }, '@kit.IPCKit': { rpc: {} },
    './ConnectionFailure': failureModule.exports
  };
  const sandbox = { exports: {}, require: name => { assert.ok(name in modules); return modules[name]; }, Promise, Date, JSON };
  vm.runInNewContext(output, sandbox);
  const context = { filesDir: '/private', applicationInfo: { name: 'test.bundle' },
    connectServiceExtensionAbility: () => 1, disconnectServiceExtensionAbility: async () => {} };
  return { ...sandbox.exports, context, probes };
}
(async () => {
  // Independently reproduces the PR #4 blocker on the fixed main source.
  {
    const { VpnController: vc, VpnStatus, context, probes } = load();
    let staleCompletion = 0;
    vc.recover(() => { staleCompletion++; });
    vc.start(context);
    await flush();
    vc.stop(context);
    await flush();
    assert.equal(vc.status, VpnStatus.Disconnected);
    probes[0](true);
    await flush();
    assert.equal(vc.status, VpnStatus.Disconnected, 'Late recovery must not revive a user-cancelled session');
    assert.equal(staleCompletion, 0, 'Obsolete recovery callback must not schedule another restore');
  }
  {
    const { VpnController: vc, VpnStatus, probes } = load();
    let staleCompletion = 0;
    let currentResult;
    vc.recover(() => { staleCompletion++; });
    vc.recover(alive => { currentResult = alive; });
    probes[1](false);
    await flush();
    probes[0](true);
    await flush();
    assert.equal(vc.status, VpnStatus.Disconnected, 'Older recovery must not replace a newer result');
    assert.equal(currentResult, false);
    assert.equal(staleCompletion, 0);
  }
  {
    const { VpnController: vc, VpnStatus, context, probes } = load();
    vc.recover();
    // Stop must invalidate intent even while status is still Disconnected.
    vc.stop(context);
    probes[0](true);
    await flush();
    assert.equal(vc.status, VpnStatus.Disconnected);
    vc.recover();
    vc.cancelRecovery();
    probes[1](true);
    await flush();
    assert.equal(vc.status, VpnStatus.Disconnected);
    let result;
    vc.recover(alive => { result = alive; });
    probes[2](true);
    await flush();
    assert.equal(vc.status, VpnStatus.Connected, 'A fresh valid recovery should still commit');
    assert.equal(result, true);
  }
  console.log('PASS: late recovery after start/cancel, newer intent, disconnected stop, explicit cancellation and fresh recovery');
})().catch(error => { console.error(error); process.exitCode = 1; });
