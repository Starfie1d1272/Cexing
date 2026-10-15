const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
let code = fs.readFileSync('cexing/entry/src/main/ets/pages/ProfileTemplatePage.ets', 'utf8');
code = code.slice(0, code.indexOf('  build()')) + '\n}';
code = code.split('\n').map(line => line.trimStart().startsWith('@') ?
  line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '') : line).join('\n').replace('export struct ', 'export class ');
const created = [];
const sandbox = { exports: {}, getContext: () => ({}), require: name => name.includes('EditorDraftHosts') ?
  { EditorDraftHosts: { create: (_context, file) => { const host = { file }; created.push(host); return host; } } } : {} };
vm.runInNewContext(ts.transpileModule(code).outputText, sandbox);
const { ProfileTemplatePage: Page, ProfileTemplateBus: Bus } = sandbox.exports;
Bus.file = 'one.yaml';
const page = new Page(); page.profileRevision = 0; page.aboutToAppear();
assert.equal(created.length, 0, 'hidden navigation cannot create an editing session');
page.visible = true; page.visibilityChanged();
assert.equal(created.length, 1); assert.equal(page.editor.file, 'one.yaml');
const editor = page.editor; page.visibilityChanged(); assert.equal(page.editor, editor);
Bus.file = 'two.yaml'; page.visible = false; page.visibilityChanged();
assert.equal(page.profileRevision, 1, 'returning refreshes subscription details from committed state');
assert.equal(page.ready, false); assert.equal(page.editor, undefined, 'hidden wizard is unmounted and its model closes');
page.visible = true; page.visibilityChanged();
assert.equal(page.editor.file, 'one.yaml', 'an existing route cannot adopt another selected profile');
assert.notEqual(page.editor, editor, 'returning starts a fresh identity-bound session');
page.aboutToDisappear(); assert.equal(page.editor, undefined);
const other = new Page(); other.visible = true; other.aboutToAppear();
assert.equal(other.editor.file, 'two.yaml');
console.log('PASS: real template route visibility, stable profile, single host instance, hidden unmount and fresh return session');
