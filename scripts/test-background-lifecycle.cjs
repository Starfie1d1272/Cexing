// Exercise actual ArkTS service code with deferred native lifecycle operations.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const flush = () => new Promise(resolve => setImmediate(resolve));
const logger = { Logger: { info() {}, warn() {}, error() {} } };
function load(name, modules, timers) {
  const source = fs.readFileSync(path.join(__dirname, '../cexing/entry/src/main/ets/lib', name + '.ets'), 'utf8');
  const code = ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
  } }).outputText;
  let next = 0;
  const ctx = { exports: {}, require: key => {
    assert.ok(key in modules, `Missing mock: ${key}`); return modules[key];
  }, setInterval: (fn, delay) => { timers.set(++next, { fn, delay }); return next; },
  clearInterval: id => timers.delete(id), clearTimeout: id => timers.delete(id), setTimeout: (fn, delay) => { timers.set(++next, { fn, delay }); return next; }, Date };
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
  const publications = [], cancellations = [];
  const settings = { keepAlive: true, mainGroup: '' };
  const modules = {
    '@kit.BackgroundTasksKit': { backgroundTaskManager: background },
    '@kit.AbilityKit': { wantAgent: { getWantAgent: async () => ({}),
      OperationType: { START_ABILITY: 1 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 1 } } },
    '@kit.NotificationKit': { notificationManager: { publish: async request => { publications.push(request); }, cancel: async id => { cancellations.push(id); },
      ContentType: { NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW: 1 }, SlotType: { LIVE_VIEW: 1 } } },
    './CoreApi': { CoreApi: { getProxies: async () => ({ test: { name: 'test', type: 'Selector', now: 'DIRECT', all: ['DIRECT'] } }), getConfigs: async () => null,
      getTraffic: async () => null, isAlive: async () => true }, formatRate: () => '' },
    './Settings': { Settings: { load: ctx => { contexts.push(ctx); return settings; }, save() {} } },
    './VpnController': { VpnController: { status: 2 }, VpnStatus: { Connected: 2 } },
    './Logger': logger
  };
  return { keeper: load('LiveViewKeeper', modules, timers), starts, stops, timers, events, contexts, modules, background, publications, cancellations };
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
async function startKeeper(f, id = 100) {
  const context = { applicationInfo: { name: 'bundle' } };
  const result = f.keeper.start(context);
  await flush();
  f.starts.at(-1).wait.resolve({ notificationId: id / 10, continuousTaskId: id });
  await result;
  return context;
}
async function stopKeeper(f, context) {
  const count = f.stops.length;
  const result = f.keeper.stop(context);
  await flush();
  if (f.stops.length > count) f.stops.at(-1).wait.resolve();
  await result;
}
async function testLateTraffic() {
  const f = keeperFixture();
  const context = await startKeeper(f);
  const queuedTick = [...f.timers.values()].find(t => t.delay === 60000).fn;
  const traffic = deferred();
  f.modules['./CoreApi'].CoreApi.getTraffic = () => traffic.promise;
  [...f.timers.values()].find(t => t.delay === 60000).fn();
  await stopKeeper(f, context);
  await startKeeper(f, 200);
  const count = f.publications.length;
  traffic.resolve({ up: 900000, down: 900000 });
  await flush();
  assert.equal(f.publications.length, count, 'Old traffic completion must not publish into new task');
  queuedTick();
  await flush();
  assert.equal(f.publications.length, count, 'Cleared but already queued old timer must not run in new task');
}
async function testLateHeartbeat() {
  const f = keeperFixture();
  const context = await startKeeper(f);
  const delay = deferred();
  f.modules['./CoreApi'].CoreApi.getProxies = async () => ({ test: { type: 'Selector', now: 'old-node' } });
  f.modules['./CoreApi'].CoreApi.delayTest = () => delay.promise;
  [...f.timers.values()].find(t => t.delay === 300000).fn();
  await flush();
  await stopKeeper(f, context);
  f.modules['./CoreApi'].CoreApi.getProxies = async () => ({ test: { type: 'Selector', now: 'DIRECT' } });
  await startKeeper(f, 200);
  delay.resolve(99000);
  await flush();
  [...f.timers.values()].find(t => t.delay === 60000).fn();
  await flush();
  assert.ok(!f.publications.at(-1).content.systemLiveView.text.includes('99000'),
    'Old delay result must not become the new session delay');
}
async function testPreTaskFailure() {
  const f = keeperFixture();
  const agent = f.modules['@kit.AbilityKit'].wantAgent;
  const original = agent.getWantAgent;
  agent.getWantAgent = async () => { throw new Error('injected wantAgent failure'); };
  const attempt = f.keeper.start({ applicationInfo: { name: 'bundle' } });
  await flush();
  assert.equal(f.stops.length, 0, 'Failure before task allocation must not broadly stop another task');
  assert.equal(await attempt, false);
  agent.getWantAgent = original;
  await startKeeper(f);
  assert.equal(f.keeper.isRunning(), true, 'Failed start must permit a later explicit retry');
}
async function testPendingPublish() {
  const f = keeperFixture();
  const context = await startKeeper(f);
  const publish = deferred();
  f.modules['@kit.NotificationKit'].notificationManager.publish = () => publish.promise;
  [...f.timers.values()].find(t => t.delay === 60000).fn();
  await flush();
  const stop = f.keeper.stop(context);
  await flush();
  assert.equal(f.cancellations.length, 0, 'Cancel must follow completion of already submitted publish');
  publish.resolve();
  await flush();
  assert.deepEqual(f.cancellations, [10]);
  f.stops[0].wait.resolve();
  await stop;
}
async function testPartialListeners() {
  const f = keeperFixture();
  const on = f.background.on;
  f.background.on = (event, fn) => {
    if (event === 'continuousTaskSuspend') throw new Error('injected registration failure');
    on(event, fn);
  };
  const start = f.keeper.start({ applicationInfo: { name: 'bundle' } });
  await flush();
  f.starts[0].wait.resolve({ notificationId: 10, continuousTaskId: 100 });
  await flush();
  assert.equal(f.events.size, 0, 'Partial registration must remove the earlier cancel listener');
  assert.equal(f.stops.length, 1, 'Registration failure must release the native task');
  f.stops[0].wait.resolve();
  assert.equal(await start, false);
  assert.equal(f.timers.size, 0);
  f.background.on = on;
  await startKeeper(f, 200);
  assert.equal(f.events.size, 3, 'A later explicit retry has one listener per event');
}
async function testCancelProbeRace() {
  const f = keeperFixture();
  const context = await startKeeper(f);
  const probe = deferred();
  f.modules['./CoreApi'].CoreApi.isAlive = () => probe.promise;
  f.events.get('continuousTaskCancel')({ id: 100, reason: 99 });
  await flush();
  const stop = f.keeper.stop(context);
  const start = f.keeper.start(context);
  probe.resolve(true);
  await flush();
  assert.equal(f.timers.size, 0, 'Late cancel probe must not create a retry timer after stop/start');
  await stop;
  await flush();
  f.starts[1].wait.resolve({ notificationId: 20, continuousTaskId: 200 });
  await start;
  assert.equal(f.timers.size, 2);
}
async function testUserCancel() {
  const f = keeperFixture();
  const context = await startKeeper(f);
  // Optional API26 detailed enum is absent in this mock, as on older runtimes.
  const cancel = deferred();
  f.modules['@kit.NotificationKit'].notificationManager.cancel = () => cancel.promise;
  f.events.get('continuousTaskCancel')({ id: 100, reason: 1 });
  await flush();
  f.keeper.ensure(context);
  cancel.resolve();
  await flush();
  assert.equal(f.starts.length, 1, 'User cancellation must not auto-reapply on foreground');
  assert.equal(f.timers.size, 0);
  await stopKeeper(f, context);
  await startKeeper(f, 200); // Explicit disconnect/connect is the retry path.
  assert.equal(f.keeper.isRunning(), true);
}
function updaterFixture() {
  const timers = new Map(), updates = [], reloads = [], writes = [];
  const settings = { autoUpdate: true, autoUpdateIntervalHours: 24 };
  let active = 'first.yaml';
  const modules = {
    '@kit.ArkData': { preferences: { getPreferencesSync: () => ({
      getSync: () => 0, putSync: (...args) => writes.push(args), flush() {}
    }) } },
    './Settings': { Settings: { load: () => settings } },
    './CoreApi': { CoreApi: { isAlive: async () => true, reloadConfig: async file => reloads.push(file) } },
    './ProfileStore': { ProfileStore: { getActiveFile: () => active, getOrigin: () => 'https://example.invalid/sub',
      updateFromOrigin: async (ctx, file) => updates.push(file), absPath: (ctx, file) => file } },
    './Logger': logger
  };
  return { updater: load('AutoUpdater', modules, timers), timers, modules, settings, updates, reloads, writes,
    setActive: file => { active = file; } };
}
async function testUpdaterLateCompletion() {
  for (const invalidate of ['stop', 'rebind', 'profile', 'preference']) {
    const f = updaterFixture(), download = deferred(), context = {};
    f.modules['./ProfileStore'].ProfileStore.updateFromOrigin = () => download.promise;
    f.updater.start(context);
    const check = f.updater.checkAndRun(context);
    await flush();
    if (invalidate === 'stop') { f.updater.stop(); f.updater.start(context); }
    if (invalidate === 'rebind') f.updater.rebindContext({});
    if (invalidate === 'profile') f.setActive('second.yaml');
    if (invalidate === 'preference') f.settings.autoUpdate = false;
    download.resolve();
    await check;
    assert.equal(f.reloads.length, 0, `Late update must not reload after ${invalidate}`);
    assert.equal(f.writes.length, 0, `Late update must not write success timestamp after ${invalidate}`);
  }
}
async function testUpdaterQueuedTickAfterStop() {
  for (const reconnect of [false, true]) {
    const f = updaterFixture(), context = {};
    let probes = 0;
    f.modules['./CoreApi'].CoreApi.isAlive = async () => { probes++; return true; };
    f.updater.start(context);
    const queued = [...f.timers.values()][0].fn;
    f.updater.stop();
    if (reconnect) f.updater.start({});
    queued(); // clearInterval cannot remove a callback already queued by the event loop.
    await flush();
    assert.deepEqual({ probes, downloads: f.updates.length, timestamps: f.writes.length, reloads: f.reloads.length },
      { probes: 0, downloads: 0, timestamps: 0, reloads: 0 },
      `Queued old timer must have no side effects after stop${reconnect ? '/start' : ''}`);
    if (reconnect) {
      [...f.timers.values()][0].fn();
      await flush();
      assert.equal(f.updates.length, 1, 'New schedule must still download');
      assert.equal(f.writes.length, 1, 'New schedule must still write timestamp');
      assert.equal(f.reloads.length, 1, 'New schedule must still reload');
    }
  }
}
async function testUpdaterOverlapAndRetry() {
  const f = updaterFixture(), download = deferred(), context = {};
  f.modules['./ProfileStore'].ProfileStore.updateFromOrigin = () => {
    f.updates.push('attempt'); return download.promise;
  };
  f.updater.start(context);
  const first = f.updater.checkAndRun(context);
  await flush();
  const second = f.updater.checkAndRun(context);
  await flush();
  assert.equal(f.updates.length, 1, 'Overlapping ticks must not duplicate subscription download');
  download.reject(new Error('injected download failure'));
  await Promise.all([first, second]);
  f.modules['./ProfileStore'].ProfileStore.updateFromOrigin = async () => {};
  await f.updater.checkAndRun(context);
  assert.equal(f.reloads.length, 1, 'Failed check must release latch for retry');
}
(async () => {
  const cases = [testRapidReconnect, testKeeperContext, testUpdaterContext, testLateTraffic, testLateHeartbeat, testPreTaskFailure, testPendingPublish,
    testPartialListeners, testCancelProbeRace, testUserCancel, testUpdaterLateCompletion, testUpdaterQueuedTickAfterStop, testUpdaterOverlapAndRetry];
  for (const test of cases) {
    if (!process.env.RUNTIME_CASE || process.env.RUNTIME_CASE === test.name) {
      await test();
      console.log('PASS: ' + test.name);
    }
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
