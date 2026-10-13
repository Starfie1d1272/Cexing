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
  const controller = { status: status.Connected, stop: () => {
    calls.push('vpn-stop');
    if (options.stopFailure) throw Error('native error');
    controller.status = options.stuckStatus ? status.Disconnecting : status.Disconnected;
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
    './CoreApi': { CoreApi: { isAlive: async () => {
      calls.push('probe');
      if (options.probeFailure) throw Error('probe error');
      if (options.hungProbe) return new Promise(() => {});
      return options.alive || false;
    } } },
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
  return { restart: () => sandbox.exports.SmartModelRestart.restart(context), calls, settings, timers };
}
(async () => {
  const success = fixture();
  await success.restart();
  assert.deepEqual(success.calls, ['cancel', 'vpn-stop', 'probe', 'save', 'flush', 'updater-stop', 'background-stop', 'app-restart']);
  assert.deepEqual(success.settings, { vpnWasConnected: false, autoRestore: true, keepAlive: true });
  assert.equal(success.timers.size, 0);
  for (const options of [{ alive: true }, { stuckStatus: true }, { hungProbe: true }]) {
    const f = fixture(options);
    const pending = assert.rejects(f.restart(), /停止 VPN/);
    await flush();
    [...f.timers.values()].find(t => t.delay === 15000).fn();
    await pending;
    assert.ok(!f.calls.includes('app-restart'), 'Timeout must not restart');
    assert.ok(!f.calls.includes('updater-stop'), 'Must wait for VPN shutdown before service cleanup');
    const polls = [...f.timers.values()];
    f.timers.clear();
    polls.forEach(t => t.fn());
    await flush();
    assert.equal(f.timers.size, 0, 'Timed-out probe must not keep scheduling');
  }
  for (const options of [{ stopFailure: true }, { probeFailure: true }, { backgroundFailure: true }, { saveFailure: true }]) {
    const f = fixture(options);
    await assert.rejects(f.restart(), /失败/);
    assert.ok(!f.calls.includes('app-restart'), 'Failed preparation must not restart');
    assert.equal(f.timers.size, 0);
  }
  const failedRestart = fixture({ restartFailure: true });
  await assert.rejects(failedRestart.restart(), /应用重启失败/);
  const busy = fixture({ hungProbe: true });
  const pending = assert.rejects(busy.restart(), /停止 VPN/);
  await assert.rejects(busy.restart(), /正在进行/);
  [...busy.timers.values()].find(t => t.delay === 15000).fn();
  await pending;
  console.log('PASS: application restart, shutdown order, preference preservation, timeout and failure guards');
})().catch(error => { console.error(error); process.exitCode = 1; });
