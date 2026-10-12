// Behavioral regression against actual page logic using the official SDK compiler.
// UI builders are excluded; HAP compilation validates ArkUI syntax. No rendering/device claim.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(path.join(process.env.OHOS_SDK_HOME, 'ets/build-tools/ets-loader/node_modules/typescript'));
const pages = path.join(__dirname, '../clash-openharmony/entry/src/main/ets/pages');
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
  const controller = { status: status.Connected, onChanged() {}, offChanged() {},
    consumeLastStartError: () => '', stop: () => stop++, start() {} };
  const common = {
    '@kit.AbilityKit': {}, '@kit.ArkUI': { promptAction: { showToast() {} } },
    '../lib/VpnController': { VpnController: controller, VpnStatus: status },
    './NativeTheme': { NativeTheme: {} }, '../lib/Logger': { Logger: { warn() {} } }
  };
  const Home = load('HomePage', { ...common,
    '../lib/CoreApi': { CoreApi: { StreamWatcher: class { start(_path, cb) { stream = cb; } stop() { stream = null; } },
      getConfigs: async () => null }, formatRate: n => `${n} B/s` },
    '../lib/ProfileStore': { ProfileStore: { getActiveFile: () => 'fixture.yaml' } },
    '../lib/Settings': { Settings: { load: () => ({ mode: 'rule' }) } },
    '../lib/AppRuntime': { AppRuntime: { cancelRestore() {} } }
  }, { Date: { now: () => now }, setInterval: cb => { tick = cb; return 1; },
    clearInterval: () => timerCleared++, AlertDialog: { show: value => { dialog = value; } } });
  const home = new Home();
  home.rootVisible = true; home.currentVisibleTab = 0; home.aboutToAppear();
  stream({ up: 128, down: 256 }); assert.equal(home.upRate, '128 B/s');
  now += 4001; tick(); assert.equal(home.upRate, '—', 'stale WS sample must be cleared');
  home.currentVisibleTab = 1; home.onTabVisible(); assert.equal(stream, null);
  home.currentVisibleTab = 0; home.onTabVisible(); assert.ok(stream);
  home.rootVisible = false; home.refreshTraffic(); assert.equal(stream, null, 'secondary navigation releases stream');
  home.toggle(); assert.equal(stop, 0, 'disconnect requires confirmation');
  dialog.primaryButton.action(); assert.equal(stop, 0);
  controller.status = status.Disconnected; dialog.secondaryButton.action(); assert.equal(stop, 0, 'late confirm rechecks status');
  controller.status = status.Connected; dialog.secondaryButton.action(); assert.equal(stop, 1);
  home.aboutToDisappear(); assert.equal(stop, 1, 'page destruction must not stop VPN'); assert.equal(timerCleared, 1);

  let resolveProbe;
  const Diagnostics = load('DiagnosticsPage', { ...common,
    '../lib/CoreApi': { CoreApi: { isAlive: () => new Promise(resolve => { resolveProbe = resolve; }) } }
  });
  const diagnostics = new Diagnostics(); diagnostics.aboutToAppear();
  const pending = diagnostics.check(); diagnostics.aboutToDisappear(); resolveProbe(true); await pending;
  assert.equal(diagnostics.control, '尚未检查', 'late probe must not update destroyed page');

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
