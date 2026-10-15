const uiFixture = require('./ci/ui-fixtures.cjs');
// Real ArkTS bridge/transaction/editor methods, with synthetic core responses.
// The Go regression separately executes the real compiler, validator and FileStore.
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const base = path.join(__dirname, '../cexing/entry/src/main/ets');
const data = new Map(), calls = [], applied = [], toasts = [];
const ctx = { filesDir: '/private' };
let state = { Current: null, Previous: null, Profiles: {} }, id = 0;
let response = 'applied', uncertain = false, failCommit = false, failDraft = false, failRead = false;
const status = { Disconnected: 0, Connected: 2 };
const controller = { status: status.Disconnected, holdConfiguration: () => () => {}, configurationEpoch: () => 0 };
const io = { accessSync: p => data.has(p), readTextSync: p => {
  if (failRead) throw Error('read failure'); return data.get(p);
}, OpenMode: { READ_WRITE: 2, CREATE: 64, TRUNC: 512 }, openSync: p => ({ fd: p }),
  writeSync: (p, text) => { if (failDraft) throw Error('disk full'); data.set(p, text); }, closeSync() {},
  moveFileSync: (from, to) => { data.set(to, data.get(from)); data.delete(from); }, unlinkSync: p => data.delete(p) };
const statePath = '/private/profile-versions/state.json';
function syncState() { data.set(statePath, JSON.stringify(state)); }
function source(v) { return JSON.parse(data.get(v.Path.replace('config.yaml', 'source.json'))); }
const core = { versionAction: async (_, input) => {
  const a = JSON.parse(input); calls.push(a);
  assert.equal(a.expected, state.Current?.ID ?? '');
  const global = a.updateGlobal ? a.globalMerge : state.GlobalMerge ?? '';
  if (a.op === 'stage') {
    if (global === 'invalid') throw Error('VERSION_COMPILE_FAILED');
    const version = { ID: `version-${++id}`, Path: `/private/profile-versions/version-${id}/config.yaml`, ProfileID: a.profileId };
    data.set(version.Path, a.original + global + a.overlay);
    data.set(version.Path.replace('config.yaml', 'original.yaml'), a.original);
    if (a.overlay) data.set(version.Path.replace('config.yaml', 'overlay.yaml'), a.overlay);
    data.set(version.Path.replace('config.yaml', 'source.json'), JSON.stringify({
      GlobalMerge: global, SmartConversion: a.smartConversion, RegionPlan: a.regionPlan }));
    return JSON.stringify({ version, receipt: 'receipt' });
  }
  if (a.op === 'verify') { assert.equal(source({Path:`/private/profile-versions/${a.versionId}/config.yaml`}).GlobalMerge, global); return '{"receipt":"receipt"}'; }
  if (a.op === 'commit') {
    if (failCommit) { failCommit = false; throw Error('VERSION_COMMIT_FAILED'); }
    const version = { ID: a.versionId, Path: `/private/profile-versions/${a.versionId}/config.yaml`, ProfileID: a.profileId };
    state.Profiles[a.profileId] = version;
    if (a.active) { state.Previous = state.Current; state.Current = version; }
    if (a.updateGlobal) { assert.equal(a.active, true); state.GlobalMerge = global; }
    syncState(); return '{}';
  }
  if (a.op === 'merge-preview') return JSON.stringify({ mergePreview: { digest: 'digest', changes: [{ section: 'rules', before: 1, after: 2 }] } });
  if (a.op === 'region-preview') return JSON.stringify({ regionPreview: { eligible: true, selectors: ['Main'] } });
  if (a.op === 'discard') return '{}';
  throw Error(a.op);
} };
let smart = false;
const settings = { idle: async () => {}, load: () => ({ smartAutoConvert: smart, allowLan: false }), setSmartAutoConvert: (_, value) => smart = value };
const modules = { '@kit.CoreFileKit': { fileIo: io }, 'libentry.so': core,
  './Settings': { Settings: settings }, './NativeTheme': {},
  '@kit.ArkUI': { promptAction: { showToast: v => toasts.push(v.message) } } };
function compile(file, page = false) {
  let src = fs.readFileSync(path.join(base, file), 'utf8');
  if (page) src = src.slice(0, src.indexOf('  build()')) + '\n}';
  src = src.split('\n').map(line => line.trimStart().startsWith('@') ? line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '') : line).join('\n').replace(/export struct /g, 'export class ');
  const sandbox = { exports: {}, getContext: () => ctx, require: n => { assert.ok(n in modules, n); return modules[n]; } };
  Object.assign(sandbox, uiFixture.globals); modules['../lib/UiText'] = uiFixture.module;
