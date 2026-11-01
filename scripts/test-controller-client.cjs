// Usage: source scripts/env.sh && node scripts/test-controller-client.cjs
// Exercise the actual ArkTS client with synthetic credentials and mocked kits.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const source = fs.readFileSync(path.join(__dirname, '../cexing/entry/src/main/ets/lib/CoreApi.ets'), 'utf8');
const output = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
const secret = 'a'.repeat(64);
let stored = secret;
const logs = [];
const requests = [];
const sockets = [];
const timers = new Map();
let nextTimer = 1;
let destroys = 0;
let totals = null;
let routes = null;
let versionCode = 200;
const polls = [];

const modules = {
  '@kit.BasicServicesKit': { deviceInfo: { sdkApiVersion: 26 } },
  '@kit.AbilityKit': { application: { getApplicationContext: () => ({ createModuleContext: () => ({ filesDir: '/private/entry/files' }) }) } },
  '@kit.CoreFileKit': { fileIo: { readTextSync: file => {
    assert.equal(file, '/private/entry/files/controller-security/secret');
    if (stored === null) throw new Error('unavailable');
    return stored;
  } } },
  '@kit.ArkTS': { util: {} },
  './Logger': { Logger: { info: (...args) => logs.push(args), warn: (...args) => logs.push(args) } },
  '@kit.NetworkKit': {
    http: { RequestMethod: { GET: 'GET', PUT: 'PUT', POST: 'POST' }, createHttp: () => ({
      request: async (url, options) => {
        requests.push({ url, options });
        if (url.endsWith('/identity?transport=poll')) return new Promise((resolve, reject) => polls.push({ resolve, reject, options, url }));
        if (url.endsWith('/version')) return { responseCode: versionCode, result: '{"version":"test"}' };
        if (url.endsWith('/connections')) return { responseCode: 200, result: JSON.stringify(totals) };
        if (url.endsWith('/ohos/app-routes')) return { responseCode: 200, result: JSON.stringify(routes) };
        if (url.endsWith('/ohos/app-routes/recover') || url.endsWith('/ohos/app-traffic/route')) return { responseCode: 204, result: '' };
        // An exception can contain the sensitive header. Client must not log it.
        throw new Error(`transport failed Authorization: ${options.header.Authorization}`);
      }, destroy: () => { destroys++; }
    }) },
    webSocket: { createWebSocket: () => {
      const events = {};
      const ws = {
        events, on: (name, callback) => { events[name] = callback; }, off: name => { delete events[name]; },
        close: async () => { ws.closed = true; },
        connect: async (url, options) => { ws.url = url; ws.options = options; }
      };
      sockets.push(ws);
      return ws;
    } }
  }
};
const context = { exports: {}, require: name => { assert.ok(name in modules, name); return modules[name]; },
  setTimeout: fn => { const id = nextTimer++; timers.set(id, fn); return id; },
  clearTimeout: id => timers.delete(id), Uint8Array, ArrayBuffer, JSON, Object, Promise };
