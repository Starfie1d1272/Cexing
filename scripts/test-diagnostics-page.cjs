// Actual page methods with deterministic platform mocks; HAP compile checks ArkUI builders.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
function compile(source) {
  return ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText;
}
const failureModule = { exports: {} };
vm.runInNewContext(compile(fs.readFileSync('cexing/entry/src/main/ets/lib/ConnectionFailure.ets', 'utf8')), failureModule);
const source = fs.readFileSync('cexing/entry/src/main/ets/pages/DiagnosticsPage.ets', 'utf8');
const methods = (source.slice(0, source.indexOf('  build()')) + '\n}')
  .replace(/@\w+(?:\([^\n)]*\))?\s*/g, '').replace('export struct ', 'export class ');
let result = 'reachable', listener, copied, opened, timeout;
const toasts = [];
const controller = { status: 2, onChanged: fn => { listener = fn; }, offChanged() {},
  getLastStartFailure: () => null, getTunCreateObserved: () => true, getKernelReadyReported: () => true };
const deviceInfo = { osFullName: 'HarmonyOS 7.0.0.109' };
const modules = {
  '../lib/CoreApi': { CoreApi: { checkController: async () => result } },
  '../lib/VpnController': { VpnController: controller, VpnStatus: { Connected: 2, Connecting: 1, Disconnecting: 3 } },
  '../lib/ConnectionFailure': failureModule.exports, './NativeTheme': {},
  '@kit.BasicServicesKit': { deviceInfo, pasteboard: { MIMETYPE_TEXT_PLAIN: 'text/plain',
    createData: (_mime, text) => text, getSystemPasteboard: () => ({ setData: async text => { copied = text; } }) } },
  '@kit.AbilityKit': { bundleManager: { BundleFlag: { GET_BUNDLE_INFO_DEFAULT: 0 },
    getBundleInfoForSelf: async () => ({ versionName: '1.0.0', versionCode: 1 }) } },
  '@kit.ArkUI': { promptAction: { showToast: value => toasts.push(value.message) } }
};
const sandbox = { exports: {}, require: key => modules[key], Date, Promise,
  getContext: () => ({ startAbility: async want => { opened = want.uri; } }),
  setTimeout: fn => { timeout = fn; return 1; }, clearTimeout() {} };
vm.runInNewContext(compile(methods), sandbox);
(async () => {
  const page = new sandbox.exports.DiagnosticsPage(); page.aboutToAppear();
  await page.copySummary(); assert.match(copied, /controller=not-run/); assert.match(copied, /controller_checked_at=not-run/);
  await page.check(); assert.equal(page.control, '本机服务可达'); assert.match(page.checkedAt, /^\d{4}-/);
  listener(2); assert.equal(page.control, '本机服务可达', 'same status notification preserves completed check');
  await page.copySummary(); assert.match(copied, /controller=reachable/); assert.match(copied, /system_version=HarmonyOS 7.0.0.109/);
  assert.match(copied, /request_forwarding=unverified/);
  deviceInfo.osFullName = 'https://private.invalid/?token=secret';
  await page.copySummary(); assert.match(copied, /system_version=unknown/); assert.ok(!copied.includes('secret'));
  for (const failure of ['failed', 'credentials', 'authorization']) {
    result = failure; await page.check(); assert.equal(page.busy, false); assert.ok(page.checkedAt);
    await page.copySummary(); assert.match(copied, /controller=failed/);
  }
  result = 'reachable'; await page.check(); listener(0);
  assert.equal(page.control, '尚未检查本机服务'); assert.equal(page.checkedAt, '');
  await page.openFeedback(); assert.equal(opened, 'https://github.com/Starfie1d1272/Cexing/issues/new?template=diagnostics.yml');
  assert.ok(!opened.includes('controller='), 'no summary or credentials in URL');
  assert.match(source, /Text\(this\.control\)/, 'display binds directly to observed state');
  assert.ok(!source.includes('this.Fact('), 'no captured value builder for check results');
  console.log('PASS: diagnostic results, time, same-status notification, bounded summary and user-submitted template');
})().catch(error => { console.error(error); process.exitCode = 1; });