vm.runInNewContext(ts.transpileModule(src, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText, sandbox);
  return sandbox.exports;
}
const versions = compile('lib/EffectiveVersions.ets').EffectiveVersions;
modules['./EffectiveVersions'] = modules['../lib/EffectiveVersions'] = { EffectiveVersions: versions };
const original = '# untouched 😀\r\nproxies: []\r\nrules: [MATCH,DIRECT]\r\n  \r\n';
const local = 'rules: [MATCH,DIRECT]\n';
const originals = new Map([['one.yaml', original], ['two.yaml', original]]), locals = new Map([['one.yaml', local]]);
const store = { isApplyUncertain: () => uncertain, markApplyUncertain: () => uncertain = true,
  getActiveFile: () => state.Current?.ProfileID ?? '', getMeta: () => ({}),
  getProfileContent: (_, file) => originals.get(file) ?? null,
  getActiveContent: () => data.get(state.Current.Path), prepareContent: text => text,
  getEnabledMerge: (_, file) => locals.get(file) ?? '', saveMergeDraft() {},
  downloadFromOrigin: async () => ({ content: original, meta: {} }) };
modules['./ProfileStore'] = { ProfileStore: store };
modules['./CoreValidator'] = { CoreValidator: { prepareResources: async () => {} } };
modules['./VpnController'] = { VpnController: controller, VpnStatus: status };
modules['./CoreApi'] = { CoreApi: { isAlive: async () => true, getControllerSession: async () => 'synthetic-session',
  applyConfigText: async text => { applied.push(text); return response; } } };
