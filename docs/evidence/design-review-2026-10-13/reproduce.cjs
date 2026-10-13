// Behavioral regression against actual page logic using the official SDK compiler.
// UI builders are excluded; HAP compilation validates ArkUI syntax. No rendering/device claim.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(path.join(process.env.OHOS_SDK_HOME, 'ets/build-tools/ets-loader/node_modules/typescript'));
const pages = path.join(process.argv[2] || path.join(__dirname, '../../..'), 'clash-openharmony/entry/src/main/ets/pages');
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
  const observations = [];
  let active = 'old.yaml', reloaded = [], messages = [];
  const profileItem = { file: 'new.yaml', name: 'New', active: false };
  const store = { setActive: (_ctx, file) => { active = file; }, getActiveContent() {},
    getActiveFile: () => active, absPath: (_ctx, file) => file,
    list: () => [profileItem], getMeta: () => ({}), updateFromOrigin: async () => {} };
  const common = { '@kit.AbilityKit': {}, '@kit.ArkUI': { promptAction: { showToast: value => messages.push(value.message) } },
    './NativeTheme': {}, '../lib/Logger': { Logger: { warn() {} } } };
  const Profile = load('ProfilePage', { ...common, '@kit.CoreFileKit': {}, '@kit.ArkTS': {},
    '@kit.BasicServicesKit': {}, './ProfileEditPage': {},
    '../lib/ProfileStore': { ProfileStore: store },
    '../lib/VpnController': { VpnStatus: status, VpnController: { status: 2 } },
    '../lib/CoreApi': { CoreApi: { isAlive: async () => true,
      reloadConfig: async file => { reloaded.push(file); return false; } } }
  });
  const profile = new Profile(); profile.profileRevision = 0; profile.navStack = { pop() {} };
  await profile.activate(profileItem);
  assert.equal(active, 'new.yaml'); assert.deepEqual(reloaded, ['new.yaml']);
  assert.ok(messages.some(x => x.includes('热切换失败')));
  observations.push({ id: 'R1', observed: 'reload=false 后 active 标记仍为 new.yaml，运行内核未接受新配置' });
  messages = []; reloaded = [];
  await profile.updateProfile({ ...profileItem, active: true });
  assert.deepEqual(reloaded, ['new.yaml']); assert.deepEqual(messages, ['已更新']);
  observations.push({ id: 'R2', observed: '更新后 reload=false，唯一反馈仍是已更新' });
  let error = ''; const listeners = new Set();
  const controller = { status: status.Connecting, onChanged: fn => listeners.add(fn),
    offChanged: fn => listeners.delete(fn), consumeLastStartError: () => { const e = error; error = ''; return e; } };
  const Home = load('HomePage', { ...common,
    '../lib/VpnController': { VpnStatus: status, VpnController: controller },
    '../lib/ProfileStore': { ProfileStore: store },
    '../lib/CoreApi': { CoreApi: { StreamWatcher: class { start() {} stop() {} }, getConfigs: async () => null }, formatRate: String },
    '../lib/Settings': { Settings: { load: () => ({ mode: 'rule' }) } },
    '../lib/AppRuntime': { AppRuntime: {} }
  }, { setInterval: () => 1, clearInterval() {} });
  const home = new Home(); home.rootVisible = true; home.currentVisibleTab = 0;
  home.aboutToAppear(); home.aboutToDisappear();
  error = 'synthetic kernel startup error'; controller.status = status.Disconnected;
  for (const fn of listeners) fn(controller.status);
  home.aboutToAppear();
  assert.equal(home.label(), '未连接'); assert.equal(error, 'synthetic kernel startup error');
  observations.push({ id: 'R3', observed: 'Home 销毁期间启动失败，返回只显示未连接，未读取仍存留的错误' });
  home.aboutToDisappear();
  const p2 = new Profile(); p2.profileRevision = 0; p2.navStack = { pop() {} };
  const releases = [];
  store.updateFromOrigin = () => new Promise(resolve => { releases.push(resolve); });
  store.getOrigin = () => 'https://example.invalid/synthetic';
  reloaded = [];
  const first = profile.updateProfile({ ...profileItem, active: true });
  const second = p2.onPullRefresh();
  assert.equal(p2.refreshing, true);
  assert.equal(releases.length, 2);
  for (const resolve of releases) resolve();
  await Promise.all([first, second]); observations.push({ id: 'R4', observed: '详情更新与列表下拉可同时进入来源更新，各页面的局部门禁未共享' });
  console.log(JSON.stringify({ source: 'SDK-transpiled actual page methods, synthetic mocks; no device/rendering claim', observations }, null, 2));
})().catch(error => { console.error(error); process.exit(1); });
