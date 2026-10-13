// SDK-backed ArkTS execution: process services must survive page lifecycle changes.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const source = fs.readFileSync(path.join(__dirname, '../cexing/entry/src/main/ets/lib/AppRuntime.ets'), 'utf8');
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
    cancelRecovery: () => {},
    recover: cb => { controller.status = recovered; listeners.forEach(fn => fn(recovered)); cb(); },
    start: () => { calls.start++; }
  };
  const modules = {
    './VpnController': { VpnController: controller, VpnStatus: status },
    './LiveViewKeeper': { LiveViewKeeper: {
      rebindContext: ctx => { calls.backgroundContext = ctx; },
      start: async () => { calls.backgroundStart++; return true; },
      stop: async () => { calls.backgroundStop++; },
      ensure: () => { calls.ensure++; }
    } },
    './AutoUpdater': { AutoUpdater: {
      rebindContext: ctx => { calls.updatesContext = ctx; },
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
  const newContext = { name: 'recreated ability' };
  f.runtime.initialize(newContext);
  assert.equal(f.calls.backgroundContext, newContext);
  assert.equal(f.calls.updatesContext, newContext);
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
  const entry = fixture();
  entry.settings.autoRestore = true;
  entry.settings.vpnWasConnected = true;
  entry.runtime.initialize({}, () => entry.runtime.cancelRestore());
  assert.equal(entry.timers.size, 0, 'Foreground entry after recovery must suppress implicit auto-restore');
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
  // A timeout already queued by the event loop must stay invalid after manual start/cancel.
  const manual = fixture();
  manual.settings.autoRestore = true;
  manual.settings.vpnWasConnected = true;
  manual.runtime.initialize({});
  const queued = [...manual.timers.values()][0];
  manual.emit(status.Connecting);
  manual.settings.vpnWasConnected = false;
  manual.emit(status.Disconnected);
  queued();
  assert.equal(manual.calls.start, 0, 'Manual start then cancel must invalidate old auto-restore');
  assert.equal(manual.timers.size, 0, 'Status transition must remove the scheduled restore');
  const delayed = fixture();
  let finishRecovery;
  delayed.controller.recover = cb => { finishRecovery = cb; };
  delayed.settings.autoRestore = true;
  delayed.settings.vpnWasConnected = true;
  delayed.runtime.initialize({});
  delayed.emit(status.Connecting);
  delayed.emit(status.Disconnected);
  finishRecovery();
  assert.equal(delayed.timers.size, 0, 'Late recovery completion must not schedule a stale restore');
  const disabled = fixture();
  disabled.settings.autoRestore = true;
  disabled.settings.vpnWasConnected = true;
  disabled.runtime.initialize({});
  const pending = [...disabled.timers.values()][0];
  disabled.settings.autoRestore = false;
  pending();
  assert.equal(disabled.calls.start, 0, 'Timeout must recheck the current auto-restore preference');
  const destroyed = fixture();
  destroyed.settings.autoRestore = true;
  destroyed.settings.vpnWasConnected = true;
  destroyed.runtime.initialize({});
  const stale = [...destroyed.timers.values()][0];
  destroyed.runtime.cancelRestore();
  stale();
  assert.equal(destroyed.calls.start, 0, 'Already queued timeout must honor cancellation');
  const recreated = fixture();
  recreated.settings.autoRestore = true;
  recreated.settings.vpnWasConnected = true;
  const oldContext = {}, newContext = {};
  recreated.runtime.initialize(oldContext);
  recreated.runtime.initialize(newContext);
  recreated.runtime.abilityDestroyed(oldContext);
  assert.equal(recreated.timers.size, 1, 'Old Ability destruction must preserve new restore');
  recreated.runtime.abilityDestroyed(newContext);
  assert.equal(recreated.timers.size, 0, 'Current Ability destruction must cancel its restore');
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
