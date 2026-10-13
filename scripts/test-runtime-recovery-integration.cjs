// Automatic runtime/controller cancellation regression; executed by Quick and Full.
// Optional first argument: exported combined source root; SDK comes from OHOS_SDK_HOME.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const root = process.argv[2] || path.join(__dirname, '..');
const flush = () => new Promise(resolve => setImmediate(resolve));
function load(name, modules, timers) {
  const source = fs.readFileSync(path.join(root, 'cexing/entry/src/main/ets/lib', name + '.ets'), 'utf8');
  const code = ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
  } }).outputText;
  let id = 0;
  const sandbox = { exports: {}, require: key => { assert.ok(key in modules, `Missing mock ${key}`); return modules[key]; },
    setTimeout: fn => { timers.set(++id, fn); return id; }, clearTimeout: key => timers.delete(key), Promise, Date, JSON };
  vm.runInNewContext(code, sandbox);
  return sandbox.exports;
}
function fixture() {
  const timers = new Map(), probes = [];
  const calls = { backgroundStart: 0, backgroundStop: 0, updatesStart: 0, updatesStop: 0 };
  const settings = { autoRestore: true, vpnWasConnected: true };
  const logger = { Logger: { info() {}, warn() {}, error() {} } };
  const controller = load('VpnController', {
    '@kit.NetworkKit': { vpnExtension: {} }, '@kit.CoreFileKit': { fileIo: {} }, '@kit.IPCKit': { rpc: {} },
    './CoreApi': { CoreApi: { isAlive: () => new Promise(resolve => probes.push(resolve)) } },
    './Settings': { Settings: { load: () => settings } }, './Logger': logger,
    './ProfileStore': { ProfileStore: { clearApplyUncertain() {} } }
  }, timers);
  const runtime = load('AppRuntime', {
    './VpnController': controller, './Settings': { Settings: { load: () => settings } }, './Logger': logger,
    './LiveViewKeeper': { LiveViewKeeper: { rebindContext() {}, ensure() {},
      start: async () => { calls.backgroundStart++; return true; }, stop: async () => { calls.backgroundStop++; } } },
    './AutoUpdater': { AutoUpdater: { rebindContext() {}, checkAndRun: async () => {},
      start: () => { calls.updatesStart++; }, stop: () => { calls.updatesStop++; } } }
  }, timers).AppRuntime;
  return { runtime, ...controller, timers, probes, calls };
}
(async () => {
  for (const cancel of ['explicit', 'currentAbility']) {
    const f = fixture(), context = {};
    f.runtime.initialize(context);
    if (cancel === 'explicit') f.runtime.cancelRestore();
    else f.runtime.abilityDestroyed(context);
    f.probes[0](true);
    await flush();
    assert.equal(f.VpnController.status, f.VpnStatus.Disconnected, `${cancel}: late alive must not commit Connected`);
    assert.equal(f.calls.backgroundStart, 0, `${cancel}: old probe must not start services`);
    assert.equal(f.calls.updatesStart, 0, `${cancel}: old probe must not start subscription scheduler`);
    assert.equal(f.timers.size, 0, `${cancel}: old completion must not schedule restore`);
  }
  {
    const f = fixture(), old = {}, fresh = {};
    f.runtime.initialize(old);
    f.runtime.initialize(fresh);
    f.runtime.abilityDestroyed(old);
    f.probes[0](true);
    await flush();
    assert.equal(f.VpnController.status, f.VpnStatus.Disconnected, 'Old initialization result must be suppressed');
    f.probes[1](true);
    await flush();
    assert.equal(f.VpnController.status, f.VpnStatus.Connected, 'Old Ability destruction must preserve fresh probe');
    assert.equal(f.calls.backgroundStart, 1);
    assert.equal(f.calls.updatesStart, 1);
    f.runtime.abilityDestroyed(fresh);
    assert.equal(f.VpnController.status, f.VpnStatus.Connected, 'Cancel recovery must not stop established VPN');
    assert.equal(f.calls.backgroundStop, 0);
    assert.equal(f.calls.updatesStop, 0);
  }
  {
    const f = fixture();
    f.runtime.initialize({});
    f.runtime.initialize({});
    f.probes[1](false);
    await flush();
    assert.equal(f.timers.size, 1, 'Fresh disconnected result must retain delayed restore');
    f.probes[0](true);
    await flush();
    assert.equal(f.VpnController.status, f.VpnStatus.Disconnected);
    assert.equal(f.timers.size, 1, 'Older alive result must not cancel newer restore');
    f.runtime.cancelRestore();
    assert.equal(f.timers.size, 0);
  }
  console.log('PASS: combined runtime/controller explicit cancellation, Ability ownership and fresh recovery');
})().catch(error => { console.error(error); process.exitCode = 1; });
