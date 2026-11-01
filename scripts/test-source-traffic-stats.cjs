const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const drain = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
let now = new Date(2026, 10, 1, 12).getTime();
class TestDate extends Date { static now() { return now; } }
function load(file, modules = {}) {
  const context = { exports: {}, Date: TestDate, require: key => { assert.ok(key in modules, key); return modules[key]; } };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8')).outputText, context); return context.exports;
}
const period = load('cexing/entry/src/main/ets/lib/TrafficLedger.ets');
const ledger = load('cexing/entry/src/main/ets/lib/SourceTrafficLedger.ets', { './TrafficLedger': period });
const controller = { status: 2, host: 'host-a', trafficSession() { return this.host; } };
const zero = () => ({ upload: 0, download: 0, connections: 0, active: 0 });
let session = 'a'.repeat(32), startedAt = now, count = 10, summaryGate = null, identityGate = null;
function snapshot() {
  const routes = { proxy: { ...zero(), upload: count }, direct: zero(), unclassified: zero() };
  return { session, startedAt, state: 'running', partial: false, totals: routes,
    apps: [{ uid: 1001, lastSeen: now, recent: [], routeTarget: 'DIRECT', identityStatus: 'uid', bundleName: '', bundleVerified: false, routes }] };
}
const api = { getControllerSession: async () => identityGate ? identityGate() : session,
  getAppTraffic: async () => summaryGate ? summaryGate : snapshot() };
const disk = { value: '', staged: '', fail: false, unreadable: false, puts: 0, flushes: 0, active: 0, peak: 0, gate: null };
const store = { getSync: () => { if (disk.unreadable) throw Error('read failed'); return disk.value; },
  putSync: (_, text) => { disk.staged = text; disk.puts++; },
  flush: async () => {
    disk.flushes++; disk.active++; disk.peak = Math.max(disk.peak, disk.active); const value = disk.staged;
    try { if (disk.gate) await disk.gate; if (disk.fail) throw Error('flush failed'); disk.value = value; }
    finally { disk.active--; }
  } };
function service() {
  return load('cexing/entry/src/main/ets/lib/SourceTrafficStats.ets', {
    '@kit.ArkData': { preferences: { getPreferencesSync: (_, options) => { assert.equal(options.name, 'cexing_source_traffic_v1'); return store; } } },
    './CoreApi': { CoreApi: api }, './VpnController': { VpnController: controller, VpnStatus: { Connected: 2 } },
    './TrafficLedger': period, './SourceTrafficLedger': ledger
  }).SourceTrafficStats;
}
const total = view => view.rows.reduce((n, row) => n + row.routes.proxy.upload, 0);
(async () => {
  let stats = service(); stats.initialize({}); assert.equal(stats.view().ready, false);
  let release; disk.gate = new Promise(resolve => { release = resolve; });
  await stats.sample(); assert.equal(stats.view().saved, false);
  const pendingLabel = stats.setLabel(1001, 'Browser');
  count = 11; now++; await stats.sample(); count = 12; now++; await stats.sample();
  assert.equal(disk.flushes, 1); assert.equal(disk.peak, 1);
  release(); await drain(); disk.gate = null;
  assert.equal(disk.flushes, 2, 'Only the latest pending snapshot follows the in-flight flush');
  assert.equal(stats.view().saved, true); assert.equal(total(stats.view()), 12);
  assert.equal(JSON.parse(disk.value).all.rows[0].counts[0], 12);
  assert.equal(await pendingLabel, true, 'Concurrent note shares the writer and survives newer samples');
  assert.equal(JSON.parse(disk.value).identities.find(item => item.uid === 1001).label, 'Browser');
  assert.equal(await stats.setLabel(-1, 'unknown app'), false);
  stats = service(); stats.initialize({}); assert.equal(stats.view().ready, true);
  assert.equal(stats.view().labels['1001'], 'Browser'); assert.equal(stats.view().numbers['1001'], 1);
  await stats.sample(); await drain(); assert.equal(total(stats.view()), 12, 'Restored checkpoint prevents re-counting');
  disk.fail = true; count = 13; now++; await stats.sample(); await drain();
  assert.equal(stats.view().saved, false); assert.equal(total(stats.view()), 13);
  disk.fail = false; await stats.sample(); await drain(); assert.equal(stats.view().saved, true);
  assert.equal(total(stats.view()), 13, 'Flush retry must not add traffic twice');
  let finish; summaryGate = new Promise(resolve => { finish = resolve; });
  const old = snapshot(), inflight = stats.sample(); await drain();
  controller.host = 'host-b'; session = 'b'.repeat(32); startedAt = ++now; count = 5;
  stats.invalidate(); assert.equal(stats.view().live, null); assert.equal(stats.view('current').rows.length, 0);
  finish(old); await inflight; summaryGate = null; await drain();
  assert.equal(total(stats.view()), 13, 'Late previous-host result cannot enter persistent history');
  await stats.sample(); await drain(); assert.equal(total(stats.view()), 18);
  assert.equal(stats.view().labels['1001'], 'Browser'); assert.equal(stats.view().numbers['1001'], 1);
  let calls = 0; identityGate = () => ++calls === 1 ? session : 'c'.repeat(32);
  count = 6; await stats.sample(); assert.equal(stats.view().readFailed, true);
  assert.equal(stats.view().live, null); assert.equal(total(stats.view()), 18);
  identityGate = null; await stats.sample(); await drain(); assert.equal(total(stats.view()), 19);
  assert.equal(stats.view().readFailed, false);
  const good = disk.value;
  disk.value = '{broken'; const puts = disk.puts;
  const corrupt = service(); corrupt.initialize({}); assert.equal(corrupt.view().historyUnavailable, true);
  await corrupt.sample(); await drain(); assert.equal(corrupt.view().saved, false);
  assert.equal(disk.value, '{broken'); assert.equal(disk.puts, puts, 'Corrupt durable data must never be overwritten');
  disk.value = good; disk.unreadable = true;
  const retry = service(); retry.initialize({}); assert.equal(retry.view().historyUnavailable, true);
  disk.unreadable = false; retry.initialize({}); assert.equal(retry.view().historyUnavailable, false);
  assert.equal(total(retry.view()), 19);
  console.log('PASS: source persistence single-writer/latest-pending, flush retry, cold recovery, label durability, stale session rejection and corrupt-file preservation');
})().catch(error => { console.error(error); process.exitCode = 1; });
