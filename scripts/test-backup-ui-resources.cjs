const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const read = locale => new Map(JSON.parse(fs.readFileSync(`cexing/entry/src/main/resources/${locale}/element/string.json`, 'utf8')).string.map(x => [x.name, x.value]));
const locales = { zh_CN: read('zh_CN'), base: read('base') };
for (const page of ['LocalBackupActions', 'ProfileStorageDetails']) {
  const source = fs.readFileSync(`cexing/entry/src/main/ets/pages/${page}.ets`, 'utf8');
  for (const [, key] of source.matchAll(/app\.string\.([A-Za-z0-9_]+)/g)) {
    assert.ok(locales.base.has(key), key); assert.ok(locales.zh_CN.has(key), key);
    assert.deepEqual(locales.base.get(key).match(/%[sd]/g), locales.zh_CN.get(key).match(/%[sd]/g), key);
  }
}
let locale = 'base';
const resourceManager = { getStringSync(id, ...args) { let i = 0; return locales[locale].get(id).replace(/%[sd]/g, () => String(args[i++])); } };
const c = { exports: {}, require: () => ({ application: { getApplicationContext: () => ({ resourceManager }) } }) };
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/UiText.ets', 'utf8')).outputText, c);
assert.equal(c.exports.UiText.get({ id: 'storage_summary' }, 3, '1.0'), '3 versions · 1.0 MiB');
assert.match(c.exports.UiText.get({ id: 'backup_restore_count' }, 2), /2 subscriptions/);
locale = 'zh_CN'; assert.equal(c.exports.UiText.get({ id: 'storage_summary' }, 3, '1.0'), '3 个版本 · 1.0 MiB');
console.log('PASS: backup/storage locale keys, formatter parameters and actual platform string boundary');
