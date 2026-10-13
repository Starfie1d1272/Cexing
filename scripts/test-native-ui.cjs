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
  let smartPrepare = async () => {};
  let activeHomeFile = 'fixture.yaml';
  const listeners = new Set();
  function emit(next) { controller.status = next; for (const listener of listeners) listener(next); }
  let pendingFailure = '';
  let lastStopCompleted = null;
  const controller = { status: status.Connected, onChanged(fn) { listeners.add(fn); }, offChanged(fn) { listeners.delete(fn); },
    getLastStopCompleted: () => lastStopCompleted,
    consumeLastStartError: () => { const value = pendingFailure; pendingFailure = ''; return value; },
    getLastStartFailure: () => null, stop: () => { stop++; return stopResult(); },
    start: () => { start++; emit(status.Connecting); } };
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
    '../lib/ProfileTransactions': { ProfileTransactions: { ensureActiveSmartPolicy: () => smartPrepare() } },
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
  emit(status.Disconnected); await home.toggle(); assert.equal(start, 1, 'reconnect starts normally');
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
  smartPrepare = async () => { throw Error('synthetic Smart preparation failure'); };
  await home.toggle();
  assert.equal(home.stopUnknown, true, 'failed preparation must preserve an unconfirmed stop');
  assert.equal(start, 1, 'failed preparation must not start VPN');
  let finishPreparation;
  smartPrepare = () => new Promise(resolve => { finishPreparation = resolve; });
  const stalePreparation = home.toggle();
  home.currentVisibleTab = 1; home.onTabVisible();
  finishPreparation(); await stalePreparation;
  assert.equal(home.stopUnknown, true, 'late preparation must preserve the stop warning');
  assert.equal(start, 1, 'late preparation after leaving the tab must not start VPN');
  smartPrepare = async () => {};
  home.currentVisibleTab = 0; home.onTabVisible();
  toasts.length = 0;
  let finishStop;
  stopResult = () => new Promise(resolve => { finishStop = resolve; });
  emit(status.Connected); home.toggle(); emit(status.Disconnecting); emit(status.Disconnected);
  await home.toggle(); assert.equal(home.stopUnknown, false, 'a new start clears the old stop warning');
  finishStop(false);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(toasts.length, 0, 'old stop result cannot toast after a newer start');
  stopResult = async () => { throw Error('synthetic stop failure'); };
  emit(status.Connected); home.toggle(); emit(status.Disconnecting); emit(status.Disconnected);
  await new Promise(resolve => setImmediate(resolve));
  assert.ok(toasts.includes('停止结果未知，请检查系统 VPN 状态后重试'), 'rejected stop must be visible');
  assert.equal(home.label(), '停止结果未知');
  home.aboutToDisappear();
  lastStopCompleted = false;
  const rebuiltHome = new Home();
  rebuiltHome.rootVisible = true; rebuiltHome.currentVisibleTab = 0;
  rebuiltHome.aboutToAppear();
  assert.equal(rebuiltHome.label(), '停止结果未知', 'page recreation must restore the controller stop outcome');
  assert.ok(rebuiltHome.stateLine().includes('检查系统 VPN'));
  rebuiltHome.aboutToDisappear();
  emit(status.Connected);
  const connectedHome = new Home();
  connectedHome.rootVisible = true; connectedHome.currentVisibleTab = 0;
  connectedHome.aboutToAppear();
  assert.equal(connectedHome.stopUnknown, false, 'an old failed stop must not override a connected session');
  assert.equal(connectedHome.label(), '已连接');
  connectedHome.aboutToDisappear();
  lastStopCompleted = true; emit(status.Disconnected);
  const confirmedHome = new Home();
  confirmedHome.rootVisible = true; confirmedHome.currentVisibleTab = 0;
  confirmedHome.aboutToAppear();
  assert.equal(confirmedHome.stopUnknown, false, 'a confirmed stop must not restore an old warning');
  confirmedHome.aboutToDisappear();
  console.log('PASS: one-tap stop, cancel/reconnect, stale traffic and sentinel-named profiles');

  let resolveProbe;
  const Diagnostics = load('DiagnosticsPage', { ...common,
    '../lib/CoreApi': { CoreApi: { checkController: () => new Promise(resolve => { resolveProbe = resolve; }) } }
  }, { setTimeout: () => 1, clearTimeout() {} });
  const diagnostics = new Diagnostics(); diagnostics.aboutToAppear();
  const pending = diagnostics.check(); assert.equal(diagnostics.busy, true);
  assert.equal(diagnostics.control, '正在检查…'); diagnostics.aboutToDisappear(); resolveProbe('reachable'); await pending;
  assert.equal(diagnostics.control, '尚未检查本机服务', 'late probe must not update destroyed page');
  const ResultDiagnostics = load('DiagnosticsPage', { ...common,
    '../lib/CoreApi': { CoreApi: { checkController: async () => 'authorization' } }
  }, { setTimeout: () => 1, clearTimeout() {} });
  const resultDiagnostics = new ResultDiagnostics(); resultDiagnostics.aboutToAppear();
  await resultDiagnostics.check();
  assert.equal(resultDiagnostics.busy, false);
  assert.equal(resultDiagnostics.control, '连接认证失败，请断开后重新连接');
  assert.ok(toasts.includes(resultDiagnostics.control));
  resultDiagnostics.aboutToDisappear(); resultDiagnostics.aboutToAppear();
  await resultDiagnostics.check(); assert.equal(resultDiagnostics.busy, false, 'returning can run another check');
  let expireProbe;
  const TimedDiagnostics = load('DiagnosticsPage', { ...common,
    '../lib/CoreApi': { CoreApi: { checkController: () => new Promise(() => {}) } }
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
  let regionResult = async () => 'saved';
  const profiles = [{ file: 'fixture.yaml', name: 'Fixture', active: true },
    { file: 'candidate.yaml', name: 'Candidate', active: false }];
  const Profile = load('ProfilePage', { ...common,
    '@kit.CoreFileKit': {}, '@kit.ArkTS': {}, '@kit.BasicServicesKit': {}, './ProfileEditPage': {},
    '../lib/CoreApi': { CoreApi: {} },
    '../lib/EffectiveVersions': { EffectiveVersions: { read: () => null } },
    '../lib/ProfileTransactions': { ProfileTransactions: {
      remove: async () => { deleted++; }, activate: (...args) => activateResult(...args),
      setRegionPlan: (...args) => regionResult(...args),
      update: async () => 'applied', rename: () => 'fixture.yaml'
    } },
    '../lib/ProfileStore': { ProfileStore: { list: () => profiles, getMeta: () => ({}),
      getActiveFile: () => active, pendingRegionSelection: () => '',
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
  function regionPage() {
    const page = activationPage().page;
    page.importedFile = 'candidate.yaml'; page.regionFromImport = true;
    page.regionPreview = { eligible: true, nodes: { Node: '香港' } };
    return page;
  }
  const createdAndEnabled = regionPage();
  await createdAndEnabled.saveRegion(true);
  assert.equal(createdAndEnabled.tabJump, 0, 'create and enable uses the activation navigation guard');
  regionResult = async () => { throw Error('地区策略未应用'); };
  const rejectedRegion = regionPage();
  await rejectedRegion.saveRegion(true);
  assert.equal(rejectedRegion.tabJump, -1, 'rejected create and enable stays on profiles');
  let finishRegion;
  regionResult = () => new Promise(resolve => { finishRegion = resolve; });
  const leftRegion = regionPage();
  const pendingRegion = leftRegion.saveRegion(true);
  leftRegion.aboutToDisappear(); finishRegion('saved'); await pendingRegion;
  assert.equal(leftRegion.tabJump, -1, 'late create and enable cannot navigate after leaving');
  let regionLists = 0, committedRegionEnabled = true;
  const PartialDisable = load('ProfilePage', { ...common,
    '@kit.CoreFileKit': {}, '@kit.ArkTS': {}, '@kit.BasicServicesKit': {}, './ProfileEditPage': {},
    '../lib/CoreApi': { CoreApi: {} },
    '../lib/EffectiveVersions': { EffectiveVersions: {
      read: () => ({ Profiles: { 'candidate.yaml': {} } }),
      regionPlan: () => ({ mode: 'region', selector: 'Main', assignments: {}, enable: committedRegionEnabled })
    } },
    '../lib/ProfileTransactions': { ProfileTransactions: {
      setRegionPlan: async () => {
        committedRegionEnabled = false;
        throw Error('地区策略已关闭，但原选项未恢复');
      }
    } },
    '../lib/ProfileStore': { ProfileStore: {
      list: () => { regionLists++; return profiles; }, getMeta: () => ({}), getActiveFile: () => active
    } }
  });
  const partialDisable = new PartialDisable();
  partialDisable.profileRevision = 0;
  partialDisable.navStack = { getAllPathName: () => [], pop() {} };
  partialDisable.aboutToAppear();
  const beforeDisable = regionLists;
  await partialDisable.toggleRegion('candidate.yaml');
  assert.ok(regionLists > beforeDisable, 'partial committed disable must refresh the displayed strategy');
  assert.equal(partialDisable.savedRegion('candidate.yaml').enable, false,
    'the view must use the committed disabled version after restore fails');
  assert.ok(toasts.includes('地区策略已关闭，但原选项未恢复'));
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
