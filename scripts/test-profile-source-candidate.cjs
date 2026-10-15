// Real profile event methods + wrapper + shared update Host. Synthetic source,
// compiler and transaction port; real atomic publication is covered by core/Host tests.
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const uiFixture = require('./ci/ui-fixtures.cjs');
const ts = require('./ci/transpile-arkts.cjs'), { resourceContext } = require('./ci/mock-profile-resources.cjs');
let ticket, download, rejectDownload, downloads = 0, normalUpdates = 0, writes = 0, applies = 0, editorSource, comparedSource, releaseLoad;
let published = { template: { templateId: 'ai', version: 1, targetGroup: 'Pick' } }, original = 'successful original';
let pendingSource = false, releaseSource;
let draft, revision = 0, checked, pagePaths = [], toasts = [], queuedShare = null;
const candidate = { original: 'downloaded original', metadata: { origin: 'https://example.invalid/synthetic', sub: {}, updatedAt: 1 } };
const context = { ...resourceContext(), filesDir: '/synthetic' };
const tx = { editTicket: () => structuredClone(ticket), isBusy: () => false, onIdle: () => () => {}, readEditSource: async (_ctx, captured, current) => { assert.deepEqual(captured, ticket); if (releaseSource) await new Promise(resolve => { releaseSource = resolve; }); assert.ok(current()); return candidate; }, update: async () => { normalUpdates++; return 'saved'; } };
const snapshot = { templateId: 'ai', version: 1, entries: [] };
const editorFactory = { create: (_ctx, file, source) => { assert.equal(file, 'one.yaml'); editorSource = source;
 return {
  load: async () => { if (releaseLoad) await new Promise(resolve => { releaseLoad = resolve; }); return { profileId: file, revision: `session-${revision}`, intent: structuredClone(draft), snapshot: { sourceRevision: 'source' } }; },
  save: async (intent, expected) => { assert.equal(expected, `session-${revision}`); writes++; ticket.draftRevision = `draft-${++revision}`;
    draft = { ...structuredClone(intent), revision: ticket.draftRevision }; return { profileId: file, revision: `session-${revision}`, intent: structuredClone(draft) }; },
  preview: async rev => { checked = { revision: rev, digest: 'digest', changes: { digest: 'digest', changes: [] } }; return checked; },
  apply: async receipt => { assert.equal(receipt, checked); applies++; original = source.original; return 'saved'; },
  target: async () => ({}), undo: async () => ({})
 }; } };
const sourceFactory = (_ctx, file, source) => { assert.equal(file, 'one.yaml'); comparedSource = source;
 return { read: async () => ({ kind: 'template', base: snapshot, mine: snapshot, next: snapshot }),
  encode: async (_value, session) => structuredClone(session.intent), label: () => 'synthetic' }; };
const mods = {
 '../lib/ProfileApplyFeedback': require('./ci/load-profile-feedback.cjs'),
 '../lib/UiText': uiFixture.module,
 '@kit.ArkUI': { promptAction: { showToast: value => toasts.push(value.message) } },
 '../lib/ProfileImportInput': { ProfileImportInput: { take: () => { const value = queuedShare; queuedShare = null; return value; }, release() {} } },
 '../lib/ProfileTransactions': { ProfileTransactions: tx }, '../lib/EditorDraftHosts': { EditorDraftHosts: editorFactory },
 '../lib/TemplateUpdateSource': { createTemplateUpdateSource: sourceFactory },
 '../lib/EffectiveVersions': { EffectiveVersions: { read: () => ({ Profiles: { 'one.yaml': { ID: 'v1' } } }), editIntent: () => published } },
 '../lib/ProfileStore': { ProfileStore: { getActiveFile: () => 'one.yaml', readEditDraft: () => ({ revision: ticket.draftRevision, intent: draft, source: pendingSource ? {} : undefined }), downloadFromOrigin: () => { assert.equal(pendingSource, false, 'pending sources must resume without a new download'); downloads++; return new Promise((resolve, reject) => { download = resolve; rejectDownload = reject; }); } } }
};
const hostBox = { exports: {}, ...uiFixture.globals, require: name => name === './CoreValidator' ? require('./ci/semantic-fixture.cjs') : name === './UiText' ? uiFixture.module : name === './TemplateUpdates' ? { TemplateUpdates: { preview: async () => ({ ready: true, conflicts: [], candidate: snapshot }) } } : {} };
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/TemplateUpdateHost.ets', 'utf8')).outputText, hostBox);
mods['../lib/TemplateUpdateHost'] = hostBox.exports;
function page(name) {
 let text = fs.readFileSync(`cexing/entry/src/main/ets/pages/${name}.ets`, 'utf8');
 const marker = text.includes('  @Builder') ? '  @Builder' : '  build()'; text = text.slice(0, text.indexOf(marker)) + '\n}';
 text = text.split('\n').map(line => line.trimStart().startsWith('@') ? line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '') : line).join('\n').replace('export struct ', 'export class ');
 const box = { exports: {}, ...uiFixture.globals, getContext: () => context, NavPathStack: class {}, require: name => mods[name] || {} };
 vm.runInNewContext(ts.transpileModule(text).outputText, box); return box.exports;
}
const update = page('ProfileUpdatePage'); mods['./ProfileUpdatePage'] = update;
const profileExports = page('ProfilePage'); const Profile = profileExports.ProfilePage;
function reset() { pendingSource = false; releaseSource = null; queuedShare = null; original = 'successful original'; ticket = { file: 'one.yaml', profileIdentity: 'identity', profileVersion: 'v1', activeVersion: 'v1', activeFile: 'one.yaml', draftRevision: 'published' };
 draft = { schemaVersion: 1, revision: 'published', sourceRevision: 'source', operations: [], template: { templateId: 'ai', version: 1, targetGroup: 'Pick' } }; revision = 0; update.ProfileUpdateBus.request = null; pagePaths = []; releaseLoad = null; }
