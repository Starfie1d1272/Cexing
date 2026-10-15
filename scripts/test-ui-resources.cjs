// Native resources and their string-only API boundary; no device/layout assertion.
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const read = locale => new Map(JSON.parse(fs.readFileSync(`cexing/entry/src/main/resources/${locale}/element/string.json`, 'utf8')).string.map(x => [x.name, x.value]));
const locales = { zh_CN: read('zh_CN'), base: read('base') };
const pages = ['HomePage', 'Index', 'SettingsPage', 'BackgroundNotice', 'SettingsReconnectButton', 'SmartPage', 'LiveViewStrategyPicker', 'ResourceRecoveryPage', 'DiagnosticsPage', 'GlobalMergeEditor', 'NetworkSettingsPage', 'OverridePage', 'ProfileEditPage', 'ProfileGeneratedPage', 'TrafficPage', 'ZashboardPage'];
for (const name of pages) {
  const source = fs.readFileSync(`cexing/entry/src/main/ets/pages/${name}.ets`, 'utf8');
  for (const match of source.matchAll(/app\.string\.([A-Za-z0-9_]+)/g)) {
    const key = match[1]; assert.ok(locales.base.has(key), key); assert.ok(locales.zh_CN.has(key), key);
    const parameters = value => (value.match(/%[sd]/g) || []).join();
    assert.equal(parameters(locales.base.get(key)), parameters(locales.zh_CN.get(key)), key + ' locale arguments');
  }
}
let locale = 'zh_CN'; const calls = [];
const resourceManager = { getStringSync: (id, ...args) => {
  calls.push({ id, args }); let n = 0; return locales[locale].get(id).replace(/%[sd]/g, () => String(args[n++]));
} };
const c = { exports: {}, require: () => ({ application: { getApplicationContext: () => ({ resourceManager }) } }) };
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/UiText.ets', 'utf8')).outputText, c);
assert.equal(c.exports.UiText.get({ id: 'action_retry' }), '重试');
locale = 'base'; assert.equal(c.exports.UiText.get({ id: 'action_retry' }), 'Retry');
assert.equal(c.exports.UiText.get({ id: 'a11y_current_profile' }, '%s-user'), 'Current subscription: %s-user');
assert.deepEqual(calls.at(-1).args, ['%s-user']);
console.log('PASS: matching locale resources/format arguments and actual platform string boundary, without user-text reformatting');
