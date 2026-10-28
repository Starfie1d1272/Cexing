const uiFixture = require('./ci/ui-fixtures.cjs');
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
const controller = { status: 2, trafficSession: () => 'vpn-session', onChanged: fn => listeners.add(fn), offChanged: fn => listeners.delete(fn) };
let points = [{ at: 1000, up: 1, down: 2 }, { at: now - 5000, up: 3, down: 4 }, { at: now, up: 5, down: 6 }];
const modules = {
  '../lib/Settings': { AppSettings: class {}, Settings: { load: () => ({}), onChanged() {}, offChanged() {} } },
  '@kit.ArkUI': { promptAction: { showToast() {} } },
  '../lib/CoreApi': { CoreApi: { getAppTraffic: async () => null, getControllerSession: async () => 'core-session', StreamWatcher: class {
    start(path, cb) { assert.equal(path, '/traffic'); stream = cb; }
    stop() { stream = null; stops++; }
  } }, formatRate: n => `${n} B/s` },
  '../lib/TrafficStats': { TrafficStats: { view: () => ({ points, ready: true }) }, TrafficView: class { points = []; } },
  '../lib/VpnController': { VpnController: controller, VpnStatus: { Connected: 2 } },
  './NativeTheme': { NativeTheme: {} }
};
const sandbox = { exports: {}, require: key => { assert.ok(key in modules, key); return modules[key]; },
  Date: { now: () => now }, setInterval: fn => { tick = fn; return 1; }, clearInterval: () => { tick = null; } };
Object.assign(sandbox, uiFixture.globals); modules['../lib/UiText'] = uiFixture.module;
vm.runInNewContext(ts.transpileModule(source).outputText, sandbox);
const page = new sandbox.exports.TrafficPage(); page.aboutToAppear();
assert.equal(listeners.size, 1); assert.ok(stream);
stream({ up: 10, down: 20 }); assert.equal(page.up, '10 B/s');
assert.equal(page.uploads.length, 2, 'Curve must break at unobserved interval');
points = [{ at: now - 5000, up: 0, down: 0 }, { at: now, up: 1024 * 1024, down: 512 * 1024 }];
page.refresh();
for (const [x, y] of [...page.uploads, ...page.downloads]) {
  assert.ok(x >= 8 && x <= page.chartWidth - 8, 'Samples must stay inside the plot frame');
  assert.ok(y >= 8 && y <= 112, 'Both idle and peak samples must fit the shared rate scale');
}
assert.equal(page.chartLevels[page.chartLevels.length - 1], '0', 'Rate axis must start at zero');
assert.equal(page.chartUnit, 'MB/s', 'All ticks share the unit appropriate for the observed peak');
assert.equal(page.chartLevels[0], '1', 'The maximum tick uses the shared unit');
now += 5000; tick(); assert.equal(page.up, '—', 'Silent socket must not freeze a live-looking speed');
controller.status = 0; for (const listener of listeners) listener(0);
assert.equal(stream, null); assert.equal(page.down, '—');
controller.status = 2; for (const listener of listeners) listener(2);
assert.ok(stream);
page.aboutToDisappear(); assert.equal(stream, null); assert.equal(tick, null); assert.equal(listeners.size, 0);
assert.ok(stops > 0);
console.log('PASS: traffic detail lifecycle, stale speeds and curve gap (host logic; no UI rendering/device claim)');
