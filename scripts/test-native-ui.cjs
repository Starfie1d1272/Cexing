const uiFixture = require('./ci/ui-fixtures.cjs');
const { resourceContext } = require('./ci/mock-profile-resources.cjs');
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
  const sandbox = { exports: {}, getContext: () => resourceContext(), Date, Promise,
    require: key => { if (key.endsWith('/ProfileApplyFeedback')) {
      const box = { exports: {}, require: dependency => modules['../lib/' + dependency.split('/').pop()] || {} };
      vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(pages, '../lib/ProfileApplyFeedback.ets'), 'utf8')).outputText, box); return box.exports;
    } if (key.endsWith('/UiText')) return uiFixture.module; if (key.endsWith('/CoreValidator') && !(key in modules)) return require('./ci/semantic-fixture.cjs'); assert.ok(key in modules, `Missing mock ${key}`); return modules[key]; }, ...extra };
  Object.assign(sandbox, uiFixture.globals);
  vm.runInNewContext(code, sandbox);
  const component = sandbox.exports[name];
  component.moduleExports = sandbox.exports;
  return component;
}
const status = { Disconnected: 0, Connecting: 1, Connected: 2, Disconnecting: 3 };
(async () => {
  let now = 1000, stream, tick, dialog, stop = 0, start = 0, cancelRestore = 0, timerCleared = 0;
  const toasts = [];
  let scanCallback, scanCalls = 0;
  let readYaml = async () => 'proxies: []';
  let profileSession = 'synthetic-session';
  let importedWrites = 0, uncertainProfile = false, recoveryCalls = 0;
  let reconnectProfile = async (_context, current) => { recoveryCalls++; return current(); };
  let autoRetry = async () => {};
  const updateState = { id: 'source-fixture', succeededAt: 10, failedAt: 20, retryAt: 30 };
  let externalPending = null, externalActive = null;
  let stopResult = async () => true;
  let smartPrepare = async () => {};
  let activeHomeFile = 'fixture.yaml';
  const listeners = new Set();
  function emit(next) { controller.status = next; for (const listener of listeners) listener(next); }
  let pendingFailure = '';
  let lastStopCompleted = null;
  const controller = { status: status.Connected, onChanged(fn) { listeners.add(fn); }, offChanged(fn) { listeners.delete(fn); },
    getLastStopCompleted: () => lastStopCompleted, needsStop: () => lastStopCompleted === false,
    consumeLastStartError: () => { const value = pendingFailure; pendingFailure = ''; return value; },
    trafficSession: () => profileSession, getLastStartFailure: () => null, stop: () => { stop++; return stopResult(); },
    start: () => { start++; emit(status.Connecting); return true; } };
  const common = {
    '@kit.AbilityKit': {}, '@kit.ScanKit': { scanCore: { ScanType: { QR_CODE: 1 } }, scanBarcode: {
      startScanForResult(_context, options, callback) {
        assert.equal(options.enableAlbum, true); scanCalls++; scanCallback = callback;
      } } }, '../lib/ProfileImportInput': { ProfileImportInput: { take: () => { const value = externalPending; externalPending = null;
      if (value) externalActive = value; return value; },
      release: value => { if (value && externalActive === value) externalActive = null; },
      hasPending: () => externalPending !== null,
      parseText: value => value.startsWith('https://') ? { kind: 'url', value } : null } }, '@kit.CoreFileKit': {}, '@kit.ShareKit': {}, '@kit.ArkData': {},
    '../lib/DiagnosticExportSnapshots': {},
    '../lib/ProfileRecovery': { ProfileRecovery: { reconnect: (...args) => reconnectProfile(...args) } },
    '../lib/AutoUpdater': { AutoUpdater: { retry: (...args) => autoRetry(...args) } },
    '../lib/BoundedFileReader': { BoundedFileReader: { yaml: (...args) => readYaml(...args) } },
    '../lib/AppRuntime': { AppRuntime: { cancelRestore: () => cancelRestore++ } },
    '../lib/DiagnosticsBundleView': { DiagnosticsBundleView: { result: r => r.reason === 'page_check_timeout' ? '检查超时' : r.stage === 'controller_authorization' ? '连接认证失败，请断开后重新连接' : '本机服务可达', title: () => '本机服务' } },
    '@kit.ArkUI': { promptAction: { showToast(value) { toasts.push(value.message); } } },
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
    '../lib/ProfileTransactions': { ProfileTransactions: { onIdle: () => () => {}, isBusy: () => false, ensureActiveSmartPolicy: () => smartPrepare() } },
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
  assert.ok(toasts.includes('断开未确认，请检查系统 VPN 状态后重试'),
    'false stop must be visible despite Disconnected status');
  assert.equal(home.label(), '断开未确认', 'the card must retain an unconfirmed stop after the toast');
  assert.ok(home.stateLine().includes('重试断开'));
  const beforeRetryStart = start;
  let retryPreparation = 0;
  smartPrepare = async () => { retryPreparation++; };
  const beforeRetryStop = stop;
  lastStopCompleted = false;
  await home.toggle();
  assert.equal(start, beforeRetryStart, 'unknown stop must never authorize a new start');
  assert.equal(retryPreparation, 0, 'unknown stop must not prepare a new config');
  assert.equal(stop, beforeRetryStop + 1, 'the primary action explicitly retries stop');
  lastStopCompleted = true; stopResult = async () => true;
  await home.toggle(); // Finish the visible unknown-stop retry.
  home.stopUnknown = false;
  await home.toggle();
  assert.equal(start, beforeRetryStart + 1, 'confirmed cleanup allows the next explicit connect');
  let finishPreparation;
  emit(status.Disconnected);
  smartPrepare = () => new Promise(resolve => { finishPreparation = resolve; });
  const interrupted = home.toggle();
  lastStopCompleted = false; emit(status.Disconnected);
  finishPreparation(); await interrupted;
  assert.equal(start, beforeRetryStart + 1, 'late prepared start must recheck the controller stop gate');
  assert.equal(home.stopUnknown, true);
  stopResult = async () => { throw Error('synthetic stop failure'); };
  const beforeFailedRetry = start;
  await home.toggle();
  assert.equal(start, beforeFailedRetry);
  home.aboutToDisappear();
  lastStopCompleted = false;
  const rebuiltHome = new Home();
  rebuiltHome.rootVisible = true; rebuiltHome.currentVisibleTab = 0;
  rebuiltHome.aboutToAppear();
  assert.equal(rebuiltHome.label(), '断开未确认', 'page recreation must restore the controller stop outcome');
  assert.ok(rebuiltHome.stateLine().includes('重试断开'));
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
  const { load: actualController, recover: recoverActual } = require('./test-vpn-recovery.cjs');
  for (const observation of [{ready:false}, {tun:false}, {session:''}, {lost:true}]) {
    const real = actualController({receiptOnSystemStop:true});
    let preparations = 0;
    const ActualHome = load('HomePage', { ...common,
      '../lib/VpnController': { VpnController: real.VpnController, VpnStatus: real.VpnStatus },
      '../lib/CoreApi': { CoreApi: { StreamWatcher: class { start() {} stop() {} }, getConfigs: async()=>null }, formatRate: String },
      '../lib/ProfileStore': { ProfileStore: { getActiveFile: ()=>'fixture.yaml' } },
      '../lib/Settings': { Settings: { load: ()=>({mode:'rule'}) } },
      '../lib/AppRuntime': { AppRuntime: { cancelRestore() {} } },
      '../lib/ProfileTransactions': { ProfileTransactions: { onIdle: () => () => {}, isBusy: () => false, ensureActiveSmartPolicy: async()=>{preparations++;} } },
      './ProfilePage': { ProfileDetailBus: { current:'' } }
    }, { getContext: ()=>real.context, setInterval:()=>1, clearInterval() {} });
    const actualHome = new ActualHome();actualHome.rootVisible=true;actualHome.currentVisibleTab=0;
    actualHome.aboutToAppear();
    real.set(observation);await recoverActual(real);
    if (observation.lost) { real.lost(); real.options.autoBind=true; }
    assert.equal(actualHome.stopUnknown,true,'actual controller notifies Home even when failed recovery remains Disconnected');
    const priorStart=real.calls.start;
    assert.equal(real.VpnController.start(real.context),false,'direct controller callers cannot bypass unknown-stop gate');
    await actualHome.toggle();
    assert.equal(real.calls.start,priorStart,'Home retry never enters authorization');
    assert.equal(preparations,0);assert.equal(actualHome.label(),'未连接');
    await actualHome.toggle();assert.equal(real.calls.start,priorStart+1);
    actualHome.aboutToDisappear();
  }
  console.log('PASS: one-tap stop, cancel/reconnect, stale traffic and sentinel-named profiles');

  let resolveProbe;
  const Diagnostics = load('DiagnosticsPage', { ...common,
    '../lib/CoreApi': { CoreApi: {} }, '../lib/DiagnosticsService': { DiagnosticsService: { record: async () => true, check: () => new Promise(resolve => { resolveProbe = () => resolve({ kind: 'controller', stage: 'controller_version', outcome: 'success', at: '2026-10-13T00:00:00Z', durationMs: 1 }); }) } }
  }, { setTimeout: () => 1, clearTimeout() {} });
  const diagnostics = new Diagnostics(); diagnostics.aboutToAppear();
  const pending = diagnostics.check(); assert.equal(diagnostics.busy, true);
  assert.equal(diagnostics.control, '正在检查…'); diagnostics.aboutToDisappear(); resolveProbe('reachable'); await pending;
  assert.equal(diagnostics.control, '尚未检查本机服务', 'late probe must not update destroyed page');
  const ResultDiagnostics = load('DiagnosticsPage', { ...common,
    '../lib/CoreApi': { CoreApi: {} }, '../lib/DiagnosticsService': { DiagnosticsService: { record: async () => true, check: async () => ({ kind: 'controller', stage: 'controller_authorization', outcome: 'failed', at: '2026-10-13T00:00:00Z', durationMs: 1 }) } }
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
    '../lib/CoreApi': { CoreApi: {} }, '../lib/DiagnosticsService': { DiagnosticsService: { record: async () => true, check: () => new Promise(() => {}) } }
  }, { setTimeout: fn => { expireProbe = fn; return 1; }, clearTimeout() {} });
  const timedDiagnostics = new TimedDiagnostics(); timedDiagnostics.aboutToAppear();
  const timedProbe = timedDiagnostics.check(); expireProbe(); await timedProbe;
  assert.equal(timedDiagnostics.control, '检查超时', 'bounded probe timeout must be distinguishable from failure');

  let saved = 0, value;
  const Override = load('OverridePage', { ...common,
    '../lib/Settings': { Settings: { idle: async () => {}, load: () => ({allowLan: false}), save: (_ctx, s) => { saved++; value = s; }, setAllowLan: (_ctx, enabled) => { value = {allowLan: enabled}; } } }
  }, { AlertDialog: { show: value => { dialog = value; } } });
  const override = new Override(); override.aboutToAppear(); await new Promise(resolve => setImmediate(resolve)); override.mixedPort = '99999'; await override.persist();
  assert.equal(saved, 0); assert.ok(override.portError); assert.equal(override.mixedPort, '99999');
  override.mixedPort = '7891'; await override.persist(); assert.equal(saved, 1); assert.equal(value.mixedPort, 7891);

  override.changeAllowLan(true); assert.equal(override.allowLan, true);
  dialog.primaryButton.action(); dialog.secondaryButton.action(); assert.equal(override.allowLan, false);
  override.changeAllowLan(true); dialog.secondaryButton.action(); assert.equal(override.allowLan, true);
  assert.equal(value.allowLan, true);
  override.changeAllowLan(false); assert.equal(value.allowLan, false);
  override.changeAllowLan(true); override.aboutToDisappear(); dialog.secondaryButton.action();
  assert.equal(value.allowLan, false, 'late confirmation cannot enable sharing after leave');

  const FailedRevoke = load('OverridePage', { ...common,
    '../lib/Settings': {Settings: {idle: async () => {}, load: () => ({allowLan:true}),
      setAllowLan: () => {throw Error('synthetic persistence failure');} }}
  });
  const failedRevoke = new FailedRevoke(); failedRevoke.aboutToAppear(); await new Promise(resolve => setImmediate(resolve)); failedRevoke.allowLan = true;
  await failedRevoke.saveAllowLan(false);
  assert.equal(failedRevoke.allowLan,true,'failed revocation keeps prior authorization visible');
  assert.match(failedRevoke.lanError,/原授权仍可能有效/);
  assert.match(failedRevoke.lanError,/重试/);

  let active = 'fixture.yaml', deleted = 0, rejectImport = true;
  let activateResult = async () => 'applied';
  let regionResult = async () => 'saved';
  const profiles = [{ file: 'fixture.yaml', name: 'Fixture', active: true },
    { file: 'candidate.yaml', name: 'Candidate', active: false }];
  const Profile = load('ProfilePage', { ...common,
    '@kit.CoreFileKit': {}, '@kit.ArkTS': {}, '@kit.BasicServicesKit': {}, './ProfileEditPage': {}, './ProfileTemplatePage': { ProfileTemplateBus: { file: '' } }, './ProfileProxyEditorPage': { ProfileProxyEditorBus: { file: '' } }, './RuleDnsEditorPage': { RuleDnsEditorBus: { file: '', section: '' } },
    '../lib/CoreApi': { CoreApi: {} },
    '../lib/EffectiveVersions': { EffectiveVersions: { read: () => null } },
    '../lib/ProfileTransactions': { ProfileTransactions: { onIdle: () => () => {}, isBusy: () => false,
      remove: async () => { deleted++; }, activate: (...args) => activateResult(...args),
      setRegionPlan: (...args) => regionResult(...args),
      ensureActiveSmartPolicy: () => smartPrepare(),
      update: async () => 'applied', rename: () => 'fixture.yaml'
    } },
    '../lib/ProfileStore': { ProfileStore: { list: () => profiles, getMeta: () => ({}),
      isApplyUncertain: () => uncertainProfile, updateState: () => ({ ...updateState }),
      importContent: () => { importedWrites++; return 'candidate.yaml'; },
      getActiveFile: () => active, getOrigin: () => '', pendingRegionSelection: () => '',
      importFromUrl: async () => { if (rejectImport) throw Error('network'); return 'candidate.yaml'; } } }
  }, { AlertDialog: { show: value => { dialog = value; } }, canIUse: () => true });
  const profile = new Profile(); profile.profileRevision = 0; profile.navStack = { pop() {} };
  profile.pageVisible = true; profile.showSheet = true; profile.inputUrl = 'https://example.invalid/fixture.yaml';
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
  function readyPage() {
    const page = activationPage().page;
    page.importedFile = 'candidate.yaml'; page.showSheet = true; page.sheetMode = 4;
    return page;
  }
  lastStopCompleted = true; controller.status = status.Disconnected;
  let firstActivations = 0;
  activateResult = async () => { firstActivations++; active = 'candidate.yaml'; return 'saved'; };
  smartPrepare = async () => {};
  const first = readyPage(), startsBeforeImport = start;
  await first.activateAndConnect();
  assert.equal(start, startsBeforeImport + 1); assert.equal(first.tabJump, 0);
  assert.equal(first.showSheet, false, 'successful authorization request returns to connection status');
  controller.status = status.Disconnected;
  activateResult = () => { firstActivations++; return new Promise(resolve => { finishActivation = resolve; }); };
  const repeat = readyPage(), activationCount = firstActivations;
  const connecting = repeat.activateAndConnect(); await repeat.activateAndConnect();
  assert.equal(firstActivations, activationCount + 1, 'repeated taps share one activation');
  repeat.showSheet = false; finishActivation('saved'); await connecting;
  assert.equal(start, startsBeforeImport + 1, 'cancelled import sheet cannot start VPN later');
  const leaveImport = readyPage(); const hiddenConnect = leaveImport.activateAndConnect();
  leaveImport.aboutToDisappear(); finishActivation('saved'); await hiddenConnect;
  assert.equal(start, startsBeforeImport + 1, 'old page result cannot start VPN');
  const tabImport = readyPage(); const oldTabConnect = tabImport.activateAndConnect();
  tabImport.currentVisibleTab = 2; tabImport.onTabVisible();
  tabImport.currentVisibleTab = 1; tabImport.onTabVisible();
  finishActivation('saved'); await oldTabConnect;
  assert.equal(start, startsBeforeImport + 1, 'returning to tab cannot revive a connection request');
  activateResult = async () => { throw Error('PROVIDER_UNRESOLVED private-token'); };
  const rejected = readyPage(); await rejected.activateAndConnect();
  assert.equal(rejected.showSheet, true); assert.match(rejected.importError, /来源尚未就绪/);
  assert.ok(!rejected.importError.includes('private-token'));
  activateResult = async () => { active = 'candidate.yaml'; return 'saved'; };
  smartPrepare = async () => { throw Error('配置资源缺失'); };
  const resources = readyPage(); await resources.activateAndConnect();
  assert.match(resources.importError, /资源未准备好/); assert.equal(resources.showSheet, true);
  assert.equal(start, startsBeforeImport + 1);
  smartPrepare = async () => {};
  lastStopCompleted = false;
  const unknownImport = readyPage(); await unknownImport.activateAndConnect();
  assert.match(unknownImport.importError, /重试断开/);
  lastStopCompleted = true;
  console.log('PASS: first import connect, repeated taps, cancel/leave/tab stale results, provider/resource failures and unknown-stop gate');
  const scanned = activationPage().page;
  scanned.scanInput(); scanned.scanInput(); assert.equal(scanCalls, 1, 'scanner launch is single-flight');
  scanCallback(null, { originalValue: 'https://example.invalid/scanned' });
  assert.equal(scanned.inputUrl, 'https://example.invalid/scanned');
  assert.equal(scanned.sheetMode, 2, 'scan only prefills the confirmation form');
  const cancelledScan = activationPage().page; cancelledScan.scanInput();
  scanCallback({ code: 1 }, null); assert.equal(cancelledScan.showSheet, false);
  const leftScan = activationPage().page; leftScan.scanInput(); leftScan.aboutToDisappear();
  scanCallback(null, { originalValue: 'https://example.invalid/stale' });
  assert.equal(leftScan.inputUrl, '', 'late scanner result cannot reopen a hidden page');
  assert.equal(start, startsBeforeImport + 1, 'scan cannot activate or start VPN');
  console.log('PASS: native scanner album option, single-flight, confirmation-only result, cancel and late result');
  let finishFile, fileReads = 0;
  readYaml = () => { fileReads++; return new Promise(resolve => { finishFile = resolve; }); };
  const fileImport = activationPage().page;
  const readingFile = fileImport.importFile('file://docs/synthetic.yaml');
  await fileImport.importFile('file://docs/synthetic.yaml');
  assert.equal(fileReads, 1, 'file import must remain single-flight while async I/O yields');
  finishFile('proxies: []'); await readingFile;
  assert.equal(importedWrites, 1); assert.equal(fileImport.sheetMode, 4);
  const hiddenFile = activationPage().page;
  const oldFile = hiddenFile.importFile('file://docs/old.yaml');
  hiddenFile.aboutToDisappear(); finishFile('late content'); await oldFile;
  assert.equal(importedWrites, 1, 'late async file content cannot be committed after leave');
  readYaml = async () => { throw Error('invalid UTF8 private-uri'); };
  const damagedFile = activationPage().page;
  await damagedFile.importFile('file://docs/damaged.yaml');
  assert.equal(importedWrites, 1); assert.equal(damagedFile.importing, false);
  assert.ok(!toasts.some(value => value.includes('private-uri')));
  console.log('PASS: shared async file helper, repeated import, late read suppression and safe failure');
  uncertainProfile = true;
  const recovery = activationPage().page;
  assert.equal(recovery.recoveryNeeded, true);
  recovery.confirmRecovery(); const cancelledRecovery = dialog;
  cancelledRecovery.primaryButton.action(); cancelledRecovery.secondaryButton.action();
  assert.equal(recoveryCalls, 0, 'cancelled recovery confirmation stays cancelled');
  recovery.confirmRecovery(); const oldRecovery = dialog;
  recovery.aboutToDisappear(); oldRecovery.secondaryButton.action(); assert.equal(recoveryCalls, 0);
  const sessionRecovery = activationPage().page;
  sessionRecovery.confirmRecovery(); const staleSessionDialog = dialog;
  profileSession = 'new-session'; staleSessionDialog.secondaryButton.action();
  assert.equal(recoveryCalls, 0, 'old recovery confirmation cannot stop a new session');
  const freshRecovery = activationPage().page;
  let finishRecovery;
  reconnectProfile = (_context, current) => { recoveryCalls++; return new Promise(resolve => {
    finishRecovery = () => resolve(current());
  }); };
  freshRecovery.confirmRecovery(); const confirmedRecovery = dialog;
  confirmedRecovery.secondaryButton.action(); confirmedRecovery.secondaryButton.action();
  assert.equal(recoveryCalls, 1, 'one confirmation produces one reconnect');
  freshRecovery.aboutToDisappear(); finishRecovery(); await Promise.resolve(); await Promise.resolve();
  assert.equal(freshRecovery.tabJump, -1, 'late recovery cannot navigate');
  uncertainProfile = false;
  active = profiles[0].file;
  const retryPage = activationPage().page;
  let finishRetry, retries = 0;
  autoRetry = () => { retries++; return new Promise(resolve => { finishRetry = resolve; }); };
  const retrying = retryPage.retryAutomatic(profiles[0]); await retryPage.retryAutomatic(profiles[0]);
  assert.equal(retries, 1, 'automatic update retry is single-flight');
  const priorRetryToasts = toasts.length;
  retryPage.aboutToDisappear(); finishRetry(); await retrying;
  assert.equal(toasts.length, priorRetryToasts, 'late auto-update retry must not report success');
  const skippedRetry = activationPage().page; autoRetry = async () => {};
  await skippedRetry.retryAutomatic(profiles[0]);
  assert.equal(toasts.at(-1), '未能更新，请检查网络及自动更新设置', 'skipped retry is not success');
  console.log('PASS: unknown recovery explicit confirmation/cancel/single-flight, late navigation and skipped/late automatic retry');
  const queuedScan = activationPage().page; queuedScan.rootVisible = true;
  queuedScan.scanInput();
  externalPending = { kind: 'url', value: 'https://shared.invalid/after-scan' };
  queuedScan.acceptExternalImport(); assert.ok(externalPending, 'busy scan retains pending input');
  scanCallback({ code: 1 }, null);
  assert.equal(externalPending, null); assert.equal(queuedScan.inputUrl, 'https://shared.invalid/after-scan');
  queuedScan.cancelImport(); assert.equal(externalActive, null, 'cancel releases the exact confirmation lease');
  const queuedFile = activationPage().page; queuedFile.rootVisible = true;
  readYaml = () => new Promise(resolve => { finishFile = resolve; });
  const importingQueuedFile = queuedFile.importFile('file://docs/queue.yaml');
  externalPending = { kind: 'url', value: 'https://shared.invalid/after-file' };
  queuedFile.acceptExternalImport(); assert.ok(externalPending, 'busy file read retains pending input');
  finishFile('proxies: []'); await importingQueuedFile;
  assert.ok(externalPending, 'ready confirmation retains the modal slot');
  assert.equal(queuedFile.sheetMode, 4);
  queuedFile.cancelImport();
  assert.equal(externalPending, null); assert.equal(queuedFile.inputUrl, 'https://shared.invalid/after-file');
  assert.equal(queuedFile.sheetMode, 2, 'new share is confirmed after the user safely closes the ready sheet');
  queuedFile.cancelImport();
  console.log('PASS: cancelled sharing lease, queued external input after scanner cancellation and async file import');
  const editorNavigation = activationPage().page;
  const editorPaths = [];
  editorNavigation.navStack = { getAllPathName: () => editorPaths.slice(), pushPath: value => editorPaths.push(value.name) };
  editorNavigation.openRuleDns('candidate.yaml'); editorNavigation.openRuleDns('candidate.yaml');
  assert.equal(editorPaths.join(','), 'ruleDnsEditor', 'real subscription action opens the registered editor once');
  editorPaths.length = 0;
  editorNavigation.openProxyEditor('candidate.yaml'); editorNavigation.openProxyEditor('candidate.yaml');
  assert.equal(editorPaths.join(','), 'profileProxyEditor', 'node editor action also deduplicates navigation');
  editorPaths.length = 0;
  editorNavigation.openTemplate('candidate.yaml'); editorNavigation.openTemplate('candidate.yaml');
  assert.equal(editorPaths.join(','), 'profileTemplate');
  const rootEntry = fs.readFileSync(path.join(pages, 'Index.ets'), 'utf8');
  assert.match(rootEntry, /name === 'profileTemplate'[\s\S]*?ProfileTemplatePage\(\{ visible: this\.templateVisible \}\)/);
  assert.match(rootEntry, /name === 'ruleDnsEditor'[\s\S]*?RuleDnsEditorPage\(\{ visible: this\.ruleDnsVisible \}\)/);
  assert.match(rootEntry, /onHidden\(\(\) => \{ this\.ruleDnsVisible = false; \}\)/);
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
  let regionFailureMessage = '地区策略已关闭，但原选项未恢复';
  const PartialDisable = load('ProfilePage', { ...common,
    '@kit.CoreFileKit': {}, '@kit.ArkTS': {}, '@kit.BasicServicesKit': {}, './ProfileEditPage': {}, './ProfileTemplatePage': { ProfileTemplateBus: { file: '' } }, './ProfileProxyEditorPage': { ProfileProxyEditorBus: { file: '' } }, './RuleDnsEditorPage': { RuleDnsEditorBus: { file: '', section: '' } },
    '../lib/CoreApi': { CoreApi: {} },
    '../lib/EffectiveVersions': { EffectiveVersions: {
      read: () => ({ Profiles: { 'candidate.yaml': {} } }),
      regionPlan: () => ({ mode: 'region', selector: 'Main', assignments: {}, enable: committedRegionEnabled })
    } },
    '../lib/ProfileTransactions': { ProfileTransactions: { onIdle: () => () => {}, isBusy: () => false,
      setRegionPlan: async () => {
        committedRegionEnabled = false;
        throw Error(regionFailureMessage);
      }
    } },
    '../lib/ProfileStore': { ProfileStore: {
      isApplyUncertain: () => false, getOrigin: () => '',
      list: () => { regionLists++; return profiles; }, getMeta: () => ({}), getActiveFile: () => active
    } }
  });
  const partialDisable = new PartialDisable();
  partialDisable.profileRevision = 0;
  partialDisable.navStack = { getAllPathName: () => [], pop() {} };
  partialDisable.aboutToAppear();
  const beforeDisable = regionLists;
  const beforeDetailKey = partialDisable.detailKey(profiles[1]);
  await partialDisable.toggleRegion('candidate.yaml');
  assert.ok(regionLists > beforeDisable, 'partial committed disable must refresh the displayed strategy');
  assert.notEqual(partialDisable.detailKey(profiles[1]), beforeDetailKey,
    'partial commit must replace the detail ForEach item rather than reuse its old actions');
  assert.equal(partialDisable.savedRegion('candidate.yaml').enable, false,
    'the view must use the committed disabled version after restore fails');
  assert.match(fs.readFileSync(path.join(pages, 'ProfilePage.ets'), 'utf8'),
    /this\.ProfileDetail\(p\)\s*\}, \(p: ProfileMeta\) => this\.detailKey\(p\)\)/,
    'detail ForEach must use the revision-aware key');
  assert.ok(toasts.includes('配置已保存，地区选择待重连恢复'), 'committed restore failures retain the necessary recovery direction');
  regionFailureMessage = 'private: synthetic-token';
  await partialDisable.toggleRegion('candidate.yaml');
  assert.equal(toasts.at(-1), '地区策略未完成，请重试');
  partialDisable.importedFile = 'candidate.yaml'; partialDisable.regionMode = 'region'; partialDisable.regionPreview = { eligible: true, nodes: {} };
  await partialDisable.saveRegion(false); assert.equal(partialDisable.importError, '地区策略未完成，请重试');
  assert.ok(!partialDisable.importError.includes('synthetic-token'));

  active = 'fixture.yaml';
  controller.status = status.Connected; profile.confirmDelete(profiles[0]); dialog.secondaryButton.action();
  assert.equal(deleted, 0, 'running active profile must be protected');
  controller.status = status.Disconnected; await dialog.secondaryButton.action(); await new Promise(resolve => setImmediate(resolve)); assert.equal(deleted, 1);
  let failDraft = true;
  const Edit = load('ProfileEditPage', { ...common,
    '../lib/ProfileStore': { ProfileStore: { writeDraft: () => { if (failDraft) throw Error('disk full'); } } },
    '../lib/ProfileTransactions': { ProfileTransactions: { onIdle: () => () => {}, isBusy: () => false, edit: async () => 'applied' } }
  });
  const editor = new Edit(); editor.persistDraft('synthetic');
  assert.equal(editor.dirty, true); assert.equal(editor.draftPersisted, false, 'failed draft write cannot claim recovery');
  failDraft = false; editor.persistDraft('synthetic'); assert.equal(editor.draftPersisted, true);
  // List editing is synchronous: hidden/cancelled sheets cannot commit queued taps.
  let networkSaved = 0;
  let networkSettings = {ipv6:false,accessMode:'white',accessList:[]};
  const source = fs.readFileSync(path.join(pages,'../lib/VpnController.ets'),'utf8');
  const policySandbox = {exports:{},require:()=>({})};
  vm.runInNewContext(ts.transpileModule(source).outputText,policySandbox);
  const Network = load('NetworkSettingsPage', {...common,
    '../lib/VpnController':policySandbox.exports,
    '../lib/Settings':{Settings:{idle:async()=>{},load:()=>({...networkSettings}),save:(_c,v)=>{networkSaved++;networkSettings=v;}}}
  }, {getContext:()=>({applicationInfo:{name:'test.bundle'}})});
  const network = new Network();network.aboutToAppear();await new Promise(resolve=>setImmediate(resolve));network.showAddDialog=true;
  network.inputPkg='bad';network.addPackage();assert.equal(networkSaved,0);assert.equal(network.showAddDialog,true);
  network.inputPkg='test.bundle';network.addPackage();assert.equal(networkSaved,0);
  network.inputPkg='sample.app';network.addPackage();network.addPackage();assert.equal(networkSaved,1,'repeated tap cannot commit twice');
  network.showAddDialog=true;network.inputPkg='sample.other';network.cancelAddPackage();network.addPackage();
  assert.equal(networkSaved,1,'cancel/hidden sheet retains existing scope');assert.equal(network.inputPkg,'');
  network.showAddDialog=true;network.inputPkg='sample.late';network.showRouteDetails=true;network.aboutToDisappear();network.addPackage();
  assert.equal(networkSaved,1,'page exit blocks queued add');assert.equal(network.showRouteDetails,false);
  const returned = new Network();returned.aboutToAppear();await new Promise(setImmediate);assert.deepEqual(Array.from(returned.accessList),['sample.app']);
  console.log('PASS: native page traffic, one-tap stop, bounded diagnosis, transaction activation/navigation identity, import retry, draft persistence and active-delete guard');
})().catch(error => { console.error(error); process.exit(1); });
