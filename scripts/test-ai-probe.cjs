// Execute the real UI observer/service with synthetic platform callbacks.
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const requests = [], networks = [], changes = [], listeners = new Set();
const deferred = () => { let resolve; const promise = new Promise(r => resolve = r); return { promise, resolve }; };
const vpn = { status: 2, onChanged: cb => listeners.add(cb), offChanged: cb => listeners.delete(cb) };
const modules = {
 '@kit.NetworkKit': {
  http: { RequestMethod: { POST: 'POST' }, HttpDataType: { STRING: 0 }, createHttp() {
   const pending = deferred(), request = { destroyed: 0, request(url, options) {
    assert.equal(url, 'http://127.0.0.1:9090/ohos/ai-probe');
    assert.equal(options.header.Authorization, 'Bearer synthetic-controller');
    assert.equal(JSON.parse(options.extraData).revision.startsWith('version-'), true);
    return pending.promise;
   }, destroy() { this.destroyed++; }, pending };
   requests.push(request); return request;
  } },
  connection: { createNetConnection() {
   const observer = { callbacks: {}, unregisters: 0, on(name, cb) { this.callbacks[name] = cb; },
    register(cb) { this.registered = cb; }, unregister(cb) { this.unregisters++; cb(); } };
   networks.push(observer); return observer;
  } }
 },
 './CoreApi': { CoreApi: { getControllerAccess: () => ({ httpBase: 'http://127.0.0.1:9090', secret: 'synthetic-controller' }) } },
 '../lib/VpnController': { VpnController: vpn, VpnStatus: { Connected: 2 } },
 './NativeTheme': {}
};
function load(file, page = false) {
 let src = fs.readFileSync(`cexing/entry/src/main/ets/${file}`, 'utf8');
 if (page) src = src.slice(0, src.indexOf('  build()')) + '\n}';
 src = src.replace(/@Component\n/g, '').replace(/@(Prop|Watch|State)(?:\([^)]*\))?\s*/g, '').replace('export struct ', 'export class ');
 const sandbox = { exports: {}, require: name => { assert.ok(name in modules, name); return modules[name]; } };
 vm.runInNewContext(ts.transpileModule(src).outputText, sandbox); return sandbox.exports;
}
let successful = { ID: 'version-good', ProfileID: 'one.yaml' }, intentReads = 0;
let successfulIntent = { schemaVersion: 1, template: { templateId: 'ai', version: 1, targetGroup: 'Pick' } };
modules['./EffectiveVersions'] = { EffectiveVersions: {
 read: () => ({ Current: successful }), editIntent: () => { intentReads++; return successfulIntent; }
} };
const Binding = load('lib/AiProbeBinding.ets').AiProbeBinding;
const binding = new Binding();
assert.equal(binding.revision({}, 'one.yaml', 'Pick'), 'version-good');
assert.equal(binding.revision({}, 'one.yaml', 'unsaved-target'), '');
assert.equal(binding.revision({}, 'other.yaml', 'Pick'), '');
assert.equal(intentReads, 1);
successful = { ID: 'version-next', ProfileID: 'one.yaml' };
assert.equal(binding.revision({}, 'one.yaml', 'Pick'), 'version-next');
assert.equal(intentReads, 2);
for (const invalid of [
 { schemaVersion: 2, template: { templateId: 'ai', version: 1, targetGroup: 'Pick' } },
 { schemaVersion: 1, disabled: true, template: { templateId: 'ai', version: 1, targetGroup: 'Pick' } },
 { schemaVersion: 1, template: { templateId: 'ai', version: 2, targetGroup: 'Pick' } },
 { schemaVersion: 1, template: { templateId: 'original', version: 1, targetGroup: 'Pick' } }, null
]) {
 successful = { ID: successful.ID + '-invalid', ProfileID: 'one.yaml' }; successfulIntent = invalid;
 assert.equal(binding.revision({}, 'one.yaml', 'Pick'), '');
}
const Service = load('lib/AiProbeService.ets').AiProbeService;
modules['../lib/AiProbeService'] = { AiProbeService: Service };
const Page = load('pages/AiProbeStatus.ets', true).AiProbeStatus;
const response = revision => ({ responseCode: 200, result: JSON.stringify({ revision,
 results: ['chatgpt', 'claude', 'gemini'].map(service => ({ service, state: 'reachable', at: new Date().toISOString() })) }) });
