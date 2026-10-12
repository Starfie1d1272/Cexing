// SDK-backed ArkTS execution: process services must survive page lifecycle changes.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(path.join(process.env.OHOS_SDK_HOME, 'ets/build-tools/ets-loader/node_modules/typescript'));
const source = fs.readFileSync(path.join(__dirname, '../clash-openharmony/entry/src/main/ets/lib/AppRuntime.ets'), 'utf8');
const compiled = ts.transpileModule(source, { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
} }).outputText;
const flush = () => new Promise(resolve => setImmediate(resolve));
const status = { Disconnected: 0, Connecting: 1, Connected: 2, Disconnecting: 3 };
function fixture(recovered = status.Disconnected) {
  const listeners = [];
  const timers = new Map();
  let timerId = 0;
  const calls = { backgroundStart: 0, backgroundStop: 0, updatesStart: 0, updatesStop: 0, check: 0, ensure: 0, start: 0 };
  const settings = { autoRestore: false, vpnWasConnected: false };
  const controller = {
    status: status.Disconnected,
    onChanged: cb => listeners.push(cb),
    recover: cb => { controller.status = recovered; listeners.forEach(fn => fn(recovered)); cb(); },
    start: () => { calls.start++; }
  };
  const modules = {
    './VpnController': { VpnController: controller, VpnStatus: status },
    './LiveViewKeeper': { LiveViewKeeper: {
      start: async () => { calls.backgroundStart++; return true; },
      stop: async () => { calls.backgroundStop++; },
      ensure: () => { calls.ensure++; }
    } },
    './AutoUpdater': { AutoUpdater: {
      start: () => { calls.updatesStart++; }, stop: () => { calls.updatesStop++; },
      checkAndRun: async () => { calls.check++; }
    } },
    './Settings': { Settings: { load: () => settings } },
    './Logger': { Logger: { warn() {} } }
  };
  const ctx = { exports: {}, require: name => {
    assert.ok(name in modules, `Missing mock: ${name}`); return modules[name];
  }, setTimeout: fn => { timers.set(++timerId, fn); return timerId; }, clearTimeout: id => timers.delete(id) };
  vm.runInNewContext(compiled, ctx);
  return { runtime: ctx.exports.AppRuntime, controller, listeners, timers, calls, settings,
    emit: value => { controller.status = value; listeners.forEach(fn => fn(value)); } };
}
async function testOwnership() {
  const f = fixture(status.Connected);
  f.runtime.initialize({ name: 'first ability' });
  await flush();
  assert.equal(f.calls.backgroundStart, 1, 'Recovery event and completion must not double-start services');
  assert.equal(f.calls.updatesStart, 1);
  f.runtime.initialize({ name: 'recreated ability' });
  f.runtime.foreground();
  f.runtime.cancelRestore(); // EntryAbility destruction does not stop a running VPN.
  await flush();
  assert.equal(f.listeners.length, 1, 'Ability recreation must retain one process listener');
  assert.equal(f.calls.updatesStart, 1);
  assert.equal(f.calls.ensure, 1);
  assert.equal(f.calls.backgroundStop, 0);
  assert.equal(f.calls.updatesStop, 0);
  f.emit(status.Disconnecting);
  assert.equal(f.calls.backgroundStop, 0, 'Transition must preserve background resources');
  f.emit(status.Disconnected);
  await flush();
  assert.equal(f.calls.backgroundStop, 1);
  assert.equal(f.calls.updatesStop, 1);
  f.emit(status.Connecting);
  f.emit(status.Connected);
  await flush();
  assert.equal(f.calls.backgroundStart, 2, 'Reconnect must restart services');
  assert.equal(f.calls.updatesStart, 2);
}
function testRestore() {
  const f = fixture();
  f.settings.autoRestore = true;
  f.settings.vpnWasConnected = true;
  f.runtime.initialize({});
  assert.equal(f.timers.size, 1);
  f.runtime.initialize({});
  assert.equal(f.timers.size, 1, 'Reinitialization must replace the pending restore');
  f.runtime.cancelRestore();
  assert.equal(f.timers.size, 0, 'Destroy must cancel delayed auto-restore');
  f.runtime.initialize({});
  f.controller.status = status.Connecting;
  [...f.timers.values()][0]();
  assert.equal(f.calls.start, 0, 'Pending restore must not interfere with manual startup');
  const g = fixture();
  g.settings.autoRestore = true;
  g.settings.vpnWasConnected = true;
  g.runtime.initialize({});
  [...g.timers.values()][0]();
  assert.equal(g.calls.start, 1);
}
(async () => {
  await testOwnership();
  testRestore();
  console.log('PASS: process-owned background services, recovery, transitions and auto-restore');
})().catch(error => { console.error(error); process.exitCode = 1; });
