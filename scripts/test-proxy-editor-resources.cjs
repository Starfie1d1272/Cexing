const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const { resourceContext } = require('./ci/mock-profile-resources.cjs');
const tables = ['base', 'zh_CN'].map(locale => new Map(JSON.parse(fs.readFileSync(
  `cexing/entry/src/main/resources/${locale}/element/string.json`, 'utf8')).string.map(item => [item.name, item.value])));
const prefix = /^proxy_(editor|form)_/;
for (const [name, value] of tables[0]) {
  if (!prefix.test(name)) continue;
  assert.ok(tables[1].has(name), name);
  assert.deepEqual(value.match(/%[sd]/g) || [], tables[1].get(name).match(/%[sd]/g) || [], name);
}
const source = fs.readFileSync('cexing/entry/src/main/ets/lib/ProxyEditorText.ets', 'utf8');
const box = { exports: {} }; vm.runInNewContext(ts.transpileModule(source).outputText, box);
const text = box.exports.ProxyEditorText;
assert.equal(text.text(resourceContext(), 'proxy_editor_loaded_count', 12), '已加载 12 个节点');
assert.equal(text.text(resourceContext('base'), 'proxy_editor_loaded_count', 1), 'Loaded nodes: 1');
assert.equal(text.text(resourceContext(), 'proxy_editor_change_count', '节点', 1, 2), '节点 1 → 2');
assert.match(text.failure(resourceContext('base'), '端口应为 1–65535'), /65535/);
assert.ok(!text.failure(resourceContext(), 'private-token-not-for-display').includes('private-token'));
for (const name of ['ProfileProxyEditorPage', 'ProxyMappingFormPage']) {
  const code = fs.readFileSync(`cexing/entry/src/main/ets/pages/${name}.ets`, 'utf8');
  assert.equal(/'[^'\n]*[\u4e00-\u9fff][^'\n]*'/.test(code), false, name + ' uses resources for visible Chinese');
  for (const key of code.matchAll(/'(proxy_(?:editor|form)_[a-z_]+)'|app\.string\.(proxy_(?:editor|form)_[a-z_]+)/g)) {
    assert.ok(tables[0].has(key[1] || key[2]), key[1] || key[2]);
  }
}
console.log('PASS: bilingual resource keys/placeholders, formatted counts, safe localized errors and editor resource coverage');
