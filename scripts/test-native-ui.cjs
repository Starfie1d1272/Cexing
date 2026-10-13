// Behavioral regression against actual page logic using the official SDK compiler.
// UI builders are excluded; HAP compilation validates ArkUI syntax. No rendering/device claim.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const pages = path.join(process.argv[2] || path.join(__dirname, '..'), 'cexing/entry/src/main/ets/pages');
function load(name, modules, extra = {}) {
  let source = fs.readFileSync(path.join(pages, name + '.ets'), 'utf8');
  const cutoff = source.indexOf('  @Builder');
  source = (cutoff >= 0 ? source.slice(0, cutoff) : source.slice(0, source.indexOf('  build()'))) + '\n}';
  source = source.split('\n').map(line => line.trimStart().startsWith('@') ?
    line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '') : line).join('\n')
    .replace(/export struct /g, 'export class ');
  const code = ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
  } }).outputText;
  const sandbox = { exports: {}, getContext: () => ({}), Date, Promise,
    require: key => { assert.ok(key in modules, `Missing mock ${key}`); return modules[key]; }, ...extra };
  vm.runInNewContext(code, sandbox);
  const component = sandbox.exports[name];
  component.moduleExports = sandbox.exports;
  return component;
}
const status = { Disconnected: 0, Connecting: 1, Connected: 2, Disconnecting: 3 };
(async () => {
  let now = 1000, stream, tick, dialog, stop = 0, start = 0, cancelRestore = 0, timerCleared = 0;
  const toasts = [];
  let stopResult = async () => true;
  let activeHomeFile = 'fixture.yaml';
  const listeners = new Set();
  function emit(next) { controller.status = next; for (const listener of listeners) listener(next); }
  let pendingFailure = '';
  const controller = { status: status.Connected, onChanged(fn) { listeners.add(fn); }, offChanged(fn) { listeners.delete(fn); },
    consumeLastStartError: () => { const value = pendingFailure; pendingFailure = ''; return value; },
    getLastStartFailure: () => null, stop: () => { stop++; return stopResult(); }, start: () => start++ };
  const common = {
    '@kit.AbilityKit': {}, '@kit.ArkUI': { promptAction: { showToast(value) { toasts.push(value.message); } } },
    '@kit.BasicServicesKit': {}, '../lib/ConnectionFailure': { ConnectionFailures: {} },
    '../lib/VpnController': { VpnController: controller, VpnStatus: status },
    './NativeTheme': { NativeTheme: {} }, '../lib/Logger': { Logger: { warn() {} } }
  };
  const Home = load('HomePage', { ...common,
    '../lib/CoreApi': { CoreApi: { StreamWatcher: class { start(_path, cb) { stream = cb; } stop() { stream = null; } },
      getConfigs: async () => null }, formatRate: n => `${n} B/s` },
    '../lib/ProfileStore': { ProfileStore: { getActiveFile: () => activeHomeFile } },
    '../lib/Settings': { Settings: { load: () => ({ mode: 'rule' }) } },
    '../lib/AppRuntime': { AppRuntime: { cancelRestore: () => cancelRestore++ } },
    './ProfilePage': { ProfileDetailBus: { current: '' } }
  }, { Date: { now: () => now }, setInterval: cb => { tick = cb; return 1; },
    clearInterval: () => timerCleared++, AlertDialog: { show: value => { dialog = value; } } });
  const home = new Home();
  home.rootVisible = true; home.currentVisibleTab = 0;
  pendingFailure = '配置解析：配置错误'; home.aboutToAppear();
  assert.equal(home.startFailed, true, 'returning to the page must retain a failure that arrived while hidden');
  // Optional exported source root + review-repro runs both reported cases against a fixed tree.
  if (process.argv[3] === 'review-repro') {
    const failures = [];
    const cases = [
      ['P1 old confirmation after disconnect/reconnect', () => {
        home.toggle(); const confirm = dialog.secondaryButton.action;
        emit(status.Disconnected); emit(status.Connecting); emit(status.Connected);
        confirm(); assert.equal(stop, 0, 'old confirmation stopped the new session');
      }],
      ['P2 valid sentinel-named profile', () => {
        activeHomeFile = '未导入.yaml'; home.refreshProfile();
        assert.equal(home.profileName, '未导入');
        assert.equal(home.hasProfile, true, 'valid named profile must remain present');
      }]
    ];
    for (const [label, run] of cases) {
      try { run(); console.log('PASS:', label); }
      catch (error) { failures.push(label); console.error('FAIL:', label, error.message); }
    }
    home.aboutToDisappear();
    assert.equal(failures.length, 0, failures.join('; '));
    return;
  }
  stream({ up: 128, down: 256 }); assert.equal(home.upRate, '128 B/s');
  now += 4001; tick(); assert.equal(home.upRate, '—', 'stale WS sample must be cleared');
  home.currentVisibleTab = 1; home.onTabVisible(); assert.equal(stream, null);
  home.currentVisibleTab = 0; home.onTabVisible(); assert.ok(stream);
  home.rootVisible = false; home.onRootVisible(); assert.equal(stream, null, 'secondary navigation releases stream');
  home.rootVisible = true; home.onRootVisible();
  home.toggle(); assert.equal(stop, 1, 'one tap disconnects immediately');
  assert.equal(cancelRestore, 1, 'explicit stop cancels pending restore');
  assert.equal(dialog, undefined, 'disconnect must not show a confirmation');
  emit(status.Disconnecting); home.toggle(); assert.equal(stop, 1, 'disconnecting ignores another tap');
  emit(status.Disconnected); home.toggle(); assert.equal(start, 1, 'reconnect starts normally');
  emit(status.Connecting); home.toggle(); assert.equal(stop, 2, 'connecting can be cancelled');
  emit(status.Disconnecting); emit(status.Disconnected); emit(status.Connecting); emit(status.Connected);
  assert.equal(stop, 2, 'old stop did not trigger a new stop after reconnect');
  home.aboutToDisappear(); assert.equal(stop, 2, 'page destruction must not stop VPN');
  assert.equal(timerCleared, 1);
  home.aboutToAppear(); assert.equal(stop, 2, 'recreated page cannot revive a stop action');
  home.aboutToDisappear();

  activeHomeFile = '未导入.yaml'; home.refreshProfile();
  assert.equal(home.profileName, '未导入'); assert.equal(home.hasProfile, true, 'display sentinel is a valid filename');
  activeHomeFile = '未导入.yml'; home.refreshProfile(); assert.equal(home.hasProfile, true);
  activeHomeFile = ''; home.refreshProfile(); assert.equal(home.hasProfile, false, 'empty selection has separate existence state');
  activeHomeFile = 'fixture.yaml'; home.refreshProfile(); home.aboutToAppear();
  stopResult = async () => false;
  home.toggle(); emit(status.Disconnecting); emit(status.Disconnected);
  await new Promise(resolve => setImmediate(resolve));
  assert.ok(toasts.includes('停止结果未知，请检查系统 VPN 状态后重试'),
    'false stop must be visible despite Disconnected status');
  assert.equal(home.label(), '停止结果未知', 'the card must retain an unconfirmed stop after the toast');
  assert.ok(home.stateLine().includes('检查系统 VPN'));
  toasts.length = 0;
  let finishStop;
  stopResult = () => new Promise(resolve => { finishStop = resolve; });
  emit(status.Connected); home.toggle(); emit(status.Disconnecting); emit(status.Disconnected);
  home.toggle(); assert.equal(home.stopUnknown, false, 'a new start clears the old stop warning');
  finishStop(false);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(toasts.length, 0, 'old stop result cannot toast after a newer start');
  stopResult = async () => { throw Error('synthetic stop failure'); };
  emit(status.Connected); home.toggle(); emit(status.Disconnecting); emit(status.Disconnected);
  await new Promise(resolve => setImmediate(resolve));
  assert.ok(toasts.includes('停止结果未知，请检查系统 VPN 状态后重试'), 'rejected stop must be visible');
  assert.equal(home.label(), '停止结果未知');
  home.aboutToDisappear();
  console.log('PASS: one-tap stop, cancel/reconnect, stale traffic and sentinel-named profiles');

  let resolveProbe;
  const Diagnostics = load('DiagnosticsPage', { ...common,
    '../lib/CoreApi': { CoreApi: { isAlive: () => new Promise(resolve => { resolveProbe = resolve; }) } }
  }, { setTimeout: () => 1, clearTimeout() {} });
  const diagnostics = new Diagnostics(); diagnostics.aboutToAppear();
  const pending = diagnostics.check(); diagnostics.aboutToDisappear(); resolveProbe(true); await pending;
  assert.equal(diagnostics.control, '尚未检查本机服务', 'late probe must not update destroyed page');
  let expireProbe;
  const TimedDiagnostics = load('DiagnosticsPage', { ...common,
    '../lib/CoreApi': { CoreApi: { isAlive: () => new Promise(() => {}) } }
  }, { setTimeout: fn => { expireProbe = fn; return 1; }, clearTimeout() {} });
  const timedDiagnostics = new TimedDiagnostics(); timedDiagnostics.aboutToAppear();
  const timedProbe = timedDiagnostics.check(); expireProbe(); await timedProbe;
  assert.equal(timedDiagnostics.control, '检查超时', 'bounded probe timeout must be distinguishable from failure');

  let saved = 0, value;
  const Override = load('OverridePage', { ...common,
    '../lib/Settings': { Settings: { load: () => ({}), save: (_ctx, s) => { saved++; value = s; } } }
  });
  const override = new Override(); override.mixedPort = '99999'; override.persist();
  assert.equal(saved, 0); assert.ok(override.portError); assert.equal(override.mixedPort, '99999');
  override.mixedPort = '7891'; override.persist(); assert.equal(saved, 1); assert.equal(value.mixedPort, 7891);

  let active = 'fixture.yaml', deleted = 0, rejectImport = true;
  let activateResult = async () => 'applied';
  const profiles = [{ file: 'fixture.yaml', name: 'Fixture', active: true },
    { file: 'candidate.yaml', name: 'Candidate', active: false }];
  const Profile = load('ProfilePage', { ...common,
    '@kit.CoreFileKit': {}, '@kit.ArkTS': {}, '@kit.BasicServicesKit': {}, './ProfileEditPage': {},
    '../lib/CoreApi': { CoreApi: {} },
    '../lib/ProfileTransactions': { ProfileTransactions: {
      remove: async () => { deleted++; }, activate: (...args) => activateResult(...args),
      update: async () => 'applied', rename: () => 'fixture.yaml'
    } },
    '../lib/ProfileStore': { ProfileStore: { list: () => profiles, getMeta: () => ({}),
      getActiveFile: () => active,
      importFromUrl: async () => { if (rejectImport) throw Error('network'); return 'candidate.yaml'; } } }
  }, { AlertDialog: { show: value => { dialog = value; } } });
  const profile = new Profile(); profile.profileRevision = 0; profile.navStack = { pop() {} };
  profile.showSheet = true; profile.inputUrl = 'https://example.invalid/fixture.yaml';
  await profile.importUrl(); assert.equal(profile.inputUrl, 'https://example.invalid/fixture.yaml');
  assert.ok(profile.importError); assert.equal(profile.importing, false);
  rejectImport = false; await profile.importUrl();
  assert.equal(active, 'fixture.yaml', 'import confirmation must not silently change active selection');
  assert.equal(profile.importedFile, 'candidate.yaml'); assert.equal(profile.showSheet, true);

  function activationPage(paths = [], detailFile = '') {
    const page = new Profile();
    let popped = 0;
    page.detailFile = detailFile; page.tabJump = -1; page.profileRevision = 0;
    page.currentVisibleTab = detailFile ? 0 : 1;
    page.navStack = { getAllPathName: () => paths.slice(), pop: () => { popped++; paths.pop(); } };
    page.aboutToAppear();
    return { page, pops: () => popped };
  }
  controller.status = status.Connected;
  const success = activationPage();
  await success.page.activate(profiles[1]);
  assert.equal(success.page.tabJump, 0, 'definite success returns to Connect');
  activateResult = async () => { throw Error('切换被拒绝'); };
  const failed = activationPage();
  await failed.page.activate(profiles[1]);
  assert.equal(failed.page.tabJump, -1, 'rejected or unconfirmed reload stays on profile page');
  activateResult = async () => { throw Error('切换结果未知'); };
  const unknown = activationPage();
  await unknown.page.activate(profiles[1]);
  assert.equal(unknown.page.tabJump, -1, 'unconfirmed local service does not navigate');
  let finishActivation;
  activateResult = () => new Promise(resolve => { finishActivation = resolve; });
  async function waitForActivation() {
    for (let i = 0; i < 8 && !finishActivation; i++) { await Promise.resolve(); }
    assert.equal(typeof finishActivation, 'function', 'activation reached transaction mock');
  }
  const timedOut = activationPage();
  const timeout = timedOut.page.activate(profiles[1]);
  await waitForActivation(); finishActivation('unknown'); await timeout;
  assert.equal(timedOut.page.tabJump, -1, 'timeout or unknown reload cannot navigate');
  finishActivation = undefined;
  const left = activationPage();
  const late = left.page.activate(profiles[1]);
  await waitForActivation();
  left.page.aboutToDisappear(); finishActivation('applied'); await late;
  assert.equal(left.page.tabJump, -1, 'completion after page leave cannot navigate');
  finishActivation = undefined;
  const switchedTab = activationPage();
  const pendingTab = switchedTab.page.activate(profiles[1]);
  await waitForActivation();
  switchedTab.page.currentVisibleTab = 2; switchedTab.page.onTabVisible();
  switchedTab.page.currentVisibleTab = 1; switchedTab.page.onTabVisible();
  finishActivation('saved'); await pendingTab;
  assert.equal(switchedTab.page.tabJump, -1, 'leaving and returning to the tab cannot revive an old request');
  const paths = ['profileDetail'];
  Profile.moduleExports.ProfileDetailBus.current = 'candidate.yaml';
  const newerRoute = activationPage(paths, 'candidate.yaml');
  finishActivation = undefined;
  const pendingRoute = newerRoute.page.activate(profiles[1]);
  await waitForActivation();
  paths.push('profileEdit'); finishActivation('applied'); await pendingRoute;
  assert.equal(newerRoute.pops(), 0, 'completion cannot pop a newer destination');
  assert.equal(newerRoute.page.tabJump, -1, 'completion cannot jump over a newer destination');
  const detail = activationPage(['profileDetail'], 'candidate.yaml');
  finishActivation = undefined;
  const completedDetail = detail.page.activate(profiles[1]);
  await waitForActivation(); finishActivation('saved'); await completedDetail;
  assert.equal(detail.pops(), 1, 'current detail pops exactly once after definite success');
  assert.equal(detail.page.tabJump, 0, 'current detail returns to Connect');
  active = 'fixture.yaml';
  controller.status = status.Connected; profile.confirmDelete(profiles[0]); dialog.secondaryButton.action();
  assert.equal(deleted, 0, 'running active profile must be protected');
  controller.status = status.Disconnected; await dialog.secondaryButton.action(); await new Promise(resolve => setImmediate(resolve)); assert.equal(deleted, 1);
  let failDraft = true;
  const Edit = load('ProfileEditPage', { ...common,
    '../lib/ProfileStore': { ProfileStore: { writeDraft: () => { if (failDraft) throw Error('disk full'); } } },
    '../lib/ProfileTransactions': { ProfileTransactions: { edit: async () => 'applied' } }
  });
  const editor = new Edit(); editor.persistDraft('synthetic');
  assert.equal(editor.dirty, true); assert.equal(editor.draftPersisted, false, 'failed draft write cannot claim recovery');
  failDraft = false; editor.persistDraft('synthetic'); assert.equal(editor.draftPersisted, true);
  console.log('PASS: native page traffic, one-tap stop, bounded diagnosis, transaction activation/navigation identity, import retry, draft persistence and active-delete guard');
})().catch(error => { console.error(error); process.exit(1); });
