// Registered page -> actual default Source/Host/receipt flow. Platform and
// worker responses are synthetic; real compiler/publication lives in Go tests.
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const uiFixture = require('./ci/ui-fixtures.cjs');
let serial = 0, version = 'v1', writes = 0, applies = 0, reads = 0, encodes = 0;
const snapshot = { templateId: 'ai', version: 1, entries: [] };
let published = { schemaVersion: 1, revision: 'published', sourceRevision: 'source', operations: [],
  template: { templateId: 'ai', version: 1, targetGroup: 'Pick', baseline: snapshot, mine: snapshot } };
let draft = { revision: 'published', intent: structuredClone(published) };
const ticket = () => ({ file: 'one.yaml', profileIdentity: 'source', profileVersion: version,
  activeVersion: version, activeFile: 'one.yaml', draftRevision: draft.revision });
const modules = {
  '@kit.ArkTS': { util: { generateRandomUUID: () => `session-${++serial}` } },
  './Settings': { Settings: { load: () => ({}), idle: async () => {} } },
  './CoreValidator': { CoreValidator: { ...require('./ci/semantic-fixture.cjs').CoreValidator, prepareResources: async () => {} } },
  './ProfileStore': { ProfileStore: { prepareContent: value => value, getProfileContent: () => 'synthetic', getEnabledMerge: () => '', readEditDraft: () => draft } },
  './EffectiveVersions': { EffectiveVersions: { read: () => ({ Profiles: { 'one.yaml': { ID: version } } }),
    globalContent: () => '', regionPlan: () => null, editIntent: () => structuredClone(published) } },
  './ConfigEditor': { ConfigEditor: { list: async () => ({ sourceRevision: 'source', sections: [
    { section: 'proxy-groups', items: [{ id: 'group', name: 'Pick', sourceName: 'Pick', type: 'select' }] }] }) } },
  './ProfileTransactions': { ProfileTransactions: { editTicket: ticket,
    saveEditDraft: async (_context, captured, intent, guard) => { await guard(); assert.equal(captured.draftRevision, draft.revision);
      draft = { revision: `draft-${++serial}`, intent: structuredClone(intent) }; draft.intent.revision = draft.revision; writes++; return draft.revision; },
    previewEditDraft: async () => ({ digest: 'compiler-digest', changes: [{ section: 'rules', before: 1, after: 2 }] }),
    applyEditDraft: async (_context, _ticket, digest, guard) => { assert.equal(digest, 'compiler-digest'); await guard(false);
      version = `version-${++serial}`; await guard(true); published = structuredClone(draft.intent); applies++; return 'applied'; }
  } },
  'libentry.so': { versionAction: async (_root, input) => {
    const value = JSON.parse(input);
    if (value.op === 'editor-identity') return JSON.stringify({ identity: JSON.stringify([value.original, value.overlay, value.editIntent, value.overrides]) });
    assert.equal(value.op, 'template-update-preview');
    if (!value.source) return JSON.stringify({ ready: true, candidate: snapshot, conflicts: [] });
    assert.equal(value.source.profileId, 'one.yaml'); assert.equal(value.source.profileVersion, version);
    if (value.source.action === 'read') { reads++; return JSON.stringify({ stamp: 'a'.repeat(64), request: { kind: 'template', base: snapshot, mine: snapshot, next: snapshot } }); }
    assert.equal(value.source.action, 'encode'); assert.equal(value.source.stamp, 'a'.repeat(64)); encodes++;
    return JSON.stringify({ intent: value.source.intent });
  } }
};
const cache = {};
function load(name, page = false) {
  if (cache[name]) return cache[name];
  let source = fs.readFileSync(`cexing/entry/src/main/ets/${page ? 'pages' : 'lib'}/${name}.ets`, 'utf8');
  if (page) { const marker = source.includes('  @Builder') ? '  @Builder' : '  build()'; source = source.slice(0, source.indexOf(marker)) + '\n}';
    source = source.split('\n').map(line => line.trimStart().startsWith('@') ? line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '') : line).join('\n').replace('export struct ', 'export class '); }
  const sandbox = { exports: {}, ...uiFixture.globals, getContext: () => ({ filesDir: '/synthetic' }), require: path => {
    if (path.endsWith('/UiText')) return uiFixture.module;
    if (modules[path]) return modules[path];
    if (path === '@kit.ArkUI') return { promptAction: {} };
    if (path.startsWith('@') || path === './NativeTheme') return {};
    return load(path.split('/').pop(), /TemplateWizard$|TemplateUpdateReview$/.test(path));
  } };
  cache[name] = sandbox.exports;
  vm.runInNewContext(ts.transpileModule(source).outputText, sandbox); return sandbox.exports;
}
async function idle(model) { for (let i = 0; i < 30 && model.busy; i++) await new Promise(setImmediate); assert.equal(model.busy, false); }
(async () => {
  const { ProfileTemplatePage: Page, ProfileTemplateBus: Bus } = load('ProfileTemplatePage', true);
  Bus.file = 'one.yaml'; const entry = new Page(); entry.profileRevision = 0; entry.visible = true; entry.aboutToAppear();
  const sharedEditor = entry.editor; assert.ok(sharedEditor);
  const wizard = new (load('TemplateWizard', true).TemplateWizard)(); wizard.profileId = 'one.yaml'; wizard.editor = sharedEditor;
  wizard.aboutToAppear(); await idle(wizard.model); assert.equal(wizard.updateAvailable, true);
  assert.equal(wizard.activeEditor, sharedEditor);
  const source = fs.readFileSync('cexing/entry/src/main/ets/pages/TemplateWizard.ets', 'utf8');
  assert.match(source, /if \(this.reviewingUpdate\)[\s\S]*TemplateUpdateReview\(\{ profileId: this.profileId, editor: this.activeEditor, source: this.activeUpdateSource/);
  assert.match(source, /if \(this.updateAvailable\)[\s\S]*this.reviewingUpdate = true/);
  const review = new (load('TemplateUpdateReview', true).TemplateUpdateReview)();
  review.profileId = 'one.yaml'; review.editor = sharedEditor; review.source = wizard.activeUpdateSource;
  review.aboutToAppear(); await idle(review.model);
  assert.equal(review.ready, true, review.message); assert.equal(reads, 1); assert.equal(encodes, 1); assert.equal(writes, 1); assert.equal(applies, 0);
  await review.model.apply(); assert.equal(applies, 1); assert.equal(review.model.result, '更新已应用');
  await review.model.apply(); assert.equal(applies, 1, 'receipt cannot be replayed');
  review.aboutToDisappear(); wizard.aboutToDisappear(); entry.visible = false; entry.visibilityChanged();
  assert.equal(entry.editor, undefined); assert.equal(entry.profileRevision, 1);
  console.log('PASS: production template entry -> default update Source/Host -> inert save/preview -> original receipt apply and route release (synthetic platform/worker)');
})().catch(error => { console.error(error); process.exitCode = 1; });
