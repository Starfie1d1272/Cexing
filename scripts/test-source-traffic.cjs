const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
function load(file, modules = {}) {
  const context = { exports: {}, require: key => { assert.ok(key in modules, key); return modules[key]; }, Date };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8')).outputText, context);
  return context.exports;
}
const periods = load('cexing/entry/src/main/ets/lib/TrafficLedger.ets');
const ledger = load('cexing/entry/src/main/ets/lib/SourceTrafficLedger.ets', { './TrafficLedger': periods });
const { SourceTrafficState, recordSourceTraffic, restoreSourceTraffic, sourceRows } = ledger;
const start = new Date(2026, 10, 1, 12).getTime();
const zero = () => ({ upload: 0, download: 0, connections: 0, active: 0 });
function snapshot(session, startedAt, rows, recent = []) {
  const apps = rows.map(([uid, count]) => ({ uid, identityStatus: uid < 0 ? 'unknown' : 'uid', bundleName: '', bundleVerified: false,
    routeTarget: 'DIRECT', lastSeen: startedAt, recent, routes: { proxy: { ...zero(), upload: count }, direct: zero(), unclassified: zero() } }));
  return { schemaVersion: 1, session: session.repeat(32), state: 'running', startedAt, endedAt: 0, partial: false,
    routeTargets: ['DIRECT'], identityFailures: {}, apps,
    totals: { proxy: { ...zero(), upload: rows.reduce((n, row) => n + row[1], 0) }, direct: zero(), unclassified: zero() } };
}
const value = (rows, uid) => rows.find(row => row.uid === uid)?.counts[0] ?? 0;
const total = rows => rows.reduce((n, row) => n + row.counts[0], 0);
let state = new SourceTrafficState();
assert.equal(recordSourceTraffic(state, 'host-a', snapshot('a', start, [[-1, 10]]), start + 100), true);
assert.equal(total(state.all.rows), 10, 'First session snapshot includes its full initial traffic');
state = restoreSourceTraffic(JSON.stringify(state));
recordSourceTraffic(state, 'host-a', snapshot('a', start, [[-1, 10]]), start + 200);
assert.equal(total(state.all.rows), 10, 'Cold recovery cannot count the same snapshot twice');
recordSourceTraffic(state, 'host-rebound', snapshot('a', start, [[-1, 3], [1001, 7]]), start + 300);
assert.equal(total(state.all.rows), 10); assert.equal(value(state.all.rows, -1), 3);
assert.equal(value(state.days[0].rows, 1001), 7, 'Same-day reattribution corrects unknown bytes');
state.identities.find(row => row.uid === 1001).label = 'Browser note';
state = restoreSourceTraffic(JSON.stringify(state));
assert.equal(state.identities.find(row => row.uid === 1001).label, 'Browser note');
assert.equal(state.identities.find(row => row.uid === 1001).number, 1);
recordSourceTraffic(state, 'host-a', snapshot('a', start, [[-1, 3], [1001, 8]]), start + 400);
assert.equal(total(state.all.rows), 11);
const nextDay = new Date(2026, 10, 2, 0, 1).getTime();
recordSourceTraffic(state, 'host-a', snapshot('a', start, [[-1, 3], [1001, 10]]), nextDay);
assert.equal(total(state.all.rows), 13);
let day = state.days.find(row => row.key === '2026-11-02');
assert.equal(total(day.rows), 0); assert.equal(day.partial, true, 'Cross-midnight bytes have no invented daily split');
recordSourceTraffic(state, 'host-a', snapshot('a', start, [[-1, 3], [1001, 15]]), nextDay + 100);
assert.equal(total(day.rows), 0, 'Transaction replaces old references');
day = state.days.find(row => row.key === '2026-11-02'); assert.equal(total(day.rows), 5);
recordSourceTraffic(state, 'host-a', snapshot('a', start, [[-1, 1], [1001, 17]]), nextDay + 200);
assert.equal(total(state.all.rows), 18); assert.equal(value(state.all.rows, -1), 1);
assert.equal(total(state.days.find(row => row.key === '2026-11-02').rows), 5, 'Late prior-day attribution cannot inflate the current day');
assert.equal(value(state.months[0].rows, 1001), 17, 'Same-month attribution remains recoverable');
const savedCheckpoint = JSON.stringify(state.checkpoint);
assert.equal(recordSourceTraffic(state, 'host-a', snapshot('a', start, [[1001, 1]]), nextDay + 300), false);
assert.equal(JSON.stringify(state.checkpoint.rows), JSON.stringify(JSON.parse(savedCheckpoint).rows), 'Regressions retain the last proven checkpoint');
assert.equal(total(state.all.rows), 18);
recordSourceTraffic(state, 'host-a', snapshot('a', start, [[-1, 1], [1001, 20]]), nextDay - 100);
assert.equal(total(state.all.rows), 21); assert.equal(state.all.partial, true);
recordSourceTraffic(state, 'host-b', snapshot('b', nextDay + 1000, [[1001, 9]]), nextDay + 1100);
assert.equal(total(state.all.rows), 30, 'A new session adds the full first snapshot');
assert.equal(state.identities.find(row => row.uid === 1001).number, 1);
assert.equal(state.identities.find(row => row.uid === 1001).label, 'Browser note');
const recentBefore = [{ at: nextDay + 1100, target: 'example.test', route: 'proxy', rule: 'MATCH', policy: ['synthetic'] }];
recordSourceTraffic(state, 'host-b', snapshot('b', nextDay + 1000, [[1001, 9]], recentBefore), nextDay + 1200);
state = restoreSourceTraffic(JSON.stringify(state));
recordSourceTraffic(state, 'host-c', snapshot('c', nextDay + 1300, [[1001, 0]]), nextDay + 1400);
assert.equal(state.identities.find(row => row.uid === 1001).recent[0].target, 'example.test', 'An empty new session preserves historical targets');
assert.equal(state.identities.find(row => row.uid === 1001).lastSeen, nextDay + 1300);
const projected = sourceRows(state, state.all.rows);
assert.equal(projected.find(row => row.uid === 1001).routeTarget, '');
assert.equal(projected.find(row => row.uid === 1001).routes.proxy.active, 0);
restoreSourceTraffic(JSON.stringify(state));
const invalid = JSON.parse(JSON.stringify(state)); invalid.checkpoint.rows[0].counts[0] += 100000;
assert.throws(() => restoreSourceTraffic(JSON.stringify(invalid)), /checkpoint/);
const duplicate = JSON.parse(JSON.stringify(state)); duplicate.identities.push(duplicate.identities[0]);
assert.throws(() => restoreSourceTraffic(JSON.stringify(duplicate)), /identities/);
const overflow = JSON.parse(JSON.stringify(state)); overflow.all.rows[0].counts[0] = Number.MAX_SAFE_INTEGER + 1;
assert.throws(() => restoreSourceTraffic(JSON.stringify(overflow)), /ledger/);

