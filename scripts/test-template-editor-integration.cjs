const uiFixture = require('./ci/ui-fixtures.cjs');
// Real wizard adapter + real shared production Host; platform/transaction I/O
// is synthetic. Go transaction/compiler tests and Full remain separate evidence.
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
let serial = 0, version = 'v1', provider = 'cache-1', writes = 0, applies = 0;
let published = { schemaVersion: 1, revision: 'published', sourceRevision: 'source', operations: [],
 smartGroups: { manual: false }, template: { templateId: 'original', version: 1 } };
let draft = { revision: 'published', intent: structuredClone(published) };
const ticket = () => ({ file: 'one.yaml', profileIdentity: 'source', profileVersion: version,
 activeVersion: version, activeFile: 'one.yaml', draftRevision: draft.revision });
const modules = { './CoreValidator': require('./ci/semantic-fixture.cjs'),
 '@kit.ArkTS': { util: { generateRandomUUID: () => `session-${++serial}` } },
 'libentry.so': { versionAction: async (_root, input) => {
  const value = JSON.parse(input); assert.equal(value.op, 'editor-identity');
  return JSON.stringify(value.expected !== version ? { error: 'stale' } :
   { identity: JSON.stringify([value.original, value.overlay, value.globalMerge, value.editIntent, value.overrides, provider]) });
 } },
 './Settings': { Settings: { load: () => ({ ipv6: false }), idle: async () => {} } },
 './ProfileStore': { ProfileStore: { getProfileContent: () => 'synthetic original', getEnabledMerge: () => '', readEditDraft: () => draft } },
 './EffectiveVersions': { EffectiveVersions: { read: () => ({ Profiles: { 'one.yaml': { ID: version } } }),
  globalContent: () => '', regionPlan: () => null, editIntent: () => structuredClone(published) } },
 './ConfigEditor': { ConfigEditor: {
  preview: async () => ({ digest: 'compiler-digest', changes: [] }),
  switchTemplate: async (_ctx,intent,next) => ({intent:{...structuredClone(intent),template:next,disabled:next.templateId==='original'?intent.disabled:false},dependentCount:0}),
  templatePlan: (templateId, version, targetGroup, region, replaceRules) => ({ templateId, version, targetGroup, region, replaceRules }),
  list: async () => ({ sourceRevision: 'source', missingFieldRevision: 'missing', sections: [
   { section: 'proxy-groups', items: [{ id: 'group', name: 'Pick', sourceName: 'Pick', type: 'select', revision: 'group-rev' }] }
  ] })
 } },
 './ProfileTransactions': { ProfileTransactions: { editTicket: ticket,
  saveEditDraft: async (_ctx, expected, intent, guard) => {
   await guard(); assert.equal(expected.draftRevision, draft.revision);
   draft = { revision: `draft-${++serial}`, intent: structuredClone(intent) }; draft.intent.revision = draft.revision; writes++; return draft.revision;
  },
  previewEditDraft: async () => ({ digest: 'compiler-digest', changes: [{ section: 'rules', before: 1, after: 9 }] }),
  applyEditDraft: async (_ctx, _ticket, digest, guard) => {
   assert.equal(digest, 'compiler-digest'); await guard(false); version = `v${++serial}`; await guard(true);
   published = structuredClone(draft.intent); applies++; return 'applied';
  }
 } }
};
function load(file) {
 const sandbox = { exports: {}, ...uiFixture.globals, require: name => { if (name.endsWith('/UiText')) return uiFixture.module; assert.ok(name in modules, name); return modules[name]; } };
 vm.runInNewContext(ts.transpileModule(fs.readFileSync(`cexing/entry/src/main/ets/lib/${file}.ets`, 'utf8')).outputText, sandbox);
 return sandbox.exports;
}
modules['./EditorDraftHosts'] = load('EditorDraftHosts');
const create = load('TemplateHost').createTemplateWizardHost;
(async () => {
 const host = create({ filesDir: '/synthetic' }, 'one.yaml');
 const input = await host.load(); assert.deepEqual(Array.from(input.groups), ['Pick']);
 const plan = { templateId: 'ai', version: 1, targetGroup: 'Pick' };
 let preview = await host.preview(plan); assert.equal(writes, 1); assert.equal(applies, 0); assert.equal(published.template.templateId, 'original');
 provider = 'cache-2'; await assert.rejects(host.apply(plan, preview), /变化/); assert.equal(applies, 0);
 preview = await host.preview(plan);
 assert.equal(await host.apply(plan, preview), '方案已应用'); assert.equal(applies, 1);
 assert.equal(published.template.templateId, 'ai'); assert.equal(published.smartGroups.manual, false);
 await assert.rejects(host.apply(plan, preview), /PREVIEW_STALE/); assert.equal(applies, 1);
 const originalPlan = { templateId: 'original', version: 1 };
 const second = await host.preview(originalPlan);
 assert.equal(await host.apply(originalPlan, second), '方案已应用'); assert.equal(applies, 2);
 assert.equal(published.template.templateId, 'original');
 console.log('PASS: real template adapter + production EditorDraftHosts, inert preview, provider-change refusal, receipt apply and replay gate');
})().catch(error => { console.error(error); process.exitCode = 1; });
