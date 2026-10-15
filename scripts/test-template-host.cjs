const uiFixture = require('./ci/ui-fixtures.cjs');
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
let published = { schemaVersion: 1, revision: 'published', sourceRevision: 'source', disabled: true,
 operations: [{ id: 'personal', kind: 'delete', section: 'rules', target: 'synthetic-target', expected: 'synthetic-revision' }] };
let draft = structuredClone(published), revision = 0, receipt, calls = [], committed = 0;
const item = { id: 'synthetic-group', name: 'Renamed Pick', sourceName: 'Pick', type: 'select', revision: 'synthetic' };
const session = () => ({ profileId: 'one.yaml', revision: `ticket-${revision}`, intent: structuredClone(draft),
 snapshot: { sourceRevision: 'source', missingFieldRevision: 'missing', sections: [{ section: 'proxy-groups', items: [item, { id: 'personal', name: 'Personal only', type: 'select' }] }] } });
const editor = {
 load: async () => session(),
 save: async (intent, expected) => { assert.equal(expected, `ticket-${revision}`); calls.push('save'); draft = structuredClone(intent); revision++; return session(); },
 preview: async expected => { assert.equal(expected, `ticket-${revision}`); calls.push('preview');
  receipt = { revision: expected, digest: `digest-${revision}`, changes: { digest: `digest-${revision}`, changes: [{ section: 'rules', before: 1, after: 9 }] } }; return receipt; },
 apply: async checked => { assert.equal(checked, receipt); assert.equal(checked.revision, `ticket-${revision}`); calls.push('apply'); committed++; published = structuredClone(draft); return 'applied'; }
};
const modules = { './EditorDraftHosts': { EditorDraftHosts: { create: () => editor } }, './ConfigEditor': { ConfigEditor: { templatePlan: (templateId, version, targetGroup, region, replaceRules) => ({templateId, version, targetGroup, region, replaceRules}) } }, './EffectiveVersions': { EffectiveVersions: { read: () => ({ Profiles: { 'one.yaml': { ID: 'version-one' } } }),
 editIntent: () => structuredClone(published), regionPlan: () => null } } };
const sandbox = { exports: {}, ...uiFixture.globals, require: name => { if (name.endsWith('/UiText')) return uiFixture.module; assert.ok(name in modules, name); return modules[name]; } };
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/TemplateHost.ets', 'utf8')).outputText, sandbox);
(async () => {
 const host = sandbox.exports.createTemplateWizardHost({ filesDir: '/private' }, 'one.yaml');
 const inputs = await host.load(); assert.deepEqual(Array.from(inputs.groups), ['Pick']); assert.equal(inputs.current.templateId, 'original'); assert.equal(inputs.labels.Pick, 'Renamed Pick'); assert.deepEqual(Array.from(inputs.selectors), ['Pick']);
 const plan = { templateId: 'ai', version: 1, targetGroup: 'Pick' };
 const preview = await host.preview(plan); assert.equal(preview.inactiveEdits, true);
 assert.equal(draft.operations.length, 1); assert.equal(draft.disabled, false); assert.equal(published.disabled, true); assert.equal(committed, 0);
 await assert.rejects(host.apply(plan, preview), /CONFIRMATION_REQUIRED/);
 await assert.rejects(host.apply({ ...plan, targetGroup: 'other' }, preview, true), /PREVIEW_STALE/);
 assert.equal(await host.apply(plan, preview, true), '方案已应用'); assert.equal(committed, 1);
 assert.equal(calls.join(','), 'save,preview,apply'); assert.equal(published.operations[0].id, 'personal');
 await assert.rejects(host.apply(plan, preview, true), /PREVIEW_STALE/);
 await host.load(); const checked = await host.preview({ templateId: 'original', version: 1 });
 revision++; await assert.rejects(host.apply({ templateId: 'original', version: 1 }, checked, true)); assert.equal(committed, 1);
 const wrong = sandbox.exports.createTemplateWizardHost({}, 'two.yaml', editor);
 await assert.rejects(wrong.load(), /PROFILE_CHANGED/);
 console.log('PASS: actual template host keeps personal intent, binds save/preview/apply receipt and refuses inactive/stale/wrong-profile application');
})().catch(error => { console.error(error); process.exitCode = 1; });