const months = new SourceTrafficState();
const endMonth = new Date(2026, 10, 30, 23, 59).getTime();
recordSourceTraffic(months, 'host', snapshot('c', endMonth, [[-1, 10]]), endMonth + 100);
const december = new Date(2026, 11, 1, 0, 1).getTime();
recordSourceTraffic(months, 'host', snapshot('c', endMonth, [[1001, 12]]), december);
assert.equal(total(months.all.rows), 12);
assert.equal(total(months.months.find(row => row.key === '2026-12').rows), 0);
assert.ok(months.months.every(row => row.partial));

const retention = new SourceTrafficState();
for (let month = 0; month < 16; month++) {
  for (let day = 1; day <= 3; day++) {
    const at = new Date(2025, month, day, 12).getTime();
    recordSourceTraffic(retention, 'host', snapshot('d', at, [[1001, 1]]), at + 100);
  }
}
assert.equal(retention.days.length, 35); assert.equal(retention.months.length, 14);
assert.equal(total(retention.all.rows), 48); restoreSourceTraffic(JSON.stringify(retention));
const capacity = new SourceTrafficState();
const largeRecent = Array.from({ length: 4 }, (_, index) => ({ at: start + index, route: 'proxy', target: 'x'.repeat(1024), rule: 'MATCH', policy: Array(8).fill('p'.repeat(256)) }));
assert.equal(recordSourceTraffic(capacity, 'host', snapshot('e', start, Array.from({ length: 128 }, (_, i) => [i, 1]), largeRecent), start + 100), true);
const beforeCapacity = JSON.stringify(capacity.checkpoint);
assert.equal(recordSourceTraffic(capacity, 'host', snapshot('f', start + 200, Array.from({ length: 128 }, (_, i) => [i + 128, 1]), largeRecent), start + 300), false);
assert.equal(JSON.stringify(capacity.checkpoint.rows), JSON.stringify(JSON.parse(beforeCapacity).rows));
assert.equal(total(capacity.all.rows), 128, 'Over-capacity snapshot cannot partially commit totals or checkpoint');
assert.ok(JSON.stringify(capacity).length <= ledger.SOURCE_JSON_LIMIT);
restoreSourceTraffic(JSON.stringify(capacity));
console.log('PASS: durable source accounting, reattribution, clock/calendar boundaries, stable labels, bounded retention and corruption/capacity rejection');
