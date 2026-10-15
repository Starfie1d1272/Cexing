// Actual transaction finalizers + visible ProfilePage subscription. Synthetic
// download/stage I/O; no manual queue consumption after transaction settlement.
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm'), path = require('node:path');
const ts = require('./ci/transpile-arkts.cjs');
const root = process.argv[2] || path.resolve(__dirname, '..');
let pending = null, finishDownload, failDownload, gate = 0, checks = 0;
let state = { Current: { ID: 'active' }, Profiles: {} }, serial = 0;
const controller = { status: 0, holdConfiguration: () => { gate++; return () => { gate--; }; }, configurationEpoch: () => 1 };
const store = { isApplyUncertain: () => false, getActiveFile: () => '', getEnabledMerge: () => '', prepareContent: value => value,
  downloadFromOrigin: () => new Promise((resolve, reject) => { finishDownload = resolve; failDownload = reject; }) };
const versions = { read: () => state, regionPlan: () => null, editIntent: () => null, stage: async () => ({ version: { ID: `version-${++serial}`, Path: 'synthetic-stage' }, receipt: 'receipt' }),
  verify: async () => 'receipt', commit: async (_context, version) => { state.Profiles['other.yaml'] = version; }, discard: async () => {} };
const mods = { './ProfileRegionChoices': { ProfileRegionChoices: { selector: () => '', prepare: async () => ({ state: { pending: '' }, observeRemoved: '' }), committed: async () => {} } }, './ProfileStore': { ProfileStore: store }, './EffectiveVersions': { EffectiveVersions: versions },
  './CoreValidator': { CoreValidator: { prepareResources: async () => {} } },
  './VpnController': { VpnStatus: { Disconnected: 0, Connected: 2 }, VpnController: controller },
  '@kit.CoreFileKit': { fileIo: { readTextSync: () => 'synthetic candidate' } }, './Settings': { Settings: { load: () => ({}), idle: async () => {} } } };
const txBox = { exports: {}, require: name => mods[name] || {} };
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, 'cexing/entry/src/main/ets/lib/ProfileTransactions.ets'), 'utf8')).outputText, txBox);
const tx = txBox.exports.ProfileTransactions;
const input = { take: () => { checks++; const candidate = pending; pending = null; return candidate; }, release() {} };
let source = fs.readFileSync(path.join(root, 'cexing/entry/src/main/ets/pages/ProfilePage.ets'), 'utf8');
let code = source.slice(0, source.indexOf('  @Builder')) + '\n}';
code = code.split('\n').map(line => line.trimStart().startsWith('@') ? line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '') : line).join('\n').replace('export struct ', 'export class ');
const pageBox = { exports: {}, getContext: () => ({}), NavPathStack: class {}, require: name => name.endsWith('/ProfileTransactions') ? { ProfileTransactions: tx } :
  name.endsWith('/ProfileImportInput') ? { ProfileImportInput: input } : {} };
vm.runInNewContext(ts.transpileModule(code).outputText, pageBox);
const Page = pageBox.exports.ProfilePage;
function page() { const p = new Page(); p.refresh = () => {}; p.profileRevision = 0; p.rootVisible = true; p.currentVisibleTab = 1;
  p.navStack = { getAllPathName: () => [] }; p.aboutToAppear(); return p; }
const sheet = source.slice(source.indexOf('.bindSheet('));
const start = sheet.indexOf('onDisappear: () => {') + 'onDisappear: () => {'.length;
let depth = 1, end = start;
while (depth > 0) { const char = sheet[end++]; if (char === '{') depth++; if (char === '}') depth--; }
const disappeared = new Function('SHEET_NONE', sheet.slice(start, end - 1));
function background(outcome) { return tx.update({}, 'other.yaml', () => outcome !== 'cancel'); }
async function settle(result, outcome) {
  if (outcome === 'failure') { failDownload(Error('synthetic download failed')); await assert.rejects(result, /download failed/); }
  else { finishDownload({ content: 'synthetic original', meta: {} }); if (outcome === 'cancel') await assert.rejects(result, /取消/); else assert.equal(await result, 'saved'); }
}
(async () => {
  const watchIdle = tx.onIdle ?? (() => () => {}); // permits semantic replay against the original implementation
  let observed = 0;
  const unsubscribe = watchIdle(() => { observed++; assert.equal(gate, 0); assert.equal(tx.isBusy(), false); });
  const stopThrowing = watchIdle(() => { throw Error('synthetic observer failure'); });
  for (const outcome of ['success', 'failure', 'cancel']) {
    const p = page();
    const operation = background(outcome); // held on the actual asynchronous download
    assert.equal(tx.isBusy(), true);
    const url = `https://example.invalid/${outcome}`; pending = { kind: 'url', value: url }; p.acceptExternalImport();
    assert.ok(pending); await settle(operation, outcome);
    assert.equal(tx.isBusy(), false); assert.equal(pending, null); assert.equal(p.inputUrl, url); assert.equal(p.showSheet, true);
    p.aboutToDisappear();
  }
  assert.equal(observed, 3); unsubscribe(); unsubscribe(); stopThrowing();
  const protectedPage = page(); protectedPage.showSheet = true; protectedPage.sheetMode = 7; protectedPage.inputUrl = 'existing draft';
  const settling = background('failure'); pending = { kind: 'url', value: 'https://example.invalid/protected' }; protectedPage.acceptExternalImport(); await settle(settling, 'failure');
  assert.ok(pending); assert.equal(protectedPage.sheetMode, 7); assert.equal(protectedPage.inputUrl, 'existing draft');
  protectedPage.showSheet = false; disappeared.call(protectedPage, 0); assert.equal(protectedPage.inputUrl, 'https://example.invalid/protected'); protectedPage.aboutToDisappear();
  const hidden = page(), leaving = background('cancel'); pending = { kind: 'url', value: 'https://example.invalid/return' }; hidden.acceptExternalImport();
  hidden.aboutToDisappear(); const before = checks; await settle(leaving, 'cancel');
  assert.ok(pending); assert.equal(checks, before, 'departed pages release the observer');
  hidden.aboutToAppear(); assert.equal(pending, null); assert.equal(hidden.inputUrl, 'https://example.invalid/return'); hidden.aboutToDisappear();
  assert.equal(observed, 3, 'unsubscribed observers stay released');
  console.log('PASS: real background transaction success/failure/cancel wakes pending shares automatically, after gate release, with draft/hidden-page protection and isolated observers');
})().catch(error => { console.error(error); process.exitCode = 1; });
