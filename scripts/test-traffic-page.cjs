// Execute actual page lifecycle/chart logic; official HAP compile owns builders.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
let source = fs.readFileSync('cexing/entry/src/main/ets/pages/TrafficPage.ets', 'utf8');
source = source.slice(0, source.indexOf('  @Builder')) + '\n}';
source = source.split('\n').map(line => line.trimStart().startsWith('@') ?
  line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '') : line).join('\n').replace('export struct', 'export class');
let now = 300000, tick, stream, stops = 0;
const listeners = new Set();
const controller = { status: 2, onChanged: fn => listeners.add(fn), offChanged: fn => listeners.delete(fn) };
let points = [{ at: 1000, up: 1, down: 2 }, { at: now - 5000, up: 3, down: 4 }, { at: now, up: 5, down: 6 }];
const modules = {
  '../lib/CoreApi': { CoreApi: { StreamWatcher: class {
    start(path, cb) { assert.equal(path, '/traffic'); stream = cb; }
    stop() { stream = null; stops++; }
  } }, formatRate: n => `${n} B/s` },
  '../lib/TrafficStats': { TrafficStats: { view: () => ({ points, ready: true }) }, TrafficView: class { points = []; } },
  '../lib/VpnController': { VpnController: controller, VpnStatus: { Connected: 2 } },
  './NativeTheme': { NativeTheme: {} }
};
const sandbox = { exports: {}, require: key => { assert.ok(key in modules, key); return modules[key]; },
  Date: { now: () => now }, setInterval: fn => { tick = fn; return 1; }, clearInterval: () => { tick = null; } };
vm.runInNewContext(ts.transpileModule(source).outputText, sandbox);
const page = new sandbox.exports.TrafficPage(); page.aboutToAppear();
assert.equal(listeners.size, 1); assert.ok(stream);
stream({ up: 10, down: 20 }); assert.equal(page.up, '10 B/s');
assert.equal(page.uploads.length, 2, 'Curve must break at unobserved interval');
now += 5000; tick(); assert.equal(page.up, '—', 'Silent socket must not freeze a live-looking speed');
controller.status = 0; for (const listener of listeners) listener(0);
assert.equal(stream, null); assert.equal(page.down, '—');
controller.status = 2; for (const listener of listeners) listener(2);
assert.ok(stream);
page.aboutToDisappear(); assert.equal(stream, null); assert.equal(tick, null); assert.equal(listeners.size, 0);
assert.ok(stops > 0);
console.log('PASS: traffic detail lifecycle, stale speeds and curve gap (host logic; no UI rendering/device claim)');
