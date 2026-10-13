const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const source = fs.readFileSync(path.join(__dirname,
  '../cexing/entry/src/main/ets/lib/SmartModelRestart.ets'), 'utf8');
const compiled = ts.transpileModule(source, { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
} }).outputText;
const status = { Disconnected: 0, Connecting: 1, Connected: 2, Disconnecting: 3 };
const flush = () => new Promise(resolve => setImmediate(resolve));
function fixture(options = {}) {
  const calls = [];
  const timers = new Map();
  let timerId = 0;
  const settings = { vpnWasConnected: true, autoRestore: true, keepAlive: true };
  let finishStop;
  const controller = { status: options.initialStatus ?? status.Connected,
    lastStopCompleted: options.lastStopCompleted ?? null,
    getLastStopCompleted() { return controller.lastStopCompleted; },
    stop: () => {
    calls.push('vpn-stop');
    if (options.stopFailure) throw Error('native error');
    if (options.hungStop) return new Promise(() => {});
    if (options.deferredStop) return new Promise(resolve => { finishStop = resolve; });
    controller.status = status.Disconnected;
    controller.lastStopCompleted = options.stopResult ?? true;
    return Promise.resolve(options.stopResult ?? true);
  } };
  const application = { restartApp: want => {
    calls.push('app-restart');
    assert.deepEqual(JSON.parse(JSON.stringify(want)), { bundleName: 'test.app', abilityName: 'EntryAbility' });
    if (options.restartFailure) throw Error('system error');
  } };
  const context = { applicationInfo: { name: 'test.app' },
    getApplicationContext: () => application,
    restartApp: () => { throw Error('must not restart only the UI process'); } };
  const modules = {
    './AppRuntime': { AppRuntime: { cancelRestore: () => calls.push('cancel') } },
    '@kit.ArkData': { preferences: { getPreferencesSync: (_ctx, spec) => {
      assert.equal(spec.name, 'clashoh_settings');
      return { putSync: (key, value) => {
        calls.push('save');
        assert.equal(key, 'vpnWasConnected');
        settings[key] = value;
      }, flush: async () => {
        calls.push('flush');
        if (options.saveFailure) throw Error('store error');
      } };
    } } },
    './VpnController': { VpnController: controller, VpnStatus: status },
    './AutoUpdater': { AutoUpdater: { stop: () => calls.push('updater-stop') } },
    './LiveViewKeeper': { LiveViewKeeper: { stop: async () => {
      calls.push('background-stop');
      if (options.backgroundFailure) throw Error('background error');
    } } }
  };
  const sandbox = { exports: {}, require: name => {
    assert.ok(name in modules, `Missing mock: ${name}`); return modules[name];
  }, setTimeout: (fn, delay) => { timers.set(++timerId, { fn, delay }); return timerId; },
  clearTimeout: id => timers.delete(id) };
  vm.runInNewContext(compiled, sandbox);
  return { restart: () => sandbox.exports.SmartModelRestart.restart(context), calls, settings, timers,
    finishStop: value => finishStop(value) };
}
(async () => {
  const success = fixture();
  await success.restart();
  assert.deepEqual(success.calls, ['cancel', 'vpn-stop', 'save', 'flush', 'updater-stop', 'background-stop', 'app-restart']);
  assert.deepEqual(success.settings, { vpnWasConnected: false, autoRestore: true, keepAlive: true });
  assert.equal(success.timers.size, 0);
  const noSession = fixture({ initialStatus: status.Disconnected });
  await noSession.restart();
  assert.ok(!noSession.calls.includes('vpn-stop'), 'First model setup has no VPN session to stop');
  assert.ok(noSession.calls.includes('app-restart'));
  const priorFailedStop = fixture({ initialStatus: status.Disconnected, lastStopCompleted: false });
  await assert.rejects(priorFailedStop.restart(), /停止 VPN/);
  assert.ok(!priorFailedStop.calls.includes('vpn-stop') && !priorFailedStop.calls.includes('app-restart'));
  const pendingStop = fixture({ deferredStop: true });
  const restartAfterStop = pendingStop.restart();
  await flush();
  assert.deepEqual(pendingStop.calls, ['cancel', 'vpn-stop'], 'Restart must wait for stop completion');
  pendingStop.finishStop(true);
  await restartAfterStop;
  for (const options of [{ stopResult: false }, { stopFailure: true },
    { backgroundFailure: true }, { saveFailure: true }]) {
    const f = fixture(options);
    await assert.rejects(f.restart(), /失败|未知/);
    assert.ok(!f.calls.includes('app-restart'), 'Failed preparation must not restart');
    assert.equal(f.timers.size, 0);
  }
  const failedStopAgain = fixture({ stopResult: false });
  await assert.rejects(failedStopAgain.restart(), /停止 VPN/);
  await assert.rejects(failedStopAgain.restart(), /停止 VPN/);
  assert.equal(failedStopAgain.calls.filter(call => call === 'vpn-stop').length, 1,
    'A false stop cannot become a no-session restart on retry');
  const timedOut = fixture({ hungStop: true });
  const timedOutRestart = assert.rejects(timedOut.restart(), /停止 VPN/);
  await flush();
  [...timedOut.timers.values()].find(t => t.delay === 15000).fn();
  await timedOutRestart;
  assert.ok(!timedOut.calls.includes('app-restart'));
  assert.equal(timedOut.timers.size, 0);
  const failedRestart = fixture({ restartFailure: true });
  await assert.rejects(failedRestart.restart(), /应用重启失败/);
  const busy = fixture({ hungStop: true });
  const pending = assert.rejects(busy.restart(), /停止 VPN/);
  await assert.rejects(busy.restart(), /正在进行/);
  [...busy.timers.values()].find(t => t.delay === 15000).fn();
  await pending;
  console.log('PASS: application restart, shutdown order, preference preservation, timeout and failure guards');
})().catch(error => { console.error(error); process.exitCode = 1; });