function profile() { const p = new Profile(); p.pageVisible = true; p.rootVisible = true; p.currentVisibleTab = 1; p.pageGeneration = 1; p.profileRevision = 0;
 p.navStack = { getAllPathName: () => pagePaths.slice(), pushPath: value => pagePaths.push(value.name) }; p.refresh = () => {}; p.toast = value => toasts.push(value); p.isUrlProfile = () => true; return p; }
function route(visible = true) { const p = new update.ProfileUpdatePage(); p.profileRevision = 0; p.visible = visible;
 p.navStack = { getAllPathName: () => pagePaths.slice(), pop: () => pagePaths.pop() }; p.aboutToAppear(); return p; }
(async () => {
 reset(); const p = profile(), reading = p.updateProfile({ file: 'one.yaml' }); await p.updateProfile({ file: 'one.yaml' }); assert.equal(downloads, 1);
 assert.equal(original, 'successful original'); download({ content: candidate.original, meta: candidate.metadata }); await reading;
 assert.equal(pagePaths.join(','), 'profileTemplateUpdate'); assert.equal(normalUpdates, 0); assert.equal(applies, 0);
 queuedShare = { kind: 'url', value: 'https://example.invalid/queued' }; p.acceptExternalImport();
 assert.ok(queuedShare); assert.equal(p.showSheet, false, 'a routed review owns the UI before its visibility callback');
 const screen = route(false); assert.equal(screen.request.source.original, candidate.original); assert.equal(update.ProfileUpdateBus.request, null);
 screen.visible = true; screen.visibilityChanged(); assert.equal(screen.ready, true); assert.equal(editorSource, comparedSource);
 let preview = await screen.host.preview({}); assert.equal(writes, 1); assert.equal(original, 'successful original'); assert.equal(applies, 0);
 screen.host.reset(); preview = await screen.host.preview({}); assert.equal(writes, 2, 'own acknowledged draft can be re-previewed');
 const host = screen.host; await host.apply(preview); assert.equal(original, candidate.original); assert.equal(applies, 1); assert.equal(pagePaths.length, 0);
 assert.equal(screen.host, undefined); assert.equal(screen.profileRevision, 1); assert.equal(toasts.at(-1), '订阅已更新');
 p.onRootVisible(); assert.equal(queuedShare, null); assert.equal(p.inputUrl, 'https://example.invalid/queued');
 reset(); const changed = profile(), pending = changed.updateProfile({ file: 'one.yaml' }); ticket.profileVersion = 'foreign'; download({ content: candidate.original, meta: candidate.metadata }); await pending;
 assert.equal(update.ProfileUpdateBus.request, null); assert.equal(pagePaths.length, 0);
 reset(); const gone = profile(), late = gone.updateProfile({ file: 'one.yaml' }); gone.pageVisible = false; gone.pageGeneration++; download({ content: candidate.original, meta: candidate.metadata }); await late;
 assert.equal(update.ProfileUpdateBus.request, null); assert.equal(pagePaths.length, 0);
 reset(); const protectedPage = profile(), protectedRead = protectedPage.updateProfile({ file: 'one.yaml' }); protectedPage.showSheet = true; protectedPage.sheetMode = 7;
 download({ content: candidate.original, meta: candidate.metadata }); await protectedRead; assert.equal(pagePaths.length, 0); assert.equal(protectedPage.sheetMode, 7);
 reset(); update.ProfileUpdateBus.request = { file: 'one.yaml', ticket: structuredClone(ticket), source: candidate }; ticket.profileVersion = 'foreign';
 assert.equal(route().failed, true, 'the bus cannot recapture an unrelated source at mount');
 reset(); update.ProfileUpdateBus.request = { file: 'one.yaml', ticket: structuredClone(ticket), source: candidate }; const delayed = route();
 releaseLoad = true; const stale = delayed.host.preview({}); ticket.draftRevision = 'foreign-draft'; releaseLoad(); await assert.rejects(stale, /UPDATE_SOURCE_CHANGED/);
 reset(); update.ProfileUpdateBus.request = { file: 'one.yaml', ticket: structuredClone(ticket), source: candidate }; const cancelled = route(false); cancelled.aboutToDisappear();
 assert.equal(cancelled.request, null); assert.equal(cancelled.host, undefined);
 reset(); published = null; const ordinary = profile(); await ordinary.updateProfile({ file: 'one.yaml' }); assert.equal(normalUpdates, 1, 'ordinary sources retain the existing update transaction');
 published = { template: { templateId: 'ai', version: 1, targetGroup: 'Pick' } }; reset(); const pull = profile(), pulling = pull.onPullRefresh(); const before = downloads; await pull.onPullRefresh();
 assert.equal(downloads, before); assert.equal(pull.refreshing, true); download({ content: candidate.original, meta: candidate.metadata }); await pulling;
 assert.equal(pagePaths.join(','), 'profileTemplateUpdate');
 reset(); const detail = profile(); detail.detailFile = 'one.yaml'; profileExports.ProfileDetailBus.current = 'one.yaml'; pagePaths = ['profileDetail'];
 const detailDownload = detail.updateProfile({ file: 'one.yaml' }); download({ content: candidate.original, meta: candidate.metadata }); await detailDownload;
 assert.equal(pagePaths.join(','), 'profileDetail,profileTemplateUpdate');
 reset(); const routeFailure = profile(); routeFailure.navStack.pushPath = () => { throw Error('synthetic route unavailable'); };
 const failedRoute = routeFailure.updateProfile({ file: 'one.yaml' }); download({ content: candidate.original, meta: candidate.metadata }); await failedRoute;
 assert.equal(update.ProfileUpdateBus.request, null, 'failed navigation releases private candidate memory'); assert.equal(original, 'successful original');
 reset(); pendingSource = true; const resumed = profile(), previousDownloads = downloads;
 await resumed.updateProfile({ file: 'one.yaml' }); assert.equal(downloads, previousDownloads);
 assert.equal(pagePaths.join(','), 'profileTemplateUpdate'); assert.equal(update.ProfileUpdateBus.request.source, candidate);
 assert.equal(original, 'successful original');
 reset(); pendingSource = true; releaseSource = true; const leftResume = profile();
 const restoring = leftResume.updateProfile({ file: 'one.yaml' }); await new Promise(setImmediate);
 leftResume.pageVisible = false; leftResume.pageGeneration++; releaseSource(); await restoring;
 assert.equal(pagePaths.length, 0); assert.equal(update.ProfileUpdateBus.request, null);
 reset(); pendingSource = true; draft.template = { templateId: 'original', version: 1 };
 await profile().updateProfile({ file: 'one.yaml' }); assert.equal(downloads, previousDownloads);
 assert.equal(pagePaths.length, 0); assert.equal(toasts.at(-1), '请先应用或撤销当前更新草稿');
 const root = fs.readFileSync('cexing/entry/src/main/ets/pages/Index.ets', 'utf8'); assert.match(root, /name === 'profileTemplateUpdate'[\s\S]*ProfileUpdatePage\(\{ visible: this.templateUpdateVisible/);
 console.log('PASS: downloaded candidates reach the registered review route and shared receipt Host; no early Original write; stale/hidden/dirty/repeat/first-read fences, own draft refresh, apply return and ordinary/pull updates');
})().catch(error => { console.error(error); process.exitCode = 1; });
