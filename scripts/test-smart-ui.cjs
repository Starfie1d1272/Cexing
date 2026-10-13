// Actual SDK-transpiled Smart page/client behavior; no native rendering/device claim.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const base = path.join(__dirname, '../cexing/entry/src/main/ets');
function compile(file, modules, extras = {}, page = false) {
  let source = fs.readFileSync(path.join(base, file), 'utf8');
  if (page) source = source.slice(0, source.indexOf('  build()')) + '\n}';
  source = source.split('\n').map(line => line.trimStart().startsWith('@') ?
    line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '') : line).join('\n').replace(/export struct /g, 'export class ');
  const sandbox = { exports: {}, require: name => { assert.ok(name in modules, name); return modules[name]; },
    getContext: () => ({}), ArrayBuffer, Uint8Array, Promise, Error, ...extras };
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS,
    target: ts.ScriptTarget.ES2020 } }).outputText, sandbox);
  return sandbox.exports;
}
(async () => {
  const secret = 'a'.repeat(64), requests = [];
  let credential = secret, destroyed = 0;
  const { CoreApi } = compile('lib/CoreApi.ets', {
    '@kit.AbilityKit': { application: { getApplicationContext: () => ({ createModuleContext: () => ({ filesDir: '/private' }) }) } },
    '@kit.CoreFileKit': { fileIo: { readTextSync: () => credential } }, '@kit.ArkTS': {},
    './Logger': { Logger: { warn() {} } }, '@kit.NetworkKit': { http: {
      RequestMethod: { GET: 'GET', POST: 'POST' }, createHttp: () => ({ destroy: () => destroyed++,
        request: async (url, options) => { requests.push({ url, options });
          return { responseCode: 200, result: url.endsWith('/status') ? JSON.stringify({ schemaVersion: 1 }) :
            JSON.stringify({ installed: true, restartRequired: true }) }; }
      }) } }
  });
  assert.ok(await CoreApi.getSmartStatus());
  const bytes = new ArrayBuffer(9345218);
  assert.ok((await CoreApi.importSmartModel(bytes)).restartRequired);
  assert.equal(requests[1].options.header.Authorization, `Bearer ${secret}`);
  assert.equal(requests[1].options.header['Content-Type'], 'application/octet-stream');
  assert.equal(requests[1].options.extraData, bytes);
  assert.equal(requests[1].options.method, 'POST');
  assert.equal(await CoreApi.importSmartModel(new ArrayBuffer(12)), null);
  credential = 'bad'; assert.equal(await CoreApi.importSmartModel(bytes), null);
  assert.equal(requests.length, 2); assert.equal(destroyed, 2);

  let status = { groups: { original: { useLightGBM: true } }, model: { state: 'loaded', predictions: 0, restartRequired: false }, message: 'loaded' };
  let selectResolve, uploaded = 0, closed = 0, offset = 0, throwRead = false;
  const timers = new Map(); let timerID = 0;
  const { SmartPage } = compile('pages/SmartPage.ets', {
    '@kit.AbilityKit': {}, './NativeTheme': {}, '../lib/SmartModelRestart': { SmartModelRestart: {} },
    '../lib/Settings': { Settings: { load: () => ({ smartAutoConvert: true }) } },
    '../lib/ProfileTransactions': { ProfileTransactions: { setSmartAutoConvert: async () => 'applied' } },
    '../lib/VpnController': { VpnStatus: { Connected: 2 }, VpnController: { status: 2 } },
    '../lib/CoreApi': { CoreApi: { getSmartStatus: async () => status,
      importSmartModel: async body => { assert.equal(body.byteLength, 9345218); uploaded++; return { installed: true, restartRequired: true }; } } },
    '@kit.CoreFileKit': { picker: { DocumentViewPicker: class { select() { return new Promise(resolve => selectResolve = resolve); } },
      DocumentSelectMode: { FILE: 1 } }, fileIo: { OpenMode: { READ_ONLY: 1 }, openSync: () => { offset = 0; return { fd: 1 }; },
      statSync: () => ({ size: 9345218 }), closeSync: () => closed++, readSync: (_fd, chunk) => {
        if (throwRead) throw Error('unreadable');
        const n = Math.min(17001, chunk.byteLength, 9345218 - offset); offset += n; return n;
      } } }
  }, { setTimeout: fn => { timers.set(++timerID, fn); return timerID; }, clearTimeout: id => timers.delete(id) }, true);
  const page = new SmartPage(); page.visible = true; page.aboutToAppear();
  await new Promise(setImmediate);
  assert.equal(page.modelSummary, '模型已加载'); assert.equal(page.predictions, '本进程有效预测 0 次');
  assert.match(page.predictionNote, /尚未记录有效预测/);
  assert.ok(page.groupSummary.includes('original'));
  let pending = page.importModel(); selectResolve(['synthetic.bin']); await pending;
  assert.equal(uploaded, 1); assert.equal(closed, 1); assert.equal(page.restartRequired, true);
  pending = page.importModel(); throwRead = true; selectResolve(['synthetic.bin']); await pending;
  assert.equal(uploaded, 1); assert.equal(closed, 2); assert.equal(page.busy, false);
  pending = page.importModel(); page.visible = false; page.onVisible(); selectResolve(['synthetic.bin']); await pending;
  assert.equal(uploaded, 1, 'hidden picker result cannot import');
  assert.equal(timers.size, 0);
  page.visible = true; page.onVisible(); await new Promise(setImmediate);
  status = null; await page.refresh(page.generation);
  assert.equal(page.ready, false); assert.equal(page.modelSummary, '尚未检查');
  page.aboutToDisappear();
  console.log('PASS: shared Bearer binary upload, exact size, short reads/close, hidden picker cleanup, loaded vs predictions and unreachable state');
})().catch(error => { console.error(error); process.exitCode = 1; });
