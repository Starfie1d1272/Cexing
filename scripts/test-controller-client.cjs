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
let versionCode = 200;

const modules = {
  '@kit.AbilityKit': { application: { getApplicationContext: () => ({ createModuleContext: () => ({ filesDir: '/private/entry/files' }) }) } },
  '@kit.CoreFileKit': { fileIo: { readTextSync: file => {
    assert.equal(file, '/private/entry/files/controller-security/secret');
    if (stored === null) throw new Error('unavailable');
    return stored;
  } } },
  '@kit.ArkTS': { util: {} },
  './Logger': { Logger: { info: (...args) => logs.push(args), warn: (...args) => logs.push(args) } },
  '@kit.NetworkKit': {
    http: { RequestMethod: { GET: 'GET', PUT: 'PUT' }, createHttp: () => ({
      request: async (url, options) => {
        requests.push({ url, options });
        if (url.endsWith('/version')) return { responseCode: versionCode, result: '{"version":"test"}' };
        if (url.endsWith('/connections')) return { responseCode: 200, result: JSON.stringify(totals) };
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
  assert.ok(!JSON.stringify(logs).includes(secret));
  assert.ok(!JSON.stringify(logs).includes(stored));
  console.log('PASS: shared REST/WS authentication, fail-closed reads, redacted logs, reconnect and stale-session cleanup');
})().catch(error => { console.error(error); process.exitCode = 1; });