const tx = compile('lib/ProfileTransactions.ets').ProfileTransactions;
modules['../lib/ProfileTransactions'] = { ProfileTransactions: tx };
const draft = compile('lib/GlobalMergeDraft.ets').GlobalMergeDraft;
modules['../lib/GlobalMergeDraft'] = { GlobalMergeDraft: draft };
const Editor = compile('pages/GlobalMergeEditor.ets', true).GlobalMergeEditor;
(async () => {
  const noProfile = new Editor(); noProfile.aboutToAppear(); noProfile.changeText('keep draft');
  await noProfile.preview(); assert.match(noProfile.summary, /请先启用/);
  assert.match(noProfile.safeFailure(Error('版本发布结果未知，请断开 VPN 后检查'), {id:'app.string.editor_apply_failed'}), /未确认.*断开/);
  assert.equal(noProfile.safeFailure(Error('https://private.invalid/?token=synthetic'), {id:'app.string.editor_apply_failed'}), '应用未完成，请重试');
  assert.equal(draft.read(ctx), 'keep draft'); assert.equal(state.Current, null);
  await assert.rejects(tx.applyGlobalMerge(ctx, 'new'), /请先启用/);
  await tx.activate(ctx, 'one.yaml');
  const prior = state.Current, priorBytes = data.get(prior.Path);
  controller.status = status.Connected;
  const global = '# common\nhosts: {example.invalid: 192.0.2.1}\n';
  await tx.previewGlobalMerge(ctx, global);
  assert.equal(state.Current.ID, prior.ID); assert.equal(versions.globalContent(ctx), '');
  const p = calls.at(-1); assert.equal(p.globalMerge, global); assert.equal(p.overlay, local);
  assert.equal(await tx.applyGlobalMerge(ctx, global), 'applied');
  assert.equal(versions.globalContent(ctx), global); assert.equal(state.Previous.ID, prior.ID);
  assert.equal(versions.globalMerge(ctx, state.Current), global); assert.equal(versions.overlay(ctx, state.Current), local);
  assert.equal(versions.original(ctx, state.Current), original);
  const beforeRejected = JSON.stringify(state);
  response = 'rejected'; await assert.rejects(tx.applyGlobalMerge(ctx, 'rejected'), /拒绝/);
  assert.equal(JSON.stringify(state), beforeRejected);
  response = 'applied'; failCommit = true;
  const previousRuntime = data.get(state.Current.Path), count = applied.length;
  await assert.rejects(tx.applyGlobalMerge(ctx, 'commit failure'), /VERSION_COMMIT_FAILED/);
  assert.equal(JSON.stringify(state), beforeRejected); assert.equal(applied.length, count + 2);
  assert.equal(applied.at(-1), previousRuntime, 'publish failure must restore previous runtime');
  await assert.rejects(tx.applyGlobalMerge(ctx, 'invalid'), /VERSION_COMPILE_FAILED/);
  assert.equal(JSON.stringify(state), beforeRejected);
  await tx.activate(ctx, 'two.yaml');
  assert.equal(versions.globalMerge(ctx, state.Current), global); assert.equal(versions.overlay(ctx, state.Current), '');
  await tx.update(ctx, 'two.yaml'); assert.equal(versions.globalMerge(ctx, state.Current), global);
  await tx.edit(ctx, 'two.yaml', original); assert.equal(versions.globalMerge(ctx, state.Current), global);
  await tx.saveMergeDraft(ctx, 'one.yaml', local);
  assert.equal(calls.at(-1).op, 'merge-preview'); assert.equal(calls.at(-1).updateGlobal, false);
  await tx.previewRegion(ctx, 'one.yaml', {mode:'region', selector:'Main', assignments:{}, enable:false});
  assert.equal(calls.at(-1).op, 'region-preview');
  controller.status = status.Disconnected;
  const upToDate = calls.length; await tx.ensureActiveSmartPolicy(ctx); assert.equal(calls.length, upToDate);
  const cached = prior; state.Current = cached; state.Profiles[cached.ProfileID] = cached; syncState();
  await tx.ensureActiveSmartPolicy(ctx); assert.equal(versions.globalMerge(ctx, state.Current), global);
  assert.notEqual(state.Current.ID, cached.ID, 'disconnected start must rebuild old-global source');
  const editor = new Editor(); editor.profileRevision = 0; editor.aboutToAppear();
  assert.equal(editor.globalEnabled, true); editor.changeText('draft only');
  const editorSource = fs.readFileSync(path.join(base, 'pages/GlobalMergeEditor.ets'), 'utf8');
  const textBinding = editorSource.match(/TextArea\(\{ text: (?:\$\$)?this\.(\w+)/)[1];
  const displayedText = () => editor[textBinding];
  assert.equal(displayedText(), 'draft only', 'a reactive redraw must bind the current draft');
  await editor.preview();
  assert.equal(displayedText(), 'draft only', 'preview must keep the visible input');
  assert.equal(editor.summary, 'rules: 1 → 2');
  assert.equal(draft.read(ctx), 'draft only');
  editor.changeText('draft only');
  const enabledState = JSON.stringify(state); let closed = 0; editor.onClose = () => closed++;
  failDraft = true; editor.close(); assert.equal(closed, 0);
  assert.equal(editor.editedText, 'draft only'); assert.equal(JSON.stringify(state), enabledState);
  failDraft = false; editor.close(); assert.equal(closed, 1); assert.equal(draft.read(ctx), 'draft only');
  assert.equal(JSON.stringify(state), enabledState);
  editor.changeText(''); await editor.apply(); assert.equal(versions.globalContent(ctx), '');
  assert.equal(versions.overlay(ctx, state.Current), local); assert.equal(editor.globalEnabled, false);
  failRead = true; const brokenEditor = new Editor(); brokenEditor.aboutToAppear();
  assert.equal(brokenEditor.loadFailed, true); brokenEditor.changeText('do not overwrite');
  assert.equal(brokenEditor.saveDraft(), false); failRead = false; assert.equal(draft.read(ctx), '');
  controller.status = status.Connected; response = 'unknown';
  const beforeUnknown = JSON.stringify(state);
  await assert.rejects(tx.applyGlobalMerge(ctx, 'unknown'), /应用未确认/);
  assert.equal(JSON.stringify(state), beforeUnknown); await assert.rejects(tx.activate(ctx, 'two.yaml'), /重连恢复/);
  assert.equal(data.get(prior.Path), priorBytes); assert.equal(originals.get('one.yaml'), original);
  const pageSource = fs.readFileSync(path.join(base, 'pages/ProfilePage.ets'), 'utf8');
  const closeBody = pageSource.match(/GlobalMergeEditor\(\{ onClose: \(\) => \{([^}]*)\}/)[1];
  const disappearBody = pageSource.slice(pageSource.lastIndexOf('.bindSheet('))
    .match(/onDisappear: \(\) => \{([^}]*)\}/)[1];
  const owner = { showSheet: true, sheetMode: 7 };
  const runCallback = body => vm.runInNewContext(`(function () {${body}}).call(owner)`, { owner, SHEET_NONE: 0 });
  runCallback(closeBody);
  assert.equal(owner.showSheet, false);
  assert.equal(owner.sheetMode, 7, 'closing keeps the content and height stable during the exit transition');
  runCallback(disappearBody);
  assert.equal(owner.sheetMode, 0, 'content is cleared after the sheet has disappeared');
  console.log('PASS: atomic global bridge/transaction flow, rejection/rollback/unknown, all generation paths, stale-start rebuild and inert draft/editor recovery');
})().catch(error => { console.error(error); process.exitCode = 1; });
