// Behavioral regression against actual page logic using the official SDK compiler.
// UI builders are excluded; HAP compilation validates ArkUI syntax. No rendering/device claim.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(path.join(process.env.OHOS_SDK_HOME, 'ets/build-tools/ets-loader/node_modules/typescript'));
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
  let activeHomeFile = 'fixture.yaml';
  const listeners = new Set();
  function emit(next) { controller.status = next; for (const listener of listeners) listener(next); }
  const controller = { status: status.Connected, onChanged(fn) { listeners.add(fn); }, offChanged(fn) { listeners.delete(fn); },
    consumeLastStartError: () => '', stop: () => stop++, start: () => start++ };
  const common = {
    '@kit.AbilityKit': {}, '@kit.ArkUI': { promptAction: { showToast() {} } },
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
  home.rootVisible = true; home.currentVisibleTab = 0; home.aboutToAppear();
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
  console.log('PASS: one-tap stop, cancel/reconnect, stale traffic and sentinel-named profiles');

  let resolveProbe;
  const Diagnostics = load('DiagnosticsPage', { ...common,
    '../lib/CoreApi': { CoreApi: { isAlive: () => new Promise(resolve => { resolveProbe = resolve; }) } }
  });
  const diagnostics = new Diagnostics(); diagnostics.aboutToAppear();
  const pending = diagnostics.check(); diagnostics.aboutToDisappear(); resolveProbe(true); await pending;
  assert.equal(diagnostics.control, '尚未检查本机服务', 'late probe must not update destroyed page');

  let saved = 0, value;
  const Override = load('OverridePage', { ...common,
    '../lib/Settings': { Settings: { load: () => ({}), save: (_ctx, s) => { saved++; value = s; } } }
  });
  const override = new Override(); override.mixedPort = '99999'; override.persist();
  assert.equal(saved, 0); assert.ok(override.portError); assert.equal(override.mixedPort, '99999');
  override.mixedPort = '7891'; override.persist(); assert.equal(saved, 1); assert.equal(value.mixedPort, 7891);

  let active = 'fixture.yaml', deleted = 0, rejectImport = true, alive = true;
  let reloadConfig = async () => true;
  const profiles = [{ file: 'fixture.yaml', name: 'Fixture', active: true },
    { file: 'candidate.yaml', name: 'Candidate', active: false }];
  const Profile = load('ProfilePage', { ...common,
    '@kit.CoreFileKit': {}, '@kit.ArkTS': {}, '@kit.BasicServicesKit': {}, './ProfileEditPage': {},
    '../lib/CoreApi': { CoreApi: { isAlive: async () => alive, reloadConfig: (...args) => reloadConfig(...args) } },
    '../lib/ProfileStore': { ProfileStore: { list: () => profiles, getMeta: () => ({}),
      getActiveFile: () => active, setActive: (_ctx, file) => { active = file; },
      getActiveContent: () => 'synthetic', absPath: (_ctx, file) => file,
      deleteProfile: () => deleted++,
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
  reloadConfig = async () => false;
  const failed = activationPage();
  await failed.page.activate(profiles[1]);
  assert.equal(failed.page.tabJump, -1, 'rejected or unconfirmed reload stays on profile page');
  alive = false;
  const unknown = activationPage();
  await unknown.page.activate(profiles[1]);
  assert.equal(unknown.page.tabJump, -1, 'unconfirmed local service does not navigate');
  alive = true;
  let finishReload;
  reloadConfig = () => new Promise(resolve => { finishReload = resolve; });
  async function waitForReload() {
    for (let i = 0; i < 8 && !finishReload; i++) { await Promise.resolve(); }
    assert.equal(typeof finishReload, 'function', 'activation reached mock reload');
  }
  const timedOut = activationPage();
  const timeout = timedOut.page.activate(profiles[1]);
  await waitForReload(); finishReload(false); await timeout;
  assert.equal(timedOut.page.tabJump, -1, 'timeout or unknown reload cannot navigate');
  finishReload = undefined;
  const left = activationPage();
  const late = left.page.activate(profiles[1]);
  await waitForReload();
  left.page.aboutToDisappear(); finishReload(true); await late;
  assert.equal(left.page.tabJump, -1, 'completion after page leave cannot navigate');
  finishReload = undefined;
  const switchedTab = activationPage();
  const pendingTab = switchedTab.page.activate(profiles[1]);
  await waitForReload();
  switchedTab.page.currentVisibleTab = 2; switchedTab.page.onTabVisible();
  switchedTab.page.currentVisibleTab = 1; switchedTab.page.onTabVisible();
  finishReload(true); await pendingTab;
  assert.equal(switchedTab.page.tabJump, -1, 'leaving and returning to the tab cannot revive an old request');
  const paths = ['profileDetail'];
  Profile.moduleExports.ProfileDetailBus.current = 'candidate.yaml';
  const newerRoute = activationPage(paths, 'candidate.yaml');
  finishReload = undefined;
  const pendingRoute = newerRoute.page.activate(profiles[1]);
  await waitForReload();
  paths.push('profileEdit'); finishReload(true); await pendingRoute;
  assert.equal(newerRoute.pops(), 0, 'completion cannot pop a newer destination');
  assert.equal(newerRoute.page.tabJump, -1, 'completion cannot jump over a newer destination');
  const detail = activationPage(['profileDetail'], 'candidate.yaml');
  finishReload = undefined;
  const completedDetail = detail.page.activate(profiles[1]);
  await waitForReload(); finishReload(true); await completedDetail;
  assert.equal(detail.pops(), 1, 'current detail pops exactly once after definite success');
  assert.equal(detail.page.tabJump, 0, 'current detail returns to Connect');
  active = 'fixture.yaml';
  controller.status = status.Connected; profile.confirmDelete(profiles[0]); dialog.secondaryButton.action();
  assert.equal(deleted, 0, 'running active profile must be protected');
  controller.status = status.Disconnected; dialog.secondaryButton.action(); assert.equal(deleted, 1);
  console.log('PASS: native page traffic, one-tap stop, bounded diagnosis, activation outcome/navigation identity, import retry and active-delete guard');
})().catch(error => { console.error(error); process.exit(1); });
