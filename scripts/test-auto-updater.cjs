const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
let now = 100000000, active = 'A', enabled = true, alive = true, updates = [], fail = false, blocked, release;
const states = new Map();
const state = file => states.get(file) ?? { id: file, attemptedAt: 0, succeededAt: 0, failedAt: 0, retryAt: 0 };
const store = { getActiveFile: () => active, getOrigin: () => active === 'local' ? '' : 'synthetic',
  updateState: (_, file) => ({ ...state(file) }), saveUpdateState: (_, file, value) => states.set(file, { ...value }) };
const sandbox = { exports: {}, Date: { now: () => now }, setInterval: () => 1, clearInterval() {}, require: key => ({
  './Settings': { Settings: { load: () => ({ autoUpdate: enabled, autoUpdateIntervalHours: 24 }) } },
  './ProfileStore': { ProfileStore: store }, './CoreApi': { CoreApi: { isAlive: async () => alive } },
  './Logger': { Logger: { info() {}, warn() {} } }, './ProfileTransactions': { ProfileTransactions: {
    update: async (_, file, current) => { updates.push(file); if (blocked) await new Promise(resolve => { release = resolve; });
      if (!current()) throw Error('cancelled'); if (fail) throw Error('synthetic failure'); }
  } }
}[key] ?? {}) };
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/AutoUpdater.ets', 'utf8')).outputText, sandbox);
const updater = sandbox.exports.AutoUpdater;
(async () => {
  await updater.checkAndRun({}); await updater.checkAndRun({}); assert.deepEqual(updates, ['A']);
  active = 'B'; await updater.checkAndRun({}); assert.deepEqual(updates, ['A', 'B']);
  active = 'A'; now += 24 * 3600000; fail = true;
  await updater.checkAndRun({}); assert.equal(state('A').failedAt, now);
  await updater.checkAndRun({}); assert.equal(updates.length, 3, 'failure is bounded to hourly retry');
  fail = false; now++; await updater.retry({}); assert.equal(updates.length, 4);
  assert.equal(state('A').succeededAt, now);
  // Rename retains the record's identity and deadline; delete/reimport gets a new one.
  states.set('renamed', states.get('A')); active = 'renamed'; await updater.checkAndRun({}); assert.equal(updates.length, 4);
  active = 'new'; blocked = true; const pending = updater.checkAndRun({});
  await new Promise(resolve => setImmediate(resolve));
  await updater.checkAndRun({}); assert.equal(updates.length, 5, 'only one in-flight fetch');
  updater.stop(); release(); await pending;
  assert.equal(state('new').succeededAt, 0, 'old timer generation cannot report success');
  active = 'local'; await updater.checkAndRun({}); assert.equal(updates.length, 5);
  console.log('PASS: independent source clocks, retry deadlines, rename identity, concurrency and stale timer results');
})().catch(error => { console.error(error); process.exitCode = 1; });
