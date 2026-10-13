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
const timers = new Map(), drafts = new Map(), writes = [], edits = [], copies = [], toasts = [];
const original = '# 注释 😀\r\nproxies: []\r\nrules: [MATCH,DIRECT]\r\n\r\n';
const originals = new Map([['first.yaml', original], ['next.yaml', 'next']]);
let timerID = 0, failWrite = false, failClear = false, failEdit = false, finishEdit;
const store = {
  getProfileContent: (_, file) => originals.get(file) ?? null,
  getMergeDraft: () => '', readDraft: (_, file) => drafts.get(file) ?? null,
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
  const missing = open('missing.yaml'); await missing.save(); assert.equal(missing.loadFailed, true);
  console.log('PASS: large-text write coalescing, stable reactive seed, exact draft/save/copy, navigation flush, discard, recovery and save races');
})().catch(error => { console.error(error); process.exitCode = 1; });
