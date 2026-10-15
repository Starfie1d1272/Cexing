const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const source = fs.readFileSync('cexing/entry/src/main/ets/lib/TemplateUpdates.ets', 'utf8');
let workerInput;
const sandbox = { exports: {}, require: name => {
 if (name === 'libentry.so') return { versionAction: async (_home, input) => {
  workerInput = JSON.parse(input); return JSON.stringify({ ready: false, conflicts: [{ id: 'conflict', entity: 'ai/web', section: 'rules', kind: 'edit' }] });
 } };
 throw Error(name);
} };
vm.runInNewContext(ts.transpileModule(source).outputText, sandbox);
const { TemplateUpdateModel: Model, TemplateUpdates } = sandbox.exports;
const deferred = () => { let resolve; const promise = new Promise(r => resolve = r); return { promise, resolve }; };
const conflict = { id: 'private-input-bound-id', entity: 'ai/web', section: 'rules', kind: 'edit' };
const candidate = { templateId: 'ai', version: 2, entries: [] };
const valid = { ready: true, candidate, conflicts: [], validation: { revision: 'version-current', digest: 'synthetic-digest', summary: '1 条规则变化' } };
(async () => {
 await TemplateUpdates.preview({ filesDir: '/private' }, { kind: 'template', base: candidate, mine: candidate, next: candidate });
 assert.equal(workerInput.op, 'template-update-preview'); assert.equal(workerInput.request.kind, 'template');
 let applies = 0, fail = false, pending = deferred(), captured;
 const model = new Model({ label: () => 'AI 规则', preview: async choices => {
  captured = choices; return Object.keys(choices).length ? valid : { ready: false, conflicts: [conflict] };
 }, apply: async () => { applies++; if (fail) throw Error('stale synthetic ticket'); return pending.promise; } }, () => {});
 await model.refresh(); await model.apply(); assert.equal(applies, 0);
 await model.choose(conflict.id, 'mine'); assert.equal(captured[conflict.id], 'mine');
 const apply = model.apply(); await model.apply(); assert.equal(applies, 1);
 model.close(); pending.resolve('已应用'); await apply; assert.equal(model.result, '');

 let callbacks = 0;
 const late = deferred(); const old = new Model({ preview: () => late.promise, apply: async () => '', label: () => '' }, () => callbacks++);
 const refreshing = old.refresh(); const before = callbacks; old.close(); late.resolve(valid); await refreshing;
 assert.equal(callbacks, before); assert.equal(old.preview, null);
 const unvalidated = new Model({ preview: async () => ({ ready: true, candidate, conflicts: [] }), apply: async () => { throw Error('must not apply'); }, label: () => '' }, () => {});
 await unvalidated.refresh(); assert.equal(unvalidated.preview, null); assert.ok(unvalidated.error);
 const stale = new Model({ preview: async () => valid, apply: async () => { throw Error('stale'); }, label: () => '' }, () => {});
 await stale.refresh(); await stale.apply(); assert.equal(stale.preview, null); assert.ok(stale.error);
 await stale.apply(); assert.equal(stale.result, '');
 const precision = new Model({ preview: async () => { throw Error('TEMPLATE_UPDATE_PRECISION'); }, apply: async () => '', label: () => '' }, () => {});
 await precision.refresh(); assert.equal(precision.error, '部分高级字段需通过高级编辑修改');
 console.log('PASS: template update worker bridge, unresolved/unvalidated gate, duplicate apply and stale/exit fencing');
})().catch(error => { console.error(error); process.exitCode = 1; });
