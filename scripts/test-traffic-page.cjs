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
let now = 300000, tick, stream, stops = 0, dialog;
const listeners = new Set();
const controller = { status: 2, trafficSession: () => 'vpn-session', onChanged: fn => listeners.add(fn), offChanged: fn => listeners.delete(fn) };
let points = [{ at: 1000, up: 1, down: 2 }, { at: now - 5000, up: 3, down: 4 }, { at: now, up: 5, down: 6 }];
class SourceTrafficView {
  ready = false; saved = true; partial = false; readFailed = false; historyUnavailable = false;
  routeStatus = null; savedRoutes = []; routeReadFailed = false;
  live = null; rows = []; labels = {}; numbers = {}; sampledAt = 0;
}
const sourceData = new SourceTrafficView();
const modules = {
  '../lib/SourceTrafficStats': { SourceTrafficView, SourceTrafficStats: {
    view: () => sourceData, refreshLive: async () => {},
    setLabel: async (uid, label) => { sourceData.labels[String(uid)] = label; return true; }
  } },
  '../lib/CoreApi': { CoreApi: { getAppTraffic: async () => null, getControllerSession: async () => 'core-session', StreamWatcher: class {
    start(path, cb) { assert.equal(path, '/traffic'); stream = cb; }
    stop() { stream = null; stops++; }
  } }, formatRate: n => `${n} B/s` },
  '../lib/TrafficStats': { TrafficStats: { view: () => ({ points, ready: true }) }, TrafficView: class { points = []; } },
  '../lib/VpnController': { VpnController: controller, VpnStatus: { Connected: 2 } },
  './NativeTheme': { NativeTheme: {} }
};
const sandbox = { AlertDialog: { show: value => { dialog = value; } }, exports: {}, require: key => { assert.ok(key in modules, key); return modules[key]; },
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

// Source routing must reject unknown rows and ignore completions after detail dismissal.
(async () => {
  page.active = true; controller.status = 2;
  const route = { upload: 0, download: 0, connections: 0, active: 0 };
  const row = { identityStatus: 'uid', uid: 1001, bundleName: '', bundleVerified: false,
    routeTarget: '', lastSeen: now, recent: [], routes: { proxy: route, direct: route, unclassified: route } };
  sourceData.live = { session: 'a'.repeat(32), state: 'running', apps: [row] };
  const status = session => ({ session, state: 'running', storage: 'ready', blocked: false, rules: [], routeTargets: ['OTHER'] });
  sourceData.routeStatus = status('a'.repeat(32));
  sourceData.rows = [row]; page.readSources();
  page.appReadFailed = false; page.openApp(row);
  let resolveRoute, writes = 0;
  modules['../lib/CoreApi'].CoreApi.setAppRoute = () => { writes++; return new Promise(resolve => { resolveRoute = resolve; }); };
  assert.equal(page.canRoute({ ...row, identityStatus: 'unknown', uid: -1 }), false);
  const pending = page.changeRoute(row, 'DIRECT');
  await page.changeRoute(row, 'DIRECT');
  assert.equal(writes, 1, 'Repeated taps must not submit parallel route changes');
  page.showApp = false; page.openApp(row);
  await page.changeRoute(row, 'OTHER');
  assert.equal(writes, 1, 'Reopening details must not bypass an in-flight source write');
  page.showApp = false; resolveRoute(true); await pending;
  assert.equal(page.routeMessage, '', 'A dismissed sheet must not receive a late success');
  page.openApp(row);
  const staleSession = page.changeRoute(row, 'DIRECT');
  sourceData.routeStatus = status('b'.repeat(32));
  sourceData.live = { session: 'b'.repeat(32), state: 'running', apps: [row] }; page.readSources();
  resolveRoute(true); await staleSession;
  assert.equal(page.routeMessage, '', 'A prior VPN session must not report success in the new session');
  sourceData.ready = true; sourceData.rows = [row]; sourceData.numbers['1001'] = 1; sourceData.live = null;
  controller.status = 0; sourceData.routeStatus = null; page.readSources();
  assert.equal(page.appRows.length, 1, 'Saved history stays visible while VPN is disconnected');
  assert.equal(page.canRoute(row), false, 'Historical UID cannot issue a live route mutation');
  await page.saveNote(row, 'Browser');
  const reopened = new sandbox.exports.TrafficPage(); reopened.readSources();
  assert.equal(reopened.sourceView.labels['1001'], 'Browser', 'Notes use the durable service across page instances');
  controller.status = 2; sourceData.live = { session: 'c'.repeat(32), state: 'running', apps: [] };
  page.readSources(); assert.equal(page.canRoute(row), false, 'A historical UID must be observed in the current session before routing');
  sourceData.routeStatus=status('c'.repeat(32));page.readSources();
  assert.equal(page.canRoute(row),false,'Unsaved historical UID cannot add a rule before being observed');
  const savedRule={uid:2002,target:'Deleted group',available:false};
  sourceData.routeStatus.rules=[savedRule];sourceData.savedRoutes=[savedRule];page.readSources();
  const synthetic=page.ruleRow(2002);page.openApp(synthetic);page.readSources();
  assert.equal(page.selected.uid,2002,'Rule without history survives periodic detail refresh');
  assert.equal(page.total(synthetic.routes),0,'Unobserved rule does not invent traffic totals');
  assert.equal(page.canRoute(synthetic),true,'Saved UID can be managed before current-session traffic');
  assert.equal(page.currentRoute(synthetic),'Deleted group');assert.equal(page.missingRoute(synthetic),true);
  const remove=page.changeRoute(synthetic,'');assert.equal(writes,3);
  sourceData.routeStatus.rules=[];sourceData.savedRoutes=[];resolveRoute(true);await remove;
  assert.equal(page.showApp,false,'Deleted synthetic entry closes after authoritative refresh');
  sourceData.savedRoutes=[savedRule];sourceData.routeStatus=null;controller.status=0;page.readSources();
  assert.equal(page.savedRules().length,1);assert.equal(page.currentRoute(synthetic),'Deleted group');
  const beforeOffline=writes;await page.changeRoute(synthetic,'DIRECT');assert.equal(writes,beforeOffline,'Offline cache is never executable');
  controller.status=2;sourceData.routeStatus={...status('d'.repeat(32)),storage:'corrupt',blocked:true};page.readSources();
  assert.equal(page.savedRules().length,1,'Storage failure preserves cached rules for read-only inspection');
  assert.equal(page.canRoute(synthetic),false);assert.ok(page.routeWarning());
  let recoveries=[], resolveRecovery;
  modules['../lib/CoreApi'].CoreApi.recoverAppRoutes=(session,action)=>{
    recoveries.push({session,action});return new Promise(resolve=>{resolveRecovery=resolve;});
  };
  page.confirmResetRoutes();const cancelled=dialog;cancelled.primaryButton.action();cancelled.secondaryButton.action();
  assert.equal(recoveries.length,0,'Cancelled reset confirmation never clears rules');
  page.confirmResetRoutes();const staleDialog=dialog;
  sourceData.routeStatus={...status('e'.repeat(32)),storage:'readError',blocked:true};page.readSources();staleDialog.secondaryButton.action();
  assert.equal(recoveries.length,0,'Prior-session confirmation never resets a new session');
  page.confirmResetRoutes();dialog.secondaryButton.action();dialog.secondaryButton.action();
  await page.changeRoute(synthetic,'DIRECT');await page.recoverRoutes('retry');
  assert.equal(recoveries.length,1,'Reset, retry and route mutations share one lock');
  page.aboutToDisappear();resolveRecovery(true);await new Promise(setImmediate);
  assert.equal(page.recoveryMessage,'','Page exit suppresses late recovery success');
  page.active=true;page.readSources();
  const retry=page.recoverRoutes('retry');assert.equal(recoveries[1].action,'retry');
  resolveRecovery(false);await retry;assert.ok(page.recoveryMessage,'Failed recovery remains visible');
  sourceData.routeStatus={...status('f'.repeat(32)),storage:'writeError',blocked:true};page.readSources();
  assert.equal(page.canRoute(synthetic),false,'Durability-uncertain writeError cannot mutate');assert.ok(page.routeWarning());
  sourceData.routeStatus={...status('f'.repeat(32)),storage:'writeError',blocked:false,rules:[savedRule]};page.readSources();
  assert.equal(page.canRoute(synthetic),true,'Uncommitted write failure retains manageable authoritative old rules');
  sourceData.routeReadFailed=true;page.readSources();assert.equal(page.canRoute(synthetic),false);
  let refreshes=0;modules['../lib/SourceTrafficStats'].SourceTrafficStats.refreshLive=async()=>{refreshes++;};
  const count=recoveries.length;await page.recoverRoutes('retry');
  assert.equal(recoveries.length,count,'Unreadable API state is refreshed without guessing a destructive recovery');assert.equal(refreshes,1);
  sourceData.routeReadFailed=false;page.readSources();page.openApp(synthetic);
  const failedWrite=page.changeRoute(synthetic,'DIRECT');resolveRoute(false);await failedWrite;
  assert.ok(page.routeMessage,'Failed route save remains visible');
  assert.equal(page.currentRoute(synthetic),'Deleted group','Failed write never optimistically replaces authoritative rule');
  page.confirmResetRoutes();const leavingDialog=dialog;page.aboutToDisappear();leavingDialog.secondaryButton.action();
  assert.equal(recoveries.length,count,'A reset confirmed after page exit cannot execute');
  console.log('PASS: durable rules without traffic, offline read-only cache, invalid outlets, storage errors, reset consent, shared write lock and stale recovery guards');
})().catch(error => { console.error(error); process.exitCode = 1; });