(async () => {
 const service = new Service(() => true, (r, busy, state) => changes.push({ r, busy, state }));
 const first = service.check('version-one'); await service.check('version-one');
 assert.equal(requests.length, 1); service.cancel(); const before = changes.length;
 requests[0].pending.resolve(response('version-one')); await first;
 assert.equal(requests[0].destroyed, 1); assert.equal(changes.length, before);
 const second = service.check('version-two'); requests.at(-1).pending.resolve(response('version-old')); await second;
 assert.equal(changes.at(-1).r.length, 0); assert.equal(changes.at(-1).state, undefined);
 const third = service.check('version-three'); requests.at(-1).pending.resolve(response('version-three')); await third;
 assert.equal(changes.at(-1).r.length, 3);

 const unchecked = service.check('version-unproven');
 requests.at(-1).pending.resolve({ responseCode: 409, result: JSON.stringify({message:'PROBE_ROUTE_UNPROVEN'}) }); await unchecked;
 assert.equal(changes.at(-1).r.length, 0); assert.equal(changes.at(-1).state, 'route_unproven');

 const page = new Page(); page.revision = 'version-page'; page.aboutToAppear();
 const oldNetwork = networks.at(-1), baseline = requests.length;
 oldNetwork.registered(); oldNetwork.callbacks.netAvailable({netId:1}); assert.equal(requests.length, baseline + 1);
 oldNetwork.callbacks.netLost({netId:1}); assert.equal(requests.at(-1).destroyed, 1); assert.equal(page.results.length, 0);
 page.aboutToDisappear(); assert.equal(listeners.size, 0);
 const leavingCount = requests.length;
 oldNetwork.callbacks.netAvailable({netId:1}); assert.equal(requests.length, leavingCount);
 page.aboutToAppear(); const newNetwork = networks.at(-1);
 oldNetwork.registered(); assert.ok(oldNetwork.unregisters >= 2);
 assert.equal(newNetwork.unregisters, 0);
 newNetwork.registered(); newNetwork.callbacks.netAvailable({netId:1});
 const beforeSwitch = requests.at(-1);
 newNetwork.callbacks.netAvailable({netId:2});
 assert.equal(beforeSwitch.destroyed, 1);
 const afterSwitch = requests.at(-1);
 newNetwork.callbacks.netLost({netId:1});
 assert.equal(afterSwitch.destroyed, 0); // an old bearer cannot cancel the replacement
 const latest = requests.at(-1); page.revision = 'version-next'; page.revisionChanged();
 assert.equal(latest.destroyed, 1);
 const pending = requests.at(-1); page.aboutToDisappear();
 pending.pending.resolve(response('version-next')); await new Promise(setImmediate);
 assert.equal(page.results.length, 0); assert.equal(listeners.size, 0);

 const uncheckedPage = new Page(); uncheckedPage.revision = 'version-unchecked-page'; uncheckedPage.aboutToAppear();
 const uncheckedNetwork = networks.at(-1); uncheckedNetwork.registered(); uncheckedNetwork.callbacks.netAvailable({netId:3});
 requests.at(-1).pending.resolve({ responseCode: 409, result: JSON.stringify({message:'PROBE_ROUTE_UNPROVEN'}) });
 await new Promise(setImmediate);
 assert.equal(uncheckedPage.summary(), '未检查'); assert.equal(uncheckedPage.results.length, 0); assert.equal(uncheckedPage.routeUnproven, true);
 uncheckedPage.aboutToDisappear(); assert.equal(listeners.size, 0);
 console.log('PASS: AI check duplicate requests, revision/exit fencing, offline cancellation and network observer cleanup');
})().catch(error => { console.error(error); process.exitCode = 1; });
