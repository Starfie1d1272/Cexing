// Host-transpiled page session observer with deterministic transport/timers; no device claim.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const version = 'a'.repeat(64), secret = 'b'.repeat(64);
let identity = 'c'.repeat(32), status = 2, ui = true, deployment = version;
let pending;
const timers = new Map(); let id = 0;
const events = [];
const CoreApi = { bindContext() {}, getControllerSession: async () => pending || identity,
  getControllerUiStatus: async () => ({ available: ui }),
  getControllerAccess: () => ({ httpBase: 'http://127.0.0.1:9090', secret }) };
const modules = { './CoreApi': { CoreApi }, './VpnController': {
  VpnStatus: { Connected: 2 }, VpnController: { get status() { return status; } }
}, './ZashboardAssets': { ZashboardAssets: { prepare: async () => ({ directory: '/private/ui', version: deployment }) } },
'./ZashboardPin': { ZASHBOARD_VERSION: version } };
const context = { exports: {}, require: name => modules[name], setTimeout: fn => { timers.set(++id, fn); return id; }, clearTimeout: id => timers.delete(id) };
const src = fs.readFileSync(path.join(__dirname, '../cexing/entry/src/main/ets/lib/ZashboardSession.ets'), 'utf8');
vm.runInNewContext(ts.transpileModule(src, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText, context);
const { ZashboardSession } = context.exports;
const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
const tick = async () => { const [key, fn] = timers.entries().next().value; timers.delete(key); fn(); await flush(); };
(async () => {
  const session = new ZashboardSession();
  const changed = (view, error) => events.push({ view, error });
  session.start({}, changed); await flush();
  assert.equal(events[0].view.url, 'http://127.0.0.1:9090/ui/');
  assert.ok(!events[0].view.url.includes(secret));
  assert.ok(events[0].view.bootstrap.includes(secret));
  await tick(); assert.equal(events.length, 1, 'Healthy generation must retain the page');
  identity = null; await tick(); assert.equal(events[1].view, null, 'Lost authentication must revoke page');
  identity = 'd'.repeat(32); await tick(); assert.ok(events[2].view, 'New generation must reopen');
  ui = false; await tick(); assert.equal(events[3].view, null);
  ui = true; deployment = 'e'.repeat(64); await tick(); assert.equal(events[4].view, null, 'Old fallback build must not receive credentials');
  deployment = version;
  let resolve; pending = new Promise(done => { resolve = done; });
  const old = timers.values().next().value;
  session.stop(); old(); session.start({}, changed); session.stop();
  resolve('f'.repeat(32)); pending = null; await flush();
  assert.equal(events.length, 5, 'Stopped/stale requests must not authorize');
  assert.equal(timers.size, 0, 'Stopped observer must not retry');
  const script = ZashboardSession.bootstrap(secret, version);
  for (const [pathname, search, top, expected] of [
    [`/ui/versions/${version}/`, '', true, true], ['/ui/', '', true, false],
    [`/ui/versions/${version}/`, '?secret=test', true, false],
    [`/ui/versions/${version}/`, '', false, false],
  ]) {
    const window = {}; window.top = top ? window : {};
    vm.runInNewContext(script, { window, location: { origin: 'http://127.0.0.1:9090', pathname, search } });
    assert.equal(!!window.__OHOS_PANEL_BOOTSTRAP__, expected);
  }
  assert.equal(ZashboardSession.bootstrap('invalid', version), '');
  status = 0; session.start({}, changed); await flush(); session.stop();
  assert.equal(events.at(-1).view, null);
  console.log('PASS: authenticated session generations, loss/reentry, pinned-only bootstrap, stale-stop cleanup; host mock only');
})().catch(error => { console.error(error); process.exitCode = 1; });
