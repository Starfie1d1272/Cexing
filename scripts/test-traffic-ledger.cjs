// Actual ArkTS reducer and service, deterministic counters/clock/persistence.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
function load(name, modules = {}, extras = {}) {
  const source = fs.readFileSync(`cexing/entry/src/main/ets/lib/${name}.ets`, 'utf8');
  const code = ts.transpileModule(source).outputText;
  const sandbox = { exports: {}, require: key => { assert.ok(key in modules, `Missing mock ${key}`); return modules[key]; }, ...extras };
  vm.runInNewContext(code, sandbox); return sandbox.exports;
}
const ledger = load('TrafficLedger');
const { TrafficState, recordTraffic, trafficPeriod, restoreTraffic } = ledger;
const start = Date.UTC(2026, 9, 14, 10);
function sample(s, session, up, down, at = start, period = trafficPeriod(at)) { return recordTraffic(s, session, up, down, at, period); }
{
  const s = new TrafficState();
  sample(s, 'one', 100, 200);
  assert.equal(s.current.up, 0, 'First snapshot is a baseline, not session traffic');
  sample(s, 'one', 150, 290, start + 5000);
  assert.equal(s.current.up, 50); assert.equal(s.current.down, 90);
  const recovered = restoreTraffic(JSON.stringify(s));
  sample(recovered, 'one', 200, 390, start + 60000);
  assert.equal(recovered.current.up, 100, 'Same verified session resumes durable checkpoint');
  assert.equal(recovered.days[0].down, 190);
  sample(recovered, 'two', 400, 900, start + 65000);
  assert.equal(recovered.current.up, 0, 'Reconnect can retain Go process counters');
  sample(recovered, 'two', 430, 970, start + 70000);
  assert.equal(recovered.current.up, 30);
  assert.equal(recovered.days[0].up, 130, 'Never double-count process total on reconnect');
  sample(recovered, 'two', 2, 3, start + 75000);
  assert.equal(recovered.current.up, 30, 'Counter regression cannot invent bytes');
  sample(recovered, 'two', 12, 23, start + 80000);
  assert.equal(recovered.current.up, 40);
  assert.equal(sample(recovered, 'two', NaN, 0), false);
  assert.equal(sample(recovered, 'two', -1, 0), false);
  assert.equal(sample(recovered, 'two', Number.MAX_SAFE_INTEGER + 1, 0), false);
}
{
  const s = new TrafficState(), midnight = Date.UTC(2026, 9, 15);
  sample(s, 'one', 10, 10, midnight - 3000);
  sample(s, 'one', 110, 210, midnight + 3000);
  assert.equal(s.current.up, 100);
  assert.equal(s.days[1].up, 0, 'Unknown midnight allocation is omitted, not interpolated');
  assert.equal(s.days[1].partial, true);
  assert.equal(s.months[0].up, 100, 'Same-month delta stays fully recoverable');
  sample(s, 'one', 120, 230, midnight + 8000);
  assert.equal(s.days[1].up, 10);
  sample(s, 'one', 130, 240, Date.UTC(2026, 10, 1, 0, 0, 2));
  assert.equal(s.months[1].up, 0); assert.equal(s.months[1].partial, true);
}
{
  const s = new TrafficState();
  sample(s, 'one', 10, 10);
  sample(s, 'one', 20, 20, start - 1000);
  assert.equal(s.current.up, 10); assert.equal(s.days[0].up, 0);
  sample(s, 'one', 30, 30, start + 1000, { ...trafficPeriod(start), zone: 60 });
  assert.equal(s.current.up, 20); assert.equal(s.months[0].up, 0, 'Timezone transition is not silently attributed');
  for (let i = 1; i <= 500; i++) sample(s, 'one', 30 + i, 30 + i, start + i * 32 * 86400000);
  assert.equal(s.days.length, 35); assert.equal(s.months.length, 14);
  assert.ok(JSON.stringify(s).length < 32000, 'Storage has a fixed bound');
  assert.throws(() => restoreTraffic('{bad'));
  assert.throws(() => restoreTraffic(JSON.stringify({ ...s, days: Array(36).fill(s.days[0]) })));
  assert.throws(() => restoreTraffic(JSON.stringify({ ...s, current: { ...s.current, up: -1 } })));
  assert.throws(() => restoreTraffic(JSON.stringify({ ...s, checkpoint: { ...s.checkpoint, day: 'broken' } })));
  assert.throws(() => restoreTraffic(JSON.stringify({ ...s, checkpoint: { ...s.checkpoint, month: '2026-99' } })));
  assert.throws(() => restoreTraffic(JSON.stringify({ ...s, days: [s.days[0], s.days[0]] })));
  assert.throws(() => restoreTraffic(JSON.stringify({ ...s, current: { ...s.current, key: 'different' } })));

}
const flush = () => new Promise(resolve => setImmediate(resolve));
(async () => {
  let now = start, pending, writes = [], durable = '', fail = false;
  const controller = { status: 2, session: 'one', trafficSession() { return this.session; } };
  const store = { getSync: () => durable, putSync: (_key, text) => { writes.push(text); }, flush: async () => {
    if (fail) throw Error('disk'); durable = writes.at(-1);
  } };
  const modules = {
    '@kit.ArkData': { preferences: { getPreferencesSync: () => store } },
    './TrafficLedger': ledger,
    './VpnController': { VpnController: controller, VpnStatus: { Connected: 2 } },
    './CoreApi': { CoreApi: { getTraffic: () => new Promise(resolve => { pending = resolve; }) } }
  };
  const FakeDate = class extends Date { static now() { return now; } };
  const { TrafficStats: service } = load('TrafficStats', modules, { Date: FakeDate });
  service.initialize({});
  let request = service.sample(); pending({ up: 100, down: 200 }); await request; await flush();
  now += 5000;
  request = service.sample();
  await service.sample(); // Single flight must not create another request.
  pending({ up: 160, down: 280 }); await request; await flush();
  assert.equal(service.view().current.up, 60); assert.equal(service.rate().down, 16);
  request = service.sample(); service.invalidate(); controller.session = 'two';
  pending({ up: 999, down: 999 }); await request; await flush();
  assert.equal(service.view().current.up, 60, 'Late old-session callback is fenced');
  request = service.sample(); pending({ up: 180, down: 300 }); await request;
  now += 5000; fail = true;
  request = service.sample(); pending({ up: 190, down: 320 }); await request; await flush();
  assert.equal(service.view().saved, false, 'Disk failure is visible and does not stop sampling');
  assert.equal(service.view().current.up, 10);
  now += 20000; assert.equal(service.rate(), null, 'Stale rate is unavailable');
  fail = false;
  request = service.sample(); pending({ up: 200, down: 340 }); await request; await flush();
  assert.equal(service.view().saved, true);
  const { TrafficStats: restarted } = load('TrafficStats', modules, { Date: FakeDate });
  restarted.initialize({}); now += 5000;
  request = restarted.sample(); pending({ up: 220, down: 360 }); await request; await flush();
  assert.equal(restarted.view().current.up, 40, 'Process restart resumes same-identity durable delta');
  durable = '{broken';
  const { TrafficStats: corrupt } = load('TrafficStats', modules, { Date: FakeDate });
  corrupt.initialize({}); request = corrupt.sample(); pending({ up: 300, down: 400 }); await request; await flush();
  assert.equal(corrupt.view().saved, false);
  assert.equal(durable, '{broken', 'Do not overwrite unrecoverable history');
  // Stall disk through many samples: exactly first + latest snapshot survive.
  durable = ''; fail = false; let releaseDisk;
  const slowStore = { ...store, flush: () => new Promise(resolve => { releaseDisk = resolve; }) };
  const slowModules = { ...modules, '@kit.ArkData': { preferences: { getPreferencesSync: () => slowStore } } };
  const { TrafficStats: slow } = load('TrafficStats', slowModules, { Date: FakeDate });
  slow.initialize({});
  const before = writes.length;
  for (let i = 0; i < 200; i++) {
    now += 5000; request = slow.sample(); pending({ up: i, down: i }); await request;
  }
  assert.equal(writes.length - before, 1, 'A blocked disk has only one active snapshot');
  releaseDisk(); await flush();
  assert.equal(writes.length - before, 2, 'Only the latest pending snapshot is then written');
  assert.equal(JSON.parse(writes.at(-1)).checkpoint.up, 199);
  releaseDisk(); await flush();
  let readAttempts = 0;
  const retryModules = { ...modules, '@kit.ArkData': { preferences: { getPreferencesSync: () => {
    if (readAttempts++ === 0) throw Error('temporary storage');
    return { ...store, getSync: () => '' };
  } } } };
  const { TrafficStats: retry } = load('TrafficStats', retryModules, { Date: FakeDate });
  retry.initialize({}); assert.equal(retry.view().saved, false);
  await retry.sample(); // No sample before read succeeds; old disk cannot be overwritten.
  retry.initialize({});
  request = retry.sample(); pending({ up: 10, down: 10 }); await request; await flush();
  assert.equal(retry.view().saved, true, 'Transient read failure can recover');
  console.log('PASS: cumulative ledger, reconnect/recovery/reset, day/month/time changes, bounds, stale callback and persistence failures (host mocks)');
})().catch(error => { console.error(error); process.exitCode = 1; });