vm.runInNewContext(output, context);
const { CoreApi } = context.exports;
function fireTimer() { const [id, fn] = timers.entries().next().value; timers.delete(id); fn(); }
(async () => {
  // Cold process resolves entry module context without modifying AppRuntime.
  assert.equal(await CoreApi.isAlive(), true);
  assert.equal(requests[0].options.header.Authorization, `Bearer ${secret}`);
  assert.equal(await CoreApi.getConfigs(), null);
  assert.equal(destroys, 2);
  stored = null;
  assert.equal(await CoreApi.isAlive(), false);
  assert.equal(requests.length, 2, 'Missing credentials must prevent anonymous requests');
  stored = 'bad';
  assert.equal(CoreApi.getControllerAccess(), null);
  stored = secret;
  const watcher = new CoreApi.StreamWatcher();
  let received = 0;
  watcher.start('/traffic', () => { received++; });
  assert.equal(sockets.length, 1);
  assert.equal(sockets[0].url, 'ws://127.0.0.1:9090/traffic');
  assert.equal(sockets[0].options.header.Authorization, `Bearer ${secret}`);
  assert.equal(sockets[0].options.supportOriginPort, true, 'Native handshake must retain the controller origin port');
  assert.equal(sockets[0].options.proxy, 'no-proxy', 'Loopback authentication must stay off system proxies');
  sockets[0].events.message({}, JSON.stringify({ up: 1, down: 0, arbitrary: secret }));
  assert.equal(received, 1);
  const staleError = sockets[0].events.error;
  staleError(new Error(secret));
  assert.equal(sockets[0].closed, true, 'Failed sockets must be closed before reconnect');
  assert.equal(timers.size, 1);
  stored = 'b'.repeat(64);
  fireTimer();
  assert.equal(sockets.length, 2);
  assert.equal(sockets[1].options.header.Authorization, `Bearer ${stored}`, 'Reconnect must reread shared credential');
  staleError(new Error(secret));
  assert.equal(timers.size, 1, 'New socket retains its no-data deadline');
  sockets[1].events.close();
  const staleTimer = timers.values().next().value;
  watcher.stop();
  assert.equal(timers.size, 0, 'Stop must clear pending reconnect');
  watcher.start('/logs?level=info', () => {});
  staleTimer();
  assert.equal(sockets.length, 3, 'Old session timer must not open a duplicate connection');
  watcher.stop();
  watcher.start('/traffic?token=secret', () => {});
  assert.equal(sockets.length, 3, 'Caller-supplied credential URLs must be rejected');
  assert.equal(await CoreApi.checkController(), 'reachable');
  versionCode = 401; assert.equal(await CoreApi.checkController(), 'authorization');
  stored = null; assert.equal(await CoreApi.checkController(), 'credentials'); stored = secret;
  totals = { uploadTotal: 0 }; assert.equal(await CoreApi.getTraffic(), null);
  totals = { uploadTotal: -1, downloadTotal: 0 }; assert.equal(await CoreApi.getTraffic(), null);
  totals = { uploadTotal: 0, downloadTotal: 0 };
  assert.equal((await CoreApi.getTraffic()).up, 0);
  const validated = new CoreApi.StreamWatcher();
  let validSamples = 0;
  validated.start('/traffic', () => validSamples++);
  const validSocket = sockets.at(-1);
  validSocket.events.message({}, '{"up":0}'); assert.equal(validSamples, 0);
  validSocket.events.message({}, '{"up":-1,"down":0}'); assert.equal(validSamples, 0);
  validSocket.events.message({}, '{"up":0,"down":0}'); assert.equal(validSamples, 1, 'real zero is valid');
  const lateMessage = validSocket.events.message; validated.stop();
  lateMessage({}, '{"up":9,"down":9}'); assert.equal(validSamples, 1);
  const stalled = new CoreApi.StreamWatcher(); stalled.start('/traffic', () => {});
  const silentSocket = sockets.at(-1); fireTimer();
  assert.equal(silentSocket.closed, true, 'handshake/no-data timeout releases silent socket');
  assert.equal(timers.size, 1, 'bounded silent stream schedules retry'); stalled.stop();
  const drain = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
  for (const api of [23, 24, 25]) {
    modules['@kit.BasicServicesKit'].deviceInfo.sdkApiVersion = api;
    const legacy = new CoreApi.StreamWatcher(); let batches = 0;
    const socketCount = sockets.length;
    legacy.start('/ohos/app-traffic/identity', () => batches++);
    assert.equal(sockets.length, socketCount, `API ${api} uses HTTP identity transport`);
    assert.equal(polls.at(-1).options.header.Authorization, `Bearer ${stored}`);
    assert.equal(polls.at(-1).options.usingProxy, false);
    const active = polls.at(-1);
    active.resolve({ responseCode: 200, result: JSON.stringify({ session: 'b'.repeat(32), requests: [] }) });
    await drain(); assert.equal(batches, 1); assert.notEqual(polls.at(-1), active, 'Long poll renews immediately');
    const late = polls.at(-1); const beforeDestroy = destroys;
    legacy.stop(); assert.equal(destroys, beforeDestroy + 1, 'Stop destroys the pending HTTP request');
    late.resolve({ responseCode: 200, result: JSON.stringify({ session: 'b'.repeat(32), requests: [] }) });
    await drain(); assert.equal(batches, 1, 'Stopped poll cannot deliver or restart');
    assert.equal(destroys, beforeDestroy + 1, 'Cancelled request destroyed once');
    legacy.start('/ohos/app-traffic/identity', () => batches++);
    polls.at(-1).resolve({ responseCode: 200, result: '{"session":"bad","requests":[]}' });
    await drain(); assert.equal(batches, 1); assert.equal(timers.size, 1, 'Malformed batch backs off');
    stored = 'c'.repeat(64); fireTimer();
    assert.equal(polls.at(-1).options.header.Authorization, `Bearer ${stored}`, 'Poll retry refreshes credentials');
    polls.at(-1).resolve({ responseCode: 409, result: '{}' });
    await drain(); assert.equal(timers.size, 1, 'Consumer conflict uses bounded backoff');
    fireTimer(); polls.at(-1).reject(new Error(`Authorization: ${stored}`));
    await drain(); assert.equal(timers.size, 1, 'Transport failure retries without logging secrets');
    legacy.stop(); assert.equal(timers.size, 0);
  }
  modules['@kit.BasicServicesKit'].deviceInfo.sdkApiVersion = 26;
  const modern = new CoreApi.StreamWatcher(); let modernBatches = 0;
  modern.start('/ohos/app-traffic/identity', () => modernBatches++);
  const modernSocket = sockets.at(-1);
  assert.equal(modernSocket.options.supportOriginPort, true);
  modernSocket.events.message({}, '{"session":"bad","requests":[]}');
  assert.equal(modernBatches, 0);
  modernSocket.events.message({}, JSON.stringify({ session: 'b'.repeat(32), requests: [] }));
  assert.equal(modernBatches, 1); modern.stop();
  assert.ok(!JSON.stringify(logs).includes(secret));
  assert.ok(!JSON.stringify(logs).includes(stored));
  assert.equal(await CoreApi.applyConfigText('synthetic', 'b'.repeat(32)), 'unknown');
  assert.equal(JSON.parse(requests.at(-1).options.extraData).expectedSession, 'b'.repeat(32), 'transaction reload binds the intended core generation');
  routes = { schemaVersion: 1, session: 'd'.repeat(32), state: 'running', storage: 'ready', blocked: false,
    rules: [{ uid: 1001, target: 'DIRECT', available: true }], routeTargets: ['DIRECT'] };
  assert.equal((await CoreApi.getAppRoutes()).rules[0].uid, 1001);
  const { validAppRouteStatus } = context.exports;
  assert.equal(validAppRouteStatus({ ...routes, rules: [routes.rules[0], routes.rules[0]] }), false);
  assert.equal(validAppRouteStatus({ ...routes, rules: [{ ...routes.rules[0], uid: 2147483648 }] }), false);
  assert.equal(validAppRouteStatus({ ...routes, rules: [{ ...routes.rules[0], target: 'x'.repeat(257) }] }), false);
  assert.equal(validAppRouteStatus({ ...routes, storage: 'unknown' }), false);
  routes.storage = 'corrupt'; routes.blocked = true;
  assert.equal((await CoreApi.getAppRoutes()).blocked, true, 'Storage errors remain visible');
  routes.schemaVersion = 2; assert.equal(await CoreApi.getAppRoutes(), null);
  const beforeInvalid = requests.length;
  assert.equal(await CoreApi.recoverAppRoutes('bad', 'reset'), false);
  assert.equal(await CoreApi.recoverAppRoutes('d'.repeat(32), 'erase'), false);
  assert.equal(await CoreApi.setAppRoute('d'.repeat(32), 2147483648, ''), false);
  assert.equal(await CoreApi.setAppRoute('d'.repeat(32), 1001, 'x'.repeat(257)), false);
  assert.equal(requests.length, beforeInvalid, 'Invalid rule writes never reach transport');
  assert.equal(await CoreApi.recoverAppRoutes('d'.repeat(32), 'retry'), true);
  assert.equal(requests.at(-1).options.method, 'POST');
  assert.equal(requests.at(-1).options.header.Authorization, `Bearer ${stored}`);
  assert.deepEqual(JSON.parse(requests.at(-1).options.extraData), { session: 'd'.repeat(32), action: 'retry' });
  assert.equal(await CoreApi.setAppRoute('d'.repeat(32), 1001, ''), true);
  console.log('PASS: shared REST/WS authentication, fail-closed reads, redacted logs, reconnect and stale-session cleanup');
})().catch(error => { console.error(error); process.exitCode = 1; });
