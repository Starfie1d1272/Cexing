// Exercise actual ArkTS service code with deferred native lifecycle operations.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(path.join(process.env.OHOS_SDK_HOME, 'ets/build-tools/ets-loader/node_modules/typescript'));
const flush = () => new Promise(resolve => setImmediate(resolve));
const logger = { Logger: { info() {}, warn() {}, error() {} } };
function load(name, modules, timers) {
  const source = fs.readFileSync(path.join(__dirname, '../clash-openharmony/entry/src/main/ets/lib', name + '.ets'), 'utf8');
  const code = ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
  } }).outputText;
  let next = 0;
  const ctx = { exports: {}, require: key => {
    assert.ok(key in modules, `Missing mock: ${key}`); return modules[key];
  }, setInterval: (fn, delay) => { timers.set(++next, { fn, delay }); return next; },
  clearInterval: id => timers.delete(id), setTimeout: (fn, delay) => { timers.set(++next, { fn, delay }); return next; }, Date };
  vm.runInNewContext(code, ctx);
  return ctx.exports[name];
}
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function keeperFixture() {
  const timers = new Map(), events = new Map(), starts = [], stops = [], contexts = [];
  const background = {
    ContinuousTaskRequest: class {}, BackgroundTaskMode: { MODE_DATA_TRANSFER: 1 },
    BackgroundTaskSubmode: { SUBMODE_LIVE_VIEW_NOTIFICATION: 1 },
    ContinuousTaskCancelReason: { USER_CANCEL: 1, USER_CANCEL_REMOVE_NOTIFICATION: 2 },
    startBackgroundRunning: ctx => { const wait = deferred(); starts.push({ ctx, wait }); return wait.promise; },
    stopBackgroundRunning: (ctx, id) => { const wait = deferred(); stops.push({ ctx, id, wait }); return wait.promise; },
    on: (event, fn) => events.set(event, fn), off: event => events.delete(event)
  };
  const settings = { keepAlive: true, mainGroup: '' };
  const modules = {
    '@kit.BackgroundTasksKit': { backgroundTaskManager: background },
    '@kit.AbilityKit': { wantAgent: { getWantAgent: async () => ({}),
      OperationType: { START_ABILITY: 1 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 1 } } },
    '@kit.NotificationKit': { notificationManager: { publish: async () => {}, cancel: async () => {},
      ContentType: { NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW: 1 }, SlotType: { LIVE_VIEW: 1 } } },
    './CoreApi': { CoreApi: { getProxies: async () => ({ test: { name: 'test', type: 'Selector', now: 'DIRECT', all: ['DIRECT'] } }), getConfigs: async () => null,
      getTraffic: async () => null, isAlive: async () => true }, formatRate: () => '' },
    './Settings': { Settings: { load: ctx => { contexts.push(ctx); return settings; }, save() {} } },
    './VpnController': { VpnController: { status: 2 }, VpnStatus: { Connected: 2 } },
    './Logger': logger
  };
  return { keeper: load('LiveViewKeeper', modules, timers), starts, stops, timers, events, contexts };
}
async function testRapidReconnect() {
  const f = keeperFixture(), old = { applicationInfo: { name: 'bundle' } }, fresh = { applicationInfo: { name: 'bundle' } };
  const first = f.keeper.start(old);
  await flush();
  const stop = f.keeper.stop(old);
  const second = f.keeper.start(fresh);
  await flush();
  assert.equal(f.starts.length, 1, 'Reconnect must wait for in-flight old startup');
  assert.equal(f.stops.length, 0, 'Stop must wait until task identity is known');
  f.starts[0].wait.resolve({ notificationId: 10, continuousTaskId: 100 });
  await first;
  await flush();
  assert.equal(f.stops.length, 1);
  assert.equal(f.stops[0].id, 100, 'Old stop must target old task');
  assert.equal(f.stops[0].ctx, fresh, 'Deferred cleanup must use rebound Ability context');
  assert.equal(f.starts.length, 1, 'New startup must wait for old stop completion');
  f.stops[0].wait.resolve();
  await stop;
  await flush();
  assert.equal(f.starts.length, 2);
  assert.equal(f.starts[1].ctx, fresh);
  f.starts[1].wait.resolve({ notificationId: 20, continuousTaskId: 200 });
  await second;
  assert.equal(f.keeper.isRunning(), true);
  assert.equal(f.timers.size, 2, 'Only new session update/heartbeat timers remain');
  f.events.get('continuousTaskCancel')({ id: 100, reason: 1 });
  await flush();
  assert.equal(f.keeper.isRunning(), true, 'Late cancellation from old task must not remove new session');
  assert.equal(f.stops.length, 1);
}
async function testKeeperContext() {
  const f = keeperFixture(), old = { applicationInfo: { name: 'bundle' } }, fresh = { applicationInfo: { name: 'bundle' } };
  const start = f.keeper.start(old);
  await flush();
  f.keeper.rebindContext(fresh);
  f.starts[0].wait.resolve({ notificationId: 10, continuousTaskId: 100 });
  await start;
  const heartbeat = [...f.timers.values()].find(timer => timer.delay === 300000);
  f.contexts.length = 0;
  heartbeat.fn();
  await flush();
  assert.ok(f.contexts.length > 0);
  assert.ok(f.contexts.every(ctx => ctx === fresh), 'Start completion must not overwrite the rebound context');
  const recreated = { applicationInfo: { name: 'bundle' } };
  f.keeper.rebindContext(recreated);
  f.contexts.length = 0;
  heartbeat.fn();
  await flush();
  assert.ok(f.contexts.every(ctx => ctx === recreated), 'Later heartbeat must use the current Ability context');
  const stop = f.keeper.stop(fresh);
  await flush();
  assert.equal(f.stops[0].ctx, fresh, 'Rebinding while start is pending must not be overwritten by start completion');
  f.stops[0].wait.resolve();
  await stop;
  assert.ok(heartbeat);
}
async function testUpdaterContext() {
  const timers = new Map(), reads = [], updates = [];
  const modules = {
    '@kit.ArkData': { preferences: { getPreferencesSync: ctx => {
      reads.push(ctx); return { getSync: () => 0, putSync() {}, flush() {} };
    } } },
    './Settings': { Settings: { load: ctx => { reads.push(ctx); return { autoUpdate: true, autoUpdateIntervalHours: 24 }; } } },
    './CoreApi': { CoreApi: { isAlive: async () => true, reloadConfig: async () => {} } },
    './ProfileStore': { ProfileStore: { getActiveFile: () => 'test.yaml', getOrigin: () => 'https://example.invalid/subscription',
      updateFromOrigin: async ctx => { updates.push(ctx); }, absPath: () => '/private/test.yaml' } },
    './Logger': logger
  };
  const updater = load('AutoUpdater', modules, timers), old = {}, fresh = {};
  updater.start(old);
  updater.rebindContext(fresh);
  assert.equal(timers.size, 1, 'Rebinding must not create another subscription timer');
  [...timers.values()][0].fn();
  await flush();
  assert.equal(updates.length, 1);
  assert.equal(updates[0], fresh, 'Later subscription tick must use the recreated Ability context');
  assert.ok(reads.every(ctx => ctx === fresh));
  updater.stop();
  assert.equal(timers.size, 0);
}
(async () => {
  await testRapidReconnect();
  await testKeeperContext();
  await testUpdaterContext();
  console.log('PASS: deferred background start/stop, stale cancellation and rebound service contexts');
})().catch(error => { console.error(error); process.exitCode = 1; });
