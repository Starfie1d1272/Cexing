// Execute production settings navigation and check the actual registered destination.
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs'), ui = require('./ci/ui-fixtures.cjs');
let source = fs.readFileSync('cexing/entry/src/main/ets/pages/SettingsPage.ets', 'utf8');
source = (source.slice(0, source.indexOf('  @Builder')) + '\n}').split('\n').map(line => line.trimStart().startsWith('@') ? line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '') : line).join('\n').replace('export struct ', 'export class ');
let profiles = [], active = '', paths = [], sheets, broken = false;
const bus = { file: '', section: 'rules' }, messages = [];
const modules = { '../lib/UiText': ui.module, '../lib/ProfileStore': { ProfileStore: {
  list: () => { if (broken) throw Error('private details'); return profiles; }, getActiveFile: () => active } },
  './RuleDnsEditorPage': { RuleDnsEditorBus: bus }, '@kit.ArkUI': { promptAction: { showToast: x => messages.push(x.message) } } };
const c = { exports: {}, ...ui.globals, require: key => modules[key] ?? {}, getContext: () => ({}), ActionSheet: { show: options => { sheets = options; } } };
vm.runInNewContext(ts.transpileModule(source).outputText, c);
const page = new c.exports.SettingsPage(); page.navStack = { getAllPathName: () => paths, pushPath: path => paths.push(path.name) };
page.ready = true; page.pageActive = true;
page.onRowTap({ action: 'dns' }); assert.match(messages.at(-1), /导入/); assert.equal(paths.length, 0); assert.equal(bus.section, 'rules');
profiles = [{ file: 'one.yaml', name: '%s-user' }]; page.openDns(); assert.deepEqual(paths, ['ruleDnsEditor']); assert.equal(bus.file, 'one.yaml'); assert.equal(bus.section, 'dns');
page.openDns(); assert.equal(paths.length, 1, 'repeated taps do not push duplicate destinations');
paths = []; profiles.push({ file: 'two.yaml', name: 'second' }); active = 'two.yaml'; page.openDns(); assert.equal(bus.file, 'two.yaml', 'the active subscription is addressed explicitly');
paths = []; active = ''; page.openDns(); assert.equal(sheets.sheets[0].title, '%s-user', 'user names are not reformatted'); const cancelled = sheets; sheets.cancel(); cancelled.sheets[0].action(); assert.equal(paths.length, 0);
page.openDns(); const old = sheets; page.openDns(); old.sheets[0].action(); assert.equal(paths.length, 0, 'older chooser cannot route');
const removed = sheets; profiles = profiles.slice(1); removed.sheets[0].action(); assert.equal(paths.length, 0); assert.match(messages.at(-1), /重试/);
profiles.push({file:'three.yaml',name:'third'});page.openDns();const hidden=sheets;page.aboutToDisappear();hidden.sheets[0].action();assert.equal(paths.length,0,'leaving invalidates chooser');
page.pageActive=true;broken=true;page.openDns();assert.equal(paths.length,0);assert.ok(!messages.at(-1).includes('private'));
const index = fs.readFileSync('cexing/entry/src/main/ets/pages/Index.ets', 'utf8'); assert.match(index, /name === 'ruleDnsEditor'[\s\S]*?RuleDnsEditorPage\(\{ visible: this.ruleDnsVisible/);
const editor = fs.readFileSync('cexing/entry/src/main/ets/pages/RuleDnsEditorPage.ets', 'utf8');assert.match(editor,/this\.file = RuleDnsEditorBus\.file; this\.section = RuleDnsEditorBus\.section/);
console.log('PASS: actual DNS settings entry, explicit subscription/section, real destination, empty/removed inputs, repeats, cancel and stale navigation');
