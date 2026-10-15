const uiFixture = require('./ci/ui-fixtures.cjs');
// Actual page methods with synthetic large text; no native rendering/device claim.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const ts = require('./ci/transpile-arkts.cjs');
let source = fs.readFileSync(path.join(__dirname, '../cexing/entry/src/main/ets/pages/ProfileEditPage.ets'), 'utf8');
assert.ok(!source.includes('text: $$this.text'), 'keystrokes must not update the reactive document seed');
source = source.slice(0, source.indexOf('  @Builder')) + '\n}';
source = source.split('\n').map(line => line.trimStart().startsWith('@') ?
  line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '') : line).join('\n')
  .replace(/export struct /g, 'export class ');
const timers = new Map(), drafts = new Map(), merges = new Map(), writes = [], edits = [], copies = [], toasts = [];
const original = '# 注释 😀\r\nproxies: []\r\nrules: [MATCH,DIRECT]\r\n\r\n';
const originals = new Map([['first.yaml', original], ['next.yaml', 'next']]);
let timerID = 0, failWrite = false, failClear = false, failEdit = false, finishEdit;
const store = {
  getProfileContent: (_, file) => originals.get(file) ?? null,
  getMergeDraft: (_, file) => merges.get(file) ?? '',
  saveMergeDraft: (_, file, text) => { if (failWrite) throw Error('disk full'); merges.set(file, text); },
  readDraft: (_, file) => drafts.get(file) ?? null,
  writeDraft: (_, file, text) => {
    if (failWrite) throw Error('disk full');
    writes.push({ file, text }); drafts.set(file, text);
  },
  clearDraft: (_, file) => { if (failClear) throw Error('disk full'); drafts.delete(file); },
  importContent: (_, name, text) => { copies.push({ name, text }); return name; }
};
const modules = {
  './NativeTheme': {}, '@kit.ArkUI': { promptAction: { showToast: value => toasts.push(value.message) } },
  '../lib/ProfileStore': { ProfileStore: store },
  '../lib/ProfileTransactions': { ProfileTransactions: { edit: async (_, file, text) => {
    edits.push({ file, text });
    if (failEdit) throw Error('rejected');
    if (finishEdit === null) await new Promise(resolve => { finishEdit = resolve; });
    originals.set(file, text); return 'saved';
  } } },
  '../lib/Logger': { Logger: { warn() {} } }
};
const sandbox = { exports: {}, getContext: () => ({}),
  require: name => { assert.ok(name in modules, name); return modules[name]; },
  setTimeout: (fn, delay) => { assert.equal(delay, 600); timers.set(++timerID, fn); return timerID; },
  clearTimeout: id => timers.delete(id)
};
Object.assign(sandbox, uiFixture.globals); modules['../lib/UiText'] = uiFixture.module;
vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
} }).outputText, sandbox);
const { ProfileEditPage, ProfileEditBus } = sandbox.exports;
function open(file = 'first.yaml') {
  ProfileEditBus.current = file;
  const page = new ProfileEditPage(); page.profileRevision = 0; page.aboutToAppear(); return page;
}
function idle() { const pending = [...timers.values()]; timers.clear(); pending.forEach(fn => fn()); }
(async () => {
  const page = open();
  page.onTextChanged(original); idle();
  assert.equal(page.dirty, false, 'initial native text feedback is not an edit');
  assert.equal(writes.length, 0);
  const large = original + '# 合成长订阅 😀\r\n'.repeat(60000);
  const seed = page.text, revision = page.editorRevision;
  for (let i = 0; i < 200; i++) page.onTextChanged(large + i);
  assert.equal(writes.length, 0, 'continuous input must not synchronously write full drafts');
  assert.equal(timers.size, 1); assert.equal(page.text, seed); assert.equal(page.editorRevision, revision);
  assert.equal(page.draftPending, true); assert.equal(page.draftPersisted, false);
  idle(); assert.equal(writes.length, 1); assert.equal(writes[0].text, large + 199);
  assert.equal(page.draftPersisted, true);
  const final = large + '\r\n  # 最后一次修改  \r\n';
  page.onTextChanged(final);
  ProfileEditBus.current = 'next.yaml'; // navigation bus can change before old page disappears
  page.aboutToDisappear();
  assert.equal(timers.size, 0); assert.equal(drafts.get('first.yaml'), final);
  assert.equal(drafts.has('next.yaml'), false);
  const restored = open(); assert.equal(restored.editedText, final); assert.equal(restored.dirty, true);
  restored.saveAsInput = 'copy.yaml'; restored.saveAs(); assert.equal(copies[0].text, final);
  restored.onTextChanged(final + '# pending'); restored.discardDraft(); idle();
  assert.equal(restored.editedText, original); assert.equal(restored.text, original);
  assert.equal(restored.editorRevision, 1, 'discard must reset native text even when its seed is unchanged');
  assert.equal(restored.dirty, false); assert.equal(drafts.has('first.yaml'), false);
  restored.onTextChanged(original); idle();
  assert.equal(restored.dirty, false, 'discard feedback must not recreate a draft');
  assert.equal(drafts.has('first.yaml'), false);
  failWrite = true; restored.onTextChanged(final); idle();
  assert.equal(restored.draftPersisted, false); assert.equal(restored.dirty, true);
  assert.ok(toasts.includes('草稿保存失败，请先保存配置'));
  failWrite = false; restored.aboutToDisappear(); assert.equal(drafts.get('first.yaml'), final);
  failEdit = true; await restored.save();
  assert.equal(originals.get('first.yaml'), original); assert.equal(restored.dirty, true);
  assert.equal(drafts.get('first.yaml'), final);
  failEdit = false; finishEdit = null;
  const pendingSave = restored.save();
  assert.equal(edits.at(-1).text, final);
  const newer = final + '# typed during save\r\n'; restored.onTextChanged(newer);
  restored.discardDraft(); assert.equal(restored.editedText, newer, 'discard cannot race an in-flight save');
  finishEdit(); await pendingSave; idle();
  assert.equal(originals.get('first.yaml'), final); assert.equal(restored.dirty, true);
  assert.equal(drafts.get('first.yaml'), newer);
  await restored.save(); idle(); assert.equal(originals.get('first.yaml'), newer);
  assert.equal(restored.dirty, false); assert.equal(drafts.has('first.yaml'), false); assert.equal(timers.size, 0);
  restored.onTextChanged('keep me'); failClear = true; restored.discardDraft(); idle();
  assert.equal(restored.editedText, 'keep me'); assert.equal(drafts.get('first.yaml'), 'keep me');
  failClear = false;
  const merge = open(); merge.mergeOnly = true;
  let pops = 0, replaced = '';
  merge.navStack = { pop: () => pops++, replacePath: value => { replaced = value.name; } };
  merge.mergeText = 'hosts: {synthetic: 192.0.2.1}\n';
  merge.closeMerge(); assert.equal(pops, 1);
  merge.aboutToDisappear();
  const reopenMerge = open(); assert.equal(reopenMerge.mergeText, merge.mergeText,
    'closing without preview preserves exact scoped override draft');
  reopenMerge.mergeText = '# back gesture draft\n'; reopenMerge.aboutToDisappear();
  assert.equal(open().mergeText, '# back gesture draft\n', 'navigation back also preserves override text');
  merges.set('first.yaml', 'keep override');
  const dirtyMerge = open(); dirtyMerge.mergeOnly = true;
  dirtyMerge.navStack = merge.navStack;
  dirtyMerge.onTextChanged('uncommitted original'); dirtyMerge.flushDraft();
  dirtyMerge.mergeText = 'keep changed override';
  dirtyMerge.openOriginalDraft();
  assert.equal(replaced, 'profileEdit', 'dirty original has an actionable raw-editor route');
  assert.equal(drafts.get('first.yaml'), 'uncommitted original', 'opening original must preserve its draft');
  assert.equal(merges.get('first.yaml'), 'keep changed override');
  const recoveredRaw = open(); assert.equal(recoveredRaw.dirty, true);
  assert.equal(recoveredRaw.editedText, 'uncommitted original');
  failWrite = true; dirtyMerge.mergeText = 'retry override';
  dirtyMerge.closeMerge(); assert.equal(pops, 1, 'failed save keeps the explicit close action on page');
  assert.equal(merges.get('first.yaml'), 'keep changed override'); failWrite = false;
  merges.set('first.yaml', 'previous override');
  const systemBack = open(); systemBack.mergeOnly = true;
  systemBack.mergeText = 'unsaved override after system back';
  failWrite = true;
  assert.equal(ProfileEditBus.shouldBlockBack(), true, 'production back guard blocks exit when either draft cannot be saved');
  assert.equal(systemBack.mergeText, 'unsaved override after system back');
  assert.equal(merges.get('first.yaml'), 'previous override');
  failWrite = false;
  assert.equal(ProfileEditBus.shouldBlockBack(), false, 'retrying system back after recovery persists the draft before exit');
  systemBack.aboutToDisappear();
  assert.equal(open().mergeText, 'unsaved override after system back');
  const routeSource = fs.readFileSync(path.join(__dirname, '../cexing/entry/src/main/ets/pages/Index.ets'), 'utf8');
  assert.equal((routeSource.match(/onBackPressed\(\(\) => ProfileEditBus\.shouldBlockBack\(\)\)/g) || []).length, 2,
    'raw and direct merge NavDestinations both use the production return guard');
  const missing = open('missing.yaml'); await missing.save(); assert.equal(missing.loadFailed, true);
  console.log('PASS: large-text write coalescing, stable reactive seed, exact draft/save/copy, navigation flush, discard, recovery and save races');
})().catch(error => { console.error(error); process.exitCode = 1; });
