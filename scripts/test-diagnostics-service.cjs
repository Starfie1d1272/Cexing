// Actual service methods, synthetic kit/worker responses; no external network.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const source = fs.readFileSync(path.join(__dirname, '../cexing/entry/src/main/ets/lib/DiagnosticsService.ets'), 'utf8');
const output = ts.transpileModule(source).outputText;
let credential = 's'.repeat(64), status = 200, workerFailed = false, transportError = null;
let body = { version: 'fixture' }, destroyed = 0;
const actions = [], requests = [], files = new Map();
const support = { schema: 'cexing-support-bundle/1', sources: [{ name: 'kernel-previous', stage: 'tun_start', code: 'errno:111' }] };
const context = { filesDir: '/fixture/files', cacheDir: '/fixture/cache' };
const kits = {
  '@kit.AbilityKit': { bundleManager: { BundleFlag: { GET_BUNDLE_INFO_DEFAULT: 0 },
    getBundleInfoForSelfSync: () => ({ versionName: '0.1.0', versionCode: 1 }) } },
  '@kit.BasicServicesKit': { deviceInfo: { sdkApiVersion: 26, osFullName: 'HarmonyOS 7.0.0.109', deviceType: 'phone', abiList: 'arm64-v8a' } },
  '@kit.CoreFileKit': { fileIo: { OpenMode: { WRITE_ONLY: 1, CREATE: 2, TRUNC: 4 },
    openSync: file => ({ fd: file }), writeSync: (file, content) => files.set(file, content), closeSync: () => {},
    moveFileSync: (from, to) => { files.set(to, files.get(from)); files.delete(from); } } },
  '@kit.NetworkKit': { http: { RequestMethod: { GET: 'GET', POST: 'POST' }, createHttp: () => ({
    request: async (url, options) => { requests.push({ url, options }); if (transportError) throw transportError;
      return { responseCode: status, result: JSON.stringify(body) }; }, destroy: () => destroyed++ }) } },
  'libentry.so': { __esModule: true, default: { versionAction: async (home, input) => {
    assert.equal(home, context.filesDir); const action = JSON.parse(input); actions.push(action);
    if (workerFailed) throw new Error('synthetic failure');
    return JSON.stringify(action.op === 'diagnostics-export' ? support : { recorded: true });
  } } },
  './CoreApi': { CoreApi: { getControllerAccess: () => credential ? { httpBase: 'http://127.0.0.1:9090', secret: credential } : null } },
  './VpnController': { VpnStatus: { Disconnected: 0 }, VpnController: { status: 0, getLastStartFailure: () => null, getLastStopCompleted: () => null, getTunCreateObserved: () => false, getKernelReadyReported: () => false, onChanged: fn => { sandbox.listener = fn; }, offChanged: fn => { assert.equal(fn, sandbox.listener); sandbox.listener = null; } } },
  './Settings': { Settings: { load: () => ({ keepAlive: true, ipv6: false, allowLan: false, logToFile: false,
    smartAutoConvert: true, autoUpdate: false, autoRestore: true, mixedPort: 7890, autoUpdateIntervalHours: 24,
    accessMode: 'all', mode: 'rule', logLevel: 'info', accessList: ['private.app'], mainGroup: 'private node' }) } }
};
const sandbox = { exports: {}, require: name => kits[name], Date, JSON, Promise, Object };
vm.runInNewContext(output, sandbox);
const { DiagnosticsService: service } = sandbox.exports;
(async () => {
  assert.equal(await service.initialize(context), true);
  assert.equal(await service.initialize(context), true);
  assert.equal(actions.length, 1, 'initialize must not reset persistent sessions on every page');
  assert.ok(!JSON.stringify(actions).includes('private.app'));
  assert.ok(!JSON.stringify(actions).includes('private node'));
  assert.equal(actions[0].environment.osVersion, 'HarmonyOS 7.0.0.109');
  const dispose = service.observe(context); await Promise.resolve(); await Promise.resolve(); sandbox.listener(2); dispose(); assert.equal(sandbox.listener, null);
  assert.equal(actions.at(-1).observations.vpnState, 'connected'); assert.equal(actions.at(-1).observations.stopOutcome, 'not_reported');
  await service.record(context, { operation: 'vpn', stage: 'system_authorization', outcome: 'failed', code: '201', object: 'synthetic-session' });
  assert.equal(actions.at(-1).code, '201');
  let result = await service.check(context, 'controller');
  assert.equal(result.outcome, 'success'); assert.equal(result.stage, 'controller_version');
  status = 403; result = await service.check(context, 'controller');
  assert.equal(result.stage, 'controller_authorization'); assert.equal(result.error.code, '403');
  status = 200; transportError = { code: 2300006, message: `Authorization Bearer ${credential}` };
  result = await service.check(context, 'controller'); assert.equal(result.error.code, '2300006');
  assert.ok(!JSON.stringify(result).includes(credential)); assert.ok(!JSON.stringify(actions).includes(credential));
  transportError = null; credential = null; const before = requests.length;
  result = await service.check(context, 'dns'); assert.equal(result.stage, 'controller_credentials');
  assert.equal(requests.length, before, 'missing credentials must not send anonymous checks');
  credential = 'c'.repeat(64); body = { kind: 'dns', stage: 'dns_exchange', outcome: 'failed', at: '2026-10-13T00:00:00Z',
    durationMs: 5, error: { kind: 'dns', code: 'DNS_RCODE_3', message: 'DNS_RCODE_3' }, details: { rcode: 3 } };
  result = await service.check(context, 'dns'); assert.equal(result.stage, 'dns_exchange'); assert.equal(result.details.rcode, 3);
  assert.equal(JSON.parse(requests.at(-1).options.extraData).kind, 'dns');
  const noTransfer = requests.length;
  result = await service.check(context, 'bandwidth'); assert.equal(result.outcome, 'skipped');
  assert.equal(requests.length, noTransfer, 'support checks never start a bandwidth transfer');
  const exportBefore = requests.length; const exported = await service.exportBundle(context);
  assert.equal(requests.length, exportBefore, 'export is offline and cannot implicitly probe');
  assert.ok(exported.json.includes('kernel-previous'));
  assert.equal(files.get(exported.path), exported.json); assert.equal(files.size, 1, 'exports reuse one local cache artifact');
  workerFailed = true;
  assert.equal(await service.record(context, { operation: 'vpn', stage: 'test', outcome: 'failed' }), false);
  result = await service.check(context, 'bandwidth'); assert.equal(result.details.evidencePersisted, false);
  await assert.rejects(service.exportBundle(context));
  assert.equal(destroyed, requests.length, 'all HTTP resources released');
  console.log('PASS: diagnostics initialization, structured errors, privacy boundary, local export, explicit probes and persistence failures');
})().catch(error => { console.error(error); process.exitCode = 1; });
