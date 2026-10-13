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
  return sandbox.exports[name];
}
const status = { Disconnected: 0, Connecting: 1, Connected: 2, Disconnecting: 3 };
(async () => {
  let now = 1000, stream, tick, dialog, stop = 0, timerCleared = 0;
  let activeHomeFile = 'fixture.yaml';
  const listeners = new Set();
  function emit(next) { controller.status = next; for (const listener of listeners) listener(next); }
  let pendingFailure = '';
  const controller = { status: status.Connected, onChanged(fn) { listeners.add(fn); }, offChanged(fn) { listeners.delete(fn); },
    consumeLastStartError: () => { const value = pendingFailure; pendingFailure = ''; return value; },
    getLastStartFailure: () => null, stop: () => stop++, start() {} };
  const common = {
    '@kit.AbilityKit': {}, '@kit.ArkUI': { promptAction: { showToast() {} } },
    '@kit.BasicServicesKit': {}, '../lib/ConnectionFailure': { ConnectionFailures: {} },
    '../lib/VpnController': { VpnController: controller, VpnStatus: status },
    './NativeTheme': { NativeTheme: {} }, '../lib/Logger': { Logger: { warn() {} } }
  };
  const Home = load('HomePage', { ...common,
    '../lib/CoreApi': { CoreApi: { StreamWatcher: class { start(_path, cb) { stream = cb; } stop() { stream = null; } },
      getConfigs: async () => null }, formatRate: n => `${n} B/s` },
    '../lib/ProfileStore': { ProfileStore: { getActiveFile: () => activeHomeFile } },
    '../lib/Settings': { Settings: { load: () => ({ mode: 'rule' }) } },
    '../lib/AppRuntime': { AppRuntime: { cancelRestore() {} } }
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
  home.toggle(); assert.equal(stop, 0, 'disconnect requires confirmation');
  dialog.primaryButton.action(); dialog.secondaryButton.action();
  assert.equal(stop, 0, 'cancelled confirmation must stay invalid');
  home.toggle(); const oldSessionConfirm = dialog.secondaryButton.action;
  emit(status.Disconnected); emit(status.Connecting); emit(status.Connected);
  oldSessionConfirm(); assert.equal(stop, 0, 'old dialog must not stop a reconnected session');
  home.toggle(); const oldTabConfirm = dialog.secondaryButton.action;
  home.currentVisibleTab = 1; home.onTabVisible(); home.currentVisibleTab = 0; home.onTabVisible();
  oldTabConfirm(); assert.equal(stop, 0, 'tab leave/return invalidates old dialog');
  home.toggle(); const oldNavigationConfirm = dialog.secondaryButton.action;
  home.rootVisible = false; home.onRootVisible(); home.rootVisible = true; home.onRootVisible();
  oldNavigationConfirm(); assert.equal(stop, 0, 'secondary navigation invalidates old dialog');
  home.toggle(); const oldPageConfirm = dialog.secondaryButton.action;
  home.aboutToDisappear(); oldPageConfirm(); assert.equal(stop, 0, 'destroyed page cannot confirm');
  assert.equal(timerCleared, 1);
  home.aboutToAppear(); oldPageConfirm(); assert.equal(stop, 0, 'recreated page cannot revive old dialog');
  home.toggle(); dialog.secondaryButton.action(); dialog.secondaryButton.action();
  assert.equal(stop, 1, 'fresh confirmation works exactly once');
  home.aboutToDisappear(); assert.equal(stop, 1, 'page destruction must not stop VPN');

  activeHomeFile = '未导入.yaml'; home.refreshProfile();
  assert.equal(home.profileName, '未导入'); assert.equal(home.hasProfile, true, 'display sentinel is a valid filename');
  activeHomeFile = '未导入.yml'; home.refreshProfile(); assert.equal(home.hasProfile, true);
  activeHomeFile = ''; home.refreshProfile(); assert.equal(home.hasProfile, false, 'empty selection has separate existence state');
  console.log('PASS: review reproductions: old-session/hidden-page confirmation invalidation and sentinel-named profiles');

  let resolveProbe;
  const Diagnostics = load('DiagnosticsPage', { ...common,
    '../lib/CoreApi': { CoreApi: { isAlive: () => new Promise(resolve => { resolveProbe = resolve; }) } }
  }, { setTimeout: () => 1, clearTimeout() {} });
  const diagnostics = new Diagnostics(); diagnostics.aboutToAppear();
  const pending = diagnostics.check(); diagnostics.aboutToDisappear(); resolveProbe(true); await pending;
  assert.equal(diagnostics.control, '尚未检查', 'late probe must not update destroyed page');
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
  const profiles = [{ file: 'fixture.yaml', name: 'Fixture', active: true }];
  const Profile = load('ProfilePage', { ...common,
    '@kit.CoreFileKit': {}, '@kit.ArkTS': {}, '@kit.BasicServicesKit': {}, './ProfileEditPage': {},
    '../lib/CoreApi': { CoreApi: {} },
    '../lib/ProfileStore': { ProfileStore: { list: () => profiles, getMeta: () => ({}),
      getActiveFile: () => active, deleteProfile: () => deleted++,
      importFromUrl: async () => { if (rejectImport) throw Error('network'); return 'candidate.yaml'; } } }
  }, { AlertDialog: { show: value => { dialog = value; } } });
  const profile = new Profile(); profile.profileRevision = 0; profile.navStack = { pop() {} };
  profile.showSheet = true; profile.inputUrl = 'https://example.invalid/fixture.yaml';
  await profile.importUrl(); assert.equal(profile.inputUrl, 'https://example.invalid/fixture.yaml');
  assert.ok(profile.importError); assert.equal(profile.importing, false);
  rejectImport = false; await profile.importUrl();
  assert.equal(active, 'fixture.yaml', 'import confirmation must not silently change active selection');
  assert.equal(profile.importedFile, 'candidate.yaml'); assert.equal(profile.showSheet, true);
  controller.status = status.Connected; profile.confirmDelete(profiles[0]); dialog.secondaryButton.action();
  assert.equal(deleted, 0, 'running active profile must be protected');
  controller.status = status.Disconnected; dialog.secondaryButton.action(); assert.equal(deleted, 1);
  console.log('PASS: native page stale traffic/navigation ownership, disconnect confirmation, stale diagnosis, invalid port, import retry/confirmation and active-delete guard');
})().catch(error => { console.error(error); process.exit(1); });
