const uiFixture = require('./ci/ui-fixtures.cjs');
// Actual editor/page/root methods, synthetic storage failure; no device APIs.
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm'), path = require('node:path');
const ts = require('./ci/transpile-arkts.cjs');
const root = process.argv[2] || path.resolve(__dirname, '..');
const pages = path.join(root, 'cexing/entry/src/main/ets/pages');
let starts = 0, active = '';
let pending = null, takes = 0, diskFull = true, saved = '', transactionBusy = false, finishRegion;
const modules = {
  '../lib/ProfileApplyFeedback': require('./ci/semantic-fixture.cjs'),
  '../lib/UiText': { UiText: { get: () => 'draft save failed' } },
  '../lib/GlobalMergeDraft': { GlobalMergeDraft: { read: () => null, save: (_context, text) => {
    if (diskFull) throw Error('disk full'); saved = text;
  } } },
  '../lib/EffectiveVersions': { EffectiveVersions: { globalContent: () => 'previous', read: () => ({ Profiles: { 'one.yaml': {} } }),
    regionPlan: () => ({ mode: 'region', selector: 'main', assignments: {}, enable: false }) } },
  '../lib/AppRuntime': { AppRuntime: { cancelRestore() {} } },
  '../lib/VpnController': { VpnStatus: { Disconnected: 0, Connected: 2 }, VpnController: { status: 0, needsStop: () => false, start: () => { starts++; return true; } } },
  '../lib/ProfileStore': { ProfileStore: { getActiveFile: () => active } },
  '../lib/ProfileTransactions': { ProfileTransactions: { activate: async () => { active = 'one.yaml'; return 'saved'; }, ensureActiveSmartPolicy: async () => {}, isBusy: () => transactionBusy,
    previewRegion: () => new Promise(resolve => { finishRegion = resolve; }) } },
  '../lib/ProfileImportInput': { ProfileImportInput: { take: () => { takes++; const value = pending; pending = null; return value; }, release: () => {} } },
  '@kit.ArkUI': { promptAction: { showToast() {} } }
};
function load(name) {
  let code = fs.readFileSync(path.join(pages, name + '.ets'), 'utf8');
  const cut = code.indexOf('  @Builder');
  code = code.slice(0, cut >= 0 ? cut : code.indexOf('  build()')) + '\n}';
  code = code.split('\n').map(line => line.trimStart().startsWith('@') ? line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '') : line).join('\n');
  code = code.replace(/export struct /g, 'export class ').replace('struct Index', 'export class Index');
  const box = { exports: {}, getContext: () => ({}), NavPathStack: class {}, require: name => name.endsWith('/UiText') ? uiFixture.module : modules[name] || {} };
  Object.assign(box, uiFixture.globals); vm.runInNewContext(ts.transpileModule(code).outputText, box); return box.exports[name];
}
const Page = load('ProfilePage'), Editor = load('GlobalMergeEditor'), Index = load('Index');
const source = fs.readFileSync(path.join(pages, 'ProfilePage.ets'), 'utf8');
const sheet = source.slice(source.indexOf('.bindSheet('));
const start = sheet.indexOf('onDisappear: () => {') + 'onDisappear: () => {'.length;
let depth = 1, end = start;
while (depth > 0) { const char = sheet[end++]; if (char === '{') depth++; if (char === '}') depth--; }
const disappeared = new Function('SHEET_NONE', sheet.slice(start, end - 1));
function page() {
  const value = new Page(); value.pageVisible = true; value.rootVisible = true; value.currentVisibleTab = 1;
  value.pageGeneration = 1; value.profileRevision = 0; value.tabJump = -1; value.navStack = { getAllPathName: () => [] }; return value;
}
(async () => {
  const parent = page(); parent.showSheet = true; parent.sheetMode = 7;
  const editor = new Editor(); editor.aboutToAppear(); editor.changeText('unsaved-new-global');
  editor.onClose = () => { parent.showSheet = false; };
  editor.close(); assert.equal(parent.showSheet, true); assert.equal(editor.dirty, true);
  pending = { kind: 'url', value: 'https://example.invalid/queued' };
  parent.acceptExternalImport();
  assert.equal(parent.sheetMode, 7, 'external sharing must not replace a protected editor after its draft write fails');
  assert.ok(pending); assert.equal(takes, 0); assert.equal(editor.editedText, 'unsaved-new-global');
  diskFull = false; editor.close(); assert.equal(saved, 'unsaved-new-global');
  parent.acceptExternalImport(); assert.ok(pending, 'the closing sheet owns its content until disappearance');
  disappeared.call(parent, 0); assert.equal(parent.sheetMode, 2); assert.equal(parent.inputUrl, 'https://example.invalid/queued');
  assert.equal(takes, 1); assert.equal(pending, null);
  const region = page(); const reading = region.editRegion('one.yaml');
  pending = { kind: 'url', value: 'https://example.invalid/after-region' };
  region.acceptExternalImport(); assert.ok(pending, 'in-flight region opening owns the modal slot');
  finishRegion({ eligible: true, selectors: ['main'], nodes: {} }); await reading;
  assert.equal(region.showSheet, true); assert.notEqual(region.sheetMode, 2); assert.ok(pending);
  region.showSheet = false; disappeared.call(region, 0); assert.equal(region.inputUrl, 'https://example.invalid/after-region');
  const gone = page(); const oldRead = gone.editRegion('one.yaml'); gone.pageVisible = false; gone.importGeneration++;
  finishRegion({ eligible: true, selectors: ['main'], nodes: {} }); await oldRead;
  assert.equal(gone.showSheet, false, 'late region preview cannot reopen a hidden page');
  const busy = page(); transactionBusy = true; pending = { kind: 'url', value: 'https://example.invalid/transaction' };
  busy.acceptExternalImport(); assert.ok(pending); transactionBusy = false; busy.acceptExternalImport(); assert.equal(pending, null);
  const lateNavigation = page(); lateNavigation.activationRequest = 2; lateNavigation.showSheet = true; lateNavigation.sheetMode = 7;
  let refreshed = 0; lateNavigation.refresh = () => refreshed++;
  lateNavigation.finishActivationNavigation(2, 1, 1, []);
  assert.equal(lateNavigation.tabJump, -1, 'activation completion cannot hide a newly opened protected editor');
  assert.equal(refreshed, 0); assert.equal(lateNavigation.showSheet, true);
  const ready = page(); ready.showSheet = true; ready.sheetMode = 4; ready.importedFile = 'one.yaml'; ready.profiles = [{ file: 'one.yaml' }];
  pending = { kind: 'url', value: 'https://example.invalid/after-ready' };
  await ready.activateAndConnect();
  assert.equal(starts, 1, 'a queued share cannot cancel the current explicit connect decision');
  assert.equal(ready.inputUrl, 'https://example.invalid/after-ready'); assert.equal(pending, null);
  assert.equal(ready.sheetMode, 2); assert.equal(ready.tabJump, -1, 'the next queued confirmation stays on the subscription page');
  let clears = 0; const index = new Index(); index.navStack = { clear: () => clears++, getAllPathName: () => ['profileEdit'] };
  index.openImportEntry(); assert.equal(clears, 0, 'external import cannot bypass routed editors back/draft guards');
  assert.equal(index.currentVisibleTab, 1);
  console.log('PASS: failed global draft remains mounted; safe-close queue, region/transaction exclusion, stale region suppression and routed editor preservation');
})().catch(error => { console.error(error); process.exitCode = 1; });
