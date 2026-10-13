// Execute the actual entry gate; OS/launcher rendering and authorization remain device checks.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const source = fs.readFileSync(path.join(__dirname, '../cexing/entry/src/main/ets/lib/ConnectionEntry.ets'), 'utf8');
const code = ts.transpileModule(source).outputText;
const status = { Disconnected: 0, Connecting: 1, Connected: 2, Disconnecting: 3 };
function fixture(persistedUnknown = false) {
  const ctx = {};
  const listeners = [];
  const calls = { start: 0, stop: 0, cancel: 0, reports: [] };
  let stopResult = null, busy = false, uncertain = false, profile = 'synthetic.yaml', observed = false;
  const controller = { status: status.Disconnected, onChanged: cb => listeners.push(cb),
    getLastStopCompleted: () => stopResult, getLastStartFailure: () => null,
    getTunCreateObserved: () => observed, getKernelReadyReported: () => observed,
    start: () => { calls.start++; stopResult = null; emit(status.Connecting); },
    stop: async () => { calls.stop++; emit(status.Disconnecting); stopResult = false;
      emit(status.Disconnected); return false; } };
  function emit(s) { controller.status = s; listeners.forEach(cb => cb(s)); }
  const modules = {
    './VpnController': { VpnController: controller, VpnStatus: status },
    './ProfileStore': { ProfileStore: { isApplyUncertain: () => uncertain, getActiveFile: () => profile } },
    './ProfileTransactions': { ProfileTransactions: { isBusy: () => busy } },
    './AppRuntime': { AppRuntime: { cancelRestore: () => calls.cancel++ } },
    './ConnectionCards': { ConnectionCards: { read: () => ({ stopUnknown: persistedUnknown }),
      publish: (_, label, unknown) => calls.reports.push({ label, unknown }) } }
  };
  const host = { exports: {}, require: name => { assert.ok(name in modules, name); return modules[name]; },
    AppStorage: { setOrCreate() {} } };
  vm.runInNewContext(code, host);
  const entry = host.exports.ConnectionEntry;
  entry.bind(ctx);
  const want = action => ({ parameters: { cexingConnectionAction: action } });
  return { entry, ctx, controller, calls, emit, want,
    set: values => { if ('busy' in values) busy = values.busy; if ('uncertain' in values) uncertain = values.uncertain;
      if ('profile' in values) profile = values.profile; if ('observed' in values) observed = values.observed; } };
}
async function tests() {
  const f = fixture();
  f.entry.receive(f.want('toggle'));
  assert.equal(f.entry.request, 0, 'Unknown actions must not become VPN intents');
  f.entry.receive({ parameters: { params: '{malformed' } });
  assert.equal(f.entry.request, 0);
  f.entry.receive({ parameters: { params: JSON.stringify({ cexingConnectionAction: 'disconnect' }) } });
  assert.equal(f.entry.action, 'disconnect', 'Card router JSON envelope must reach the shared gate');
  assert.equal(f.calls.stop, 0, 'Card routing must only navigate');
  assert.equal(f.entry.takeNavigation(), true);
  assert.equal(f.entry.takeNavigation(), false, 'Window rebuild must not replay a routed Want');
  f.entry.receive(f.want('connect'));
  assert.equal(f.calls.start, 0, 'Want arrival must only navigate');
  assert.equal(f.entry.canConfirm(), false, 'Cold recovery must settle before confirmation');
  f.entry.recovered(f.ctx);
  const oldRequest = f.entry.request;
  f.entry.receive(f.want('disconnect'));
  await f.entry.confirm(f.ctx, oldRequest, f.entry.revision);
  assert.equal(f.calls.start + f.calls.stop, 0, 'Superseded Want must not act');
  f.entry.receive(f.want('connect'));
  const oldRevision = f.entry.revision;
  f.emit(status.Connected);
  assert.equal(f.entry.label(), '本机服务可用，VPN 待确认', 'REST recovery must not claim a confirmed VPN');
  await f.entry.confirm(f.ctx, f.entry.request, oldRevision);
  assert.equal(f.calls.start, 0, 'Old rendered state must not start');
  f.emit(status.Disconnected);
  for (const block of [{ busy: true }, { uncertain: true }, { profile: '' }]) {
    f.set({ busy: false, uncertain: false, profile: 'synthetic.yaml', ...block });
    await f.entry.confirm(f.ctx, f.entry.request, f.entry.revision);
    assert.equal(f.calls.start, 0, 'Configuration safety gate must block connection');
  }
  f.set({ busy: false, uncertain: false, profile: 'synthetic.yaml' });
  await f.entry.confirm({}, f.entry.request, f.entry.revision);
  assert.equal(f.calls.start, 0, 'Old Ability context must not act');
  const request = f.entry.request, revision = f.entry.revision;
  await Promise.all([f.entry.confirm(f.ctx, request, revision), f.entry.confirm(f.ctx, request, revision)]);
  assert.equal(f.calls.start, 1, 'Repeated confirmation must submit once');
  f.entry.receive(f.want('connect'));
  await f.entry.confirm(f.ctx, f.entry.request, f.entry.revision);
  assert.equal(f.calls.start, 1, 'Connect must not toggle a pending start');
  f.entry.receive(f.want('disconnect'));
  const result = await f.entry.confirm(f.ctx, f.entry.request, f.entry.revision);
  assert.match(result, /停止结果未知/);
  assert.equal(f.calls.stop, 1, 'Cancel delegates to the existing stop implementation');
  assert.equal(f.calls.reports.at(-1).unknown, true);
  f.entry.receive(f.want('connect'));
  await f.entry.confirm(f.ctx, f.entry.request, f.entry.revision);
  assert.equal(f.calls.start, 1, 'Unconfirmed stop must block a new entry start');
  const cold = fixture(true);
  cold.entry.receive(cold.want('connect')); cold.entry.recovered(cold.ctx);
  assert.equal(cold.entry.canConfirm(), false, 'Stop unknown must survive UI process recreation');
  const g = fixture();
  g.entry.recovered(g.ctx); g.emit(status.Connected); g.entry.receive(g.want('disconnect'));
  let finish;
  g.controller.stop = () => { g.calls.stop++; g.emit(status.Disconnecting); return new Promise(r => finish = r); };
  const pending = g.entry.confirm(g.ctx, g.entry.request, g.entry.revision);
  g.entry.receive(g.want('connect'));
  finish(true);
  assert.equal(await pending, '', 'Old stop result must not be delivered to a new Want');
  g.entry.destroyed(g.ctx);
  assert.equal(g.entry.canConfirm(), false, 'Destroyed Ability cannot confirm');
  assert.equal(g.entry.takeNavigation(), false);
  const rebound = fixture();
  rebound.entry.receive(rebound.want('connect'));
  const nextContext = {};
  rebound.entry.bind(nextContext);
  rebound.entry.recovered(nextContext);
  assert.equal(rebound.entry.action, '', 'A normal Ability recreation must discard a previous external intent');
  assert.equal(rebound.calls.cancel, 0, 'An old external intent must not suppress normal auto-restore');
  rebound.entry.destroyed(rebound.ctx);
  assert.equal(rebound.entry.ready, true, 'Late old-Ability teardown must preserve the new context');
  // Persistence belongs to the card adapter, not to an alternate VPN controller.
  const files = new Map(), updates = [];
  const io = { OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
    openSync: p => ({ fd: p }), writeSync: (p, data) => files.set(p, data), closeSync() {},
    renameSync: (a, b) => { files.set(b, files.get(a)); files.delete(a); },
    readTextSync: p => { if (!files.has(p)) throw Error('missing'); return files.get(p); } };
  const cardModules = { '@kit.CoreFileKit': { fileIo: io }, '@kit.FormKit': {
    formBindingData: { createFormBindingData: data => data },
    formProvider: { updateForm: async (id, data) => updates.push({ id, data }) }
  }, './Logger': { Logger: { warn() {} } } };
  const host = { exports: {}, require: name => { assert.ok(name in cardModules, name); return cardModules[name]; } };
  const cardsCode = ts.transpileModule(fs.readFileSync(path.join(__dirname,
    '../cexing/entry/src/main/ets/lib/ConnectionCards.ets'), 'utf8')).outputText;
  vm.runInNewContext(cardsCode, host);
  const cards = host.exports.ConnectionCards, cardCtx = { filesDir: '/synthetic' };
  assert.equal(cards.read(cardCtx).label, '状态待确认');
  const id = '9007199254740993';
  cards.add(cardCtx, id); cards.add(cardCtx, id);
  cards.publish(cardCtx, '停止结果未知', true);
  assert.equal(updates.length, 1, 'Multiple callbacks must retain one exact string form identity');
  assert.equal(updates[0].id, id);
  assert.equal(cards.read(cardCtx).stopUnknown, true);
  assert.ok(cards.read(cardCtx).reportedAt.length > 0, 'Historical reports must include their observation time');
  cards.remove(cardCtx, id); cards.publish(cardCtx, '已确认断开', false);
  assert.equal(updates.length, 1, 'Removed forms must not receive later lifecycle reports');
  assert.equal(cards.read(cardCtx).stopUnknown, false);
  console.log('PASS: foreground-only Want routing, cold recovery, stale/repeated intents, profile gate and stop-unknown protection');
}
tests().catch(e => { console.error(e); process.exitCode = 1; });
