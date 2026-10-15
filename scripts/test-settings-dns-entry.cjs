// The settings screen addresses the host; subscription definitions stay in detail.
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs'), ui = require('./ci/ui-fixtures.cjs');
let source = fs.readFileSync('cexing/entry/src/main/ets/pages/SettingsPage.ets', 'utf8');
source = (source.slice(0, source.indexOf('  @Builder')) + '\n}').split('\n').map(line => line.trimStart().startsWith('@') ? line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '') : line).join('\n').replace('export struct ', 'export class ');
const c = { exports: {}, ...ui.globals, require: key => key.endsWith('/UiText') ? ui.module : {}, getContext: () => ({}) };
vm.runInNewContext(ts.transpileModule(source).outputText, c);
const page = new c.exports.SettingsPage(), paths = [];
page.navStack = { pushPath: path => paths.push(path.name) };
const rows = page.groups.flatMap(group => group.rows);
assert.ok(!rows.some(row => row.action === 'dns' || row.dest === 'resources'));
page.onRowTap(rows.find(row => row.dest === 'network'));
assert.deepEqual(paths, ['network']);
const profile = fs.readFileSync('cexing/entry/src/main/ets/pages/ProfilePage.ets', 'utf8');
assert.ok(profile.indexOf('this.openRuleDns(p.file)', profile.indexOf('if (this.moreActions)')) > 0);
const index = fs.readFileSync('cexing/entry/src/main/ets/pages/Index.ets', 'utf8');
assert.match(index, /name === 'ruleDnsEditor'[\s\S]*?RuleDnsEditorPage\(\{ visible: this.ruleDnsVisible/);
console.log('PASS: host settings keep network entry; per-subscription DNS remains under advanced editing');
